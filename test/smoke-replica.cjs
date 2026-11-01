// Run with Nix-provided Node and an explicit akyuu binary. No remote or live store.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawn, spawnSync } = require('node:child_process');
const { once } = require('node:events');

const binary = process.argv[2];
assert.ok(binary, 'Pass the akyuu executable path.');
const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'akyuu-replica-smoke-'));
const root = path.join(temporary, 'repository');
const env = Object.fromEntries(Object.entries(process.env).filter(([key]) => !key.startsWith('AKYUU_')));
env.AKYUU_CONFIG = path.join(temporary, 'absent-config.toml');
let server;
let stderr = '';
const pending = new Map();
let sequence = 0;

function cli(args, expected = 0) {
  const result = spawnSync(binary, ['--root', root, ...args], { env, encoding: 'utf8', timeout: 5000 });
  assert.ifError(result.error);
  assert.equal(result.status, expected, result.stderr || result.stdout);
  return result;
}

function jsonCli(args, expected = 0) {
  return JSON.parse(cli([...args, '--json'], expected).stdout);
}

function rpc(method, params) {
  const id = ++sequence;
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      pending.delete(id);
      reject(new Error(`MCP request ${method} timed out. ${stderr}`));
    }, 5000);
    pending.set(id, { resolve, reject, timer });
    server.stdin.write(JSON.stringify({ jsonrpc: '2.0', id, method, params }) + '\n');
  });
}

async function tool(name, args) {
  const response = await rpc('tools/call', { name, arguments: args });
  assert.ok(response.result, JSON.stringify(response));
  return response.result;
}

async function main() {
  assert.equal(jsonCli(['replica', 'init', '--label', 'smoke']).status, 'ready');
  const created = jsonCli(['replica', 'create', 'me/topic', '--kind', 'fact', '--agent', 'test', '--body', 'first']);
  assert.equal(created.status, 'resolved');
  assert.equal(created.heads[0].body, 'first');
  const replaced = jsonCli(['replica', 'replace', 'me/topic', '--expected', created.version, '--kind', 'fact', '--agent', 'test', '--body', 'second']);
  const stale = jsonCli(['replica', 'replace', 'me/topic', '--expected', created.version, '--kind', 'fact', '--agent', 'test', '--body', 'lost update'], 1);
  assert.equal(stale.error, 'stale-version');
  assert.equal(stale.topic.heads[0].body, 'second');
  const selected = jsonCli(['replica', 'resolve', 'me/topic', '--expected', replaced.version, '--select', replaced.heads[0].memory]);
  assert.equal(selected.heads[0].memory, replaced.heads[0].memory);
  assert.notEqual(selected.version, replaced.version);
  const merged = jsonCli(['replica', 'resolve', 'me/topic', '--expected', selected.version, '--kind', 'fact', '--agent', 'test', '--body', 'merged']);
  assert.equal(merged.heads[0].body, 'merged');
  assert.equal(jsonCli(['replica', 'read', 'me/topic']).version, merged.version);

  assert.match(cli(['get', '--ref', 'me/topic'], 1).stderr, /checkpoint repository/);
  assert.match(cli(['mcp', '--tool-set', 'replicated', '--policy-ref', 'me/policy'], 1).stderr, /does not expand/);
  for (const name of ['store', 'refs', 'cache.sqlite']) assert.equal(fs.existsSync(path.join(root, name)), false);

  server = spawn(binary, ['--root', root, 'mcp', '--tool-set', 'replicated'], { env, stdio: ['pipe', 'pipe', 'pipe'] });
  let buffer = '';
  server.stdout.setEncoding('utf8');
  server.stderr.setEncoding('utf8');
  server.stderr.on('data', data => { stderr = (stderr + data).slice(-16000); });
  server.stdout.on('data', data => {
    buffer += data;
    for (;;) {
      const newline = buffer.indexOf('\n');
      if (newline < 0) break;
      const line = buffer.slice(0, newline);
      buffer = buffer.slice(newline + 1);
      let response;
      try { response = JSON.parse(line); }
      catch (error) {
        for (const request of pending.values()) { clearTimeout(request.timer); request.reject(error); }
        pending.clear();
        return;
      }
      const request = pending.get(response.id);
      if (request) {
        pending.delete(response.id);
        clearTimeout(request.timer);
        request.resolve(response);
      }
    }
  });
  server.on('error', error => {
    for (const request of pending.values()) { clearTimeout(request.timer); request.reject(error); }
    pending.clear();
  });
  const initial = await rpc('initialize', { protocolVersion: '2025-03-26', clientInfo: { name: 'Smoke Test' } });
  assert.match(initial.result.instructions, /opaque version/);
  const listed = await rpc('tools/list', {});
  assert.equal(listed.result.tools.length, 6);
  assert.equal(listed.result.tools.some(tool => tool.name === 'supersede'), false);
  const read = await tool('topic_read', { ref: 'me/topic' });
  assert.equal(read.structuredContent.heads[0].body, 'merged');
  assert.deepEqual(JSON.parse(read.content[0].text), read.structuredContent);
  const made = await tool('topic_create', { ref: 'me/other', kind: 'fact', body: 'from MCP' });
  assert.equal(made.isError, false);
  assert.equal(made.structuredContent.heads[0].agent, 'smoke-test');
  const context = await tool('topic_context', { refs: ['me/topic', 'me/missing'] });
  assert.deepEqual(context.structuredContent.topics.map(topic => topic.status), ['missing', 'resolved']);
  assert.ok(context.structuredContent.topics.every(topic => topic.checkpoint === context.structuredContent.checkpoint));
  const conflict = await tool('topic_replace', { ref: 'me/topic', expected: created.version, kind: 'fact', body: 'stale' });
  assert.equal(conflict.isError, true);
  assert.equal(conflict.structuredContent.error, 'stale-version');
  const unavailable = await rpc('tools/call', { name: 'supersede', arguments: {} });
  assert.equal(unavailable.error.code, -32602);
  const finished = once(server, 'exit');
  server.stdin.end();
  const [code] = await Promise.race([finished, new Promise((_, reject) => {
    const timer = setTimeout(() => reject(new Error('MCP shutdown timed out.')), 3000);
    timer.unref();
  })]);
  assert.equal(code, 0, stderr);
  server = undefined;
  console.log('Replica CLI and MCP smoke passed.');
}

main().catch(error => { console.error(error); process.exitCode = 1; }).finally(() => {
  if (server) server.kill('SIGKILL');
  for (const request of pending.values()) clearTimeout(request.timer);
  fs.rmSync(temporary, { recursive: true, force: true });
});

// Run with Nix-provided Node and an explicit akyuu binary. No remote or live store.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawn, spawnSync } = require('node:child_process');
const { once } = require('node:events');
const http = require('node:http');

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
  const result = spawnSync(binary, ['--root', root, ...args], { env, encoding: 'utf8', timeout: 5000, maxBuffer: 16000000 });
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
  jsonCli(['replica', 'create', 'policy/memory', '--kind', 'instruction', '--agent', 'test', '--body', 'Keep all concurrent heads.']);
  jsonCli(['replica', 'create', 'policy/tiers', '--kind', 'config', '--agent', 'test', '--body', 'always: me/topic']);
  assert.equal(jsonCli(['replica', 'configured-context']).ready, true);
  assert.equal(jsonCli(['replica', 'search', 'merged']).hits.length, 1);
  for (const name of ['store', 'refs', 'cache.sqlite']) assert.equal(fs.existsSync(path.join(root, name)), false);

  server = spawn(binary, ['--root', root, 'mcp', '--tool-set', 'replicated', '--policy-ref', 'policy/memory', '--tiers-ref', 'policy/tiers'], { env, stdio: ['pipe', 'pipe', 'pipe'] });
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
  assert.equal(listed.result.tools.length, 21);
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
  const configured = await tool('configured_context', {});
  assert.equal(configured.structuredContent.ready, true);
  const found = await tool('topic_search', { query: 'merged' });
  assert.equal(found.structuredContent.hits.length, 1);
  const conflict = await tool('topic_replace', { ref: 'me/topic', expected: created.version, kind: 'fact', body: 'stale' });
  assert.equal(conflict.isError, true);
  assert.equal(conflict.structuredContent.error, 'stale-version');
  const unavailable = await rpc('tools/call', { name: 'supersede', arguments: {} });
  assert.equal(unavailable.error.code, -32602);
  const missingLog = await tool('topic_read', { ref: 'me/log' });
  const episodeA = await tool('log_append', { ref: 'me/log', expected: missingLog.structuredContent.version, kind: 'note', body: 'episode a' });
  assert.equal(episodeA.isError, false);
  assert.equal(episodeA.structuredContent.heads[0].agent, 'smoke-test');
  const episodeB = jsonCli(['replica', 'append', 'me/log', '--expected', episodeA.structuredContent.version, '--kind', 'note', '--agent', 'test', '--body', 'episode b']);
  const log = await tool('log_read', { ref: 'me/log', limit: 1 });
  assert.equal(log.structuredContent.complete, false);
  assert.equal(log.structuredContent.entries.length, 1);
  assert.deepEqual(log.structuredContent.frontier, [episodeA.structuredContent.heads[0].memory]);
  const levels = jsonCli(['replica', 'log-levels', 'me/log']);
  const summary = await tool('log_summarise', { ref: 'me/log', expected: levels.version, level: 1, sources: [episodeA.structuredContent.heads[0].memory, episodeB.heads[0].memory], kind: 'summary', body: 'both episodes' });
  assert.equal(summary.isError, false, JSON.stringify(summary));
  const staleSummary = await tool('log_summarise', { ref: 'me/log', expected: levels.version, level: 1, sources: [episodeA.structuredContent.heads[0].memory, episodeB.heads[0].memory], kind: 'summary', body: 'stale' });
  assert.equal(staleSummary.isError, true);
  const compressed = jsonCli(['replica', 'log-resolution', 'me/log', '--keep', '0']);
  assert.equal(compressed.view.entries.length, 1);
  assert.equal(compressed.view.entries[0].level, 1);
  const expanded = await tool('log_unfold', { id: summary.structuredContent.heads[0].memory });
  assert.equal(expanded.structuredContent.entries.length, 2);
  const todo = await tool('log_todo', { ref: 'me/log', size: 2, keep: 0 });
  assert.deepEqual(todo.structuredContent.runs, []);
  const wholeLog = jsonCli(['replica', 'log', 'me/log']);
  assert.equal(wholeLog.complete, true);
  assert.equal(wholeLog.entries.length, 2);
  const sources = jsonCli(['replica', 'unfold', summary.structuredContent.heads[0].memory]);
  assert.equal(sources.entries.length, 2);
  const refreshed = await tool('log_levels', { ref: 'me/log' });
  const cliSummary = jsonCli(['replica', 'summarise', 'me/log', '--expected', refreshed.structuredContent.version, '--level', '1', '--source', episodeA.structuredContent.heads[0].memory, '--source', episodeB.heads[0].memory, '--kind', 'summary', '--agent', 'test', '--body', 'CLI summary']);
  assert.equal(cliSummary.status, 'log');
  const mcpView = await tool('log_resolution', { ref: 'me/log', keep: 0 });
  assert.equal(mcpView.structuredContent.view.entries.length, 1);
  const cliTodo = jsonCli(['replica', 'log-todo', 'me/log', '--size', '2', '--keep', '0']);
  assert.equal(cliTodo.runs.length, 1);
  assert.equal(cliTodo.runs[0].level, 2);
  const memoryA = created.heads[0].memory;
  const memoryB = replaced.heads[0].memory;
  const noPin = await tool('pin_state', { id: memoryA });
  assert.equal(noPin.structuredContent.pinned, false);
  const pinned = await tool('pin_set', { id: memoryA, expected: noPin.structuredContent.version });
  assert.equal(pinned.structuredContent.pinned, true);
  const pinRead = jsonCli(['replica', 'pin-state', memoryA]);
  assert.equal(pinRead.pinned, true);
  const unpinned = jsonCli(['replica', 'unpin', memoryA, '--expected', pinRead.version]);
  assert.equal(unpinned.pinned, false);
  const repinned = jsonCli(['replica', 'pin', memoryA, '--expected', unpinned.version]);
  const pinCleared = await tool('pin_clear', { id: memoryA, expected: repinned.version });
  assert.equal(pinCleared.structuredContent.pinned, false);
  const noReview = await tool('review_state', { a: memoryA, b: memoryB });
  const reviewed = await tool('review_set', { a: memoryA, b: memoryB, expected: noReview.structuredContent.version, reason: 'Distinct versions.' });
  assert.equal(reviewed.isError, false, JSON.stringify(reviewed));
  assert.equal(reviewed.structuredContent.records[0].author, 'smoke-test');
  const reviewRead = jsonCli(['replica', 'review-state', memoryB, memoryA]);
  assert.equal(reviewRead.reviewed, true);
  const clearedReview = jsonCli(['replica', 'unreview', memoryA, memoryB, '--expected', reviewRead.version]);
  assert.equal(clearedReview.reviewed, false);
  const reviewFromCli = jsonCli(['replica', 'review', memoryA, memoryB, '--expected', clearedReview.version, '--agent', 'test', '--reason', 'Still distinct.']);
  const finalReview = await tool('review_clear', { a: memoryB, b: memoryA, expected: reviewFromCli.version });
  assert.equal(finalReview.structuredContent.reviewed, false);
  const localArchive = jsonCli(['replica', 'archive']);
  assert.match(localArchive.archived_checkpoint, /^sha256-/);
  const gcPlan = jsonCli(['replica', 'gc', '--dry-run', '--keep-generations', '1']);
  assert.deepEqual(gcPlan.candidates, [], 'Unpublished data must stay active even after local archive.');
  const gcDone = jsonCli(['replica', 'gc', '--expected', gcPlan.checkpoint, '--keep-generations', '1']);
  assert.deepEqual(gcDone.evicted, []);
  const stalePin = await tool('pin_set', { id: memoryA, expected: noPin.structuredContent.version });
  assert.equal(stalePin.isError, true);
  assert.equal(stalePin.structuredContent.error, 'stale-version');
  const latestLog = jsonCli(['replica', 'read', 'me/log']);
  const episodeC = jsonCli(['replica', 'append', 'me/log', '--expected', latestLog.version, '--kind', 'note', '--agent', 'test', '--body', 'recent episode c']);
  const configuredLog = await tool('configured_context', { refs:['me/log'], log_keep:1, log_limit:1 });
  assert.equal(configuredLog.isError,false);
  assert.equal(configuredLog.structuredContent.ready,true);
  assert.equal(configuredLog.structuredContent.logs[0].entries[0].body,'recent episode c');
  const checkpoint = configuredLog.structuredContent.checkpoint;
  const nextLog = await tool('configured_context', { refs:['me/log'], log_keep:1, log_limit:1, log_page:2, log_checkpoint:checkpoint });
  assert.equal(nextLog.isError,false);
  assert.equal(nextLog.structuredContent.logs[0].entries[0].level,1);
  assert.equal(nextLog.structuredContent.logs[0].entries[0].direct_sources.length,2);
  const cliLog = jsonCli(['replica','configured-context','--ref','me/log','--log-keep','1','--log-limit','1','--log-page','2','--checkpoint',checkpoint]);
  assert.deepEqual(cliLog.logs,nextLog.structuredContent.logs);
  const badPage = await rpc('tools/call',{name:'configured_context',arguments:{log_page:2}});
  assert.equal(badPage.result.isError,true);
  const finished = once(server, 'exit');
  server.stdin.end();
  const [code] = await Promise.race([finished, new Promise((_, reject) => {
    const timer = setTimeout(() => reject(new Error('MCP shutdown timed out.')), 3000);
    timer.unref();
  })]);
  assert.equal(code, 0, stderr);
  server = undefined;
  const exported = cli(['replica', 'viz']).stdout;
  assert.ok(exported.includes('id="akyuu-data"'));
  server = spawn(binary, ['--root', root, 'replica', 'serve', '--port', '0'], { env, stdio: ['ignore', 'pipe', 'pipe'] });
  server.stdout.setEncoding('utf8');
  const address = await new Promise((resolve, reject) => {
    let text = '';
    const timer = setTimeout(() => reject(new Error('Browser startup timed out.')), 5000);
    server.stdout.on('data', chunk => {
      text += chunk;
      if(text.includes('\n')){ clearTimeout(timer); resolve(text.split('\n')[0]); }
    });
    server.once('error', error => { clearTimeout(timer); reject(error); });
  });
  const webResponse = await fetch(new URL('api/view?q=merged', address), { signal: AbortSignal.timeout(5000) });
  assert.equal(webResponse.status, 200);
  const web = await webResponse.json();
  assert.equal(web.checkpoint, web.context.checkpoint);
  assert.equal(web.checkpoint, web.search.checkpoint);
  assert.ok(web.topics.every(topic => topic.checkpoint === web.checkpoint));
  const firstPageResponse = await fetch(new URL('api/view?log_limit=1&log_keep=1',address),{signal:AbortSignal.timeout(5000)});
  const firstPage = await firstPageResponse.json();
  const firstLog = firstPage.logs.find(log=>log.topic?.topic==='me/log');
  assert.equal(firstLog.entries[0].body,'recent episode c');
  const nextURL = new URL(`api/view?log_limit=1&log_keep=1&log_page=2&checkpoint=${firstPage.checkpoint}`,address);
  const secondPageResponse = await fetch(nextURL,{signal:AbortSignal.timeout(5000)});
  assert.equal(secondPageResponse.status,200);
  const secondPage = await secondPageResponse.json();
  const secondLog = secondPage.logs.find(log=>log.topic?.topic==='me/log');
  assert.equal(secondLog.entries[0].level,1);
  assert.deepEqual(secondLog.entries[0].sources.sort(),[episodeA.structuredContent.heads[0].memory,episodeB.heads[0].memory].sort());
  const sourceURL = new URL(`api/source?checkpoint=${secondPage.checkpoint}&memory=${episodeA.structuredContent.heads[0].memory}`,address);
  const sourceResponse = await fetch(sourceURL,{signal:AbortSignal.timeout(5000)});
  assert.equal(sourceResponse.status,200);
  assert.equal((await sourceResponse.json()).body,'episode a');
  jsonCli(['replica','append','me/log','--expected',episodeC.version,'--kind','note','--agent','test','--body','later episode']);
  assert.equal((await fetch(nextURL,{signal:AbortSignal.timeout(5000)})).status,409);
  assert.equal((await fetch(sourceURL,{signal:AbortSignal.timeout(5000)})).status,409);
  const denied = await fetch(new URL('api/view', address), { method: 'POST', signal: AbortSignal.timeout(5000) });
  assert.equal(denied.status, 405);
  const hostileStatus = await new Promise((resolve, reject) => {
    const request = http.get(new URL('api/view', address), { headers: { Host: 'untrusted.invalid' } }, response => {
      response.resume();
      resolve(response.statusCode);
    });
    request.setTimeout(5000, () => request.destroy(new Error('Host guard check timed out.')));
    request.on('error', reject);
  });
  assert.equal(hostileStatus, 403);
  const exited = once(server, 'exit');
  server.kill('SIGTERM');
  await exited;
  server = undefined;
  console.log('Replica CLI, MCP and HTTP smoke passed.');
}

main().catch(error => { console.error(error); process.exitCode = 1; }).finally(() => {
  if (server) server.kill('SIGKILL');
  for (const request of pending.values()) clearTimeout(request.timer);
  fs.rmSync(temporary, { recursive: true, force: true });
});

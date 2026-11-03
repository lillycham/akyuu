// Temporary stores and a local bare remote only. No configured account or model.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const binary = process.argv[2];
assert.ok(binary);
const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'akyuu-sync-smoke-'));
const env = Object.fromEntries(Object.entries(process.env).filter(([key]) => !key.startsWith('AKYUU_') && !key.startsWith('GIT_')));
Object.assign(env, { AKYUU_CONFIG: path.join(temporary, 'no-config'), GIT_CONFIG_GLOBAL: '/dev/null', GIT_CONFIG_NOSYSTEM: '1' });
function call(program, args, expected = 0) {
  const result = spawnSync(program, args, { env, encoding: 'utf8', timeout: 20000, maxBuffer: 16000000 });
  assert.ifError(result.error);
  assert.equal(result.status, expected, result.stderr || result.stdout);
  return result.stdout;
}
function cli(root, args, expected = 0) { return call(binary, ['--root', root, ...args], expected); }
function json(root, args, expected = 0) { return JSON.parse(cli(root, ['replica', ...args, '--json'], expected)); }
function read(root) { return json(root, ['read', 'me/topic']); }
function replace(root, body) {
  return json(root, ['replace', 'me/topic', '--expected', read(root).version, '--kind', 'fact', '--agent', 'test', '--body', body]);
}
try {
  const remote = path.join(temporary, 'remote.git');
  const a = path.join(temporary, 'a');
  const b = path.join(temporary, 'b');
  call('git', ['init', '--bare', '--quiet', remote]);
  json(a, ['init', '--label', 'a']);
  const original = json(a, ['create', 'me/topic', '--kind', 'fact', '--agent', 'test', '--body', 'first']);
  const firstId = original.heads[0].memory;
  json(a, ['sync-config', '--remote', remote]);
  assert.equal(json(a, ['sync']).pending_events, 0);
  json(b, ['join', '--remote', remote, '--label', 'b']);
  assert.notEqual(fs.readFileSync(path.join(a, 'REPLICA'), 'utf8'), fs.readFileSync(path.join(b, 'REPLICA'), 'utf8'));
  replace(a, 'second');
  json(a, ['sync']);
  json(b, ['sync']);
  for (const root of [a,b]) {
    const plan = json(root, ['gc', '--dry-run', '--keep-generations', '1']);
    assert.ok(plan.candidates.includes(firstId));
    json(root, ['gc', '--expected', plan.checkpoint, '--keep-generations', '1']);
    assert.equal(fs.existsSync(path.join(root, 'objects', firstId)), false);
    json(root, ['sync']);
    assert.equal(fs.existsSync(path.join(root, 'objects', firstId)), false);
  }
  const pin = json(a, ['pin-state', firstId]);
  json(a, ['pin', firstId, '--expected', pin.version]);
  json(a, ['sync']);
  json(b, ['sync']);
  assert.equal(fs.existsSync(path.join(b, 'objects', firstId)), true);
  replace(a, 'from a');
  replace(b, 'from b');
  json(a, ['sync']);
  json(b, ['sync']);
  json(a, ['sync']);
  const conflict = read(a);
  assert.equal(conflict.status, 'conflict');
  assert.equal(conflict.heads.length, 2);
  json(a, ['resolve', 'me/topic', '--expected', conflict.version, '--select', conflict.heads[0].memory]);
  json(a, ['sync']);
  json(b, ['sync']);
  assert.equal(read(b).status, 'resolved');
  const before = fs.readFileSync(path.join(b, 'CURRENT'), 'utf8');
  assert.equal(json(b, ['sync', '--dry-run']).preview, true);
  assert.equal(fs.readFileSync(path.join(b, 'CURRENT'), 'utf8'), before);
  assert.equal(json(b, ['sync-status']).last_error, null);

  const legacy = path.join(temporary, 'legacy');
  const migrated = path.join(temporary, 'migrated');
  fs.mkdirSync(legacy);
  const legacyId = cli(legacy, ['add', '--ref', 'me/topic', '--kind', 'fact', '--agent', 'test', '--body', 'legacy fact']).trim();
  cli(legacy, ['append', 'me/log', '--kind', 'note', '--agent', 'test', '--body', 'first episode']);
  cli(legacy, ['append', 'me/log', '--kind', 'note', '--agent', 'test', '--body', 'second episode']);
  const classification = path.join(temporary, 'classification.json');
  fs.writeFileSync(classification, JSON.stringify({ 'me/topic': 'topic', 'me/log': 'log' }));
  const flags = ['migrate', '--source', legacy, '--classification', classification];
  const plan = json(migrated, [...flags, '--dry-run']);
  assert.equal(fs.existsSync(migrated), false);
  const copied = json(migrated, [...flags, '--expected', plan.version]);
  assert.equal(copied.cutover_complete, false);
  assert.equal(read(migrated).heads[0].memory, legacyId);
  assert.equal(json(migrated, ['log', 'me/log']).entries.length, 2);
  assert.equal(fs.existsSync(path.join(legacy, 'IDENTITY')), false);
  const identity = fs.readFileSync(path.join(migrated, 'REPLICA'), 'utf8');
  json(migrated, [...flags, '--expected', plan.version]);
  assert.equal(fs.readFileSync(path.join(migrated, 'REPLICA'), 'utf8'), identity);
  console.log('Sync, join, GC, pin, conflict and migration CLI smoke passed.');
} finally {
  fs.rmSync(temporary, { recursive: true, force: true });
}

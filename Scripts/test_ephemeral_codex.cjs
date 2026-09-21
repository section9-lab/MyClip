const { test } = require('node:test');
const assert = require('node:assert/strict');
const { spawn } = require('node:child_process');
const { mkdtempSync, writeFileSync, rmSync } = require('node:fs');
const { tmpdir } = require('node:os');
const { join } = require('node:path');

async function run(requests, persistent = false) {
  const directory = mkdtempSync(join(tmpdir(), 'myclip-ephemeral-'));
  const fake = join(directory, 'codex');
  writeFileSync(fake, `#!/usr/bin/env node
    const rl = require('node:readline').createInterface({input: process.stdin});
    rl.on('line', line => {
      const request = JSON.parse(line);
      if (request.id === undefined) return console.log(line);
      const thread = {ephemeral: ${persistent ? 'false' : 'request.params?.ephemeral'}, path: null};
      console.log(JSON.stringify({id: request.id, result: {thread, echo: request}}));
    });
  `, { mode: 0o700 });
  try {
    const child = spawn(process.execPath, [join(__dirname, '../MyClip/Core/Resources/codex-ephemeral.cjs'), 'app-server'], {
      env: { ...process.env, MYCLIP_CODEX_PATH: fake }, stdio: ['pipe', 'pipe', 'pipe']
    });
    let stdout = '', stderr = '';
    child.stdout.on('data', chunk => stdout += chunk);
    child.stderr.on('data', chunk => stderr += chunk);
    child.stdin.on('error', error => { if (error.code !== 'EPIPE') throw error; });
    const done = new Promise((resolve, reject) => {
      child.on('error', reject);
      child.on('close', code => resolve({code, stderr, messages: stdout.trim().split('\n').filter(Boolean).map(JSON.parse)}));
    });
    child.stdin.end(requests.map(JSON.stringify).join('\n') + '\n');
    return await done;
  } finally { rmSync(directory, { recursive: true, force: true }); }
}

test('start and fork are ephemeral, unrelated traffic and large image payloads survive', {timeout: 5000}, async () => {
  const prompt = { id: 3, method: 'turn/start', params: { input: [{type: 'image', data: 'a'.repeat(300_000)}] } };
  const result = await run([
    {id: 1, method: 'thread/start', params: {cwd: '/tmp/中文', ephemeral: false}},
    {id: 2, method: 'thread/fork', params: {threadId: 'old'}}, prompt,
    {method: 'initialized'}
  ]);
  assert.equal(result.code, 0, result.stderr);
  assert.equal(result.messages[0].result.echo.params.ephemeral, true);
  assert.equal(result.messages[1].result.echo.params.ephemeral, true);
  assert.deepEqual(result.messages[2].result.echo, prompt);
  assert.deepEqual(result.messages[3], {method: 'initialized'});
});

test('refuses a backend that does not acknowledge ephemeral mode', {timeout: 5000}, async () => {
  const result = await run([{id: 1, method: 'thread/start', params: {}}], true);
  assert.notEqual(result.code, 0);
  assert.equal(result.messages.some(message => message.result?.thread), false);
  assert.match(result.stderr, /did not acknowledge ephemeral mode/);
});

test('does not resume persistent history', {timeout: 5000}, async () => {
  const result = await run([{id: 1, method: 'thread/resume', params: {threadId: 'old'}}]);
  assert.notEqual(result.code, 0);
  assert.equal(result.messages.length, 0);
  assert.match(result.stderr, /cannot resume persistent history/);
});

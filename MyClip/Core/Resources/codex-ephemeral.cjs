#!/usr/bin/env node
// codex-acp 1.12.0 does not forward thread/start.ephemeral. Keep its ACP behavior
// intact and enforce non-persistent threads at the app-server boundary instead.
const { spawn } = require('node:child_process');
const { createInterface } = require('node:readline');
const { once } = require('node:events');

const executable = process.env.MYCLIP_CODEX_PATH;
if (!executable || process.argv[2] !== 'app-server') {
  process.stderr.write('MyClip: ephemeral proxy requires a Codex app-server executable.\n');
  process.exit(1);
}
const child = spawn(executable, process.argv.slice(2), { stdio: ['pipe', 'pipe', 'inherit'] });
const pending = new Set();
let failed = false;
let shutdownTimer;

function stop() {
  process.stdin.destroy();
  child.kill('SIGTERM');
  clearTimeout(shutdownTimer);
  shutdownTimer = setTimeout(() => child.kill('SIGKILL'), 2000).unref();
}
function fail(error) {
  if (failed) return;
  failed = true;
  process.exitCode = 1;
  process.stderr.write(`MyClip: ${error.message}\n`);
  process.stdin.destroy();
  stop();
}
async function write(stream, line) {
  if (!stream.write(line + '\n')) await once(stream, 'drain');
}
async function forward(input, output, transform) {
  for await (const line of createInterface({ input, crlfDelay: Infinity })) {
    if (!line.trim()) continue;
    await write(output, transform(line));
  }
}

child.on('error', fail);
child.stdin.on('error', fail);
process.stdout.on('error', fail);
process.on('SIGTERM', stop);
process.on('SIGINT', stop);
child.on('close', code => {
  clearTimeout(shutdownTimer);
  process.exitCode = failed ? 1 : (code ?? 1);
  process.stdin.destroy();
});

forward(process.stdin, child.stdin, line => {
  const message = JSON.parse(line);
  if (message.method === 'thread/resume') throw new Error('ephemeral sessions cannot resume persistent history.');
  if (message.method === 'thread/start' || message.method === 'thread/fork') {
    message.params = { ...message.params, ephemeral: true };
    pending.add(JSON.stringify(message.id));
    return JSON.stringify(message);
  }
  return line;
}).then(() => {
  child.stdin.end();
  // Parent exit must not leave an idle app-server behind.
  shutdownTimer ??= setTimeout(stop, 2000).unref();
}).catch(fail);

forward(child.stdout, process.stdout, line => {
  const message = JSON.parse(line);
  if (pending.delete(JSON.stringify(message.id)) && !message.error) {
    if (message.result?.thread?.ephemeral !== true) {
      throw new Error('Codex did not acknowledge ephemeral mode; refusing a persistent session.');
    }
  }
  return line;
}).catch(fail);

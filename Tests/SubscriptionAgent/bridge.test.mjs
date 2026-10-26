import test from 'node:test'
import assert from 'node:assert/strict'
import { spawn } from 'node:child_process'
import { createInterface } from 'node:readline'
import { mkdtemp, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { fileURLToPath } from 'node:url'
import { once } from 'node:events'

test('ACP bridge maps executor mode, declares vision, and rejects a failed upstream even with end_turn', { timeout: 10000 }, async () => {
  const root = await mkdtemp(tmpdir() + '/MyClip-Bridge-')
  const path = relative => fileURLToPath(new URL(relative, import.meta.url))
  const child = spawn(process.execPath, ['--import', path('./upstream-fixture.mjs'),
    path('../../MyClip/Core/Resources/SubscriptionAgent/agent.mjs'), 'workbuddy', root, process.execPath, path('./executor-fixture.mjs')],
    { stdio: ['pipe', 'pipe', 'pipe'] })
  const pending = new Map()
  let id = 0
  const send = data => child.stdin.write(JSON.stringify({ jsonrpc: '2.0', ...data }) + '\n')
  const request = (method, params = {}) => new Promise(resolve => {
    const next = ++id; pending.set(next, resolve); send({ id: next, method, params })
  })
  const lines = createInterface({ input: child.stdout })
  child.stderr.resume()
  lines.on('line', line => {
    const message = JSON.parse(line)
    if (message.method) {
      const result = message.method === 'myclip/account/read' ? { type: 'oauth', uid: 'fixture', access: 'fixture-access', expires: Date.now() + 3600000 } : {}
      send({ id: message.id, result })
    } else { pending.get(message.id)?.(message); pending.delete(message.id) }
  })
  try {
    const init = await request('initialize', { protocolVersion: 1, clientCapabilities: {} })
    assert.equal(init.result.agentCapabilities.promptCapabilities.image, true)
    const session = await request('session/new', { cwd: root, mcpServers: [] })
    assert.equal(session.result.models.availableModels[0]._meta.myclip.supportsImages, true)
    const mode = await request('session/set_mode', { sessionId: 'fixture-session', modeId: 'bypassPermissions' })
    assert.equal(mode.error, undefined)
    const prompt = await request('session/prompt', { sessionId: 'fixture-session', prompt: [{ type: 'text', text: 'Fixture' }] })
    assert.match(prompt.error.message, /403/)
    assert.equal(prompt.result, undefined)
  } finally {
    const exited = once(child, 'exit')
    child.stdin.end()
    await exited
    lines.close()
    await rm(root, { recursive: true, force: true })
  }
})

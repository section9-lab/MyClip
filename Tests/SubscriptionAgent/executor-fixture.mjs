import { createInterface } from 'node:readline'
const config = JSON.parse(process.env.OPENCODE_CONFIG_CONTENT)
const provider = config.provider.workbuddy
createInterface({ input: process.stdin }).on('line', async line => {
  const request = JSON.parse(line)
  let result = {}
  if (request.method === 'initialize') result = { protocolVersion: 1 }
  if (request.method === 'session/new') result = { sessionId: 'fixture-session', models: {
    currentModelId: config.model, availableModels: [{ modelId: config.model, name: 'Fixture Vision' }],
  } }
  if (request.method === 'session/set_mode' && request.params.modeId !== 'build') {
    process.stdout.write(JSON.stringify({ jsonrpc: '2.0', id: request.id, error: { code: -32602, message: 'Incorrect mode mapping' } }) + '\n')
    return
  }
  if (request.method === 'session/prompt') {
    await fetch(provider.options.baseURL + '/chat/completions', { method: 'POST',
      headers: { Authorization: 'Bearer ' + provider.options.apiKey },
      body: JSON.stringify({ model: 'fixture-vision', messages: [{ role: 'user', content: 'Fixture only' }] }) })
    // Reproduce an executor that reports end_turn after a provider refused it.
    result = { stopReason: 'end_turn' }
  }
  process.stdout.write(JSON.stringify({ jsonrpc: '2.0', id: request.id, result }) + '\n')
})

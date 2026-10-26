// ACP account bridge owned by MyClip. OpenCode supplies the existing tool loop;
// this process owns authorization and protocol conversion, without Magpie.
import { createServer } from 'node:http'
import { randomBytes } from 'node:crypto'
import { spawn } from 'node:child_process'
import { mkdir } from 'node:fs/promises'
import { createInterface } from 'node:readline'
import { join } from 'node:path'
import { createAccount, AccountError, safeError } from './providers.mjs'

const [provider, stateDirectory, enginePath, ...engineArgs] = process.argv.slice(2)
if (!['qwenwork', 'workbuddy'].includes(provider) || !stateDirectory || !enginePath) process.exit(2)
const send = message => process.stdout.write(JSON.stringify({ jsonrpc: '2.0', ...message }) + '\n')
const waiting = new Map(), engineWaiting = new Map()
let serial = 0, engine, gateway, account, catalog = [], initialization, initializing
let closing = false
let activeTurn = {}
let upstreamFailure
const localKey = randomBytes(32).toString('hex')
const hostRequest = (method, params = {}) => new Promise((resolve, reject) => {
  const id = 'myclip-account-' + ++serial
  const timer = setTimeout(() => { waiting.delete(id); reject(new AccountError('MyClip 账号连接超时。')) }, 30000)
  waiting.set(id, { resolve, reject, timer }); send({ id, method, params })
})
const getAccount = async () => account ??= await createAccount(provider, {
  read: () => hostRequest('myclip/account/read'),
  save: credential => hostRequest('myclip/account/save', { credential }),
  open: url => hostRequest('myclip/account/open_url', { url }),
})
const fail = (response, status, text) => {
  response.writeHead(status, { 'Content-Type': 'application/json' })
  response.end(JSON.stringify({ error: { message: text, type: 'myclip_account_error' } }))
}
async function listen() {
  gateway = createServer(async (request, response) => {
    const controller = new AbortController()
    response.on('close', () => controller.abort())
    try {
      if (request.headers.authorization !== 'Bearer ' + localKey) return fail(response, 401, 'Unauthorized')
      if (request.method !== 'POST' || request.url !== '/v1/chat/completions') return fail(response, 404, 'Not found')
      let size = 0; const chunks = []
      for await (const chunk of request) {
        size += chunk.length
        if (size > 64 * 1024 * 1024) return fail(response, 413, '图片与上下文过大。')
        chunks.push(chunk)
      }
      let body
      try { body = JSON.parse(Buffer.concat(chunks).toString('utf8')) }
      catch { return fail(response, 400, 'Invalid JSON') }
      const model = catalog.find(m => m.id === body.model)
      if (!model) return fail(response, 400, '模型已不可用，请刷新目录。')
      const images = (body.messages ?? []).some(m => Array.isArray(m.content) && m.content.some(p => p.type === 'image_url'))
      if (images && !model.images) return fail(response, 400, '所选模型不支持图片。')
      if ((body.tools ?? []).length && !model.tools) return fail(response, 400, '所选模型不支持工具调用。')
      body.user ||= activeTurn.sessionID
      const upstream = await (await getAccount()).chat(body, controller.signal, activeTurn)
      // Do not return arbitrary upstream error bodies, which may include tokens.
      if (!upstream.ok) {
        await upstream.body?.cancel()
        upstreamFailure = new AccountError(`账号服务拒绝请求（HTTP ${upstream.status}），请检查授权、额度或渠道权限。`, upstream.status)
        return fail(response, upstream.status, upstreamFailure.message)
      }
      if (!upstream.body) {
        upstreamFailure = new AccountError('账号服务没有返回响应。')
        return fail(response, 502, upstreamFailure.message)
      }
      upstreamFailure = undefined
      response.writeHead(200, { 'Content-Type': upstream.headers.get('content-type') || 'text/event-stream', 'Cache-Control': 'no-store' })
      for await (const chunk of upstream.body) {
        if (response.destroyed) break
        if (!response.write(Buffer.from(chunk))) await new Promise(resolve => {
          response.once('drain', resolve); response.once('close', resolve)
        })
      }
      response.end()
    } catch (error) {
      upstreamFailure = new AccountError('账号请求未完成：' + safeError(error), error instanceof AccountError ? error.status : 502)
      if (!response.headersSent) fail(response, error instanceof AccountError ? error.status : 502, safeError(error))
      else response.destroy()
    }
  })
  await new Promise((resolve, reject) => { gateway.once('error', reject); gateway.listen(0, '127.0.0.1', resolve) })
  return `http://127.0.0.1:${gateway.address().port}/v1`
}
function engineRequest(method, params) {
  return new Promise((resolve, reject) => {
    if (!engine || engine.exitCode !== null || engine.killed) return reject(new AccountError('ACP 执行器已退出。'))
    const id = 'myclip-engine-' + ++serial
    engineWaiting.set(id, { resolve, reject })
    engine.stdin.write(JSON.stringify({ jsonrpc: '2.0', id, method, params }) + '\n')
  })
}
async function startEngine() {
  if (initializing) return initializing
  initializing = (async () => {
    const source = await getAccount()
    if (!source.signedIn()) throw new AccountError('请先登录你的产品账号。', 401)
    catalog = await source.models()
    if (!catalog.length) throw new AccountError('账号没有返回可用模型。')
    const usable = catalog.find(m => m.images && m.tools)
    if (!usable) throw new AccountError('此账号当前没有同时支持图片与工具调用的模型。', 400)
    const baseURL = await listen()
    const config = {
      enabled_providers: [provider], model: provider + '/' + usable.id, small_model: provider + '/' + usable.id,
      provider: { [provider]: { name: provider === 'workbuddy' ? 'WorkBuddy 账号' : '千问办公账号',
        npm: '@ai-sdk/openai-compatible', options: { baseURL, apiKey: localKey },
        models: Object.fromEntries(catalog.map(m => [m.id, { name: m.name, attachment: m.images, tool_call: m.tools,
          limit: { context: m.context || 200000, output: m.output || 32000 },
          modalities: { input: m.images ? ['text', 'image'] : ['text'], output: ['text'] } }])) } },
      // Capture content is data; project plugins/config and other provider auth must
      // not be inherited by this account-scoped executor.
      plugin: [],
    }
    await mkdir(stateDirectory, { recursive: true, mode: 0o700 })
    const env = { ...process.env, HOME: stateDirectory, OPENCODE_CONFIG_CONTENT: JSON.stringify(config), OPENCODE_CONFIG_DIR: join(stateDirectory, 'config'),
      XDG_CONFIG_HOME: join(stateDirectory, 'config-home'), XDG_DATA_HOME: join(stateDirectory, 'data'),
      XDG_CACHE_HOME: join(stateDirectory, 'cache'), OPENCODE_DISABLE_PROJECT_CONFIG: 'true', OPENCODE_DISABLE_DEFAULT_PLUGINS: 'true' }
    delete env.OPENCODE_CONFIG
    engine = spawn(enginePath, engineArgs, { env, detached: true, stdio: ['pipe', 'pipe', 'pipe'] })
    // The engine's diagnostics may contain prompt/config text. Emit only exit status.
    engine.stderr.resume()
    engine.on('error', () => shutdown('ACP 执行器无法启动。'))
    engine.on('exit', code => { if (!closing) shutdown(`ACP 执行器已退出（${code}）。`) })
    createInterface({ input: engine.stdout }).on('line', line => {
      try {
        const message = JSON.parse(line), pending = engineWaiting.get(message.id)
        if (pending && !message.method) {
          engineWaiting.delete(message.id)
          if (message.error) pending.reject(new AccountError(safeError(new Error(message.error.message))))
          else pending.resolve(message.result)
        } else {
          if (message.method === 'session/update' && message.params?.update?.sessionUpdate === 'config_option_update') annotate(message.params.update)
          send(message)
        }
      } catch { shutdown('ACP 执行器返回了无效消息。') }
    })
    await engineRequest('initialize', initialization)
    return true
  })()
  try { return await initializing } catch (error) {
    initializing = undefined
    if (gateway) { gateway.closeAllConnections(); gateway.close(); gateway = undefined }
    throw error
  }
}
function annotate(result) {
  const enrich = option => {
    const id = option.value ?? option.modelId
    const model = catalog.find(m => id === provider + '/' + m.id)
    return model ? { ...option, _meta: { myclip: { supportsImages: model.images, supportsTools: model.tools } } } : option
  }
  if (Array.isArray(result.configOptions)) result.configOptions = result.configOptions.map(c => c.category !== 'model' ? c : {
    ...c, options: (c.options ?? []).map(o => o.options ? { ...o, options: o.options.map(enrich) } : enrich(o)),
  })
  if (result.models?.availableModels) result.models.availableModels = result.models.availableModels.map(enrich)
  return result
}
async function handle(method, params) {
  if (method === 'initialize') {
    initialization = params
    return { protocolVersion: 1, agentInfo: { name: 'myclip-' + provider, version: '1.0.0' },
      agentCapabilities: { promptCapabilities: { image: true } },
      authMethods: [{ id: 'desktop-account', name: provider === 'workbuddy' ? '登录 WorkBuddy 账号' : '登录千问办公账号' }] }
  }
  if (method === 'authenticate') {
    if (engine) throw new AccountError('请结束当前连接后重新授权。', 409)
    if (params.methodId !== 'desktop-account') throw new AccountError('不支持的授权方式。', 400)
    await (await getAccount()).login()
    await hostRequest('myclip/account/status', await (await getAccount()).status())
    return {}
  }
  if (method === 'myclip/account/status') return (await getAccount()).status()
  if (method === 'session/cancel') {
    if (engine) engine.stdin.write(JSON.stringify({ jsonrpc: '2.0', method, params }) + '\n')
    return {}
  }
  await startEngine()
  // MyClip's WorkBuddy entry uses CodeBuddy's mode ID; the explicitly labelled
  // shared OpenCode executor names the equivalent tool mode "build".
  if (method === 'session/set_mode' && provider === 'workbuddy' && params.modeId === 'bypassPermissions') {
    params = { ...params, modeId: 'build' }
  }
  if (method === 'session/prompt') {
    activeTurn = { sessionID: params.sessionId, turnID: randomBytes(16).toString('hex') }
    upstreamFailure = undefined
  }
  const result = await engineRequest(method, params)
  // A normal ACP stop reason cannot turn a refused model request into success.
  // A subsequent successful upstream request clears a recovered transient error.
  if (method === 'session/prompt' && upstreamFailure) throw upstreamFailure
  if (method === 'session/new') {
    // Display-only metadata; account failure remains visible, never triggers another provider.
    try { await hostRequest('myclip/account/status', await (await getAccount()).status()) } catch { /* generation can continue with known account */ }
  }
  if (method === 'session/prompt') {
    try { await hostRequest('myclip/account/status', await (await getAccount()).status()) } catch { /* usage read does not change the actual generation result */ }
  }
  return annotate(result)
}
function shutdown(message) {
  if (closing) return
  closing = true
  if (message) process.stderr.write(message + '\n')
  const killEngine = signal => {
    if (!engine?.pid) return
    try { process.kill(-engine.pid, signal) } catch { /* the owned process group already exited */ }
  }
  killEngine('SIGTERM')
  for (const p of [...waiting.values(), ...engineWaiting.values()]) { clearTimeout(p.timer); p.reject(new AccountError('连接已关闭。')) }
  waiting.clear(); engineWaiting.clear()
  gateway?.closeAllConnections(); gateway?.close()
  const timer = setTimeout(() => { killEngine('SIGKILL'); process.exit(message ? 1 : 0) }, 1000)
  timer.unref()
}
createInterface({ input: process.stdin }).on('line', line => {
  let message
  try { message = JSON.parse(line) } catch { shutdown('无效 ACP 消息。'); return }
  if (!message.method) {
    const pending = waiting.get(message.id)
    if (pending) {
      waiting.delete(message.id); clearTimeout(pending.timer)
      if (message.error) pending.reject(new AccountError(message.error.message))
      else pending.resolve(message.result)
    } else engine?.stdin.write(line + '\n')
    return
  }
  handle(message.method, message.params ?? {}).then(result => {
    if (message.id !== undefined) send({ id: message.id, result })
  }).catch(error => {
    if (message.id !== undefined) send({ id: message.id, error: { code: error.status === 401 ? -32000 : -32603, message: safeError(error) } })
  })
}).on('close', () => shutdown())
process.on('SIGTERM', () => shutdown())
process.on('SIGINT', () => shutdown())

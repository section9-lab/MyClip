import test from 'node:test'
import assert from 'node:assert/strict'
import { createAccount } from '../../MyClip/Core/Resources/SubscriptionAgent/providers.mjs'
import { decodeQwenBody } from '../../MyClip/Core/Resources/SubscriptionAgent/qwenwork-protocol.mjs'

const originalFetch = globalThis.fetch
const qwenCredential = { type: 'oauth', access: 'fixture-access', refresh: 'fixture-refresh', deviceToken: 'fixture-access',
  uid: 'fixture-qwen', accountId: 'Fixture', machineId: 'fixture-machine', deviceChat: true, expires: Date.now() + 3600000 }
const workCredential = { type: 'oauth', access: 'fixture-access', refresh: 'fixture-refresh', uid: 'fixture-work',
  accountId: 'Fixture', expires: Date.now() + 3600000 }
const host = value => ({ read: async () => value, save: async next => { value = next }, open: async () => {} })
const envelope = data => Response.json({ code: 0, data })
const sse = delta => `data: ${JSON.stringify({ statusCodeValue: 200, body: JSON.stringify({ choices: [{ delta, finish_reason: null }] }) })}\n\n`

test('Qwen live catalog, image payload and structured tool calls use the account protocol', async () => {
  const requests = []
  globalThis.fetch = async (input, init = {}) => {
    const url = new URL(input)
    assert.equal(url.origin, 'https://gateway.qwenwork.cn')
    if (url.pathname.endsWith('/model/list')) return Response.json({ qwork: [
      { key: 'fixture-vision', display_name: 'Fixture Vision', is_vl: true, max_input_tokens: 200000 },
      { key: 'fixture-text', display_name: 'Fixture Text', is_vl: false, max_input_tokens: 100000 },
    ] })
    if (url.pathname.endsWith('/agent_chat_generation')) {
      requests.push(JSON.parse(decodeQwenBody(init.body)))
      return new Response(sse({ role: 'assistant', tool_calls: [{ index: 0, id: 'fixture-call', type: 'function',
        function: { name: 'read', arguments: '{"path":"Memory.md"}' } }] }) + 'data: {"body":"[DONE]"}\n\n',
      { headers: { 'Content-Type': 'text/event-stream' } })
    }
    throw new Error('Unexpected upstream request')
  }
  try {
    const account = await createAccount('qwenwork', host(qwenCredential))
    const models = await account.models()
    assert.deepEqual(models.map(m => [m.id, m.images]), [['fixture-vision', true], ['fixture-text', false]])
    const response = await account.chat({ model: 'fixture-vision', stream: true,
      messages: [{ role: 'user', content: [{ type: 'text', text: 'Remember this.' },
        { type: 'image_url', image_url: { url: 'data:image/png;base64,fixture-image' } }] }],
      tools: [{ type: 'function', function: { name: 'read', parameters: { type: 'object', properties: { path: { type: 'string' } } } } }] }, AbortSignal.timeout(1000))
    assert.equal(response.status, 200)
    assert.match(await response.text(), /fixture-call/)
    assert.match(JSON.stringify(requests[0].messages), /data:image\/png;base64,fixture-image/)
    assert.equal(requests[0].tools[0].function.name, 'read')
    assert.equal(requests[0].business.name, 'MyClip memory')
  } finally { globalThis.fetch = originalFetch }
})

test('Qwen catalog failure does not invent fallback models', async () => {
  globalThis.fetch = async () => new Response('unavailable', { status: 503 })
  try { const account = await createAccount('qwenwork', host(qwenCredential)); await assert.rejects(account.models()) }
  finally { globalThis.fetch = originalFetch }
})

test('Qwen remaining-only quota stays distinct from unknown total and used values', async () => {
  globalThis.fetch = async () => Response.json({ data: { user: { id: 'fixture-qwen' }, plan: { name: 'Fixture plan' },
    quota: { total: null, used: null, remaining: 2093.5 } } })
  try {
    const account = await createAccount('qwenwork', host(qwenCredential))
    const info = await account.status()
    assert.equal(info.accountID, 'fixture-qwen')
    assert.deepEqual(info.credits, { used: null, total: null, remaining: 2093.5 })
  } finally { globalThis.fetch = originalFetch }
})

test('WorkBuddy uses the authorized enterprise catalog and meter', async () => {
  globalThis.fetch = async (input, init = {}) => {
    const url = new URL(input)
    assert.equal(url.origin, 'https://copilot.tencent.com')
    assert.equal(init.headers['X-Enterprise-Id'], 'fixture-enterprise')
    assert.equal(init.headers['X-Tenant-Id'], 'fixture-enterprise')
    if (url.pathname === '/v3/config') return envelope({ agents: [{ name: 'cli', models: ['fixture-vision', 'fixture-text'] }],
      models: [{ id: 'fixture-vision', supportsImages: true, supportsToolCall: true },
        { id: 'fixture-text', supportsImages: false }, { id: 'not-allowed', supportsImages: true }] })
    if (url.pathname.endsWith('/get-enterprise-user-usage')) return envelope({ credit: '12.5', limitNum: '100' })
    throw new Error('Unexpected upstream request')
  }
  try {
    const account = await createAccount('workbuddy', host({ ...workCredential, enterpriseId: 'fixture-enterprise' }))
    assert.deepEqual((await account.models()).map(m => m.id), ['fixture-vision', 'fixture-text'])
    const info = await account.status()
    assert.equal(info.accountID, workCredential.uid)
    assert.deepEqual(info.credits, { used: 12.5, total: 100, remaining: 87.5 })
  } finally { globalThis.fetch = originalFetch }
})

test('WorkBuddy personal credits use package capacity, not guessed fields', async () => {
  globalThis.fetch = async () => envelope({ Packages: [{ CycleTotalCapacity: '80', CycleUsedCapacity: '10.25' },
    { CycleTotalCapacity: '20', CycleUsedCapacity: '3.75' }] })
  try {
    const account = await createAccount('workbuddy', host(workCredential))
    assert.deepEqual((await account.status()).credits, { used: 14, total: 100, remaining: 86 })
  } finally { globalThis.fetch = originalFetch }
})

test('WorkBuddy channel refusals are returned without identity rewriting or retries', async () => {
  let calls = 0
  globalThis.fetch = async (input, init = {}) => {
    calls++
    const body = JSON.parse(init.body)
    assert.equal(body.messages[0].content, 'Actual executor identity: OpenCode.')
    return new Response('unapproved channel', { status: 403 })
  }
  try {
    const account = await createAccount('workbuddy', host(workCredential))
    const res = await account.chat({ model: 'fixture-model', messages: [{ role: 'system', content: 'Actual executor identity: OpenCode.' }] }, AbortSignal.timeout(1000))
    assert.equal(res.status, 403); assert.equal(calls, 1)
  } finally { globalThis.fetch = originalFetch }
})

test('WorkBuddy concurrent expiry refresh is serialized and the rotated token is saved', async () => {
  let refreshes = 0, saved
  globalThis.fetch = async input => {
    const path = new URL(input).pathname
    if (path.endsWith('/token/refresh')) { refreshes++; return envelope({ accessToken: 'fixture-rotated', refreshToken: 'fixture-next-refresh', expiresIn: 3600 }) }
    if (path === '/v3/config') return envelope({ agents: [{ name: 'cli', models: ['fixture'] }], models: [{ id: 'fixture' }] })
    throw new Error('Unexpected upstream request')
  }
  try {
    const account = await createAccount('workbuddy', { ...host({ ...workCredential, expires: 1 }), save: async next => { saved = next } })
    await Promise.all([account.models(), account.models()])
    assert.equal(refreshes, 1); assert.equal(saved.refresh, 'fixture-next-refresh')
  } finally { globalThis.fetch = originalFetch }
})

test('Missing WorkBuddy credentials fail before any network request', async () => {
  globalThis.fetch = () => { throw new Error('Network must not be called') }
  try {
    const account = await createAccount('workbuddy', host(null))
    await assert.rejects(account.models(), e => e.status === 401)
  } finally { globalThis.fetch = originalFetch }
})

test('WorkBuddy version metadata varies per installation and models remain account-provided', async () => {
  const priorVersion = process.env.MYCLIP_PRODUCT_VERSION
  const seen = []
  globalThis.fetch = async (input, init = {}) => {
    seen.push(init.headers['User-Agent'])
    return envelope({ agents: [{ name: 'cli', models: ['account-only-model'] }], models: [{ id: 'account-only-model' }] })
  }
  try {
    for (const version of ['6.1.2', '7.3.4-beta.1']) {
      process.env.MYCLIP_PRODUCT_VERSION = version
      const account = await createAccount('workbuddy', host(workCredential))
      assert.deepEqual((await account.models()).map(m => m.id), ['account-only-model'])
      assert.match(seen.at(-1), new RegExp('WorkBuddy/' + version.replaceAll('.', '\\.')))
    }
    process.env.MYCLIP_PRODUCT_VERSION = 'invalid\nheader'
    const account = await createAccount('workbuddy', host(workCredential))
    await account.models()
    assert.doesNotMatch(seen.at(-1), /invalid|\n/)
  } finally {
    globalThis.fetch = originalFetch
    if (priorVersion === undefined) delete process.env.MYCLIP_PRODUCT_VERSION
    else process.env.MYCLIP_PRODUCT_VERSION = priorVersion
  }
})

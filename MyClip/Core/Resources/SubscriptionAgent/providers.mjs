// MyClip-owned account adapters. See LICENSES.txt for protocol references.
// Tokens live only in memory and the host's Keychain; never in an agent config.
import { randomBytes } from 'node:crypto'
import { readFile } from 'node:fs/promises'
import { createQwenProtocol } from './qwenwork-protocol.mjs'

export class AccountError extends Error {
  constructor(message, status = 502) { super(message); this.status = status }
}
export function safeError(error) {
  return String(error?.message ?? error).replace(/(?:Bearer\s+|COSY\.)[^\s"<>]+/gi, '[redacted]')
    .replace(/\bey[\w-]+\.[\w-]+\.[\w-]+/g, '[redacted]').slice(0, 300)
}

/** @param {'qwenwork'|'workbuddy'} provider @param {{read:Function,save:Function,open:Function}} host */
export async function createAccount(provider, host) {
  let auth = await host.read()
  const save = async value => { await host.save(value); auth = value }
  if (provider === 'qwenwork') {
    const d = JSON.parse(await readFile(new URL('./qwenwork-defaults.json', import.meta.url), 'utf8'))
    const site = {
      id: provider, name: '千问办公', clientId: d.CLIENT_ID, web: d.WEB, openapi: d.OPENAPI, api: d.API,
      rsaKey: d.RSA_PUBLIC_KEY.replaceAll('\\n', '\n'), cosyVersion: d.COSY_VERSION,
      redirect: 'qwenwork-cn://', deviceOnly: true, deviceRefreshTarget: 'c', modelScene: 'qwork', listAllModels: true,
      clientType: '6', businessProduct: 'qoder_work', sessionType: 'qoder_work', models: [],
      userInfoPath: '/api/v1/adapter/user/account-context?include=user,plan,quota,page,data_sharing',
      normalizeUser: v => (v?.data ?? v)?.user ?? (v?.data ?? v),
      systemPrompt: 'You are an assistant generating memory for MyClip. Follow the supplied instructions and use the available tools.',
    }
    const protocol = await createQwenProtocol(site)({ client: { auth: { set: async ({ body }) => save(body) } } })
    return {
      signedIn: () => !!auth?.access,
      async login() {
        const flow = await protocol.auth.methods[0].authorize()
        await host.open(flow.url)
        const result = await flow.callback()
        if (result.type !== 'success') throw new AccountError('千问办公授权未完成。', 401)
        await save({ ...result, type: 'oauth' })
      },
      async models() {
        const list = await protocol.provider.models({ models: {} }, { auth })
        if (!Object.keys(list).length) throw new AccountError('千问办公没有返回模型，请完成账号授权后刷新。', 401)
        return Object.values(list).map(m => ({ id: m.id, name: m.name, context: m.limit.context,
          output: m.limit.output, images: m.capabilities.input.image === true, tools: m.capabilities.toolcall === true }))
      },
      async status() {
        if (!auth?.access) return { signedIn: false }
        const response = await fetch(site.openapi + '/api/v1/adapter/user/account-context?include=user,plan,quota', {
          headers: { Authorization: 'Bearer ' + auth.access }, signal: AbortSignal.timeout(20000), redirect: 'error',
        })
        if (!response.ok) throw new AccountError(`千问办公账号读取失败（HTTP ${response.status}）。`, response.status)
        const data = (await response.json()).data ?? {}
        return { signedIn: true, account: String(data.user?.name ?? data.user?.id ?? auth.accountId ?? ''),
          accountID: String(data.user?.id ?? auth.uid ?? ''), plan: String(data.plan?.name ?? ''),
          credits: data.quota ? { used: data.quota.used, total: data.quota.total, remaining: data.quota.remaining } : null }
      },
      async chat(body, signal) {
        const loader = await protocol.auth.loader(async () => auth)
        if (!loader.fetch) throw new AccountError('请先授权千问办公账号。', 401)
        return loader.fetch(site.api + '/chat/completions', { method: 'POST', body: JSON.stringify(body), signal })
      },
    }
  }
  if (provider !== 'workbuddy') throw new AccountError('不支持的账号来源。', 400)
  const settings = JSON.parse(await readFile(new URL('./account-protocols.json', import.meta.url), 'utf8')).workbuddy
  const endpoint = settings.endpoint
  const detectedVersion = process.env.MYCLIP_PRODUCT_VERSION ?? ''
  const productVersion = /^\d+\.\d+\.\d+(?:[-.][a-zA-Z0-9.]+)?$/.test(detectedVersion) ? detectedVersion : settings.compatibleProductVersion
  const clientVersion = settings.protocolClientVersion
  // The product protocol requires its version header. No prompt/identity rewriting
  // or retry after an unapproved-channel refusal is performed here.
  const productHeaders = { 'User-Agent': 'WorkBuddy/' + productVersion, 'X-IDE-Type': 'WorkBuddy', 'X-Product': 'SaaS' }
  const headers = a => ({ ...productHeaders, Authorization: 'Bearer ' + a.access, 'X-User-Id': a.uid ?? '',
    'X-Domain': a.domain || 'copilot.tencent.com', ...(a.enterpriseId ? { 'X-Enterprise-Id': a.enterpriseId, 'X-Tenant-Id': a.enterpriseId } : {}) })
  const call = async (path, { method = 'GET', extra = {}, body, signal } = {}) => {
    const res = await fetch(endpoint + path, { method, headers: { ...productHeaders, Accept: 'application/json',
      'Content-Type': 'application/json', ...extra }, body: body === undefined ? undefined : JSON.stringify(body),
      signal: signal ?? AbortSignal.timeout(30000), redirect: 'error' })
    const env = await res.json().catch(() => ({}))
    if (!res.ok || Number(env.code ?? 0) !== 0) {
      const e = new AccountError(`WorkBuddy 请求失败（HTTP ${res.status}，code ${Number(env.code ?? 0)}）。`, res.ok ? 502 : res.status)
      e.code = Number(env.code ?? 0); throw e
    }
    return env.data
  }
  const merge = (a, t) => ({ ...a, access: t.accessToken, refresh: t.refreshToken || a.refresh || '',
    domain: t.domain || a.domain || '', expires: t.expiresAt || (t.expiresIn ? Date.now() + t.expiresIn * 1000 : a.expires || 0),
    refreshExpiresAt: t.refreshExpiresAt || (t.refreshExpiresIn ? Date.now() + t.refreshExpiresIn * 1000 : a.refreshExpiresAt || 0) })
  let refreshing
  const fresh = async (force = false) => {
    if (!auth?.access || !auth?.uid) throw new AccountError('请登录你的 WorkBuddy 账号。', 401)
    if (!force && (!auth.expires || auth.expires > Date.now() + 60000)) return auth
    if (!auth.refresh || (auth.refreshExpiresAt && auth.refreshExpiresAt <= Date.now())) throw new AccountError('WorkBuddy 登录已过期，请重新授权。', 401)
    refreshing ??= (async () => {
      const token = await call('/v2/plugin/auth/token/refresh', { method: 'POST', extra: {
        'X-Refresh-Token': auth.refresh, 'X-Auth-Refresh-Source': 'plugin', 'X-Domain': auth.domain || 'copilot.tencent.com',
        ...(auth.enterpriseId ? { 'X-Enterprise-Id': auth.enterpriseId, 'X-Tenant-Id': auth.enterpriseId } : {}),
      }, body: {} })
      if (!token?.accessToken) throw new AccountError('WorkBuddy 未返回新的授权，请重新登录。', 401)
      await save(merge(auth, token)); return auth
    })().finally(() => { refreshing = undefined })
    return refreshing
  }
  return {
    signedIn: () => !!auth?.access,
    async login() {
      const state = await call('/v2/plugin/auth/state?platform=' + encodeURIComponent(settings.platform), { method: 'POST', extra: {
        'X-No-Authorization': 'true', 'X-No-User-Id': 'true', 'X-No-Enterprise-Id': 'true', 'X-No-Department-Info': 'true',
      }, body: {} })
      if (!state?.state || !state?.authUrl) throw new AccountError('WorkBuddy 未返回授权地址。')
      const url = new URL(state.authUrl)
      if (url.protocol !== 'https:' || url.username || url.password) throw new AccountError('WorkBuddy 授权地址无效。')
      url.searchParams.set('version', clientVersion); url.searchParams.set('loginSessionId', randomBytes(16).toString('hex'))
      await host.open(url.href)
      const until = Date.now() + 300000
      const poll = async (path, extra, retryCodes) => {
        while (Date.now() < until) {
          try { const value = await call(path, { extra }); if (value && Object.keys(value).length) return value }
          catch (e) { if (!retryCodes.includes(e.code) && ![408, 429].includes(e.status)) throw e }
          await new Promise(resolve => setTimeout(resolve, 1000))
        }
        throw new AccountError('WorkBuddy 授权超时，请重试。', 401)
      }
      const q = encodeURIComponent(state.state)
      const token = await poll('/v2/plugin/auth/token?state=' + q, {}, [11217])
      if (!token.accessToken) throw new AccountError('WorkBuddy 未返回授权凭据。', 401)
      const next = merge({}, token)
      const who = await poll('/v2/plugin/login/account?state=' + q, { Authorization: 'Bearer ' + next.access,
        'X-Domain': next.domain || 'copilot.tencent.com', 'X-No-User-Id': 'true', 'X-No-Enterprise-Id': 'true' }, [12151])
      if (!who.uid) throw new AccountError('WorkBuddy 未确认账号身份。', 401)
      let enterpriseId = who.enterpriseId
      if (!enterpriseId && who.type && String(who.type).toLowerCase() !== 'personal') {
        const list = await call('/v2/plugin/accounts', { extra: { Authorization: 'Bearer ' + next.access, 'X-Domain': next.domain || 'copilot.tencent.com' } })
        const entries = (list?.accounts ?? []).filter(a => a.uid === who.uid && a.enterpriseId && (a.type === who.type || a.lastLogin))
        if (entries.length !== 1) throw new AccountError('无法确认 WorkBuddy 企业账号，请在桌面端确认组织后重试。', 401)
        enterpriseId = entries[0].enterpriseId
      }
      await save({ ...next, type: 'oauth', uid: String(who.uid), accountId: String(who.nickname || who.uid), enterpriseId: enterpriseId || '' })
    },
    async models() {
      const a = await fresh()
      const cfg = await call('/v3/config', { extra: { ...headers(a), 'User-Agent': 'CLI/' + clientVersion + ' WorkBuddy/' + productVersion, 'X-Requested-With': 'XMLHttpRequest' } })
      const allowed = new Set((cfg?.agents ?? []).filter(a => a.name === 'cli').flatMap(a => a.models ?? []))
      const models = (cfg?.models ?? []).filter(m => allowed.has(m.id)).map(m => ({ id: m.id, name: m.name || m.id,
        context: m.maxInputTokens || 0, output: m.maxOutputTokens || 0, images: m.supportsImages === true,
        tools: m.supportsToolCall !== false }))
      if (!models.length) throw new AccountError('WorkBuddy 没有返回账号可用模型，请刷新或重新授权。')
      return models
    },
    async status() {
      if (!auth?.access) return { signedIn: false }
      const a = await fresh()
      const path = a.enterpriseId ? '/billing/meter/get-enterprise-user-usage' : '/billing/meter/get-user-resource-summary'
      const usage = await call(path, { method: 'POST', extra: headers(a), body: {} })
      // Return only display/number fields, never the upstream response or credentials.
      const number = value => Number.isFinite(Number(value)) ? Number(value) : 0
      const packages = usage?.Packages ?? []
      const total = a.enterpriseId ? number(usage?.limitNum) : packages.reduce((n, p) => n + number(p.CycleTotalCapacity), 0)
      const used = a.enterpriseId ? number(usage?.credit) : packages.reduce((n, p) => n + number(p.CycleUsedCapacity), 0)
      return { signedIn: true, account: String(a.accountId || a.uid), accountID: String(a.uid),
        organization: String(a.enterpriseId || ''), plan: a.enterpriseId ? 'WorkBuddy 企业账号' : 'WorkBuddy',
        credits: total > 0 ? { used, total, remaining: Math.max(0, total - used) } : null }
    },
    async chat(body, signal, context = {}) {
      let a = await fresh()
      const id = randomBytes(16).toString('hex')
      const send = () => fetch(endpoint + '/v2/chat/completions', { method: 'POST', headers: { ...headers(a),
        'Content-Type': 'application/json', Accept: 'text/event-stream', 'X-Conversation-ID': String(context.sessionID || body.user || id),
        'X-Conversation-Request-ID': String(context.turnID || id), 'X-Conversation-Message-ID': id, 'X-Request-ID': id,
        'X-Requested-With': 'XMLHttpRequest', 'X-Client-Name': 'MyClip' },
        body: JSON.stringify({ ...body, stream: true }), signal, redirect: 'error' })
      let res = await send()
      if (res.status === 401 && /invalid_token/i.test(res.headers.get('www-authenticate') || '')) {
        await res.body?.cancel(); a = await fresh(true); res = await send()
      }
      return res
    },
  }
}

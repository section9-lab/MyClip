// Network-free upstream for the real, downloaded executor. Test-only --import.
import { resolve, join } from 'node:path'
import { decodeQwenBody } from '../../MyClip/Core/Resources/SubscriptionAgent/qwenwork-protocol.mjs'
const target = join(resolve(process.argv[3], '../../..'), 'Memory', 'clean-profile.md')
const marker = '# Fresh-user memory\n\nManaged runtime completed the ACP tool loop.\n'
globalThis.fetch = async (input, init = {}) => {
  const url = new URL(input)
  const json = data => Response.json({ code: 0, data })
  if (url.pathname === '/v3/config') return json({ agents: [{ name: 'cli', models: ['fixture-vision'] }],
    models: [{ id: 'fixture-vision', supportsImages: true, supportsToolCall: true, maxInputTokens: 100000, maxOutputTokens: 4096 }] })
  if (url.pathname.endsWith('/model/list')) return Response.json({ qwork: [
    { key: 'fixture-vision', display_name: 'Fixture vision', is_vl: true, max_input_tokens: 100000 },
  ] })
  if (url.pathname.endsWith('/account-context')) return Response.json({ data: { user: { id: 'fixture', name: 'Fixture' },
    plan: { name: 'Fixture plan' }, quota: { used: 0, total: 10, remaining: 10 } } })
  if (url.pathname.includes('/billing/')) return json({ Packages: [] })
  const qwen = url.pathname.endsWith('/agent_chat_generation')
  if (!qwen && url.pathname !== '/v2/chat/completions') throw new Error('Unexpected upstream host/path')
  const body = JSON.parse(qwen ? decodeQwenBody(init.body) : init.body)
  const tool = (body.tools ?? []).find(t => t.function?.name === 'write')
  const finished = (body.messages ?? []).some(m => m.role === 'tool' && m.tool_call_id === 'fixture-write')
  let delta, reason
  if (tool && !finished) {
    const properties = tool.function.parameters?.properties ?? {}
    const args = { content: marker, [properties.filePath ? 'filePath' : 'path']: target }
    delta = { role: 'assistant', tool_calls: [{ index: 0, id: 'fixture-write', type: 'function',
      function: { name: 'write', arguments: JSON.stringify(args) } }] }
    reason = 'tool_calls'
  } else { delta = { role: 'assistant', content: 'Memory saved.' }; reason = 'stop' }
  const chunk = { id: 'fixture-completion', object: 'chat.completion.chunk', model: 'fixture-vision',
    choices: [{ index: 0, delta, finish_reason: null }] }
  const finish = { ...chunk, choices: [{ index: 0, delta: {}, finish_reason: reason }] }
  const encode = value => 'data: ' + JSON.stringify(qwen ? { statusCodeValue: 200, body: JSON.stringify(value) } : value) + '\n\n'
  return new Response(encode(chunk) + encode(finish) + (qwen ? 'data: {"body":"[DONE]"}\n\n' : 'data: [DONE]\n\n'),
    { headers: { 'Content-Type': 'text/event-stream' } })
}

// Loaded only by the test process with Node's --import, never by production.
globalThis.fetch = async input => {
  const path = new URL(input).pathname
  const data = path === '/v3/config' ? {
    agents: [{ name: 'cli', models: ['fixture-vision'] }],
    models: [{ id: 'fixture-vision', supportsImages: true, supportsToolCall: true }],
  } : { Packages: [] }
  if (path === '/v2/chat/completions') return new Response('fixture channel refused', { status: 403 })
  if (!['/v3/config', '/billing/meter/get-user-resource-summary'].includes(path)) throw new Error('Unexpected fixture request')
  return Response.json({ code: 0, data })
}

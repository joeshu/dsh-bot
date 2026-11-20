import { defineTool } from '@deepseek-ai/dsh-tools'
import { iosHost } from './index.mjs'

function resultText(value) {
  if (typeof value?.output === 'string') return [{ type: 'text', text: value.output }]
  return [{ type: 'text', text: JSON.stringify(value) }]
}

function apply(context) {
  const unregisterFetch = context.web.registerFetchProvider({
    id: 'dsbot-ios-approved',
    title: 'DS Bot iOS',
    available: () => true,
    async fetch({ url }, signal) {
      const { rpc, runtime } = iosHost()
      const [turn] = runtime.activeTurns.values()
      if (!turn || turn.done) throw new Error('Web fetch requires an active user turn')
      const result = await rpc.request('native.tool.execute', {
        name: 'web_fetch', args: { url }, botId: turn.botId, sessionId: turn.botId,
        turnId: turn.turnId, isGroup: turn.isGroup,
      }, 90_000, signal)
      try {
        return JSON.parse(result.output)
      } catch {
        throw new Error(result.output || 'Native web fetch failed')
      }
    },
  })
  const bridge = async (name, args, exec) => {
    const { rpc, runtime } = iosHost()
    const id = exec.agent.session.id
    const active = runtime.activeTurns.get(id)
    if (!active) throw new Error('The iOS tool bridge is available only during an active user turn')
    const botId = id.startsWith('ios:') ? id.slice(4) : id
    const result = await rpc.request('native.tool.execute', {
      name, args, botId, sessionId: botId, turnId: active.turnId, isGroup: active.isGroup,
    }, 120_000, exec.signal)
    return { output: String(result.output ?? '') }
  }
  const output = { type: 'object', properties: { output: { type: 'string' } }, additionalProperties: false }
  const common = { output: { schema: output, render: (_args, value) => resultText(value) } }
  const definitions = [
    defineTool({
      ...common, name: 'js_eval',
      description: 'Evaluate a short calculation or data transform in the iOS JavaScript sandbox. No filesystem, network, or process access.',
      parameters: { script: { type: 'string', required: true, description: 'JavaScript expression or short script.' } }, timeoutMs: 5_000,
      execute: (args, exec) => bridge('js_eval', args, exec),
    }),
    defineTool({
      ...common, name: 'device_status', description: 'Read the current iPhone operating system, power, thermal, and hardware summary.',
      parameters: {}, timeoutMs: 10_000, execute: (args, exec) => bridge('device_status', args, exec),
    }),
    defineTool({
      ...common, name: 'memory_save', description: 'Save a user-approved memory in the selected DS Bot memory space.',
      parameters: { title: { type: 'string', required: true }, content: { type: 'string', required: true }, layer: { type: 'string', enum: ['delta', 'pinned'] } },
      timeoutMs: 70_000, execute: (args, exec) => bridge('memory_save', args, exec),
    }),
    defineTool({
      ...common, name: 'group_todo_add', description: 'Add a user-approved task to the current group bot checklist.',
      parameters: { text: { type: 'string', required: true } }, timeoutMs: 70_000, execute: (args, exec) => bridge('group_todo_add', args, exec),
    }),
    defineTool({
      ...common, name: 'web_fetch', description: 'Fetch a text or HTML HTTPS page after the user approves its exact address.',
      parameters: { url: { type: 'string', required: true } }, timeoutMs: 70_000, execute: async (args, exec) => {
        const { runtime } = iosHost()
        if (!runtime.activeTurns.has(exec.agent.session.id)) throw new Error('Only the parent Agent can request a web fetch')
        const result = await context.web.fetch(args, exec.signal)
        return { output: result.body.content }
      },
    }),
    defineTool({
      ...common, name: 'remote_mcp_call', description: 'Call a user-configured Remote MCP tool after the user approves the connector and tool.',
      parameters: { connectorName: { type: 'string', required: true }, toolName: { type: 'string', required: true }, arguments: { type: 'json' } },
      timeoutMs: 70_000, execute: (args, exec) => bridge('remote_mcp_call', args, exec),
    }),
  ]
  const removers = definitions.map((definition) => context.tools.register(definition))
  context.effect(() => () => { unregisterFetch(); removers.reverse().forEach((remove) => remove()) }, 'dsbot-ios.nativeTools')
}

export default { name: 'dsbot-ios-native-tools', inject: ['tools', 'web'], apply }

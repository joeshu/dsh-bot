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
      ...common, name: 'remote_mcp_list',
      description: 'List configured Remote MCP connectors, or pass connectorName to discover its available tools and input schemas.',
      parameters: { connectorName: { type: 'string', description: 'Optional connector name to list tools for.' } },
      timeoutMs: 70_000, execute: (args, exec) => bridge('remote_mcp_list', args, exec),
    }),
    defineTool({
      ...common, name: 'remote_mcp_call', description: 'Call a user-configured Remote MCP tool after the user approves the connector and tool.',
      parameters: { connectorName: { type: 'string', required: true }, toolName: { type: 'string', required: true }, arguments: { type: 'json' } },
      timeoutMs: 70_000, execute: (args, exec) => bridge('remote_mcp_call', args, exec),
    }),
    defineTool({
      ...common, name: 'workspace_list',
      description: 'List files inside the sandboxed DS Bot workspace files/ folder (visible in the iOS Files app).',
      parameters: { path: { type: 'string', description: 'Optional relative subfolder inside files/.' } },
      timeoutMs: 10_000, execute: (args, exec) => bridge('workspace_list', args, exec),
    }),
    defineTool({
      ...common, name: 'workspace_read',
      description: 'Read a UTF-8 text file (up to 64 KB) inside the sandboxed DS Bot workspace files/ folder.',
      parameters: { path: { type: 'string', required: true, description: 'Relative path inside files/.' } },
      timeoutMs: 10_000, execute: (args, exec) => bridge('workspace_read', args, exec),
    }),
    defineTool({
      ...common, name: 'workspace_write',
      description: 'Write a UTF-8 text file (up to 256 KB) inside the sandboxed DS Bot workspace files/ folder after user approval.',
      parameters: {
        path: { type: 'string', required: true, description: 'Relative path inside files/.' },
        content: { type: 'string', required: true, description: 'UTF-8 file content to write.' },
      },
      timeoutMs: 70_000, execute: (args, exec) => bridge('workspace_write', args, exec),
    }),
    defineTool({
      ...common, name: 'workspace_search',
      description: 'Search UTF-8 text files inside the sandboxed DS Bot workspace files/ folder by substring.',
      parameters: {
        query: { type: 'string', required: true, description: 'Text substring to search for (case-insensitive).' },
        path: { type: 'string', description: 'Optional relative subfolder inside files/.' },
      },
      timeoutMs: 10_000, execute: (args, exec) => bridge('workspace_search', args, exec),
    }),
    defineTool({
      ...common, name: 'workspace_edit',
      description: 'Replace an exact text snippet inside a UTF-8 file in the sandboxed DS Bot workspace files/ folder after user approval.',
      parameters: {
        path: { type: 'string', required: true, description: 'Relative path inside files/.' },
        old_text: { type: 'string', required: true, description: 'Exact existing text to replace.' },
        new_text: { type: 'string', required: true, description: 'Replacement text.' },
      },
      timeoutMs: 70_000, execute: (args, exec) => bridge('workspace_edit', args, exec),
    }),
    defineTool({
      ...common, name: 'terminal_exec',
      description: 'Run a command inside the persistent iOS Sandboxed Virtual Terminal (PTY) rooted at the workspace files/ directory. Retains cwd, env, and command history across calls. Supports pwd, cd, ls, ll, cat, head, tail, mkdir, touch, cp, mv, rm, find, grep, wc, echo, env, export, date, uname, whoami, node -e, python -c, and git status/diff/log.',
      parameters: {
        command: { type: 'string', required: true, description: 'Shell command to execute inside the sandboxed virtual terminal.' },
      },
      timeoutMs: 70_000,
      async execute(args, exec) {
        const { runtime } = iosHost()
        if (typeof runtime.executeVirtualTerminal !== 'function') {
          throw new Error('The iOS Sandboxed Virtual Terminal is not initialized.')
        }
        return await runtime.executeVirtualTerminal(args, exec)
      },
    }),
    defineTool({
      ...common, name: 'git_workspace',
      description: 'Inspect or synchronize the iOS Git Worktree & PR Tracker inside the workspace files/ directory. Supports actions: status (list modified/added/deleted files vs snapshot), diff (unified diff of workspace changes), snapshot (record current workspace as clean baseline), and pr_list (fetch open pull requests for a bound GitHub owner/repo).',
      parameters: {
        action: { type: 'string', required: true, enum: ['status', 'diff', 'snapshot', 'pr_list'], description: 'Git workspace action to run.' },
        repo: { type: 'string', description: 'Optional GitHub repository in owner/repo format for pr_list.' },
        path: { type: 'string', description: 'Optional relative file path for diff.' },
      },
      timeoutMs: 60_000,
      async execute(args, exec) {
        const { runtime } = iosHost()
        if (typeof runtime.executeGitWorkspaceTool !== 'function') {
          throw new Error('The iOS Git Worktree & PR Tracker is not initialized.')
        }
        return await runtime.executeGitWorkspaceTool(args, exec)
      },
    }),
  ]
  const removers = definitions.map((definition) => context.tools.register(definition))
  context.effect(() => () => { unregisterFetch(); removers.reverse().forEach((remove) => remove()) }, 'dsbot-ios.nativeTools')
}

export default { name: 'dsbot-ios-native-tools', inject: ['tools', 'web'], apply }

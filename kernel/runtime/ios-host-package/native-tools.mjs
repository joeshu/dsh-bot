import { existsSync, mkdirSync, readdirSync, readFileSync, statSync, writeFileSync } from 'node:fs'
import { dirname, isAbsolute, join, relative, resolve, sep } from 'node:path'
import vm from 'node:vm'
import { defineTool } from '@deepseek-ai/dsh-tools'
import { iosHost } from './index.mjs'

function resultText(value) {
  if (typeof value?.output === 'string') return [{ type: 'text', text: value.output }]
  return [{ type: 'text', text: JSON.stringify(value) }]
}

function resolveSandboxedWorkspacePath(workspace, rawPath = '') {
  const root = resolve(workspace, 'files')
  mkdirSync(root, { recursive: true })
  let text = String(rawPath ?? '').replaceAll('\\', '/').trim()
  if (text === '/workspace' || text === '/workspace/' || text === 'files' || text === 'files/' || text === '.' || text === './') {
    return { root, abs: root, rel: '' }
  }
  if (text.startsWith('/workspace/')) text = text.slice('/workspace/'.length)
  else if (text.startsWith('files/')) text = text.slice('files/'.length)
  while (text.startsWith('./')) text = text.slice(2)
  const abs = resolve(root, text)
  const rel = relative(root, abs)
  if (rel === '..' || rel.startsWith(`..${sep}`) || isAbsolute(rel)) {
    throw new Error('Path escapes the iOS files/ workspace')
  }
  return { root, abs, rel: rel.split(sep).join('/') }
}

async function executeWebFallbackTool(context, name, args, exec) {
  const { workspace } = iosHost()
  if (name === 'js_eval') {
    const script = String(args?.script ?? '')
    const logs = []
    const sandbox = {
      console: {
        log: (...items) => logs.push(items.map((x) => typeof x === 'string' ? x : JSON.stringify(x)).join(' ')),
        error: (...items) => logs.push(items.map((x) => typeof x === 'string' ? x : JSON.stringify(x)).join(' ')),
      },
      Math, Date, JSON, Number, String, Boolean, Array, Object,
    }
    const result = vm.runInNewContext(script, sandbox, { timeout: 2_000 })
    if (result !== undefined) logs.push(typeof result === 'string' ? result : JSON.stringify(result, null, 2))
    return { output: logs.join('\n') }
  }
  if (name === 'workspace_list') {
    const { abs } = resolveSandboxedWorkspacePath(workspace, args?.path ?? '')
    const entries = readdirSync(abs, { withFileTypes: true })
      .filter((e) => !e.name.startsWith('.'))
      .map((e) => (e.isDirectory() ? `${e.name}/` : e.name))
      .sort()
    return { output: entries.length ? entries.join('\n') : '(空目录)' }
  }
  if (name === 'workspace_read') {
    const { abs, rel } = resolveSandboxedWorkspacePath(workspace, args?.path ?? '')
    if (!rel || !existsSync(abs) || !statSync(abs).isFile()) throw new Error(`File not found: files/${rel}`)
    const content = readFileSync(abs, 'utf8')
    return { output: content.length > 65_536 ? `${content.slice(0, 65_536)}\n…(truncated)` : content }
  }
  if (name === 'workspace_search') {
    const query = String(args?.query ?? '').toLowerCase()
    if (!query) throw new Error('workspace_search requires a non-empty query')
    const { abs, root } = resolveSandboxedWorkspacePath(workspace, args?.path ?? '')
    const hits = []
    const walk = (dir) => {
      for (const entry of readdirSync(dir, { withFileTypes: true })) {
        if (entry.name.startsWith('.') || hits.length >= 80) continue
        const full = join(dir, entry.name)
        if (entry.isDirectory()) walk(full)
        else if (entry.isFile() && statSync(full).size <= 256 * 1024) {
          const lines = readFileSync(full, 'utf8').split(/\r?\n/)
          const display = relative(root, full).split(sep).join('/')
          lines.forEach((line, idx) => {
            if (hits.length < 80 && line.toLowerCase().includes(query)) {
              hits.push(`${display}:${idx + 1}: ${line.slice(0, 240)}`)
            }
          })
        }
      }
    }
    walk(abs)
    return { output: hits.length ? hits.join('\n') : '(无匹配结果)' }
  }
  if (name === 'workspace_write' || name === 'workspace_edit') {
    const { abs, rel } = resolveSandboxedWorkspacePath(workspace, args?.path ?? '')
    if (!rel) throw new Error('A file path inside files/ is required')
    if (context.approval?.request) {
      const outcome = await context.approval.request({
        agent: exec.agent,
        toolName: name,
        ...(exec.callId ? { callId: exec.callId } : {}),
        reason: `Modify workspace file files/${rel}`,
        displayReason: `允许 ${name} 修改工作区文件 files/${rel}？`,
        signal: exec.signal,
      })
      if (outcome !== 'allowed-once') throw new Error(`User did not approve ${name} for files/${rel}`)
    }
    if (name === 'workspace_write') {
      const content = String(args?.content ?? '')
      if (Buffer.byteLength(content, 'utf8') > 262_144) throw new Error('File write exceeds 256 KB limit')
      mkdirSync(dirname(abs), { recursive: true })
      writeFileSync(abs, content, 'utf8')
      return { output: `已写入 files/${rel}（${Buffer.byteLength(content, 'utf8')} 字节）` }
    }
    if (!existsSync(abs)) throw new Error(`File not found: files/${rel}`)
    const current = readFileSync(abs, 'utf8')
    const oldText = String(args?.old_text ?? '')
    const newText = String(args?.new_text ?? '')
    if (!oldText || !current.includes(oldText)) throw new Error(`old_text not found in files/${rel}`)
    writeFileSync(abs, current.replace(oldText, newText), 'utf8')
    return { output: `已更新 files/${rel}` }
  }
  return undefined
}

function apply(context) {
  const unregisterFetch = context.web.registerFetchProvider({
    id: 'dsbot-ios-approved',
    title: 'DS Bot iOS',
    available: () => true,
    async fetch({ url }, signal) {
      const { rpc, runtime } = iosHost()
      const [turn] = runtime.activeTurns.values()
      if (!turn || turn.done) {
        const parsed = new URL(String(url ?? ''))
        if (parsed.protocol !== 'https:') throw new Error('web_fetch only supports HTTPS URLs')
        const host = parsed.hostname.toLowerCase()
        if (host === 'localhost' || host === '127.0.0.1' || host === '::1' || host.endsWith('.local')
          || /^(10\.|192\.168\.|169\.254\.|172\.(1[6-9]|2\d|3[01])\.)/.test(host)) {
          throw new Error('web_fetch blocked private or loopback address')
        }
        const timeoutSignal = AbortSignal.timeout(15_000)
        const combinedSignal = signal ? AbortSignal.any([signal, timeoutSignal]) : timeoutSignal
        const resp = await globalThis.fetch(parsed.toString(), { signal: combinedSignal, redirect: 'follow' })
        const text = (await resp.text()).slice(0, 131_072)
        return {
          url: resp.url || parsed.toString(),
          status: resp.status,
          contentType: resp.headers.get('content-type') || 'text/plain',
          body: { content: text },
        }
      }
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
    if (!active) {
      const fallback = await executeWebFallbackTool(context, name, args, exec)
      if (fallback !== undefined) return fallback
      throw new Error('The iOS tool bridge is available only during an active user turn')
    }
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
        if (exec?.agent?.session?.header?.parentSession != null) {
          throw new Error('Only the parent Agent can request a web fetch')
        }
        const isNativeTurn = runtime.activeTurns.has(exec?.agent?.session?.id)
        if (!isNativeTurn && context.approval?.request) {
          const outcome = await context.approval.request({
            agent: exec.agent,
            toolName: 'web_fetch',
            ...(exec.callId ? { callId: exec.callId } : {}),
            reason: `Fetch HTTPS page: ${String(args?.url ?? '')}`,
            displayReason: `允许访问以下 HTTPS 网页？\n${String(args?.url ?? '')}`,
            signal: exec.signal,
          })
          if (outcome !== 'allowed-once') throw new Error('User did not approve web_fetch')
        }
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

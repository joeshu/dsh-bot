import { existsSync, mkdirSync, readdirSync, readFileSync, realpathSync, statSync, writeFileSync } from 'node:fs'
import { lookup as dnsLookup } from 'node:dns/promises'
import { isIP } from 'node:net'
import { basename, dirname, isAbsolute, join, relative, resolve, sep } from 'node:path'
import vm from 'node:vm'
import { defineTool } from '@deepseek-ai/dsh-tools'
import { iosHost } from './index.mjs'

function resultText(value) {
  if (typeof value?.output === 'string') return [{ type: 'text', text: value.output }]
  return [{ type: 'text', text: JSON.stringify(value) }]
}

function canonicalizePath(targetPath) {
  let current = resolve(targetPath)
  const suffix = []
  for (let depth = 0; depth < 64; depth++) {
    try {
      const real = realpathSync(current)
      return suffix.length ? resolve(real, ...suffix) : real
    } catch {
      const parent = dirname(current)
      if (parent === current) break
      suffix.unshift(basename(current))
      current = parent
    }
  }
  return resolve(targetPath)
}

function isPrivateOrReservedIPv4(ip) {
  const parts = ip.split('.').map(Number)
  if (parts.length !== 4 || parts.some((n) => !Number.isInteger(n) || n < 0 || n > 255)) return true
  const [a, b] = parts
  if (a === 0 || a === 10 || a === 127) return true
  if (a === 100 && b >= 64 && b <= 127) return true // CGNAT 100.64.0.0/10
  if (a === 169 && b === 254) return true // link-local / cloud metadata
  if (a === 172 && b >= 16 && b <= 31) return true
  if (a === 192 && b === 168) return true
  if (a === 192 && b === 0 && parts[2] === 0) return true
  if (a === 198 && (b === 18 || b === 19)) return true
  if (a >= 224) return true // multicast / reserved
  return false
}

export function isPrivateOrReservedIP(raw) {
  const ip = String(raw ?? '').trim().toLowerCase().replace(/^\[|\]$/g, '').split('%')[0]
  const ver = isIP(ip)
  if (ver === 4) return isPrivateOrReservedIPv4(ip)
  if (ver === 6) {
    if (ip === '::' || ip === '::1') return true
    if (ip.startsWith('fc') || ip.startsWith('fd')) return true // ULA fc00::/7
    if (/^fe[89ab]/.test(ip)) return true // link-local fe80::/10
    if (ip.startsWith('ff')) return true // multicast
    const mappedV4 = /^::ffff:(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})$/.exec(ip)
    if (mappedV4) return isPrivateOrReservedIPv4(mappedV4[1])
    const mappedHex = /^::ffff:([0-9a-f]{1,4}):([0-9a-f]{1,4})$/.exec(ip)
    if (mappedHex) {
      const hi = parseInt(mappedHex[1], 16)
      const lo = parseInt(mappedHex[2], 16)
      return isPrivateOrReservedIPv4(`${(hi >> 8) & 255}.${hi & 255}.${(lo >> 8) & 255}.${lo & 255}`)
    }
    return false
  }
  return true
}

async function assertSafePublicHttpsUrl(rawUrl) {
  let parsed
  try {
    parsed = new URL(String(rawUrl ?? ''))
  } catch {
    throw new Error('web_fetch requires a valid HTTPS URL')
  }
  if (parsed.protocol !== 'https:' || parsed.username || parsed.password) {
    throw new Error('web_fetch only supports credential-free HTTPS URLs')
  }
  const host = parsed.hostname.toLowerCase().replace(/^\[|\]$/g, '')
  if (!host || host === 'localhost' || host.endsWith('.local') || host.endsWith('.internal')) {
    throw new Error('web_fetch blocked private or loopback address')
  }
  if (isIP(host)) {
    if (isPrivateOrReservedIP(host)) throw new Error('web_fetch blocked private or loopback address')
    return parsed
  }
  const resolved = await dnsLookup(host, { all: true, verbatim: true })
  if (!Array.isArray(resolved) || resolved.length === 0) {
    throw new Error(`web_fetch could not resolve host: ${host}`)
  }
  for (const record of resolved) {
    if (isPrivateOrReservedIP(record.address)) {
      throw new Error('web_fetch blocked private or loopback address')
    }
  }
  return parsed
}

async function safePublicHttpsFetch(rawUrl, { maxBytes = 131_072, maxRedirects = 5, timeoutMs = 15_000, signal } = {}) {
  const timeoutSignal = AbortSignal.timeout(timeoutMs)
  const combinedSignal = signal ? AbortSignal.any([signal, timeoutSignal]) : timeoutSignal
  let current = await assertSafePublicHttpsUrl(rawUrl)
  let resp
  for (let hop = 0; ; hop++) {
    resp = await globalThis.fetch(current.toString(), { signal: combinedSignal, redirect: 'manual' })
    if (![301, 302, 303, 307, 308].includes(resp.status)) break
    const location = resp.headers.get('location')
    await resp.body?.cancel().catch(() => {})
    if (!location || hop >= maxRedirects) throw new Error('web_fetch rejected invalid or excessive redirects')
    current = await assertSafePublicHttpsUrl(new URL(location, current).toString())
  }
  const reader = resp.body?.getReader()
  if (!reader) {
    return {
      url: current.toString(),
      status: resp.status,
      contentType: resp.headers.get('content-type') || 'text/plain',
      body: { content: '' },
    }
  }
  const chunks = []
  let total = 0
  let truncated = false
  try {
    while (true) {
      const { done, value } = await reader.read()
      if (done) break
      const remaining = maxBytes - total
      if (value.byteLength > remaining) {
        chunks.push(Buffer.from(value.subarray(0, remaining)))
        total += remaining
        truncated = true
        await reader.cancel().catch(() => {})
        break
      }
      chunks.push(Buffer.from(value))
      total += value.byteLength
    }
  } finally {
    reader.releaseLock?.()
  }
  const text = Buffer.concat(chunks, total).toString('utf8')
  return {
    url: current.toString(),
    status: resp.status,
    contentType: resp.headers.get('content-type') || 'text/plain',
    body: { content: truncated ? `${text}\n…(truncated at ${maxBytes} bytes)` : text },
  }
}

function resolveSandboxedWorkspacePath(workspace, rawPath = '') {
  const rawRoot = resolve(workspace, 'files')
  mkdirSync(rawRoot, { recursive: true })
  const root = canonicalizePath(rawRoot)
  let text = String(rawPath ?? '').replaceAll('\\', '/').trim()
  if (text.includes('\0')) throw new Error('Path contains invalid null byte')
  if (text === '/workspace' || text === '/workspace/' || text === 'files' || text === 'files/' || text === '.' || text === './') {
    return { root, abs: root, rel: '' }
  }
  if (text.startsWith('/workspace/')) text = text.slice('/workspace/'.length)
  else if (text.startsWith('files/')) text = text.slice('files/'.length)
  while (text.startsWith('./')) text = text.slice(2)
  const abs = canonicalizePath(resolve(root, text))
  const rel = relative(root, abs)
  if (rel === '..' || rel.startsWith(`..${sep}`) || isAbsolute(rel)) {
    throw new Error('Path escapes the iOS files/ workspace')
  }
  return { root, abs, rel: rel.split(sep).join('/') }
}

async function runHardenedQuickJS(rpc, script, timeoutMs = 2_000, signal) {
  if (rpc && typeof rpc.request === 'function') {
    const res = await rpc.request('sandbox.js_eval', { script, timeoutMs }, Math.max(5_000, timeoutMs + 3_000), signal)
    if (res?.ok === false) throw new Error(String(res.error || 'JavaScript evaluation failed'))
    return { output: String(res?.output ?? '') }
  }
  // Strict fallback only when native QuickJS RPC is unavailable (headless tests):
  // null-prototype context + disabled string codegen, zero host intrinsics passed in.
  const logs = []
  const ctx = vm.createContext(Object.create(null), { codeGeneration: { strings: false, wasm: false } })
  ctx.__emit = (line) => { if (logs.length < 200) logs.push(String(line).slice(0, 2000)) }
  vm.runInContext(
    'globalThis.console = Object.freeze({ log: (...a) => __emit(a.map(String).join(" ")), error: (...a) => __emit(a.map(String).join(" ")) });',
    ctx,
    { timeout: 500 }
  )
  const result = vm.runInContext(script, ctx, { timeout: timeoutMs })
  if (result !== undefined) logs.push(typeof result === 'string' ? result : JSON.stringify(result, null, 2))
  return { output: logs.join('\n') }
}

async function executeWebFallbackTool(context, name, args, exec) {
  const { workspace, rpc } = iosHost()
  if (name === 'js_eval') {
    const script = String(args?.script ?? '')
    return await runHardenedQuickJS(rpc, script, 2_000, exec?.signal)
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
    const info = statSync(abs)
    if (info.size > 512 * 1024) throw new Error(`File exceeds 512 KB read limit: files/${rel}`)
    const content = readFileSync(abs, 'utf8')
    return { output: content.length > 65_536 ? `${content.slice(0, 65_536)}\n…(truncated)` : content }
  }
  if (name === 'workspace_search') {
    const query = String(args?.query ?? '').toLowerCase()
    if (!query) throw new Error('workspace_search requires a non-empty query')
    const { abs, root } = resolveSandboxedWorkspacePath(workspace, args?.path ?? '')
    const hits = []
    const visited = new Set()
    const walk = (dir, depth = 0) => {
      if (depth > 12 || hits.length >= 80) return
      const canonicalDir = canonicalizePath(dir)
      const dirRel = relative(root, canonicalDir)
      if (dirRel === '..' || dirRel.startsWith(`..${sep}`) || isAbsolute(dirRel)) return
      if (visited.has(canonicalDir)) return
      visited.add(canonicalDir)
      for (const entry of readdirSync(canonicalDir, { withFileTypes: true })) {
        if (entry.name.startsWith('.') || entry.isSymbolicLink() || hits.length >= 80) continue
        const full = join(canonicalDir, entry.name)
        if (entry.isDirectory()) walk(full, depth + 1)
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
      const turn = runtime.activeTurns.size === 1 ? [...runtime.activeTurns.values()][0] : undefined
      if (!turn || turn.done) {
        return await safePublicHttpsFetch(url, { maxBytes: 131_072, maxRedirects: 5, timeoutMs: 15_000, signal })
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

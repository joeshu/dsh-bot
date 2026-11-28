import { existsSync, mkdirSync, readdirSync, readFileSync, realpathSync, statSync, writeFileSync } from 'node:fs'
import { lookup as dnsLookup } from 'node:dns/promises'
import { isIP } from 'node:net'
import { basename, dirname, isAbsolute, join, relative, resolve, sep } from 'node:path'
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
    resp = await globalThis.fetch(current.toString(), {
      signal: combinedSignal,
      redirect: 'manual',
      headers: {
        'User-Agent': 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1',
        'Accept': 'text/html,application/xhtml+xml,application/json,text/plain;q=0.9,*/*;q=0.8',
      },
    })
    if (![301, 302, 303, 307, 308].includes(resp.status)) break
    const location = resp.headers.get('location')
    await resp.body?.cancel().catch(() => {})
    if (!location || hop >= maxRedirects) throw new Error('web_fetch rejected invalid or excessive redirects')
    current = await assertSafePublicHttpsUrl(new URL(location, current).toString())
  }
  const contentType = resp.headers.get('content-type') || 'text/plain'
  const bodyKind = contentType.toLowerCase().includes('html') ? 'html' : 'text'
  const reader = resp.body?.getReader()
  if (!reader) {
    return {
      url: current.toString(),
      status: resp.status,
      statusCode: resp.status,
      contentType,
      truncated: false,
      body: { kind: bodyKind, content: '' },
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
    statusCode: resp.status,
    contentType,
    truncated,
    body: { kind: bodyKind, content: truncated ? `${text}\n…(truncated at ${maxBytes} bytes)` : text },
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
  if (!rpc || typeof rpc.request !== 'function') {
    throw new Error('Native QuickJS bridge is unavailable; JavaScript execution failed closed.')
  }
  const res = await rpc.request('sandbox.js_eval', { script, timeoutMs }, Math.max(5_000, timeoutMs + 3_000), signal)
  if (res?.ok === false) throw new Error(String(res.error || 'JavaScript evaluation failed'))
  return { output: String(res?.output ?? '') }
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
  if (name === 'device_status') {
    if (rpc && typeof rpc.request === 'function') {
      const st = await rpc.request('device.status', {}, 5_000)
      return { output: JSON.stringify(st) }
    }
    return { output: JSON.stringify({ platform: process.platform, arch: process.arch, note: 'Running in DSH Web Workbench context' }) }
  }
  if (name === 'memory_save' || name === 'group_todo_add' || name === 'remote_mcp_list' || name === 'remote_mcp_call') {
    throw new Error(`工具 ${name} 仅在原生 iOS Bot 会话中可用，当前 Web 工作台独立会话不支持该原生端侧桥接。`)
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
    }, name === 'terminal_exec' ? 180_000 : 120_000, exec.signal)
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
      description: 'Run one command in an isolated ARM64 Alpine Linux shell backed by a real guest PTY. Each command requires a separate user approval, including in autoReview mode. The guest has no network access and cannot directly access iOS app files.',
      parameters: {
        command: { type: 'string', required: true, description: 'A POSIX shell command, up to 8,000 characters / 32 KiB, with each line at most 3.5 KiB. It runs in a fresh unprivileged ARM64 Linux PTY and requires one-time user approval.' },
      },
      timeoutMs: 180_000,
      execute: (args, exec) => bridge('terminal_exec', args, exec),
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
    ...(() => {
      async function runBrowserAction(action, args, exec, { mutating = false, askInStandard = false, summary = '' } = {}) {
        const { rpc, runtime } = iosHost()
        const sessionId = exec?.agent?.session?.id
        const active = typeof sessionId === 'string' ? runtime.activeTurns.get(sessionId) : undefined
        if (typeof sessionId === 'string' && sessionId.startsWith('ios:')) {
          const botId = sessionId.slice(4).split(':')[0]
          if (runtime.privateBotIds?.has(botId)) {
            throw new Error('私密会话禁止控制 App 内置浏览器。')
          }
        }
        const permissionMode = active?.permissionMode ?? 'ask'
        if (permissionMode === 'readOnly' && mutating) {
          throw new Error(`只读保护模式已拦截网页交互操作 browser_${action}。`)
        }
        if (permissionMode !== 'autoReview' && askInStandard && context.approval?.request) {
          const outcome = await context.approval.request({
            agent: exec.agent,
            toolName: `browser_${action}`,
            ...(exec.callId ? { callId: exec.callId } : {}),
            reason: summary || `Run in-app browser action: ${action}`,
            displayReason: summary || `允许 Bot 在内置浏览器执行 ${action}？`,
            signal: exec.signal,
          })
          if (outcome !== 'allowed-once') throw new Error(`用户未批准内置浏览器操作 browser_${action}`)
        }
        const result = await rpc.request('browser.action', { action, args: args ?? {} }, 35_000)
        return { output: JSON.stringify(result, null, 2) }
      }
      return [
        defineTool({
          ...common, name: 'browser_open',
          description: 'Open a public HTTPS URL inside the live iOS in-app WKWebView browser (visible to the user for live viewing or manual login takeover) and return the page title, visible text, and indexed interactive elements.',
          parameters: {
            url: { type: 'string', required: true, description: 'Public HTTPS URL to open.' },
            maxChars: { type: 'number', description: 'Optional max text characters to return (default 8000).' },
          },
          timeoutMs: 45_000,
          execute: (args, exec) => runBrowserAction('open', args, exec, {
            mutating: false, askInStandard: true,
            summary: `允许 Bot 在 App 内置浏览器中打开网页？\n${String(args?.url ?? '')}`,
          }),
        }),
        defineTool({
          ...common, name: 'browser_snapshot',
          description: 'Read the current URL, title, visible text, and indexed interactive elements ([0], [1], ...) of the active iOS in-app browser page.',
          parameters: {
            maxChars: { type: 'number', description: 'Optional max text characters (500–16000, default 10000).' },
          },
          timeoutMs: 25_000,
          execute: (args, exec) => runBrowserAction('snapshot', args, exec, { mutating: false, askInStandard: false }),
        }),
        defineTool({
          ...common, name: 'browser_click',
          description: 'Click an interactive element in the iOS in-app browser by snapshot index, CSS selector, or visible button/link text, then return the updated page snapshot.',
          parameters: {
            index: { type: 'number', description: 'Element index from the latest browser_snapshot.' },
            selector: { type: 'string', description: 'Optional CSS selector.' },
            text: { type: 'string', description: 'Optional visible text of the button or link.' },
          },
          timeoutMs: 35_000,
          execute: (args, exec) => runBrowserAction('click', args, exec, {
            mutating: true, askInStandard: true,
            summary: `允许 Bot 点击内置浏览器页面元素？\n${JSON.stringify(args ?? {})}`,
          }),
        }),
        defineTool({
          ...common, name: 'browser_type',
          description: 'Type text into an input or textarea in the iOS in-app browser (React/Vue SPA compatible) by snapshot index or CSS selector, optionally submitting the form.',
          parameters: {
            index: { type: 'number', description: 'Input element index from browser_snapshot.' },
            selector: { type: 'string', description: 'Optional CSS selector for the input.' },
            text: { type: 'string', required: true, description: 'Text to fill into the input.' },
            submit: { type: 'boolean', description: 'Whether to submit the form or press Enter after typing.' },
          },
          timeoutMs: 35_000,
          execute: (args, exec) => runBrowserAction('type', args, exec, {
            mutating: true, askInStandard: true,
            summary: `允许 Bot 在内置浏览器输入框填入内容${args?.submit ? '并提交' : ''}？\n长度：${String(args?.text ?? '').length} 字符`,
          }),
        }),
        defineTool({
          ...common, name: 'browser_select',
          description: 'Select an option in a <select> dropdown in the iOS in-app browser by value, visible label, or optionIndex (avoids triggering native iOS picker sheets).',
          parameters: {
            index: { type: 'number', description: 'Select element index from browser_snapshot.' },
            selector: { type: 'string', description: 'Optional CSS selector for the <select>.' },
            value: { type: 'string', description: 'Option value attribute to select.' },
            label: { type: 'string', description: 'Visible option text to match.' },
            optionIndex: { type: 'number', description: 'Zero-based option index from browser_snapshot options array.' },
          },
          timeoutMs: 30_000,
          execute: (args, exec) => runBrowserAction('select', args, exec, {
            mutating: true, askInStandard: true,
            summary: `允许 Bot 在内置浏览器下拉框中选择选项？\n${JSON.stringify(args ?? {})}`,
          }),
        }),
        defineTool({
          ...common, name: 'browser_press_key',
          description: 'Send a keyboard key (Enter, Escape, Tab, ArrowDown, ArrowUp, Backspace, Space) to the focused element in the iOS in-app browser.',
          parameters: {
            key: { type: 'string', required: true, enum: ['Enter', 'Escape', 'Tab', 'ArrowDown', 'ArrowUp', 'Backspace', 'Space'], description: 'Keyboard key to dispatch.' },
          },
          timeoutMs: 25_000,
          execute: (args, exec) => runBrowserAction('press_key', args, exec, {
            mutating: true, askInStandard: false,
          }),
        }),
        defineTool({
          ...common, name: 'browser_scroll',
          description: 'Scroll the active iOS in-app browser page (down, up, top, or bottom) and return the updated visible text.',
          parameters: {
            direction: { type: 'string', enum: ['down', 'up', 'top', 'bottom'], description: 'Scroll direction (default down).' },
            amount: { type: 'number', description: 'Pixels to scroll for up/down (default 600).' },
          },
          timeoutMs: 25_000,
          execute: (args, exec) => runBrowserAction('scroll', args, exec, { mutating: false, askInStandard: false }),
        }),
        defineTool({
          ...common, name: 'browser_screenshot',
          description: 'Capture a JPEG screenshot of the active iOS in-app browser viewport, save it to files/, and return Vision OCR text extracted from the screenshot.',
          parameters: {},
          timeoutMs: 25_000,
          execute: (args, exec) => runBrowserAction('screenshot', args, exec, { mutating: false, askInStandard: false }),
        }),
        defineTool({
          ...common, name: 'browser_back',
          description: 'Navigate back one step in the iOS in-app browser history and return the updated page snapshot.',
          parameters: {},
          timeoutMs: 25_000,
          execute: (args, exec) => runBrowserAction('back', args, exec, { mutating: false, askInStandard: false }),
        }),
        defineTool({
          ...common, name: 'browser_wait',
          description: 'Wait up to 20 seconds for a CSS selector or visible text substring to appear in the active iOS in-app browser page, then return the updated snapshot.',
          parameters: {
            selector: { type: 'string', description: 'Optional CSS selector to wait for.' },
            text: { type: 'string', description: 'Optional visible text substring to wait for.' },
            timeoutSeconds: { type: 'number', description: 'Max seconds to wait (1–20, default 8).' },
          },
          timeoutMs: 30_000,
          execute: (args, exec) => runBrowserAction('wait', args, exec, { mutating: false, askInStandard: false }),
        }),
        defineTool({
          ...common, name: 'browser_eval',
          description: 'Evaluate a JavaScript expression inside the active iOS in-app browser page to extract structured data (tables, JSON, metrics).',
          parameters: {
            script: { type: 'string', required: true, description: 'JavaScript expression or function body to evaluate in the page.' },
          },
          timeoutMs: 30_000,
          execute: (args, exec) => runBrowserAction('eval', args, exec, {
            mutating: true, askInStandard: true,
            summary: `允许 Bot 在内置浏览器当前页面执行数据提取脚本？\n${String(args?.script ?? '').slice(0, 240)}`,
          }),
        }),
        defineTool({
          ...common, name: 'browser_handoff',
          description: 'Pause automation and notify the user to take over the live iOS in-app browser manually (for example, to sign in, complete 2FA, or solve a verification gate). Always call this instead of attempting to bypass login or verification gates.',
          parameters: {
            reason: { type: 'string', required: true, description: 'Clear Chinese explanation of what the user needs to do in the browser.' },
          },
          timeoutMs: 15_000,
          execute: (args, exec) => runBrowserAction('handoff', args, exec, { mutating: false, askInStandard: false }),
        }),
      ]
    })(),
  ]
  const removers = definitions.map((definition) => context.tools.register(definition))
  context.effect(() => () => { unregisterFetch(); removers.reverse().forEach((remove) => remove()) }, 'dsbot-ios.nativeTools')
}

export default { name: 'dsbot-ios-native-tools', inject: ['tools', 'web'], apply }

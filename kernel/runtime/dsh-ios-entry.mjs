import { EventEmitter } from 'node:events'
import { parentPort, workerData } from 'node:worker_threads'
import net from 'node:net'
import { fileURLToPath } from 'node:url'
import { configureIOSHost } from '@dsbot/dsh-ios-host'
import { auditStartupEntries, initProfile, loadLayeredEnv, loadProfileDirectory, readProfileManifest, resolveProfileDir, writeProfileBundles } from '@deepseek-ai/dsh-app-boot'
import { runProfile } from './vendor/dsh-profile-boot/lib/profile-boot.js'
import { cleanupPendingPluginRemovals, createIOSPluginManager, settlePluginRevision } from './ios-plugin-manager.mjs'
import { SessionPersistenceNotFoundError } from '@deepseek-ai/dsh-session-persistence'
import { createUserMessage } from '@deepseek-ai/dsh-llm'
import { IPCRpcEndpoint } from './ipc-protocol.mjs'

const IPC_FD = Number(process.argv.find((arg) => arg.startsWith('--ipc-fd='))?.slice('--ipc-fd='.length))
const WORKSPACE = process.argv.find((arg) => arg.startsWith('--workspace='))?.slice('--workspace='.length)
const API_BASE = process.argv.find((arg) => arg.startsWith('--api-base='))?.slice('--api-base='.length) || 'https://api.deepseek.com'
if (!Number.isInteger(IPC_FD) || IPC_FD < 0 || !WORKSPACE) throw new Error('Invalid iOS runtime arguments')
process.env.DSH_HOME = WORKSPACE
process.env.DSH_TELEMETRY_DISABLED = '1'
process.env.DS_BOT_IOS_HOST = '1'
if (!workerData?.supervised) process.chdir(WORKSPACE)

const PROFILE = 'dsbot-ios'
const PROFILE_BUNDLE = '@dsbot/dsh-ios-profile'
const INSTALL_ANCHOR = fileURLToPath(new URL('./package.json', import.meta.url))
const PROFILE_DIR = resolveProfileDir(PROFILE, WORKSPACE)

function workerWire() {
  const transport = new EventEmitter()
  transport.write = (data) => parentPort.postMessage({ data })
  parentPort.on('message', ({ data, stop }) => {
    if (stop) transport.emit('close')
    else if (data) transport.emit('data', data)
  })
  return transport
}

const wire = workerData?.supervised ? workerWire() : new net.Socket({ fd: IPC_FD, readable: true, writable: true })
const rpc = new IPCRpcEndpoint(wire)
const runtime = {
  persistence: undefined,
  apiBaseURL: API_BASE,
  providerBaseURL: undefined,
  providerFiber: undefined,
  profile: undefined,
  profileShutdown: undefined,
  pluginManager: undefined,
  activeAgents: new Map(),
  activeTurns: new Map(),
  suspended: false,
  shuttingDown: false,
  pluginMutationInProgress: false,
  preparingTurn: false,
  profileRestartRequired: false,
}
let ctx

function routeForApiBase(value) {
  const url = new URL(value)
  if (url.protocol !== 'https:' || url.username || url.password || url.search || url.hash) {
    throw new Error('DSH requires an HTTPS API address without credentials, query, or fragment')
  }
  url.pathname = url.pathname.replace(/\/+$/, '')
  if (isOfficialDeepSeekBase(url)) {
    return 'https://api.deepseek.com/anthropic'
  }
  // Custom endpoints must expose the Anthropic Messages protocol used by the
  // upstream DeepSeek adapter. The iOS UI still owns the Keychain account URL.
  return url.toString().replace(/\/+$/, '')
}

function isOfficialDeepSeekBase(value) {
  const url = value instanceof URL ? value : new URL(value)
  const path = url.pathname.replace(/\/+$/, '')
  return url.protocol === 'https:' && url.hostname.toLowerCase() === 'api.deepseek.com'
    && !url.port && ['', '/v1'].includes(path)
}

function messageText(blocks) {
  if (typeof blocks === 'string') return blocks
  if (!Array.isArray(blocks)) return ''
  return blocks.filter((block) => block && block.type === 'text' && typeof block.text === 'string')
    .map((block) => block.text).join('')
}

function eventMessages(events, botId) {
  const messages = []
  for (const event of events) {
    if (event.type === 'user/message' && (!event.data.source || event.data.source.kind === 'user')) {
      const content = messageText(event.data.content)
      if (content) messages.push({ id: event.data.id, sessionId: botId, role: 'user', content, reasoning: '', timestamp: event.time })
    } else if (event.type === 'assistant/message') {
      const content = messageText(event.data.message?.content)
      const reasoning = Array.isArray(event.data.message?.content)
        ? event.data.message.content.filter((block) => block?.type === 'thinking' && typeof block.thinking === 'string').map((block) => block.thinking).join('')
        : ''
      if (content || reasoning) messages.push({ id: event.data.message?.id ?? `assistant-${event.seq}`, sessionId: botId, role: 'assistant', content, reasoning, timestamp: event.time })
    }
  }
  return messages
}

function dshSessionId(botId) { return `ios:${botId}` }
function botIdFromSession(id) { return id.startsWith('ios:') ? id.slice(4) : id }

function renderLegacyHistory(messages) {
  if (!Array.isArray(messages)) return ''
  const records = messages.filter((item) => item && (item.role === 'user' || item.role === 'assistant') && typeof item.content === 'string')
    .slice(-12)
  if (!records.length) return ''
  const transcript = records.map((item) => `${item.role === 'user' ? 'User' : 'Assistant'}: ${item.content.slice(0, 12_000)}`).join('\n\n')
  return `Earlier conversation imported from the previous DS Bot iOS chat store. Treat it as background context; the current DSH session log is authoritative for new turns.\n\n${transcript.slice(-48_000)}`
}

const NATIVE_TOOL_NAMES = ['js_eval', 'device_status', 'memory_save', 'group_todo_add', 'web_fetch', 'remote_mcp_call']
const ACTIVE_PLUGINS = [
  'dsh-agent', 'dsh-agent-loop', 'dsh-llm', 'dsh-llm-deepseek-api-key',
  'dsh-session', 'dsh-session-projection', 'dsh-system-prompt',
  'dsh-tools', 'dsh-tool-executor-native', 'dsh-web', 'dsh-fs-local', 'dsh-working-directory',
  'dsh-subagent', 'dsh-subagent-spawn-in-process', 'dsh-tool-subagent',
  'dsbot-ios-sqlite-session-persistence', 'dsbot-ios-keychain-credentials', 'dsbot-ios-native-tools',
]

function setupAgent({ botId, systemPrompt, legacyHistory, toolsEnabled, subagentEnabled }) {
  const id = dshSessionId(botId)
  let setPersona = () => {}
  let setToolsEnabled = () => {}
  const setup = (agentCtx) => {
    let personaDisposer
    let toolRestriction
    setPersona = (value) => {
      personaDisposer?.()
      personaDisposer = undefined
      if (typeof value === 'string' && value.trim()) {
        personaDisposer = agentCtx.systemPrompt.section({ name: 'dsbot-ios-persona', order: 900, text: value.trim() })
      }
    }
    setPersona(systemPrompt)
    setToolsEnabled = (enabled, allowSubagent) => {
      toolRestriction?.()
      toolRestriction = undefined
      const deny = enabled ? [] : [...NATIVE_TOOL_NAMES]
      if (!allowSubagent || !enabled) deny.push('subagent')
      if (deny.length) toolRestriction = agentCtx.tools.restrict({ deny })
    }
    setToolsEnabled(toolsEnabled, subagentEnabled)
    const importedContext = renderLegacyHistory(legacyHistory)
    if (importedContext) {
      agentCtx.systemPrompt.section({ name: 'dsbot-ios-imported-history', order: 800, text: importedContext })
    }
    agentCtx.on('agent/assistant-stream', ({ frame }) => {
      if (frame?.type !== 'chunk') return
      const active = runtime.activeTurns.get(id)
      if (!active || active.done) return
      const chunk = frame.chunk
      if (chunk.type === 'text-delta') {
        rpc.notify('chat.delta', { sessionId: botId, turnId: active.turnId, content: chunk.text, reasoning: '' })
      } else if (chunk.type === 'reasoning-delta') {
        rpc.notify('chat.delta', { sessionId: botId, turnId: active.turnId, content: '', reasoning: chunk.text })
      }
    })
    agentCtx.effect(() => () => { personaDisposer?.() }, 'dsbot-ios.persona')
    return undefined
  }
  return { setup, setPersona: (value) => setPersona(value), setToolsEnabled: (value) => setToolsEnabled(value), id }
}

async function boot() {
  runtime.providerBaseURL = routeForApiBase(runtime.apiBaseURL)
  process.env.DS_BOT_PROVIDER_BASE_URL = runtime.providerBaseURL
  initProfile(PROFILE_DIR, [PROFILE_BUNDLE])
  if (workerData?.safeMode || workerData?.recoveringRevision) await settlePluginRevision(PROFILE_DIR, true)
  const manifest = readProfileManifest('dsh', PROFILE_DIR)
  const currentBundles = manifest.dsh?.profile?.bundles ?? []
  const bundles = [PROFILE_BUNDLE, ...currentBundles.filter((name) => name !== PROFILE_BUNDLE)]
  if (bundles.join('\n') !== currentBundles.join('\n')) writeProfileBundles(PROFILE_DIR, manifest, bundles)
  const safeMode = workerData?.safeMode === true
  const profile = loadProfileDirectory('dsh', PROFILE_DIR, INSTALL_ANCHOR, { userLayer: !safeMode })
  if (safeMode) profile.layers = profile.layers.filter(({ packageName }) => packageName === PROFILE_BUNDLE)
  else if (profile.skippedBundles.some(({ packageName }) => packageName !== PROFILE_BUNDLE)) {
    throw new Error('An enabled DSH plugin failed profile validation')
  }
  const profileFailure = profile.skippedBundles.find(({ packageName }) => packageName === PROFILE_BUNDLE)
  if (profileFailure) throw new Error(`The iOS DSH profile could not load: ${profileFailure.reason}`)
  configureIOSHost({ rpc, runtime, workspace: WORKSPACE })
  const application = await runProfile({
    environment: loadLayeredEnv('dsh', WORKSPACE),
    profile: PROFILE,
    resolvedProfile: { profile, installAnchor: INSTALL_ANCHOR },
    patchFiles: [],
    args: [],
  })
  ctx = application.ctx
  runtime.profile = profile
  runtime.profileShutdown = application.shutdown
  runtime.persistence = ctx.get('sessionPersistence')
  const mountedRows = new Map([...ctx.loader.entries()].map((entry) => [entry.options.id, entry.fiber]))
  runtime.providerFiber = mountedRows.get('llm-deepseek')
  const requiredRows = ['session', 'session-projection', 'llm', 'llm-deepseek', 'system-prompt', 'tools',
    'agent', 'agent-loop', 'tool-executor-native', 'ios-web', 'ios-fs', 'ios-working-directory', 'ios-subagent', 'ios-subagent-in-process', 'ios-tool-subagent', 'ios-keychain-credentials', 'ios-session-persistence', 'ios-native-tools']
  const inactive = requiredRows.filter((id) => mountedRows.get(id)?.state !== 2)
  if (inactive.length) throw new Error(`Required iOS DSH profile rows are inactive: ${inactive.join(', ')}`)
  if (!runtime.persistence || !runtime.providerFiber) {
    throw new Error('The iOS DSH profile did not activate its persistence and DeepSeek provider plugins')
  }
  if (!safeMode && profile.layers.some(({ packageName }) => packageName !== PROFILE_BUNDLE)) {
    await auditStartupEntries(ctx, 'dsh', (warning) => { throw new Error(warning) })
  }
  if (!safeMode) await settlePluginRevision(PROFILE_DIR, false)
  await cleanupPendingPluginRemovals(PROFILE_DIR)
  createIOSPluginManager({ rpc, runtime, workspace: WORKSPACE, profileDir: PROFILE_DIR, installAnchor: INSTALL_ANCHOR, safeMode, drainAgents: () => ctx.subagents.drainDescendants([...runtime.activeAgents.values()].map(({ agent }) => agent)) })
  await rpc.request('runtime.ready', runtimeInfo(), 30_000)
}

const runtimeInfo = () => ({
  engine: 'node+dsh', dshVersion: '0.2.2-rc.5', nodeVersion: process.versions.node,
  ipcProtocolVersion: '1.0.0', persistentSessions: true,
  bootLifecycle: 'official-runProfile',
  profile: { name: PROFILE, bundles: runtime.profile?.layers?.map((layer) => layer.packageName) ?? [] },
  webProviders: ctx?.web?.listProviders(),
  pluginIndexFormat: 1, safeMode: workerData?.safeMode === true,
  plugins: ACTIVE_PLUGINS,
  tools: ['js_eval', 'device_status', 'memory_save', 'group_todo_add', 'web_fetch', 'remote_mcp_call'],
})
rpc.handle('agent.info', async () => runtimeInfo())

rpc.handle('chat.send', async (params) => {
  if (runtime.preparingTurn || runtime.activeTurns.size) throw new Error('Another DSH turn is already running')
  if (runtime.pluginMutationInProgress || runtime.profileRestartRequired) throw new Error('The DSH profile is changing')
  runtime.preparingTurn = true
  try {
    return await startTurn(params)
  } finally {
    runtime.preparingTurn = false
  }
})

async function startTurn(params) {
  if (runtime.suspended) throw new Error('The DSH runtime is suspended')
  if (runtime.pluginMutationInProgress) throw new Error('The DSH profile is changing; try again when the plugin operation finishes')
  const botId = String(params.sessionId ?? '')
  const text = typeof params.text === 'string' ? params.text.trim() : ''
  const model = typeof params.model === 'string' ? params.model.trim() : ''
  const turnId = String(params.turnId ?? '')
  if (!/^[A-Za-z0-9_-]{1,80}$/.test(botId) || !turnId || !model || !text) throw new TypeError('Invalid chat request')
  if (Buffer.byteLength(text, 'utf8') > 262_144) throw new RangeError('Message exceeds 256 KB')
  if (runtime.activeTurns.size) throw new Error('Another DSH turn is already running')
  const nextApiBaseURL = typeof params.apiBaseURL === 'string' ? params.apiBaseURL : runtime.apiBaseURL
  const nextProviderBaseURL = routeForApiBase(nextApiBaseURL)
  if (nextProviderBaseURL !== runtime.providerBaseURL) {
    for (const [id, active] of runtime.activeAgents) await drainAndDispose(id, active)
    // Cordis validates the plain config and owns the volatile references.
    // Fiber.update applies this through Cordis' normal update lifecycle.
    await runtime.providerFiber.update({ baseURL: nextProviderBaseURL })
    runtime.providerBaseURL = nextProviderBaseURL
    process.env.DS_BOT_PROVIDER_BASE_URL = nextProviderBaseURL
  }
  runtime.apiBaseURL = nextApiBaseURL
  const dshModel = model === 'deepseek-flash-thinking' ? 'deepseek-flash' : model
  const reasoningEnabled = model === 'deepseek-flash-thinking' || model === 'deepseek-v4-pro'
  const officialDeepSeek = isOfficialDeepSeekBase(runtime.apiBaseURL)
  const toolsEnabled = officialDeepSeek || params.customTools === true
  const id = dshSessionId(botId)
  let active = runtime.activeAgents.get(id)
  const options = {
    provider: 'deepseek-official', model: dshModel,
    reasoningEffort: reasoningEnabled ? 'high' : 'off',
  }
  if (!active) {
    const composition = setupAgent({ botId, systemPrompt: params.systemPrompt, legacyHistory: params.legacyHistory, toolsEnabled, subagentEnabled: params.subagentEnabled === true })
    let handle
    try {
      if (await runtime.persistence.stat(id)) {
        handle = await ctx.agents.resume({ resumeSessionId: id, agentOptions: options, setup: composition.setup })
      } else {
        handle = await ctx.agents.create({ sessionId: id, meta: { cwd: WORKSPACE }, agentOptions: options, setup: composition.setup })
      }
    } catch (error) {
      if (error instanceof SessionPersistenceNotFoundError) {
        handle = await ctx.agents.create({ sessionId: id, meta: { cwd: WORKSPACE }, agentOptions: options, setup: composition.setup })
      } else throw error
    }
    active = { handle, agent: handle.agent, setPersona: composition.setPersona, setToolsEnabled: composition.setToolsEnabled, botId }
    runtime.activeAgents.set(id, active)
  } else {
    active.agent.model.select(options)
    active.setPersona(params.systemPrompt)
    active.setToolsEnabled(toolsEnabled, params.subagentEnabled === true)
  }

  const userMessage = createUserMessage({ content: [{ type: 'text', text }], source: { kind: 'user' } })
  const turn = { turnId, botId, isGroup: params.isGroup === true, done: false }
  runtime.activeTurns.set(id, turn)
  const startSeq = active.agent.session.seq
  try {
    active.agent.followup(userMessage)
  } catch (error) {
    runtime.activeTurns.delete(id)
    throw error
  }
  void (async () => {
    let status = 'completed'
    let error
    try {
      await active.agent.whenIdle()
      await ctx.sessions.flush(active.agent.session)
      const events = active.agent.session.snapshotEvents()
      const end = [...events].reverse().find((event) => event.seq >= startSeq && event.type === 'turn/end')
      const reason = end?.data.reason
      if (reason?.kind !== 'completed') {
        status = reason?.kind === 'aborted' ? 'aborted' : reason?.kind === 'error' ? 'error' : 'incomplete'
        if (typeof reason?.error?.message === 'string') error = reason.error.message
      }
    } catch (reason) {
      status = 'error'
      error = reason instanceof Error ? reason.message : String(reason)
    } finally {
      turn.done = true
      runtime.activeTurns.delete(id)
      rpc.notify('chat.done', { sessionId: botId, turnId, status, ...(error ? { error } : {}) })
    }
  })()
  return { turnId, status: 'accepted', engine: 'node+dsh' }
}

async function drainAndDispose(id, active) {
  await ctx.subagents.drainDescendants([active.agent])
  await active.agent.whenIdle()
  await ctx.sessions.flush(active.agent.session)
  await active.handle.dispose()
  runtime.activeAgents.delete(id)
}

rpc.handle('chat.abort', async ({ turnId }) => {
  const item = [...runtime.activeTurns.entries()].find(([, active]) => active.turnId === turnId)
  if (!item) return { aborted: false }
  const [id, activeTurn] = item
  const active = runtime.activeAgents.get(id)
  active?.agent.cancel({ kind: 'user' })
  void rpc.request('native.tool.cancel', { botId: activeTurn.botId, sessionId: activeTurn.botId, turnId }, 5_000).catch(() => {})
  if (active) await drainAndDispose(id, active)
  return { aborted: true, sessionId: activeTurn.botId }
})

rpc.handle('agent.suspend', async () => {
  runtime.suspended = true
  const cancelTools = []
  for (const [id, turn] of runtime.activeTurns) {
    runtime.activeAgents.get(id)?.agent.cancel({ kind: 'user' })
    cancelTools.push(rpc.request('native.tool.cancel', {
      botId: turn.botId, sessionId: turn.botId, turnId: turn.turnId,
    }, 5_000).catch(() => {}))
  }
  await Promise.all(cancelTools)
  for (const [id, active] of runtime.activeAgents) await drainAndDispose(id, active)
  await runtime.persistence.flush()
  return { suspended: true }
})
rpc.handle('agent.resume', async () => { runtime.suspended = false; return { suspended: false } })

rpc.handle('session.list', async () => {
  const sessions = (await runtime.persistence.list())
    .filter((item) => item.header.id.startsWith('ios:'))
    .map((item) => ({ sessionId: botIdFromSession(item.header.id), createdAt: item.header.createdAt, eventCount: item.eventCount }))
  return { sessions }
})

rpc.handle('session.history', async ({ sessionId }) => {
  const id = String(sessionId ?? '').startsWith('ios:') ? String(sessionId) : dshSessionId(String(sessionId ?? ''))
  const events = await runtime.persistence.history(id)
  return { sessionId: botIdFromSession(id), messages: eventMessages(events, botIdFromSession(id)) }
})

rpc.handle('session.clear', async ({ sessionId }) => {
  const id = dshSessionId(String(sessionId ?? ''))
  const active = runtime.activeAgents.get(id)
  if (active) {
    if (runtime.activeTurns.has(id)) active.agent.cancel({ kind: 'user' })
    await drainAndDispose(id, active)
  }
  await runtime.persistence.delete(id)
  return { cleared: true }
})

for (const method of [
  'models.test', 'memory.add', 'memory.journal', 'memory.legacy', 'memory.assign', 'memory.undo',
  'group.state', 'group.goal.set', 'group.todo.add', 'group.todo.toggle', 'group.todo.clearCompleted',
  'connectors.list', 'connectors.upsert', 'connectors.delete', 'usage.summary', 'tools.jsEval',
  'device.status', 'device.speak', 'device.stopSpeaking', 'mcp.listTools', 'mcp.callTool', 'side.ask',
  'approval.respond',
]) {
  rpc.handle(method, (params) => rpc.request('workspace.request', { method, params }, 120_000))
}

rpc.handle('side.cancel', async () => ({ cancelled: false, reason: 'Side-chat sessions are not included in the local DSH profile yet.' }))

rpc.onNotification((method, params) => {
  if (method === 'approval.request' || method === 'approval.closed') rpc.notify(method, params)
})

wire.once('close', () => {
  if (runtime.shuttingDown) return
  runtime.shuttingDown = true
  void (async () => {
    try {
      await ctx?.subagents?.drainDescendants([...runtime.activeAgents.values()].map(({ agent }) => agent))
      await runtime.persistence?.flush()
    } finally {
      await runtime.profileShutdown?.shutdown(0)
      if (workerData?.supervised) parentPort.close()
    }
  })()
})

try {
  await boot()
} catch (error) {
  rpc.notify('runtime.failed', { message: error instanceof Error ? error.message : String(error) })
  throw error
}

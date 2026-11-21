import { EventEmitter } from 'node:events'
import { existsSync, mkdirSync, readdirSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { parentPort, workerData } from 'node:worker_threads'
import net from 'node:net'
import { fileURLToPath, pathToFileURL } from 'node:url'
import { configureIOSHost } from '@dsbot/dsh-ios-host'
import { auditStartupEntries, initProfile, loadLayeredEnv, loadProfileDirectory, readProfileManifest, resolveProfileDir, writeProfileBundles } from '@deepseek-ai/dsh-app-boot'
import { runProfile } from './vendor/dsh-profile-boot/lib/profile-boot.js'
import { cleanupPendingPluginRemovals, createIOSPluginManager, ensurePurgeSafeIOSCompatibility, settlePluginRevision } from './ios-plugin-manager.mjs'
import {
  cancelAllIOSPythonExecutions,
  cancelIOSPythonExecution,
  executeIOSPython,
  mountIOSPythonTool,
} from '@dsbot/dsh-ios-host/ios-python-tool'
import { mountIOSPythonJobTool } from '@dsbot/dsh-ios-host/ios-python-jobs'
import { mountIOSScheduleTools, iosSchedulePublicTask, iosScheduleTaskVisible } from '@dsbot/dsh-ios-host/ios-schedule-tools'
import { SessionPersistenceNotFoundError } from '@deepseek-ai/dsh-session-persistence'
import { createUserMessage } from '@deepseek-ai/dsh-llm'
import { IPCRpcEndpoint } from './ipc-protocol.mjs'

const IPC_FD = Number(process.argv.find((arg) => arg.startsWith('--ipc-fd='))?.slice('--ipc-fd='.length))
const WORKSPACE = process.argv.find((arg) => arg.startsWith('--workspace='))?.slice('--workspace='.length)
const WORKSPACE_FILES = WORKSPACE ? join(WORKSPACE, 'files') : undefined
const API_BASE = process.argv.find((arg) => arg.startsWith('--api-base='))?.slice('--api-base='.length) || 'https://api.deepseek.com'
const PRIVATE_SESSION_IDS_ARG = process.argv.find((arg) => arg.startsWith('--private-session-ids='))?.slice('--private-session-ids='.length) ?? 'W10'
function initialPrivateBotIds(value) {
  try {
    const decoded = Buffer.from(value.replaceAll('-', '+').replaceAll('_', '/'), 'base64').toString('utf8')
    const ids = JSON.parse(decoded)
    return Array.isArray(ids) ? ids.filter((id) => typeof id === 'string' && /^[A-Za-z0-9_-]{1,80}$/.test(id)) : []
  } catch {
    return []
  }
}
process.env.DS_BOT_IOS_PRIVATE_BOT_IDS = JSON.stringify(initialPrivateBotIds(PRIVATE_SESSION_IDS_ARG))
if (!Number.isInteger(IPC_FD) || IPC_FD < 0 || !WORKSPACE) throw new Error('Invalid iOS runtime arguments')
process.env.DSH_HOME = WORKSPACE
process.env.DSH_TELEMETRY_DISABLED = '1'
process.env.DS_BOT_IOS_HOST = '1'
process.env.DS_BOT_IOS_REDTEAM_ENABLED = '0'
process.env.DS_BOT_IOS_REDTEAM_WEB_READ = '0'
process.env.DS_BOT_IOS_REDTEAM_WEB_WRITE = '0'
process.env.DS_BOT_IOS_REDTEAM_WEB_SENSITIVE = '0'
if (!workerData?.supervised) process.chdir(WORKSPACE)
mkdirSync(WORKSPACE_FILES, { recursive: true })
const WORKSPACE_ROOT_MARKER = join(WORKSPACE_FILES, '.dsbot-ios-workspace-root')
if (!existsSync(WORKSPACE_ROOT_MARKER)) {
  try { writeFileSync(WORKSPACE_ROOT_MARKER, '', { flag: 'wx' }) } catch (error) {
    if (error?.code !== 'EEXIST') throw error
  }
}

const PROFILE = 'dsbot-ios'
const PROFILE_BUNDLE = '@dsbot/dsh-ios-profile'
const INSTALL_ANCHOR = fileURLToPath(new URL('./package.json', import.meta.url))
const PROFILE_DIR = resolveProfileDir(PROFILE, WORKSPACE)

function workerWire() {
  const transport = new EventEmitter()
  transport.write = (data) => parentPort.postMessage({ data })
  parentPort.on('message', ({ data, stop }) => {
    if (stop) {
      cancelAllIOSPythonExecutions()
      transport.emit('close')
    }
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
  pendingDshApprovals: new Map(),
  redteamApprovalGrants: new Map(),
  redteamTurnPolicies: new Map(),
  pendingUserQuestions: new Map(),
  sideRequests: new Map(),
  suspended: false,
  suspendGeneration: 0,
  shuttingDown: false,
  pluginMutationInProgress: false,
  preparingTurn: undefined,
  profileRestartRequired: false,
  activePlugins: [],
  activePluginRows: [],
  redteamToolsEnabled: false,
  redteamWebPermissions: { read: false, write: false, sensitive: false },
  redteamCompatibility: { webWorkbenchAvailable: false, reason: '尚未检查插件' },
  liveConfig: undefined,
  webSearchConfigSynced: false,
  privateBotIds: new Set(initialPrivateBotIds(PRIVATE_SESSION_IDS_ARG)),
}
let ctx

const backgroundWakeGuardedAgents = new WeakSet()

function guardIOSBackgroundFollowups(agent) {
  if (!agent || backgroundWakeGuardedAgents.has(agent)) return
  const followup = agent.followup.bind(agent)
  agent.followup = (message) => {
    // Native Chat only tracks user-initiated turns in its live stream. Keep
    // idle Jobs completions durable in the inbox for the next user turn, and
    // never let any DSH followup start while iOS has suspended the host.
    if (runtime.suspended || message?.source?.kind === 'tool-jobs') {
      agent.inject(message)
      return
    }
    followup(message)
  }
  backgroundWakeGuardedAgents.add(agent)
}

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
      if (content) messages.push({ id: event.data.id, sessionId: botId, role: 'user', content, reasoning: '', timestamp: event.time, sequence: event.seq })
    } else if (event.type === 'assistant/message') {
      const content = messageText(event.data.message?.content)
      const reasoning = Array.isArray(event.data.message?.content)
        ? event.data.message.content.filter((block) => block?.type === 'thinking' && typeof block.thinking === 'string').map((block) => block.thinking).join('')
        : ''
      if (content || reasoning) messages.push({ id: event.data.message?.id ?? `assistant-${event.seq}`, sessionId: botId, role: 'assistant', content, reasoning, timestamp: event.time, sequence: event.seq })
    }
  }
  return messages
}

function fileActivitySummary(toolName, rawArguments) {
  if (!['write', 'edit', 'apply_patch', 'patch', 'delete'].includes(toolName)) return undefined
  let args = rawArguments
  if (typeof rawArguments === 'string') {
    try { args = JSON.parse(rawArguments) } catch { return toolName === 'apply_patch' || toolName === 'patch' ? '多文件 patch' : undefined }
  }
  if (!args || typeof args !== 'object' || Array.isArray(args)) return undefined
  const path = typeof args.file_path === 'string' ? args.file_path : typeof args.path === 'string' ? args.path : undefined
  if (path) return path.slice(0, 800)
  const patch = typeof args.patch === 'string' ? args.patch : typeof args.patch_text === 'string' ? args.patch_text : ''
  const paths = patch.split(/\r?\n/).flatMap((line) => {
    for (const prefix of ['*** Add File: ', '*** Update File: ', '*** Delete File: ']) {
      if (line.startsWith(prefix)) return [line.slice(prefix.length).slice(0, 800)]
    }
    return []
  })
  return paths.length > 0 ? `${paths.slice(0, 3).join(', ')}${paths.length > 3 ? ' …' : ''}`
    : toolName === 'apply_patch' || toolName === 'patch' ? '多文件 patch' : undefined
}

function eventToolActivities(events, botId, callBefore = Infinity, limit = 30) {
  const activities = new Map()
  const byCallId = new Map()
  for (const event of events) {
    const data = event?.data
    if (event?.type === 'tool/ptc-dispatch' && event.seq < callBefore) {
      const parentCallId = String(data?.parentCallId ?? '')
      const subCallId = String(data?.subCallId ?? '')
      if (!parentCallId || !subCallId) continue
      const activity = {
        id: `dsh-history-ptc-${event.seq}-${subCallId}`,
        callId: subCallId,
        sessionId: botId,
        turnId: `dsh-history-ptc-${parentCallId}`,
        toolName: String(data?.name ?? 'DSH tool'),
        fileSummary: fileActivitySummary(String(data?.name ?? ''), data?.arguments),
        phase: data?.isError === true ? 'failed' : 'completed',
        arguments: excerpt(data?.arguments),
        result: toolResultText({ content: data?.content, isError: data?.isError === true }, data?.error),
        timestamp: Number.isSafeInteger(event.time) ? event.time : 0,
        sequence: Number.isSafeInteger(event.seq) ? event.seq : 0,
        callSequence: Number.isSafeInteger(event.seq) ? event.seq : 0,
      }
      activities.set(activity.id, activity)
      continue
    }
    if (event?.type === 'tool/call' && event.seq < callBefore) {
      const callId = String(data?.callId ?? '')
      const turn = Number.isSafeInteger(data?.turn) ? data.turn : 0
      const step = Number.isSafeInteger(data?.step) ? data.step : 0
      if (!callId) continue
      const id = `dsh-history-${turn}-${step}-${callId}`
      const activity = {
        id, callId, sessionId: botId, turnId: `dsh-history-${turn}`,
        toolName: String(data?.name ?? 'DSH tool'), phase: 'unknown',
        fileSummary: fileActivitySummary(String(data?.name ?? ''), data?.arguments),
        arguments: excerpt(data?.arguments), result: '工具结果未写入历史；这次调用可能在执行期间中断。',
        timestamp: Number.isSafeInteger(event.time) ? event.time : 0,
        sequence: Number.isSafeInteger(event.seq) ? event.seq : 0,
        callSequence: Number.isSafeInteger(event.seq) ? event.seq : 0,
      }
      activities.set(id, activity)
      byCallId.set(callId, [...(byCallId.get(callId) ?? []), id])
      continue
    }
    if (event?.type !== 'tool/result') continue
    const message = data?.message
    const callId = String(message?.source?.callId ?? '')
    if (!callId) continue
    const turn = Number.isSafeInteger(data?.turn) ? data.turn : 0
    const step = Number.isSafeInteger(data?.step) ? data.step : 0
    const exactId = `dsh-history-${turn}-${step}-${callId}`
    const fallbackId = (byCallId.get(callId) ?? []).find((id) => activities.get(id)?.phase === 'unknown')
    const id = activities.has(exactId) ? exactId : fallbackId
    if (!id) continue
    const activity = activities.get(id)
    activity.toolName = String(message?.source?.toolName ?? activity.toolName)
    activity.phase = data?.error || message?.isError ? 'failed' : 'completed'
    activity.result = toolResultText(message, data?.error)
    activity.timestamp = Number.isSafeInteger(event.time) ? event.time : activity.timestamp
    activity.sequence = Number.isSafeInteger(event.seq) ? event.seq : activity.sequence
  }
  return [...activities.values()].slice(-limit)
}

function eventApprovalAudits(events, botId, limit = 80) {
  const audits = new Map()
  for (const event of events) {
    const data = event.data ?? {}
    const id = String(data.id ?? '')
    if (!id) continue
    if (event.type === 'approval/asked') {
      const audit = audits.get(id) ?? { id, sessionId: botId, toolName: 'DSH 工具', outcome: 'unknown' }
      audit.toolName = String(data.toolName ?? audit.toolName)
      audit.timestamp = Number.isSafeInteger(event.time) ? event.time : audit.timestamp
      audit.sequence = Number.isSafeInteger(event.seq) ? event.seq : audit.sequence
      audits.set(id, audit)
    } else if (event.type === 'approval/decided') {
      const audit = audits.get(id) ?? { id, sessionId: botId, toolName: 'DSH 工具', outcome: 'unknown' }
      audit.outcome = ['allowed-once', 'rejected', 'cancelled', 'unavailable'].includes(data.outcome)
        ? data.outcome : 'unknown'
      audit.decisionTimestamp = Number.isSafeInteger(event.time) ? event.time : undefined
      audit.decisionSequence = Number.isSafeInteger(event.seq) ? event.seq : undefined
      audit.timestamp ??= audit.decisionTimestamp
      audit.sequence ??= audit.decisionSequence
      audits.set(id, audit)
    }
  }
  return [...audits.values()].slice(-limit)
}

async function approvalEventsForHistoryPage(handle, events, start, end, eventCount) {
  const ids = new Set(events
    .filter((event) => event.type === 'approval/asked' || event.type === 'approval/decided')
    .map((event) => String(event.data?.id ?? '')).filter(Boolean))
  if (ids.size === 0) return []
  const lower = Math.max(0, start - 100)
  const upper = Math.min(eventCount, end + 100)
  const related = []
  for (let offset = lower; offset < upper; offset += 25) {
    const batch = await handle.read(offset, Math.min(25, upper - offset))
    for (const event of batch.events) {
      if ((event.type === 'approval/asked' || event.type === 'approval/decided')
          && ids.has(String(event.data?.id ?? ''))) related.push(event)
    }
  }
  return related
}

function usageCounts(value) {
  if (!value || typeof value !== 'object') return undefined
  const count = (field) => Number.isSafeInteger(value[field]) && value[field] >= 0 ? value[field] : undefined
  const inputTokens = count('inputTokens')
  const outputTokens = count('outputTokens')
  const cacheReadTokens = count('cacheReadTokens')
  const cacheWriteTokens = count('cacheWriteTokens')
  const reportedTotal = count('totalTokens')
  if ([inputTokens, outputTokens, cacheReadTokens, cacheWriteTokens, reportedTotal].every((item) => item === undefined)) return undefined
  const input = inputTokens ?? 0
  const output = outputTokens ?? 0
  const cacheRead = cacheReadTokens ?? 0
  const cacheWrite = cacheWriteTokens ?? 0
  return {
    inputTokens: input,
    outputTokens: output,
    cacheReadTokens: cacheRead,
    cacheWriteTokens: cacheWrite,
    totalTokens: reportedTotal ?? input + output + cacheRead + cacheWrite,
  }
}

function usageFromStream(stream) {
  if (!Array.isArray(stream)) return undefined
  let usage
  for (const record of stream) {
    if (record?.type === 'chunk' && record.chunk?.type === 'usage') usage = usageCounts(record.chunk.usage)
  }
  return usage
}

function emptyUsageTotals() {
  return { calls: 0, inputTokens: 0, cacheReadTokens: 0, cacheWriteTokens: 0, outputTokens: 0, totalTokens: 0 }
}

function addUsageTotals(totals, usage) {
  const add = (left, right) => left > Number.MAX_SAFE_INTEGER - right ? Number.MAX_SAFE_INTEGER : left + right
  totals.calls = add(totals.calls, 1)
  totals.inputTokens = add(totals.inputTokens, usage.inputTokens)
  totals.cacheReadTokens = add(totals.cacheReadTokens, usage.cacheReadTokens)
  totals.cacheWriteTokens = add(totals.cacheWriteTokens, usage.cacheWriteTokens)
  totals.outputTokens = add(totals.outputTokens, usage.outputTokens)
  totals.totalTokens = add(totals.totalTokens, usage.totalTokens)
}

function addUsageGroup(groups, id, title, usage) {
  let group = groups.get(id)
  if (!group) {
    group = { id, title, ...emptyUsageTotals() }
    groups.set(id, group)
  }
  addUsageTotals(group, usage)
}

async function dshUsageSummary({ dayWindows } = {}) {
  const snapshots = await runtime.persistence.list()
  const bySessionId = new Map(snapshots.map((snapshot) => [String(snapshot.header.id), snapshot]))
  const ownerBotId = (snapshot) => {
    let current = snapshot
    const seen = new Set()
    while (current) {
      const sessionId = String(current.header?.id ?? '')
      if (sessionId.startsWith('ios:')) return sessionId.slice(4)
      if (seen.has(sessionId)) return undefined
      seen.add(sessionId)
      const parentSession = current.header?.parentSession
      if (typeof parentSession !== 'string') return undefined
      current = bySessionId.get(parentSession)
    }
    return undefined
  }

  const totals = emptyUsageTotals()
  const byBot = new Map()
  const byModel = new Map()
  const windows = (Array.isArray(dayWindows) ? dayWindows : []).slice(0, 8).flatMap((window) => {
    const start = Number(window?.start)
    const end = Number(window?.end)
    if (typeof window?.id !== 'string' || !window.id || !Number.isSafeInteger(start) || !Number.isSafeInteger(end) || end <= start) return []
    return [{ id: window.id, title: typeof window.title === 'string' ? window.title.slice(0, 40) : window.id, start, end }]
  })
  const byDay = new Map(windows.map((window) => [window.id, { id: window.id, title: window.title, ...emptyUsageTotals() }]))
  let unreportedCalls = 0
  let unreadSessions = 0
  for (const snapshot of snapshots) {
    const botId = ownerBotId(snapshot)
    if (!botId) continue
    const sessionId = String(snapshot.header.id)
    let handle
    try {
      handle = await runtime.persistence.open(sessionId, 'read')
      const { events } = await handle.read()
      const inheritedEventCount = Number(handle.inheritedEventCount ?? 0)
      let model = '未知模型'
      for (const event of events) {
        if (event.seq < inheritedEventCount) continue
        if (event.type === 'request/header') {
          const configuredModel = event.data?.header?.config?.model
          if (typeof configuredModel === 'string' && configuredModel.trim()) model = configuredModel.trim()
          continue
        }
        if (event.type !== 'assistant/message' && event.type !== 'assistant/attempt') continue

        const messageModel = event.data?.message?.source?.model
        const eventModel = typeof messageModel === 'string' && messageModel.trim() ? messageModel.trim() : model
        const usage = usageCounts(event.data?.usage) ?? usageFromStream(event.data?.stream)
        if (!usage) {
          unreportedCalls += 1
          continue
        }
        if (!Number.isSafeInteger(event.time) || event.time < 0) continue
        addUsageTotals(totals, usage)
        addUsageGroup(byBot, botId, botId, usage)
        addUsageGroup(byModel, eventModel, eventModel, usage)
        for (const window of windows) {
          if (event.time >= window.start && event.time < window.end) {
            addUsageTotals(byDay.get(window.id), usage)
            break
          }
        }
      }
    } catch (error) {
      unreadSessions += 1
      ctx?.logger?.warn(`Could not read DSH usage for ${sessionId}: ${String(error)}`)
    } finally {
      if (handle) {
        try { await handle.close() } catch (error) {
          ctx?.logger?.warn(`Could not close DSH usage reader for ${sessionId}: ${String(error)}`)
        }
      }
    }
  }
  const ordered = (groups) => [...groups.values()].sort((left, right) => right.totalTokens - left.totalTokens)
  return {
    source: 'dsh-session-events', totals, byBot: ordered(byBot), byModel: ordered(byModel),
    byDay: [...byDay.values()], unreportedCalls, unreadSessions,
  }
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

function collectProfileEntryRows(value, rows = [], insideMutation = false) {
  if (Array.isArray(value)) {
    for (const item of value) collectProfileEntryRows(item, rows, insideMutation)
    return rows
  }
  if (!value || typeof value !== 'object') return rows
  if (typeof value.name === 'string') {
    if (insideMutation && value.disabled !== true) {
      rows.push(value)
      if (value.group === true) collectProfileEntryRows(value.config, rows, true)
    }
    return rows
  }
  for (const key of ['insert', 'append', 'replace']) {
    if (value[key] !== undefined) collectProfileEntryRows(value[key], rows, true)
  }
  return rows
}

async function auditExternalProfileLayers(profileLayers) {
  const entries = [...ctx.loader.entries()]
  for (const layer of profileLayers.filter(({ packageName }) => packageName !== PROFILE_BUNDLE)) {
    const rows = layer.patches.flatMap((patch) => collectProfileEntryRows(patch))
    for (const row of rows) {
      if (row.disabled === true) continue
      const candidates = entries.filter((entry) =>
        (typeof row.id === 'string' && entry.options.id === row.id)
        || (typeof row.id !== 'string' && entry.options.name === row.name))
      const entry = candidates.at(-1)
      const label = `${layer.packageName}/${row.id ?? row.name}`
      if (!entry) throw new Error(`iOS DSH profile bundle entry was not mounted: ${label}`)
      if (entry.disabled) continue
      if (entry.fiber?.state === 2) continue
      const missing = entry.fiber
        ? Object.keys(entry.fiber.inject).filter((name) => entry.fiber.ctx.get(name) === undefined)
        : []
      if (entry.fiber && entry.fiber.state !== 0) {
        try { await entry.fiber.await() } catch (error) {
          throw new Error(`iOS DSH profile bundle entry failed: ${label}`, { cause: error })
        }
      }
      throw new Error(`iOS DSH profile bundle entry is inactive: ${label}${missing.length ? ` (waiting for ${missing.join(', ')})` : ''}`)
    }
  }
}

function excerpt(value, limit = 2_400) {
  const text = typeof value === 'string' ? value : value === undefined ? '' : JSON.stringify(value)
  let preview = ''
  let count = 0
  for (const scalar of text) {
    if (count === limit) return `${preview}… (已截断)`
    preview += scalar
    count += 1
  }
  return text
}

function toolResultText(message, error) {
  const text = Array.isArray(message?.content)
    ? message.content.filter((block) => block?.type === 'text').map((block) => String(block.text ?? '')).join('\n')
    : ''
  return excerpt(text || error?.reason || error?.code || (message?.isError ? '工具调用失败。' : '工具已完成。'))
}

function fullToolResultText(message, error) {
  const text = Array.isArray(message?.content)
    ? message.content.filter((block) => block?.type === 'text').map((block) => String(block.text ?? '')).join('\n')
    : ''
  return text || error?.reason || error?.code || (message?.isError ? '工具调用失败。' : '工具已完成。')
}

const NATIVE_TOOL_NAMES = [
  'js_eval', 'python_exec', 'python_job_start', 'device_status', 'memory_save', 'group_todo_add', 'web_fetch', 'web_search', 'remote_mcp_list', 'remote_mcp_call',
  'workspace_list', 'workspace_read', 'workspace_write', 'workspace_search', 'workspace_edit',
  'terminal_exec', 'git_workspace',
  'schedule_create', 'schedule_list', 'schedule_view', 'schedule_history', 'schedule_edit',
  'job_output', 'job_list', 'job_kill',
]
const DEVELOPER_TOOL_NAMES = [
  'read', 'read_image', 'write', 'edit', 'apply_patch', 'glob', 'grep',
  'skill', 'ask_user_question', 'exit_plan_mode', 'todo_write', 'cordis_inspect_list', 'cordis_inspect_query',
]
const DISABLED_TOOL_NAMES = new Set([...NATIVE_TOOL_NAMES, ...DEVELOPER_TOOL_NAMES])
const REDTEAM_READ_TOOL_NAMES = new Set([
  'redteam_session_info', 'redteam_preflight', 'redteam_asset_query', 'redteam_asset_get',
  'redteam_asset_stats', 'redteam_asset_graph', 'redteam_role_prompt', 'redteam_roles',
  'redteam_vuln_query', 'redteam_shot_list', 'redteam_asset_next', 'redteam_next_action',
  'redteam_attention', 'redteam_attack_path', 'redteam_web_list', 'redteam_domain_index',
  'redteam_score_list', 'redteam_chain', 'redteam_report_targets', 'redteam_attack_chain',
  'redteam_score_report', 'redteam_report', 'redteam_asset_timeline',
])
const REDTEAM_WRITE_TOOL_NAMES = new Set([
  'redteam_engagement_open', 'redteam_session_bind', 'redteam_asset_add', 'redteam_asset_link',
  'redteam_asset_test', 'redteam_asset', 'redteam_vuln_add', 'redteam_vuln_update',
  'redteam_shot_add', 'redteam_shot_delete', 'redteam_role_prompt_reset', 'redteam_score_hit',
  'redteam_score_point_save', 'redteam_asset_assess', 'redteam_http_evidence_add', 'redteam_chain_add',
  'redteam_agent_slot', 'redteam_template_refresh', 'redteam_credential_add', 'redteam_access_add',
  'redteam_webshell_add', 'redteam_webshell_update', 'redteam_tunnel_add', 'redteam_tunnel_update',
  'redteam_session_check', 'redteam_attack_file_add', 'redteam_poc_add', 'redteam_poc_update',
  'redteam_poc_use', 'redteam_batch', 'redteam_pivot_probe', 'redteam_data_proof', 'redteam_cleanup',
])
const REDTEAM_SENSITIVE_TOOL_NAMES = new Set([
  'redteam_agent_slot', 'redteam_template_refresh', 'redteam_host', 'redteam_credential_add',
  'redteam_credential_list', 'redteam_access_add', 'redteam_access_list', 'redteam_sessions',
  'redteam_webshell_add', 'redteam_webshell_list', 'redteam_webshell_update', 'redteam_tunnel_add',
  'redteam_tunnel_list', 'redteam_tunnel_update', 'redteam_session_check', 'redteam_attack_file_add',
  'redteam_attack_file_list', 'redteam_poc_search', 'redteam_poc_get', 'redteam_poc_add',
  'redteam_poc_list', 'redteam_poc_update', 'redteam_poc_use', 'redteam_scope_check',
  'redteam_batch', 'redteam_pivot_probe', 'redteam_data_proof', 'redteam_cleanup',
])

function redteamToolClass(name) {
  if (REDTEAM_READ_TOOL_NAMES.has(name)) return 'read'
  if (REDTEAM_WRITE_TOOL_NAMES.has(name)) return 'write'
  if (REDTEAM_SENSITIVE_TOOL_NAMES.has(name)) return 'sensitive'
  return 'unknown'
}

function redteamToolDenial(policy, name) {
  const kind = redteamToolClass(name)
  if (kind === 'unknown') return `iOS 未审核红队工具 ${name}，默认拒绝。`
  if (!policy.enabled || !runtime.redteamToolsEnabled) return '红队工具宿主或本 Bot 授权已关闭。'
  if (runtime.privateBotIds.has(policy.botId)) return '私密会话禁止调用 dsh-purge-safe 工具。'
  if (REDTEAM_SENSITIVE_TOOL_NAMES.has(name) && !policy.sensitive) return `本 Bot 未获准访问敏感红队数据：${name}。`
  if (REDTEAM_WRITE_TOOL_NAMES.has(name) && (!policy.write || policy.permissionMode === 'readOnly')) {
    if (policy.permissionMode === 'readOnly') return '只读模式禁止修改红队演练数据。'
    return REDTEAM_SENSITIVE_TOOL_NAMES.has(name)
      ? '敏感数据写入需要同时授予演练台写入权限。'
      : `本 Bot 未获准写入红队演练数据：${name}。`
  }
  return undefined
}

function redteamToolNeedsApproval(policy, name) {
  const isSensitive = REDTEAM_SENSITIVE_TOOL_NAMES.has(name)
  const isWrite = REDTEAM_WRITE_TOOL_NAMES.has(name)
  return (policy.permissionMode === 'ask' && (isWrite || isSensitive))
    || (policy.permissionMode === 'autoReview' && isSensitive)
}

function redteamApprovalKey(sessionId, callId) {
  return `${String(sessionId ?? '')}:${String(callId ?? '')}`
}

function registeredRedteamToolNames() {
  try {
    const toolsSvc = ctx?.get?.('tools')
    if (!toolsSvc) return []
    const list = typeof toolsSvc.definitions === 'function'
      ? toolsSvc.definitions()
      : (typeof toolsSvc.list === 'function' ? toolsSvc.list() : [])
    return list
      .map((item) => (typeof item === 'string' ? item : item?.name))
      .filter((name) => typeof name === 'string' && name.startsWith('redteam_'))
  } catch {
    return []
  }
}

function setupAgent({ botId, systemPrompt, legacyHistory, agentPreset, toolsEnabled, subagentEnabled, webSearchEnabled,
  redteamMode = false, redteamWriteEnabled = false, redteamSensitiveDataEnabled = false, permissionMode = 'ask' }) {
  const id = dshSessionId(botId)
  let setPersona = () => {}
  let setToolsEnabled = () => {}
  let redteamPolicy = { botId, enabled: false, write: false, sensitive: false, permissionMode: 'ask' }
  const setup = async (agentCtx) => {
    if (agentPreset !== 'minimal') {
      if (agentPreset !== 'ptc-python') mountIOSPythonTool(agentCtx)
      if (agentPreset === 'standard' || agentPreset === 'cordis') mountIOSPythonJobTool(agentCtx)
      mountIOSScheduleTools(agentCtx)
    }
    await ctx.agentPresets.mount(agentCtx, agentPreset)
    let personaDisposer
    let redteamPromptDisposer
    let toolRestriction
    let toolGuard
    let redteamPreExecuteDisposer
    setPersona = (value) => {
      personaDisposer?.()
      personaDisposer = undefined
      if (typeof value === 'string' && value.trim()) {
        personaDisposer = agentCtx.systemPrompt.section({ name: 'dsbot-ios-persona', order: 900, text: value.trim() })
      }
    }
    setPersona(systemPrompt)
    setToolsEnabled = (enabled, allowSubagent, allowWebSearch, allowRedteam = false,
      allowRedteamWrites = false, allowRedteamSensitive = false, redteamPermissionMode = 'ask') => {
      toolRestriction?.()
      toolRestriction = undefined
      toolGuard?.()
      toolGuard = undefined
      redteamPreExecuteDisposer?.()
      redteamPreExecuteDisposer = undefined
      redteamPromptDisposer?.()
      redteamPromptDisposer = undefined
      redteamPolicy = {
        botId,
        enabled: enabled && allowRedteam,
        write: allowRedteamWrites,
        sensitive: allowRedteamSensitive,
        permissionMode: ['ask', 'autoReview', 'readOnly'].includes(redteamPermissionMode) ? redteamPermissionMode : 'ask',
      }
      const globalToolNames = new Set(ctx.tools.definitions().map((tool) => tool.name))
      const deny = enabled ? [] : [...DISABLED_TOOL_NAMES].filter((name) => globalToolNames.has(name))
      if (!allowSubagent || !enabled) deny.push('subagent')
      if (enabled && !allowWebSearch) deny.push('web_search')
      const rtTools = registeredRedteamToolNames()
      if (!allowRedteam || !enabled) {
        deny.push(...rtTools)
      } else {
        for (const name of rtTools) {
          if (redteamToolDenial(redteamPolicy, name)) deny.push(name)
        }
      }
      const allowedRedteamTools = rtTools.filter((name) => !redteamToolDenial(redteamPolicy, name))
      if (allowedRedteamTools.length > 0) {
        redteamPromptDisposer = agentCtx.systemPrompt.section({
          name: 'dsbot-ios-redteam-mode',
          order: 850,
          text: `dsh-purge-safe 红队演练工具已获本 Bot 授权。只允许在用户明确授权的演练范围内查询与记录；不得自行扩大范围。敏感资料、凭据、入口、PoC、网络探测和清理操作会经过额外授权/审批。iOS 已关闭插件补丁应用、工具审批旁路和子代理审批接管。当前可用工具：${allowedRedteamTools.join(', ')}。`,
        })
      }
      if (deny.length) toolRestriction = agentCtx.tools.restrict({ deny })
      toolGuard = agentCtx.tools.guard((execution) => {
        if (String(execution.name ?? '').startsWith('redteam_')) {
          const denial = redteamToolDenial(redteamPolicy, execution.name)
          if (denial) return { reason: denial }
        }
        if (!enabled && DISABLED_TOOL_NAMES.has(execution.name)) {
          return { reason: 'This tool is disabled for the selected provider.' }
        }
        if (!allowWebSearch && execution.name === 'web_search') {
          return { reason: 'Web search is disabled for this conversation.' }
        }
        return undefined
      })
      redteamPreExecuteDisposer = agentCtx.on('tools/pre-execute', async (execution, next) => {
        const name = String(execution?.name ?? '')
        if (!name.startsWith('redteam_')) return typeof next === 'function' ? next() : { kind: 'allow' }
        const downstream = typeof next === 'function' ? await next() : { kind: 'allow' }
        if (downstream?.kind && downstream.kind !== 'allow') return downstream
        const denial = redteamToolDenial(redteamPolicy, name)
        if (denial) return { kind: 'deny', reason: denial }
        if (redteamToolNeedsApproval(redteamPolicy, name)) {
          if (!execution?.callId) return { kind: 'deny', reason: '红队工具调用缺少审批关联编号，已拒绝执行。' }
          return {
            kind: 'ask',
            reason: `dsh-purge-safe 工具 ${name} 需要当前 Bot 的 iOS 用户审批。`,
            displayReason: { en: `Approve dsh-purge-safe tool ${name} for this Bot?`, zh: `允许当前 Bot 调用红队工具 ${name}？` },
          }
        }
        return downstream ?? { kind: 'allow' }
      })
    }
    setToolsEnabled(toolsEnabled, subagentEnabled, webSearchEnabled, redteamMode,
      redteamWriteEnabled, redteamSensitiveDataEnabled, permissionMode)
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
    const toolNamesByCall = new Map()
    const approvalToolsById = new Map()
    agentCtx.on('session/event', (session, event) => {
      if (session?.id !== id) return
      const active = runtime.activeTurns.get(id)
      if (!active || active.done) return
      if (event?.type === 'approval/asked') {
        const id = String(event.data?.id ?? '')
        if (id) approvalToolsById.set(id, String(event.data?.toolName ?? 'DSH 工具'))
        return
      }
      if (event?.type === 'approval/decided') {
        const id = String(event.data?.id ?? '')
        if (!id) return
        rpc.notify('dsh.approval.event', {
          sessionId: botId, turnId: active.turnId, id,
          toolName: approvalToolsById.get(id) ?? 'DSH 工具',
          outcome: String(event.data?.outcome ?? 'unknown'),
          timestamp: event.time, sequence: event.seq,
        })
        approvalToolsById.delete(id)
        return
      }
      if (event?.type === 'tool/ptc-dispatch') {
        const data = event.data ?? {}
        const parentCallId = String(data.parentCallId ?? '')
        const callId = String(data.subCallId ?? '')
        if (!parentCallId || !callId) return
        rpc.notify('dsh.tool.event', {
          sessionId: botId,
          turnId: active.turnId,
          callId,
          parentCallId,
          toolName: String(data.name ?? 'DSH tool'),
          fileSummary: fileActivitySummary(String(data.name ?? ''), data.arguments),
          phase: data.isError === true ? 'failed' : 'completed',
          arguments: excerpt(data.arguments),
          result: toolResultText({ content: data.content, isError: data.isError === true }, data.error),
          timestamp: event.time,
          sequence: event.seq,
          callSequence: event.seq,
        })
        return
      }
      if (event?.type !== 'tool/call' && event?.type !== 'tool/result') return
      if (event.type === 'tool/call') {
        const callId = String(event.data?.callId ?? '')
        const toolName = String(event.data?.name ?? 'DSH tool')
        if (!callId) return
        toolNamesByCall.set(callId, toolName)
        rpc.notify('dsh.tool.event', {
          sessionId: botId, turnId: active.turnId, callId, toolName,
          phase: 'started', arguments: excerpt(event.data?.arguments),
          fileSummary: fileActivitySummary(toolName, event.data?.arguments),
          timestamp: event.time, sequence: event.seq,
        })
        return
      }
      const message = event.data?.message
      const callId = String(message?.source?.callId ?? '')
      if (!callId) return
      const toolName = toolNamesByCall.get(callId) ?? String(message?.source?.toolName ?? 'DSH tool')
      toolNamesByCall.delete(callId)
      rpc.notify('dsh.tool.event', {
        sessionId: botId, turnId: active.turnId, callId, toolName,
        phase: event.data?.error || message?.isError ? 'failed' : 'completed',
        result: toolResultText(message, event.data?.error),
        timestamp: event.time, sequence: event.seq,
      })
    })
    agentCtx.effect(() => () => {
      personaDisposer?.(); redteamPromptDisposer?.(); toolRestriction?.(); toolGuard?.(); redteamPreExecuteDisposer?.()
    }, 'dsbot-ios.persona')
    return undefined
  }
  return {
    setup,
    setPersona: (value) => setPersona(value),
    setToolsEnabled: (enabled, allowSubagent, allowWebSearch, allowRedteam = false,
      allowRedteamWrites = false, allowRedteamSensitive = false, redteamPermissionMode = 'ask') =>
      setToolsEnabled(enabled, allowSubagent, allowWebSearch, allowRedteam,
        allowRedteamWrites, allowRedteamSensitive, redteamPermissionMode),
    id,
  }
}

async function boot() {
  runtime.providerBaseURL = routeForApiBase(runtime.apiBaseURL)
  process.env.DS_BOT_PROVIDER_BASE_URL = runtime.providerBaseURL
  initProfile(PROFILE_DIR, [PROFILE_BUNDLE])
  if (workerData?.safeMode || workerData?.recoveringRevision) await settlePluginRevision(PROFILE_DIR, true)
  const safeMode = workerData?.safeMode === true
  const compatibilityPatch = await preparePurgeSafeIOSOverlay(!safeMode)
  const manifest = readProfileManifest('dsh', PROFILE_DIR)
  const currentBundles = manifest.dsh?.profile?.bundles ?? []
  const bundles = [PROFILE_BUNDLE, ...currentBundles.filter((name) => name !== PROFILE_BUNDLE)]
  if (bundles.join('\n') !== currentBundles.join('\n')) writeProfileBundles(PROFILE_DIR, manifest, bundles)
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
    patchFiles: [compatibilityPatch],
    args: [],
  })
  ctx = application.ctx
  ctx.tools.guard((execution) => {
    const name = String(execution?.name ?? '')
    if (!name.startsWith('redteam_')) return undefined
    const sessionId = String(execution.agent?.session?.id ?? '')
    const policy = runtime.redteamTurnPolicies.get(sessionId)
    if (!policy) return { reason: 'iOS Web/非原生会话没有 dsh-purge-safe Bot 工具授权。' }
    const denial = redteamToolDenial(policy, name)
    if (denial) return { reason: denial }
    if (redteamToolNeedsApproval(policy, name)) {
      const key = redteamApprovalKey(sessionId, execution.callId)
      const approved = runtime.redteamApprovalGrants.get(key) === true
      runtime.redteamApprovalGrants.delete(key)
      if (!approved) return { reason: '此红队工具调用没有通过 iOS 会话审批，已拒绝执行。' }
    }
    return undefined
  })
  ctx.on('approval/request', async (request, next) => {
    const outcome = typeof next === 'function' ? await next() : 'rejected'
    if (String(request?.toolName ?? '').startsWith('redteam_') && request?.callId) {
      const key = redteamApprovalKey(request.agent?.session?.id, request.callId)
      if (outcome === 'allowed-once') runtime.redteamApprovalGrants.set(key, true)
      else runtime.redteamApprovalGrants.delete(key)
    }
    return outcome
  }, { global: true, prepend: true })
  runtime.profile = profile
  runtime.profileShutdown = application.shutdown
  runtime.persistence = ctx.get('sessionPersistence')
  const profileEntries = [...ctx.loader.entries()]
  const mountedRows = new Map(profileEntries.map((entry) => [entry.options.id, entry.fiber]))
  const hostPluginNames = new Map([
    ['@dsbot/dsh-ios-host/credentials', 'dsbot-ios-keychain-credentials'],
    ['@dsbot/dsh-ios-host/session-persistence', 'dsbot-ios-sqlite-session-persistence'],
    ['@dsbot/dsh-ios-host/native-tools', 'dsbot-ios-native-tools'],
    ['@dsbot/dsh-ios-host/sandbox-fs', 'dsbot-ios-sandbox-fs'],
    ['@dsbot/dsh-ios-host/approval', 'dsbot-ios-approval'],
    ['@dsbot/dsh-ios-host/fs-search', 'dsbot-ios-fs-search'],
    ['@dsbot/dsh-ios-host/questions', 'dsbot-ios-user-questions'],
  ])
  runtime.activePlugins = profileEntries
    .filter((entry) => entry.fiber?.state === 2)
    .map((entry) => {
      const name = entry.options.name ?? entry.options.id
      return hostPluginNames.get(name) ?? (name.startsWith('@deepseek-ai/') ? name.slice('@deepseek-ai/'.length) : name)
    })
    .filter((name) => typeof name === 'string')
    .sort()
  runtime.activePluginRows = profileEntries
    .filter((entry) => entry.fiber?.state === 2)
    .map((entry) => entry.options.id)
    .filter((id) => typeof id === 'string')
    .sort()
  runtime.providerFiber = mountedRows.get('llm-deepseek')
  runtime.subagentFiber = mountedRows.get('ios-subagent')
  runtime.toolSubagentFiber = mountedRows.get('ios-tool-subagent')
  runtime.webSearchFiber = mountedRows.get('ios-web-search')
  const requiredRows = ['session', 'session-projection', 'llm', 'llm-deepseek', 'system-prompt', 'tools',
    'agent', 'agent-loop', 'tool-executor-native', 'ios-web', 'ios-web-search', 'ios-fs', 'ios-working-directory', 'ios-subagent', 'ios-subagent-in-process', 'ios-tool-subagent',
    'commands', 'token-meter', 'compaction-pruner', 'compaction-basic', 'skill', 'user-approval', 'ios-approval', 'ios-fs-search', 'ios-questions',
    'command-feedback', 'message-feedback', 'session-log-export', 'session-query-sqlite', 'attachments',
    'agent-preset-registry', 'agent-preset-standard', 'agent-preset-creator', 'agent-preset-minimal', 'cordis-host-runner', 'cordis-inspect-providers', 'user-questions',
    'webserver', 'web-runtime', 'modules', 'connection', 'ios-private-session-access',
    'ios-keychain-credentials', 'ios-session-persistence', 'ios-native-tools']
  const inactive = requiredRows.filter((id) => mountedRows.get(id)?.state !== 2)
  if (inactive.length) throw new Error(`Required iOS DSH profile rows are inactive: ${inactive.join(', ')}`)
  const presetFailures = (await ctx.agentPresets.list())
    .filter((preset) => ['standard', 'cordis', 'minimal'].includes(preset.id) && preset.broken)
  if (presetFailures.length) {
    throw new Error(`Required iOS DSH modes are unavailable: ${presetFailures.map((preset) => `${preset.id}: ${preset.broken}`).join('; ')}`)
  }
  if (!runtime.persistence || !runtime.providerFiber) {
    throw new Error('The iOS DSH profile did not activate its persistence and DeepSeek provider plugins')
  }
  if (!safeMode && profile.layers.some(({ packageName }) => packageName !== PROFILE_BUNDLE)) {
    await auditStartupEntries(ctx, 'dsh')
    await auditExternalProfileLayers(profile.layers)
  }
  if (!safeMode) await settlePluginRevision(PROFILE_DIR, false)
  await cleanupPendingPluginRemovals(PROFILE_DIR)
  createIOSPluginManager({ rpc, runtime, workspace: WORKSPACE, profileDir: PROFILE_DIR, installAnchor: INSTALL_ANCHOR, safeMode, drainAgents: () => ctx.subagents.drainDescendants([...runtime.activeAgents.values()].map(({ agent }) => agent)) })
  await rpc.request('runtime.ready', runtimeInfo(), 30_000)
}

const webUiInfo = () => {
  const port = ctx?.webServer?.port
  if (!Number.isInteger(port) || port <= 0) return { ready: false, url: '', port: 0 }
  const baseUrl = `http://127.0.0.1:${port}/`
  const authUrl = typeof ctx?.connection?.authenticatedUrl === 'function'
    ? ctx.connection.authenticatedUrl(baseUrl)
    : baseUrl
  return { ready: true, url: authUrl, baseUrl, port }
}

const runtimeInfo = () => ({
  engine: 'node+dsh', dshVersion: '0.2.2-rc.5', nodeVersion: process.versions.node,
  ipcProtocolVersion: '1.0.0', persistentSessions: true,
  bootLifecycle: 'official-runProfile',
  profile: { name: PROFILE, bundles: runtime.profile?.layers?.map((layer) => layer.packageName) ?? [] },
  webProviders: ctx?.web?.listProviders(),
  webUI: webUiInfo(),
  pluginIndexFormat: 1, safeMode: workerData?.safeMode === true,
  plugins: runtime.activePlugins,
  tools: [...NATIVE_TOOL_NAMES, ...DEVELOPER_TOOL_NAMES],
})
rpc.handle('agent.info', async () => runtimeInfo())
rpc.handle('web.ui.info', async () => webUiInfo())
rpc.handle('agent.presets.list', async () => ({
  defaultId: ctx.agentPresets.defaultId,
  presets: await ctx.agentPresets.list(),
}))

rpc.handle('approval.respond', async ({ approvalId, sessionId, turnId, approved }) => {
  const pending = runtime.pendingDshApprovals.get(String(approvalId ?? ''))
  if (!pending || pending.sessionId !== sessionId || pending.turnId !== turnId) return { found: false }
  pending.settle(approved === true ? 'allowed-once' : 'rejected')
  return { found: true }
})

rpc.handle('user-question.respond', async ({ questionId, sessionId, turnId, answers }) => {
  const pending = runtime.pendingUserQuestions.get(String(questionId ?? ''))
  if (!pending || pending.sessionId !== sessionId || pending.turnId !== turnId || !Array.isArray(answers)) {
    return { found: false }
  }
  pending.settle({ answers })
  return { found: true }
})

rpc.handle('python.execute', async ({ botId, turnId, code }) => {
  const normalizedBotId = String(botId ?? '')
  const normalizedTurnId = String(turnId ?? '')
  const normalizedCode = typeof code === 'string' ? code : ''
  if (!/^[A-Za-z0-9_-]{1,80}$/.test(normalizedBotId)
      || !/^[A-Za-z0-9_-]{1,128}$/.test(normalizedTurnId)) {
    throw new TypeError('Invalid local Python session or turn.')
  }
  const active = runtime.activeTurns.get(dshSessionId(normalizedBotId))
  if (!active || active.turnId !== normalizedTurnId || active.done || runtime.suspended || runtime.shuttingDown) {
    throw new Error('Local Python is available only in the active Bot turn.')
  }
  return await executeIOSPython({ code: normalizedCode, botId: normalizedBotId, turnId: normalizedTurnId })
})

rpc.handle('python.cancel', async ({ botId, turnId }) => ({
  cancelled: cancelIOSPythonExecution({ botId: String(botId ?? ''), turnId: String(turnId ?? '') }),
}))

rpc.handle('chat.send', async (params) => {
  if (runtime.preparingTurn || runtime.activeTurns.size) throw new Error('Another DSH turn is already running')
  if (runtime.pluginMutationInProgress || runtime.profileRestartRequired) throw new Error('The DSH profile is changing')
  const preparation = {
    turnId: String(params.turnId ?? ''),
    botId: String(params.sessionId ?? ''),
    cancelled: false,
  }
  runtime.preparingTurn = preparation
  preparation.finished = startTurn(params, preparation).finally(() => {
    runtime.preparingTurn = undefined
  })
  return await preparation.finished
})

async function startTurn(params, preparation) {
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
  const webSearchEnabled = officialDeepSeek && params.webSearchEnabled === true
  const permissionMode = ['ask', 'autoReview', 'readOnly'].includes(params.permissionMode) ? params.permissionMode : 'ask'
  const redteamMode = params.redteamMode === true && runtime.redteamToolsEnabled && !runtime.privateBotIds.has(botId)
  const redteamWriteEnabled = redteamMode && params.redteamWriteEnabled === true
  const redteamSensitiveDataEnabled = redteamMode && params.redteamSensitiveDataEnabled === true
  const agentPreset = typeof params.agentPreset === 'string' ? params.agentPreset : ctx.agentPresets.defaultId
  const availablePresets = await ctx.agentPresets.list()
  if (!availablePresets.some((preset) => preset.id === agentPreset && !preset.broken)) {
    throw new Error(`Unknown or unavailable DSH mode: ${agentPreset}`)
  }
  if (agentPreset === 'redteam'
    && (!redteamMode || !redteamWriteEnabled || !redteamSensitiveDataEnabled || permissionMode === 'readOnly')) {
    throw new Error('红队模式要求当前 Bot 获准使用工具、写入演练台并访问敏感资料；只读模式不可使用。')
  }
  if (redteamMode) await setRedteamToolsMounted(true).catch(() => {})
  const id = dshSessionId(botId)
  let active = runtime.activeAgents.get(id)
  const options = {
    provider: 'deepseek-official', model: dshModel,
    reasoningEffort: reasoningEnabled ? 'high' : 'off',
  }
  if (!active) {
    const composition = setupAgent({
      botId, systemPrompt: params.systemPrompt, legacyHistory: params.legacyHistory, agentPreset,
      toolsEnabled, subagentEnabled: params.subagentEnabled === true, webSearchEnabled,
      redteamMode, redteamWriteEnabled, redteamSensitiveDataEnabled, permissionMode,
    })
    let handle
    try {
      if (await runtime.persistence.stat(id)) {
        handle = await ctx.agents.resume({ resumeSessionId: id, agentOptions: options, setup: composition.setup })
      } else {
        handle = await ctx.agents.create({ sessionId: id, meta: { cwd: WORKSPACE_FILES }, agentOptions: options, setup: composition.setup })
      }
    } catch (error) {
      if (error instanceof SessionPersistenceNotFoundError) {
        handle = await ctx.agents.create({ sessionId: id, meta: { cwd: WORKSPACE_FILES }, agentOptions: options, setup: composition.setup })
      } else throw error
    }
    try {
      const currentDirectory = ctx.workingDirectory.get(handle.agent.session)
      const target = await ctx.fs.resolve(currentDirectory)
      const info = await ctx.fs.stat(target)
      if (info?.type !== 'directory') throw new Error('The saved working directory is unavailable')
    } catch {
      await ctx.workingDirectory.set(handle.agent, WORKSPACE_FILES)
    }
    const selection = ctx.agentPresets.presetForSession(handle.agent.session)
    const boundary = ctx.agents.turnBoundaryOf(handle.agent.session)
    if (boundary.lastTurn === 0 && selection !== agentPreset) {
      await ctx.agentPresets.select(handle.agent, agentPreset)
    }
    active = { handle, agent: handle.agent, setPersona: composition.setPersona, setToolsEnabled: composition.setToolsEnabled, botId, agentPreset }
    guardIOSBackgroundFollowups(active.agent)
    runtime.activeAgents.set(id, active)
  } else {
    if (active.agentPreset !== agentPreset) {
      throw new Error('DSH mode is fixed for this conversation. Create a new Bot conversation to switch modes.')
    }
    active.agent.model.select(options)
    active.setPersona(params.systemPrompt)
    active.setToolsEnabled(toolsEnabled, params.subagentEnabled === true, webSearchEnabled,
      redteamMode, redteamWriteEnabled, redteamSensitiveDataEnabled, permissionMode)
  }

  if (preparation.cancelled || runtime.suspended) {
    rpc.notify('chat.done', { sessionId: botId, turnId, status: 'aborted' })
    return { turnId, status: 'accepted', engine: 'node+dsh' }
  }
  const userMessage = createUserMessage({ content: [{ type: 'text', text }], source: { kind: 'user' } })
  const turn = { turnId, botId, isGroup: params.isGroup === true, webSearchEnabled, toolsEnabled, permissionMode, done: false }
  runtime.activeTurns.set(id, turn)
  runtime.redteamTurnPolicies.set(id, {
    botId,
    enabled: toolsEnabled && redteamMode,
    write: redteamWriteEnabled,
    sensitive: redteamSensitiveDataEnabled,
    permissionMode,
  })
  const startSeq = active.agent.session.seq
  try {
    active.agent.followup(userMessage)
  } catch (error) {
    runtime.activeTurns.delete(id)
    clearRedteamApprovalGrants(id)
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
      clearRedteamApprovalGrants(id)
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

function clearRedteamApprovalGrants(sessionId) {
  runtime.redteamTurnPolicies.delete(sessionId)
  const prefix = `${sessionId}:`
  for (const key of runtime.redteamApprovalGrants.keys()) {
    if (key.startsWith(prefix)) runtime.redteamApprovalGrants.delete(key)
  }
}

async function preparePurgeSafeIOSOverlay(enabled) {
  const pluginRoot = join(PROFILE_DIR, 'node_modules', 'dsh-purge-safe')
  const installed = existsSync(join(pluginRoot, 'package.json'))
  let compatibility = { webWorkbenchAvailable: false, reason: installed ? '尚未检查插件 Web 适配' : '插件尚未安装' }
  if (installed) {
    try { compatibility = await ensurePurgeSafeIOSCompatibility(pluginRoot) }
    catch (error) { compatibility = { webWorkbenchAvailable: false, reason: error instanceof Error ? error.message : String(error) } }
  }
  runtime.redteamCompatibility = compatibility
  const rows = []
  if (enabled && installed) {
    rows.push([
      '- id: dsh-purge-safe',
      '  config:',
      '    enabled: true',
      '    autoApplyOnStart: false',
      '    autoUpdateOnStart: false',
      '    autoRevertOnMissing: false',
      '    toolGateBypass: false',
      '    subagentControl: false',
    ].join('\n'))
    if (!compatibility.webWorkbenchAvailable) rows.push('- id: dsh-purge-safe-redteam-ui\n  disabled: true')
  }
  const path = join(WORKSPACE, '.dsbot-ios-plugin-compat.patch.yml')
  writeFileSync(path, `${rows.length ? rows.join('\n') : '[]'}\n`, { mode: 0o600 })
  return path
}

rpc.handle('chat.abort', async ({ turnId }) => {
  const item = [...runtime.activeTurns.entries()].find(([, active]) => active.turnId === turnId)
  if (!item) {
    const preparation = runtime.preparingTurn
    if (!preparation || preparation.turnId !== turnId) return { aborted: false }
    preparation.cancelled = true
    return { aborted: true, sessionId: preparation.botId }
  }
  const [id, activeTurn] = item
  const active = runtime.activeAgents.get(id)
  active?.agent.cancel({ kind: 'user' })
  void rpc.request('native.tool.cancel', { botId: activeTurn.botId, sessionId: activeTurn.botId, turnId }, 5_000).catch(() => {})
  if (active) await drainAndDispose(id, active)
  return { aborted: true, sessionId: activeTurn.botId }
})

rpc.handle('agent.suspend', async () => {
  runtime.suspended = true
  const suspendGeneration = ++runtime.suspendGeneration
  const preparation = runtime.preparingTurn
  if (preparation) preparation.cancelled = true
  const cancelTools = []
  for (const [id, active] of runtime.activeAgents) {
    const turn = runtime.activeTurns.get(id)
    if (active.agent.status === 'running') {
      const pendingJobNotices = [...(active.agent.inbox?.nextStep ?? []), ...(active.agent.inbox?.nextTurn ?? [])]
        .filter((message) => message.source?.kind === 'tool-jobs')
      active.agent.cancel({ kind: 'user' })
      for (const message of pendingJobNotices) active.agent.inject(message)
    }
    if (turn) cancelTools.push(rpc.request('native.tool.cancel', {
      botId: turn.botId, sessionId: turn.botId, turnId: turn.turnId,
    }, 5_000).catch(() => {}))
  }
  const cancelSideRequests = [...runtime.sideRequests.keys()].map((sideId) => rpc.request('workspace.request', {
    method: 'side.cancel', params: { sideId },
  }, 5_000).catch(() => {}))
  await Promise.all([...cancelTools, ...cancelSideRequests])
  if (preparation) await preparation.finished.catch(() => {})
  if (runtime.suspendGeneration !== suspendGeneration || !runtime.suspended) {
    return { suspended: false }
  }
  for (const [id, active] of runtime.activeAgents) {
    const ownsJobs = (ctx.jobs?.list(id) ?? []).some((job) => job.owner === id)
    if (ownsJobs) {
      // Preserve the owner while its process-local Jobs records or queued
      // completion notices remain visible to the native task manager.
      await ctx.subagents.drainDescendants([active.agent])
      await active.agent.whenIdle()
      await ctx.sessions.flush(active.agent.session)
      if (runtime.suspendGeneration !== suspendGeneration || !runtime.suspended) {
        return { suspended: false }
      }
      continue
    }
    await drainAndDispose(id, active)
    if (runtime.suspendGeneration !== suspendGeneration || !runtime.suspended) {
      return { suspended: false }
    }
  }
  await runtime.persistence.flush()
  return { suspended: runtime.suspendGeneration === suspendGeneration && runtime.suspended }
})
rpc.handle('agent.resume', async () => {
  runtime.suspendGeneration += 1
  runtime.suspended = false
  return { suspended: false }
})

rpc.handle('session.list', async () => {
  const sessions = (await runtime.persistence.list())
    .filter((item) => item.header.id.startsWith('ios:'))
    .map((item) => {
      const botId = botIdFromSession(item.header.id)
      return {
        sessionId: botId,
        createdAt: item.header.createdAt,
        eventCount: item.eventCount,
        ...(!runtime.privateBotIds.has(botId) ? {
          lastActivityAt: item.lastActivityAt,
          lastMessagePreview: item.lastMessagePreview,
        } : {}),
      }
    })
  return { sessions }
})

rpc.handle('session.history', async ({ sessionId }) => {
  const id = String(sessionId ?? '').startsWith('ios:') ? String(sessionId) : dshSessionId(String(sessionId ?? ''))
  const events = await runtime.persistence.history(id)
  return {
    sessionId: botIdFromSession(id),
    messages: eventMessages(events, botIdFromSession(id)),
    toolActivities: eventToolActivities(events, botIdFromSession(id)),
    approvals: eventApprovalAudits(events, botIdFromSession(id), 80),
  }
})

// Sequence cursors refer to raw events, including events with no visible row.
function nativeHistorySessionId(sessionId) {
  if (typeof sessionId !== 'string' || !/^[A-Za-z0-9_-]{1,80}$/.test(sessionId)) {
    throw new TypeError('Invalid native session identifier')
  }
  return dshSessionId(sessionId)
}

// Keep native search on the same DSH index as Web, with a native Bot allowlist.
rpc.handle('session.search', async ({ query, botIds, cursor } = {}) => {
  if (typeof query !== 'string' || !query.trim() || Array.from(query).length > 160
    || !Array.isArray(botIds) || botIds.length > 5000
    || (cursor !== undefined && (typeof cursor !== 'string' || cursor.length > 8192))) {
    throw new TypeError('Invalid native session search request')
  }
  const allowed = new Set(botIds.map((botId) => {
    const id = nativeHistorySessionId(botId)
    return runtime.privateBotIds.has(botId) ? undefined : id
  }).filter(Boolean))
  if (!allowed.size) return { results: [] }
  const provider = ctx.get('sessionQuery')
  if (!provider) throw new Error('DSH session search is unavailable')
  const page = await provider.searchSessions({
    query: query.trim(),
    sessionFilters: [{ kind: 'id', values: [...allowed].sort() }],
    eventFilters: [
      { kind: 'type', values: ['user/message', 'assistant/message'] },
      { kind: 'surface', values: ['current'] },
    ],
    limit: 20,
    ...(cursor === undefined ? {} : { cursor }),
  })
  const results = []
  for (const { header, bestMatch } of page.items) {
    const botId = botIdFromSession(header.id)
    if (!allowed.has(header.id) || runtime.privateBotIds.has(botId) || header.parentSession != null) continue
    results.push({
      botId, sequence: bestMatch.seq, timestamp: bestMatch.time, snippet: bestMatch.snippet,
    })
  }
  return { results, nextCursor: page.nextCursor }
})

rpc.handle('session.search.context', async ({ sessionId, sequence } = {}) => {
  const id = nativeHistorySessionId(sessionId)
  if (!Number.isSafeInteger(sequence) || sequence < 0 || runtime.privateBotIds.has(sessionId)) {
    throw new Error('Search result is unavailable')
  }
  await runtime.persistence.flushSession(id)
  const summary = await runtime.persistence.stat(id)
  if (!summary || summary.header.parentSession != null || sequence >= summary.eventCount) {
    throw new Error('Search result is unavailable')
  }
  const start = Math.max(0, sequence - 20)
  const end = Math.min(summary.eventCount, sequence + 21)
  const handle = await runtime.persistence.open(id, 'read')
  try {
    const { events } = await handle.read(start, end - start)
    const messages = eventMessages(events, sessionId)
    if (!messages.some((message) => message.sequence === sequence) || runtime.privateBotIds.has(sessionId)) {
      throw new Error('Search result is unavailable')
    }
    return { messages: messages.map(historyMessagePreview) }
  } finally {
    await handle.close()
  }
})

function historyMessagePreview(row) {
  return {
    ...row, content: excerpt(row.content, 1000), reasoning: excerpt(row.reasoning, 300),
    truncated: row.content.length > 1000 || row.reasoning.length > 300,
  }
}

rpc.handle('session.history.message', async ({ sessionId, sequence } = {}) => {
  const id = nativeHistorySessionId(sessionId)
  if (!Number.isSafeInteger(sequence) || sequence < 0) throw new TypeError('Invalid message sequence')
  const handle = await runtime.persistence.open(id, 'read')
  try {
    const { events } = await handle.read(sequence, 1)
    const [message] = eventMessages(events, sessionId)
    if (!message) throw new Error('Message not found')
    if (Buffer.byteLength(JSON.stringify(message)) > 2 * 1024 * 1024) throw new RangeError('Message exceeds the preview size limit')
    return message
  } finally {
    await handle.close()
  }
})

function historyStringPage(value, from, limit) {
  const bytes = Buffer.from(String(value ?? ''), 'utf8')
  if (from > bytes.length) throw new RangeError('Tool history cursor exceeds the field length')
  let start = from
  while (start < bytes.length && (bytes[start] & 0xc0) === 0x80) start += 1
  let end = Math.min(start + limit, bytes.length)
  while (end < bytes.length && (bytes[end] & 0xc0) === 0x80) end -= 1
  return {
    text: bytes.subarray(start, end).toString('utf8'),
    next: end,
    total: bytes.length,
  }
}

function pagedHistoryToolPayload(payload, argumentsFrom, resultFrom, pageBytes) {
  const argumentsPage = historyStringPage(payload.arguments, argumentsFrom, pageBytes)
  const resultPage = historyStringPage(payload.result, resultFrom, pageBytes)
  return {
    ...payload,
    arguments: argumentsPage.text,
    argumentsNext: argumentsPage.next,
    argumentsTotalBytes: argumentsPage.total,
    result: resultPage.text,
    resultNext: resultPage.next,
    resultTotalBytes: resultPage.total,
  }
}

rpc.handle('session.history.tool', async ({ sessionId, sequence, argumentsFrom = 0, resultFrom = 0, pageBytes = 64 * 1024 } = {}) => {
  const id = nativeHistorySessionId(sessionId)
  if (!Number.isSafeInteger(sequence) || sequence < 0
    || !Number.isSafeInteger(argumentsFrom) || argumentsFrom < 0
    || !Number.isSafeInteger(resultFrom) || resultFrom < 0
    || !Number.isSafeInteger(pageBytes) || pageBytes < 1024 || pageBytes > 64 * 1024) {
    throw new TypeError('Invalid tool history page request')
  }
  await runtime.persistence.flushSession(id)
  const summary = await runtime.persistence.stat(id)
  if (!summary || sequence >= summary.eventCount) throw new Error('Tool activity not found')
  const handle = await runtime.persistence.open(id, 'read')
  try {
    const first = await handle.read(sequence, 1)
    const call = first.events[0]
    if (call?.type === 'tool/ptc-dispatch' && call.seq === sequence) {
      const data = call.data ?? {}
      const parentCallId = String(data.parentCallId ?? '')
      const subCallId = String(data.subCallId ?? '')
      if (!parentCallId || !subCallId) throw new Error('PTC tool activity not found')
      const payload = {
        id: `dsh-history-ptc-${sequence}-${subCallId}`,
        callId: subCallId,
        toolName: String(data.name ?? 'DSH tool'),
        arguments: typeof data.arguments === 'string' ? data.arguments : JSON.stringify(data.arguments ?? {}),
        result: fullToolResultText({ content: data.content, isError: data.isError === true }, data.error),
        phase: data.isError === true ? 'failed' : 'completed',
      }
      return pagedHistoryToolPayload(payload, argumentsFrom, resultFrom, pageBytes)
    }
    if (call?.type !== 'tool/call' || call.seq !== sequence) throw new Error('Tool activity not found')
    const callId = String(call.data?.callId ?? '')
    if (!callId) throw new Error('Tool activity not found')
    const turn = Number.isSafeInteger(call.data?.turn) ? call.data.turn : 0
    const step = Number.isSafeInteger(call.data?.step) ? call.data.step : 0
    const activityId = `dsh-history-${turn}-${step}-${callId}`
    let resultEvent
    const end = Math.min(sequence + 1_000, summary.eventCount)
    for (let offset = sequence + 1; offset < end && !resultEvent; offset += 25) {
      const batch = await handle.read(offset, Math.min(25, end - offset))
      resultEvent = batch.events.find((event) => event.type === 'tool/result'
        && event.data?.message?.source?.callId === callId)
    }
    const resultMessage = resultEvent?.data?.message
    const resultText = Array.isArray(resultMessage?.content)
      ? resultMessage.content.filter((block) => block?.type === 'text').map((block) => String(block.text ?? '')).join('\n')
      : ''
    const args = typeof call.data?.arguments === 'string'
      ? call.data.arguments
      : JSON.stringify(call.data?.arguments ?? {})
    const errorValue = resultEvent?.data?.error?.reason ?? resultEvent?.data?.error?.code
    const payload = {
      id: activityId,
      callId,
      toolName: String(resultMessage?.source?.toolName ?? call.data?.name ?? 'DSH tool'),
      arguments: args,
      result: resultText || (errorValue === undefined ? undefined : String(errorValue))
        || (resultMessage?.isError ? '工具调用失败。' : resultEvent ? '工具已完成。' : '工具结果未写入历史；这次调用可能在执行期间中断。'),
      phase: !resultEvent ? 'unknown' : resultEvent.data?.error || resultMessage?.isError ? 'failed' : 'completed',
    }
    return pagedHistoryToolPayload(payload, argumentsFrom, resultFrom, pageBytes)
  } finally {
    await handle.close()
  }
})

rpc.handle('session.history.markdown', async ({ sessionId } = {}) => {
  const id = nativeHistorySessionId(sessionId)
  await runtime.persistence.flushSession(id)
  const summary = await runtime.persistence.stat(id)
  if (!summary) return { markdown: '' }
  const handle = await runtime.persistence.open(id, 'read')
  const sections = []
  let bytes = 0
  try {
    for (let offset = 0; offset < summary.eventCount; offset += 50) {
      const { events } = await handle.read(offset, Math.min(50, summary.eventCount - offset))
      for (const message of eventMessages(events, sessionId)) {
        const speaker = message.role === 'user' ? '用户' : '助手'
        const date = new Date(message.timestamp)
        const timestamp = Number.isFinite(date.getTime()) ? date.toISOString() : ''
        const section = '## ' + speaker + (timestamp ? ' · ' + timestamp : '') + '\n\n' + message.content + '\n\n'
        bytes += Buffer.byteLength(section)
        if (bytes > 2 * 1024 * 1024) throw new RangeError('完整导出超过 2 MiB 上限')
        sections.push(section)
      }
    }
    return { markdown: sections.join('') }
  } finally {
    await handle.close()
  }
})

rpc.handle('session.history.page', async ({ sessionId, beforeSeq } = {}) => {
  if (typeof sessionId !== 'string' || !/^[A-Za-z0-9_-]{1,80}$/.test(sessionId)
    || (beforeSeq !== undefined && (!Number.isSafeInteger(beforeSeq) || beforeSeq < 0))) {
    throw new TypeError('Invalid session history cursor')
  }
  const id = dshSessionId(sessionId)
  await runtime.persistence.flushSession(id)
  const summary = await runtime.persistence.stat(id)
  const end = Math.min(beforeSeq ?? Infinity, summary?.eventCount ?? 0)
  const start = Math.max(0, end - 50)
  if (!summary || end === start) return { messages: [], toolActivities: [], hasMore: false }
  const handle = await runtime.persistence.open(id, 'read')
  try {
    const { events } = await handle.read(start, end - start)
    const activityEvents = [...events]
    const approvals = await approvalEventsForHistoryPage(handle, events, start, end, summary.eventCount)
    const pageCalls = new Set(events
      .filter((event) => event.type === 'tool/call')
      .map((event) => event.data.callId))
    if (pageCalls.size > 0) {
      const limit = Math.min(end + 500, summary.eventCount)
      for (let offset = end; offset < limit; offset += 25) {
        const batch = await handle.read(offset, Math.min(25, limit - offset))
        for (const result of batch.events) {
          if (result.type === 'tool/result' && pageCalls.has(result.data?.message?.source?.callId)) {
            activityEvents.push(result)
          }
        }
      }
    }
    return {
      messages: eventMessages(events, sessionId).map(historyMessagePreview),
      toolActivities: eventToolActivities(activityEvents, sessionId, end, 50).map((row) => ({
        ...row, arguments: excerpt(row.arguments, 600), result: excerpt(row.result, 600),
      })),
      approvals: eventApprovalAudits(approvals, sessionId, 80),
      hasMore: start > 0,
      nextBeforeSeq: start,
    }
  } finally {
    await handle.close()
  }
})

rpc.handle('schedule.list', async ({ botId }) => {
  if (typeof botId !== 'string' || !/^[A-Za-z0-9_-]{1,80}$/.test(botId)) throw new TypeError('Invalid Bot id')
  const sessionId = dshSessionId(botId)
  const tasks = (await ctx.schedule.catalog())
    .filter((task) => iosScheduleTaskVisible(task, sessionId))
    .map(iosSchedulePublicTask)
  return { tasks }
})

function iosJobsOwner(botId) {
  if (typeof botId !== 'string' || !/^[A-Za-z0-9_-]{1,80}$/.test(botId)) throw new TypeError('Invalid Bot id')
  if (runtime.privateBotIds.has(botId)) throw new Error('Background Jobs are disabled for private Bot sessions')
  return dshSessionId(botId)
}

function iosJobPublicView(job) {
  return {
    id: String(job.id), kind: String(job.kind), label: excerpt(job.label, 160), status: String(job.status),
    ...(typeof job.progress === 'string' && job.progress ? { progress: excerpt(job.progress, 300) } : {}),
    ...(typeof job.detail === 'string' && job.detail ? { detail: excerpt(job.detail, 800) } : {}),
    startedAt: job.startedAt,
    ...(Number.isSafeInteger(job.finishedAt) ? { finishedAt: job.finishedAt } : {}),
    output: {
      total: job.output?.total ?? 0,
      earliest: job.output?.earliest ?? 0,
    },
  }
}

rpc.handle('jobs.list', async ({ botId } = {}) => {
  const owner = iosJobsOwner(botId)
  if (!ctx.jobs) throw new Error('DSH Jobs is unavailable in this runtime')
  const jobs = ctx.jobs.list(owner)
    .filter((job) => job.owner === owner)
    .sort((left, right) => right.startedAt - left.startedAt)
    .slice(0, 100)
    .map(iosJobPublicView)
  return { jobs }
})

rpc.handle('jobs.output', async ({ botId, jobId, from = 0 } = {}) => {
  const owner = iosJobsOwner(botId)
  if (typeof jobId !== 'string' || !/^[A-Za-z0-9][A-Za-z0-9_-]{0,99}$/.test(jobId)
    || !Number.isSafeInteger(from) || from < 0) throw new TypeError('Invalid Jobs output request')
  if (!ctx.jobs) throw new Error('DSH Jobs is unavailable in this runtime')
  let job
  try { job = ctx.jobs.get(jobId, owner) } catch { return { found: false } }
  if (job.owner !== owner || from > job.output.total) return { found: false }
  const output = ctx.jobs.readAt(jobId, from, owner)
  return {
    found: true,
    job: iosJobPublicView(ctx.jobs.get(jobId, owner)),
    chunks: output.chunks.map((chunk) => ({
      at: chunk.at,
      text: chunk.text,
      ...(chunk.channel ? { channel: chunk.channel } : {}),
      ...(chunk.gapBefore ? { gapBefore: true } : {}),
    })),
    next: output.next,
    lossy: output.lossy,
  }
})

rpc.handle('jobs.kill', async ({ botId, jobId, reason } = {}) => {
  const owner = iosJobsOwner(botId)
  if (typeof jobId !== 'string' || !/^[A-Za-z0-9][A-Za-z0-9_-]{0,99}$/.test(jobId)
    || (reason !== undefined && (typeof reason !== 'string' || reason.length > 160))) {
    throw new TypeError('Invalid Jobs cancellation request')
  }
  if (!ctx.jobs) throw new Error('DSH Jobs is unavailable in this runtime')
  let current
  try { current = ctx.jobs.get(jobId, owner) } catch { return { found: false } }
  if (current.owner !== owner) return { found: false }
  const result = ctx.jobs.kill(jobId, owner, reason ?? 'Cancelled from the iOS Jobs manager')
  return { found: true, result, job: iosJobPublicView(ctx.jobs.get(jobId, owner)) }
})

rpc.handle('schedule.edit', async ({ botId, id, action, title, prompt, rrule, expectedUpdatedAt }) => {
  if (typeof botId !== 'string' || !/^[A-Za-z0-9_-]{1,80}$/.test(botId)
    || typeof id !== 'string' || id.length > 160
    || !['pause', 'resume', 'delete', 'update'].includes(action)
    || (title !== undefined && (typeof title !== 'string' || title.length > 120))
    || (prompt !== undefined && (typeof prompt !== 'string' || prompt.length > 20_000))
    || (rrule !== undefined && (typeof rrule !== 'string' || rrule.length > 4_096))
    || (expectedUpdatedAt !== undefined && (typeof expectedUpdatedAt !== 'string' || expectedUpdatedAt.length > 64))) throw new TypeError('Invalid Schedule request')
  const sessionId = dshSessionId(botId)
  const current = await ctx.schedule.view({ id })
  if (!iosScheduleTaskVisible(current, sessionId)) return { found: false }
  const revision = expectedUpdatedAt !== undefined
    ? { expectedUpdatedAt }
    : current.updatedAt === undefined ? {} : { expectedUpdatedAt: current.updatedAt }
  let request
  if (action === 'delete') {
    request = { id, action: 'delete', ...revision }
  } else if (action === 'pause' || action === 'resume') {
    request = { id, action: 'update', patch: { active: action === 'resume' }, ...revision }
  } else {
    const patch = {
      ...(title === undefined ? {} : { title }),
      ...(prompt === undefined ? {} : { prompt }),
      ...(rrule === undefined ? {} : { timing: { kind: 'rrule', rrule } }),
    }
    if (Object.keys(patch).length === 0) throw new TypeError('Schedule update requires at least one field')
    if (rrule !== undefined && current.kind !== 'rrule') throw new TypeError('Only RFC 5545 recurrence tasks accept an RRULE edit')
    request = { id, action: 'update', patch, ...revision }
  }
  const task = await ctx.schedule.edit(request, sessionId)
  const found = Boolean(task && typeof task === 'object' && !('code' in task) && !('deleted' in task))
  const deleted = Boolean(task && typeof task === 'object' && task.deleted === true)
  return { found: found || deleted, deleted, ...(found ? { task: iosSchedulePublicTask(task) } : { result: task }) }
})

rpc.handle('schedule.history', async ({ botId, id, limit, before }) => {
  if (typeof botId !== 'string' || !/^[A-Za-z0-9_-]{1,80}$/.test(botId)
    || typeof id !== 'string' || id.length > 160
    || (limit !== undefined && (!Number.isSafeInteger(limit) || limit < 1 || limit > 100))
    || (before !== undefined && (typeof before !== 'string' || before.length > 256))) throw new TypeError('Invalid Schedule history request')
  const sessionId = dshSessionId(botId)
  const current = await ctx.schedule.view({ id })
  if (!iosScheduleTaskVisible(current, sessionId)) return { found: false }
  const result = await ctx.schedule.history({ id, limit: limit ?? 50, ...(before === undefined ? {} : { before }) })
  if (!Array.isArray(result?.records)) return { found: false }
  return {
    found: true,
    history: {
      ...result,
      records: result.records.map(({ targetSessionId: _targetSessionId, ...receipt }) => receipt),
    },
  }
})

rpc.handle('session.private.update', async ({ botIds }) => {
  if (!Array.isArray(botIds) || botIds.length > 10_000
    || botIds.some((id) => typeof id !== 'string' || !/^[A-Za-z0-9_-]{1,80}$/.test(id))) {
    throw new TypeError('Invalid private Bot id list')
  }
  runtime.privateBotIds = new Set(botIds)
  process.env.DS_BOT_IOS_PRIVATE_BOT_IDS = JSON.stringify([...runtime.privateBotIds])
  for (const botId of runtime.privateBotIds) {
    const owner = dshSessionId(botId)
    for (const job of ctx.jobs?.list(owner) ?? []) {
      if (job.owner === owner && (job.status === 'running' || job.status === 'stopping')) {
        try { ctx.jobs.kill(job.id, owner, 'Bot session was marked private') } catch { /* settled during the privacy update */ }
      }
    }
  }
  ctx?.emit('ios/private-sessions/changed', [...runtime.privateBotIds])
  return { updated: runtime.privateBotIds.size }
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

// UI-owned workspace methods (memory, connectors, approvals, speech, local JS) are routed by
// Swift directly to its native workspace and are intentionally not reachable through this process.

let redteamToolsFork = null

function redteamToolsModulePath() {
  const candidate = join(PROFILE_DIR, 'node_modules', 'dsh-purge-safe', 'lib', 'redteam', 'tools.js')
  return existsSync(candidate) ? candidate : null
}

function redteamSkillsCount() {
  for (const dir of [
    join(WORKSPACE, 'redteam', 'skills'),
    join(PROFILE_DIR, 'node_modules', 'dsh-purge-safe', 'skills', 'redteam'),
  ]) {
    if (existsSync(dir)) {
      try {
        return readdirSync(dir).filter((f) => f.endsWith('.md')).length
      } catch { /* ignore */ }
    }
  }
  return 0
}

async function setRedteamToolsMounted(enabled) {
  runtime.redteamToolsEnabled = enabled === true
  process.env.DS_BOT_IOS_REDTEAM_ENABLED = runtime.redteamToolsEnabled ? '1' : '0'
  if (!enabled) {
    runtime.redteamApprovalGrants.clear()
    for (const policy of runtime.redteamTurnPolicies.values()) policy.enabled = false
    if (redteamToolsFork) {
      try { await redteamToolsFork.dispose() } catch { /* ignore */ }
      redteamToolsFork = null
    }
    return redteamStatus()
  }
  if (!redteamToolsFork) {
    const toolsPath = redteamToolsModulePath()
    if (!toolsPath) return redteamStatus()
    const mod = await import(pathToFileURL(toolsPath).href)
    const plugin = mod?.default ?? mod
    if (plugin && ctx) {
      redteamToolsFork = ctx.plugin(plugin)
      try { await redteamToolsFork.await?.() } catch { /* ignore */ }
    }
  }
  return redteamStatus()
}

function redteamStatus() {
  const installed = Boolean(redteamToolsModulePath())
  const layerActive = runtime.activePlugins.includes('dsh-purge-safe')
  const webLayerActive = runtime.activePluginRows.includes('dsh-purge-safe-redteam-ui')
  const storeReady = Boolean(ctx?.get?.('redteam'))
  const tools = registeredRedteamToolNames()
  const compatibilityWarning = runtime.redteamCompatibility.reason
    || (!webLayerActive ? 'iOS DSH profile 未激活 dsh-purge-safe/redteam/ui 子层' : '')
  return {
    installed,
    pluginActive: layerActive,
    rootPatchDisabled: true,
    storeReady,
    redteamModeActive: runtime.redteamToolsEnabled && (Boolean(redteamToolsFork) || tools.length > 0),
    hostEnabled: runtime.redteamToolsEnabled,
    webPermissions: { ...runtime.redteamWebPermissions },
    webWorkbenchSupported: runtime.redteamCompatibility.webWorkbenchAvailable === true && webLayerActive,
    compatibilityWarning: compatibilityWarning ?? '',
    toolCount: tools.length,
    tools,
    skillCount: redteamSkillsCount(),
  }
}

rpc.handle('redteam.status', async () => redteamStatus())
rpc.handle('redteam.setMode', async ({ enabled } = {}) => setRedteamToolsMounted(enabled === true))
rpc.handle('redteam.setWebPermissions', async ({ read, write, sensitive } = {}) => {
  if ([read, write, sensitive].some((value) => value !== undefined && typeof value !== 'boolean')) {
    throw new TypeError('Invalid dsh-purge-safe Web permissions')
  }
  const next = {
    read: read === undefined ? runtime.redteamWebPermissions.read : read,
    write: write === undefined ? runtime.redteamWebPermissions.write : write,
    sensitive: sensitive === undefined ? runtime.redteamWebPermissions.sensitive : sensitive,
  }
  next.write = next.read && next.write
  next.sensitive = next.read && next.sensitive
  runtime.redteamWebPermissions = next
  process.env.DS_BOT_IOS_REDTEAM_WEB_READ = next.read ? '1' : '0'
  process.env.DS_BOT_IOS_REDTEAM_WEB_WRITE = next.write ? '1' : '0'
  process.env.DS_BOT_IOS_REDTEAM_WEB_SENSITIVE = next.sensitive ? '1' : '0'
  return redteamStatus()
})

const liveConfig = {
  subagentMaxDepth: 1,
  subagentMaxActive: 1,
  subagentModelSelection: false,
  webSearchCount: 5,
  webSearchSendOriginalQuestion: false,
}
runtime.liveConfig = liveConfig

rpc.handle('runtime.config.get', async () => ({ ...liveConfig }))

rpc.handle('runtime.config.update', async (params = {}) => {
  const next = { ...liveConfig }
  const integerSetting = (name, minimum, maximum) => {
    if (params[name] === undefined) return
    if (!Number.isInteger(params[name])) throw new TypeError(`${name} must be an integer`)
    next[name] = Math.max(minimum, Math.min(maximum, params[name]))
  }
  const booleanSetting = (name) => {
    if (params[name] === undefined) return
    if (typeof params[name] !== 'boolean') throw new TypeError(`${name} must be a boolean`)
    next[name] = params[name]
  }
  integerSetting('subagentMaxDepth', 0, 3)
  integerSetting('subagentMaxActive', 1, 8)
  integerSetting('webSearchCount', 1, 20)
  booleanSetting('subagentModelSelection')
  booleanSetting('webSearchSendOriginalQuestion')

  const previous = { ...liveConfig }
  const updated = []
  const updates = [
    [runtime.subagentFiber, {
      maxDepth: next.subagentMaxDepth,
      maxActiveSubagents: next.subagentMaxActive,
    }, {
      maxDepth: previous.subagentMaxDepth,
      maxActiveSubagents: previous.subagentMaxActive,
    }],
    [runtime.toolSubagentFiber, {
      provider: 'spawn',
      toolName: 'subagent',
      maxDepth: next.subagentMaxDepth,
      modelSelection: next.subagentModelSelection,
    }, {
      provider: 'spawn',
      toolName: 'subagent',
      maxDepth: previous.subagentMaxDepth,
      modelSelection: previous.subagentModelSelection,
    }],
    [runtime.webSearchFiber, {
      searchBaseURL: 'https://api.deepseek.com/v1/tools',
      searchApiKeyEnv: 'DEEPSEEK_API_KEY',
      searchBilling: 'api-key',
      sendOriginalQuestion: next.webSearchSendOriginalQuestion,
      count: next.webSearchCount,
    }, {
      searchBaseURL: 'https://api.deepseek.com/v1/tools',
      searchApiKeyEnv: 'DEEPSEEK_API_KEY',
      searchBilling: 'api-key',
      sendOriginalQuestion: previous.webSearchSendOriginalQuestion,
      count: previous.webSearchCount,
    }],
  ].filter(([fiber]) => fiber)

  runtime.webSearchConfigSynced = false
  try {
    for (const [fiber, config, rollback] of updates) {
      updated.push([fiber, rollback])
      await fiber.update(config)
    }
  } catch (error) {
    runtime.webSearchConfigSynced = false
    const rollbackErrors = []
    for (const [fiber, config] of updated.reverse()) {
      try { await fiber.update(config) } catch (rollbackError) {
        rollbackErrors.push(rollbackError instanceof Error ? rollbackError.message : String(rollbackError))
      }
    }
    const detail = rollbackErrors.length ? `; rollback failed: ${rollbackErrors.join('; ')}` : ''
    throw new Error(`Runtime configuration update failed: ${error instanceof Error ? error.message : String(error)}${detail}`)
  }

  Object.assign(liveConfig, next)
  runtime.webSearchConfigSynced = Boolean(runtime.webSearchFiber)
  return { ok: true, config: { ...liveConfig } }
})

rpc.handle('usage.summary', (params) => dshUsageSummary(params))

rpc.handle('side.ask', async (params) => {
  const sideId = typeof params?.sideId === 'string' ? params.sideId : ''
  if (!sideId || sideId.length > 128 || runtime.sideRequests.has(sideId)) throw new TypeError('Invalid or duplicate side-chat request id')
  const request = rpc.request('workspace.request', { method: 'side.ask', params }, 120_000)
  runtime.sideRequests.set(sideId, request)
  try { return await request } finally {
    if (runtime.sideRequests.get(sideId) === request) runtime.sideRequests.delete(sideId)
  }
})

rpc.handle('side.cancel', async (params = {}) => {
  const sideId = params?.sideId
  if (typeof sideId !== 'string' || !sideId || sideId.length > 128) return { cancelled: false }
  const wasActive = runtime.sideRequests.has(sideId)
  try {
    const result = await rpc.request('workspace.request', { method: 'side.cancel', params: { sideId } }, 5_000)
    return { cancelled: result?.cancelled === true || wasActive }
  } catch {
    return { cancelled: false }
  }
})

// ── iOS Experimental Desktop Capabilities: Sandboxed Virtual Terminal (PTY), Git Worktree & PR Tracker, and Cordis/Node DevTools Inspector ──

import { copyFileSync, lstatSync, readFileSync, rmSync, statSync } from 'node:fs'
import { createHash } from 'node:crypto'
import { basename, dirname, isAbsolute, relative, resolve, sep } from 'node:path'
import vm from 'node:vm'

const virtualTerminals = new Map()
const devtoolsLogs = []
const MAX_DEVTOOLS_LOGS = 200

function pushDevtoolsLog(level, category, message) {
  devtoolsLogs.push({
    id: `${Date.now()}_${Math.random().toString(36).slice(2, 7)}`,
    timestamp: new Date().toISOString(),
    level,
    category,
    message: String(message ?? '').slice(0, 4_000),
  })
  if (devtoolsLogs.length > MAX_DEVTOOLS_LOGS) devtoolsLogs.splice(0, devtoolsLogs.length - MAX_DEVTOOLS_LOGS)
}

function getVirtualTerminalSession(sessionId = 'default') {
  const key = typeof sessionId === 'string' && sessionId.trim() ? sessionId.trim() : 'default'
  let term = virtualTerminals.get(key)
  if (!term) {
    term = {
      id: key,
      cwd: '/',
      env: {
        USER: 'ios-sandbox',
        HOME: '/workspace',
        PWD: '/workspace',
        SHELL: '/bin/dsbot-vsh',
        LANG: 'zh_CN.UTF-8',
      },
      history: [],
    }
    virtualTerminals.set(key, term)
  }
  return term
}

function resolveInsideWorkspaceFiles(virtualCwd, targetPath = '.') {
  const root = resolve(WORKSPACE_FILES)
  const raw = String(targetPath || '.').trim()
  const baseVirtual = virtualCwd.startsWith('/') ? virtualCwd.slice(1) : virtualCwd
  const combined = raw.startsWith('/workspace')
    ? resolve(root, raw.slice('/workspace'.length).replace(/^\/+/, ''))
    : raw.startsWith('/')
      ? resolve(root, raw.replace(/^\/+/, ''))
      : resolve(root, baseVirtual, raw)
  const rel = relative(root, combined)
  if (rel === '..' || rel.startsWith(`..${sep}`) || isAbsolute(rel)) {
    throw new Error(`权限拒绝：路径越出 iOS 沙盒工作区 (${targetPath})`)
  }
  return {
    abs: combined,
    rel: rel ? rel.split(sep).join('/') : '',
    virtual: rel ? `/${rel.split(sep).join('/')}` : '/',
  }
}

function tokenizeShellWords(input) {
  const tokens = []
  let current = ''
  let quote = null
  for (let i = 0; i < input.length; i++) {
    const ch = input[i]
    if (quote) {
      if (ch === quote) quote = null
      else if (ch === '\\' && quote === '"' && i + 1 < input.length) current += input[++i]
      else current += ch
    } else if (ch === '"' || ch === "'") {
      quote = ch
    } else if (/\s/.test(ch)) {
      if (current) { tokens.push(current); current = '' }
    } else {
      current += ch
    }
  }
  if (current) tokens.push(current)
  return tokens
}

function walkWorkspaceTree(dirAbs, baseAbs = resolve(WORKSPACE_FILES), out = []) {
  let entries = []
  try { entries = readdirSync(dirAbs, { withFileTypes: true }) } catch { return out }
  for (const entry of entries) {
    if (entry.name === '.DS_Store' || entry.name === '.dsbot-ios-workspace-root' || entry.name === '.dsbot-git-tracker.json') continue
    const full = join(dirAbs, entry.name)
    const rel = relative(baseAbs, full).split(sep).join('/')
    if (entry.isDirectory()) {
      walkWorkspaceTree(full, baseAbs, out)
    } else if (entry.isFile()) {
      try {
        const st = statSync(full)
        const buf = st.size <= 524_288 ? readFileSync(full) : null
        const sha = buf ? createHash('sha1').update(buf).digest('hex') : `size:${st.size}`
        out.push({
          path: rel,
          size: st.size,
          mtimeMs: Math.round(st.mtimeMs),
          sha,
          content: buf && !buf.includes(0) ? buf.toString('utf8') : null,
        })
      } catch { /* ignore */ }
    }
  }
  return out.sort((a, b) => a.path.localeCompare(b.path))
}

function gitTrackerFilePath() {
  return join(WORKSPACE, 'git-worktree-tracker.json')
}

function loadGitTrackerState() {
  const fp = gitTrackerFilePath()
  try {
    if (existsSync(fp)) return JSON.parse(readFileSync(fp, 'utf8'))
  } catch { /* ignore */ }
  return {
    repo: '',
    branch: 'main',
    snapshotAt: null,
    commits: [],
    files: {},
  }
}

function saveGitTrackerState(state) {
  writeFileSync(gitTrackerFilePath(), JSON.stringify(state, null, 2), 'utf8')
}

function computeWorkspaceGitStatus() {
  const tracker = loadGitTrackerState()
  const currentFiles = walkWorkspaceTree(resolve(WORKSPACE_FILES))
  const currentMap = new Map(currentFiles.map((f) => [f.path, f]))
  const baseline = tracker.files || {}
  const changes = []

  for (const file of currentFiles) {
    const prev = baseline[file.path]
    if (!prev) {
      changes.push({ path: file.path, status: 'A', label: '新增', size: file.size })
    } else if (prev.sha !== file.sha) {
      changes.push({ path: file.path, status: 'M', label: '修改', size: file.size })
    }
  }
  for (const oldPath of Object.keys(baseline)) {
    if (!currentMap.has(oldPath)) {
      changes.push({ path: oldPath, status: 'D', label: '删除', size: 0 })
    }
  }
  return {
    repo: tracker.repo || '',
    branch: tracker.branch || 'main',
    snapshotAt: tracker.snapshotAt,
    commits: Array.isArray(tracker.commits) ? tracker.commits.slice(0, 30) : [],
    totalTracked: Object.keys(baseline).length,
    totalWorkspaceFiles: currentFiles.length,
    changes,
  }
}

function computeWorkspaceGitDiff(targetRelPath) {
  const tracker = loadGitTrackerState()
  const currentFiles = walkWorkspaceTree(resolve(WORKSPACE_FILES))
  const currentMap = new Map(currentFiles.map((f) => [f.path, f]))
  const baseline = tracker.files || {}
  const paths = targetRelPath
    ? [targetRelPath.replace(/^\/+/, '')]
    : [...new Set([...Object.keys(baseline), ...currentMap.keys()])].sort()
  const chunks = []
  for (const p of paths) {
    const prev = baseline[p]
    const curr = currentMap.get(p)
    if (!prev && curr) {
      const lines = (curr.content ?? '[二进制文件]').split(/\r?\n/).slice(0, 120)
      chunks.push(`--- /dev/null\n+++ b/${p}\n@@ -0,0 +1,${lines.length} @@\n` + lines.map((l) => `+${l}`).join('\n'))
    } else if (prev && !curr) {
      const lines = (prev.content ?? '[二进制文件]').split(/\r?\n/).slice(0, 120)
      chunks.push(`--- a/${p}\n+++ /dev/null\n@@ -1,${lines.length} +0,0 @@\n` + lines.map((l) => `-${l}`).join('\n'))
    } else if (prev && curr && prev.sha !== curr.sha) {
      const oldLines = (prev.content ?? '').split(/\r?\n/)
      const newLines = (curr.content ?? '').split(/\r?\n/)
      const diffLines = [`--- a/${p}`, `+++ b/${p}`, `@@ -1,${oldLines.length} +1,${newLines.length} @@`]
      const maxLen = Math.min(120, Math.max(oldLines.length, newLines.length))
      for (let i = 0; i < maxLen; i++) {
        const o = oldLines[i]
        const n = newLines[i]
        if (o === n) diffLines.push(` ${o ?? ''}`)
        else {
          if (o !== undefined) diffLines.push(`-${o}`)
          if (n !== undefined) diffLines.push(`+${n}`)
        }
      }
      chunks.push(diffLines.join('\n'))
    }
  }
  return chunks.join('\n\n') || '工作树干净，与基线快照无差异。'
}

function takeWorkspaceGitSnapshot(message = 'Update workspace snapshot') {
  const tracker = loadGitTrackerState()
  const currentFiles = walkWorkspaceTree(resolve(WORKSPACE_FILES))
  const filesObj = {}
  for (const f of currentFiles) {
    filesObj[f.path] = {
      sha: f.sha,
      size: f.size,
      mtimeMs: f.mtimeMs,
      content: typeof f.content === 'string' && f.content.length <= 65_536 ? f.content : null,
    }
  }
  const commitId = createHash('sha1').update(`${Date.now()}:${message}:${currentFiles.length}`).digest('hex').slice(0, 7)
  const now = new Date().toISOString()
  tracker.snapshotAt = now
  tracker.files = filesObj
  tracker.commits = [
    { id: commitId, message: String(message || 'Workspace snapshot').slice(0, 160), timestamp: now, fileCount: currentFiles.length },
    ...(Array.isArray(tracker.commits) ? tracker.commits : []).slice(0, 29),
  ]
  saveGitTrackerState(tracker)
  return computeWorkspaceGitStatus()
}

async function fetchGithubPullRequests(repoInput) {
  const tracker = loadGitTrackerState()
  const repo = String(repoInput || tracker.repo || '').trim().replace(/^https?:\/\/github\.com\//i, '').replace(/\.git$/i, '').replace(/^\/+|\/+$/g, '')
  if (!/^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/.test(repo)) {
    throw new Error('请输入有效的 GitHub 仓库标识（格式：owner/repo）')
  }
  if (repo !== tracker.repo) {
    tracker.repo = repo
    saveGitTrackerState(tracker)
  }
  const headers = {
    'Accept': 'application/vnd.github+json',
    'User-Agent': 'DSBot-iOS-GitTracker/1.0',
  }
  const [prsRes, commitsRes] = await Promise.all([
    fetch(`https://api.github.com/repos/${repo}/pulls?state=all&per_page=15`, { headers }),
    fetch(`https://api.github.com/repos/${repo}/commits?per_page=10`, { headers }),
  ])
  if (!prsRes.ok) {
    throw new Error(`GitHub API 请求失败 (${prsRes.status})：请确认仓库 ${repo} 为公开仓库或网络可达`)
  }
  const prsData = await prsRes.json()
  const commitsData = commitsRes.ok ? await commitsRes.json() : []
  const pullRequests = Array.isArray(prsData) ? prsData.map((pr) => ({
    number: pr.number,
    title: String(pr.title ?? ''),
    state: pr.merged_at ? 'merged' : String(pr.state ?? 'open'),
    author: String(pr.user?.login ?? ''),
    branch: `${pr.head?.ref ?? ''} → ${pr.base?.ref ?? ''}`,
    updatedAt: String(pr.updated_at ?? ''),
    url: String(pr.html_url ?? ''),
  })) : []
  const remoteCommits = Array.isArray(commitsData) ? commitsData.map((c) => ({
    sha: String(c.sha ?? '').slice(0, 7),
    message: String(c.commit?.message ?? '').split('\n')[0],
    author: String(c.commit?.author?.name ?? c.author?.login ?? ''),
    date: String(c.commit?.author?.date ?? ''),
  })) : []
  return { repo, pullRequests, remoteCommits }
}

async function runSingleVirtualCommand(term, rawSegment) {
  const line = rawSegment.trim()
  if (!line) return ''
  const tokens = tokenizeShellWords(line)
  if (!tokens.length) return ''
  const cmd = tokens[0]
  const args = tokens.slice(1)

  switch (cmd) {
    case 'help':
      return [
        'DS Bot iOS 沙盒持久终端 (Virtual PTY) 支持命令：',
        '  pwd, cd <dir>, ls [-la] [dir], cat <file>, head [-n N] <file>, tail [-n N] <file>',
        '  mkdir <dir>, touch <file>, cp <src> <dst>, mv <src> <dst>, rm [-r] <path>',
        '  find [dir] [-name pat], grep <pattern> [file/dir], wc <file>, echo <text>',
        '  env, export KEY=VAL, date, uname -a, whoami, clear',
        '  node -e "<js>"  — 在沙盒 VM 中运行 JavaScript',
        '  python -c "<py>" — 在本机离线 Python 3.13/NumPy 中执行代码',
        '  git status | git diff [path] | git log | git commit -m "<msg>"',
      ].join('\n')

    case 'pwd':
      return `/workspace${term.cwd === '/' ? '' : term.cwd}`

    case 'whoami':
      return term.env.USER || 'ios-sandbox'

    case 'uname':
      return `Darwin DSBot-iOS-Sandbox 24.0.0 arm64 Node/${process.versions.node} DSH/0.2.2-rc.5`

    case 'date':
      return new Date().toISOString()

    case 'env':
      return Object.entries(term.env).map(([k, v]) => `${k}=${v}`).join('\n')

    case 'export': {
      for (const item of args) {
        const eq = item.indexOf('=')
        if (eq > 0) {
          const k = item.slice(0, eq).trim()
          const v = item.slice(eq + 1)
          if (/^[A-Za-z_][A-Za-z0-9_]*$/.test(k)) term.env[k] = v
        }
      }
      return ''
    }

    case 'cd': {
      const target = args[0] || '/'
      const resolved = resolveInsideWorkspaceFiles(term.cwd, target)
      if (!existsSync(resolved.abs) || !statSync(resolved.abs).isDirectory()) {
        throw new Error(`cd: 目录不存在: ${target}`)
      }
      term.cwd = resolved.virtual
      term.env.PWD = `/workspace${term.cwd === '/' ? '' : term.cwd}`
      return ''
    }

    case 'ls':
    case 'll': {
      const flags = args.filter((a) => a.startsWith('-')).join('')
      const longFmt = cmd === 'll' || flags.includes('l')
      const showHidden = cmd === 'll' || flags.includes('a')
      const targetArg = args.find((a) => !a.startsWith('-')) || '.'
      const resolved = resolveInsideWorkspaceFiles(term.cwd, targetArg)
      if (!existsSync(resolved.abs)) throw new Error(`ls: 路径不存在: ${targetArg}`)
      const st = statSync(resolved.abs)
      if (!st.isDirectory()) return basename(resolved.abs)
      const entries = readdirSync(resolved.abs, { withFileTypes: true })
        .filter((e) => showHidden || !e.name.startsWith('.'))
        .sort((a, b) => a.name.localeCompare(b.name))
      if (!longFmt) return entries.map((e) => e.isDirectory() ? `${e.name}/` : e.name).join('  ')
      return entries.map((e) => {
        const full = join(resolved.abs, e.name)
        let size = 0
        let mtime = ''
        try {
          const s = lstatSync(full)
          size = s.size
          mtime = s.mtime.toISOString().slice(0, 16).replace('T', ' ')
        } catch { /* ignore */ }
        const typeChar = e.isDirectory() ? 'd' : '-'
        return `${typeChar}rw-r--r--  ${String(size).padStart(8)}  ${mtime}  ${e.name}${e.isDirectory() ? '/' : ''}`
      }).join('\n')
    }

    case 'cat': {
      if (!args.length) throw new Error('cat: 请指定文件名')
      const outputs = []
      for (const arg of args) {
        const resolved = resolveInsideWorkspaceFiles(term.cwd, arg)
        if (!existsSync(resolved.abs) || statSync(resolved.abs).isDirectory()) {
          throw new Error(`cat: 无法读取文件: ${arg}`)
        }
        outputs.push(readFileSync(resolved.abs, 'utf8').slice(0, 32_000))
      }
      return outputs.join('\n')
    }

    case 'head':
    case 'tail': {
      let count = 10
      const fileArgs = []
      for (let i = 0; i < args.length; i++) {
        if (args[i] === '-n' && args[i + 1]) {
          count = Math.max(1, Math.min(500, Number(args[++i]) || 10))
        } else if (/^-\d+$/.test(args[i])) {
          count = Math.max(1, Math.min(500, Number(args[i].slice(1)) || 10))
        } else {
          fileArgs.push(args[i])
        }
      }
      if (!fileArgs.length) throw new Error(`${cmd}: 请指定文件名`)
      const resolved = resolveInsideWorkspaceFiles(term.cwd, fileArgs[0])
      const lines = readFileSync(resolved.abs, 'utf8').split(/\r?\n/)
      return (cmd === 'head' ? lines.slice(0, count) : lines.slice(-count)).join('\n')
    }

    case 'wc': {
      if (!args.length) throw new Error('wc: 请指定文件名')
      const fileArg = args.find((a) => !a.startsWith('-'))
      const resolved = resolveInsideWorkspaceFiles(term.cwd, fileArg)
      const content = readFileSync(resolved.abs, 'utf8')
      const lines = content.split(/\r?\n/).length
      const words = content.trim() ? content.trim().split(/\s+/).length : 0
      const bytes = Buffer.byteLength(content, 'utf8')
      return `  ${lines}  ${words}  ${bytes} ${fileArg}`
    }

    case 'mkdir': {
      const dirs = args.filter((a) => !a.startsWith('-'))
      if (!dirs.length) throw new Error('mkdir: 请指定目录名')
      for (const d of dirs) {
        const resolved = resolveInsideWorkspaceFiles(term.cwd, d)
        mkdirSync(resolved.abs, { recursive: true })
      }
      return ''
    }

    case 'touch': {
      const files = args.filter((a) => !a.startsWith('-'))
      if (!files.length) throw new Error('touch: 请指定文件名')
      for (const f of files) {
        const resolved = resolveInsideWorkspaceFiles(term.cwd, f)
        mkdirSync(dirname(resolved.abs), { recursive: true })
        if (!existsSync(resolved.abs)) writeFileSync(resolved.abs, '', 'utf8')
      }
      return ''
    }

    case 'cp': {
      const paths = args.filter((a) => !a.startsWith('-'))
      if (paths.length < 2) throw new Error('cp: 用法 cp <src> <dst>')
      const src = resolveInsideWorkspaceFiles(term.cwd, paths[0])
      const dst = resolveInsideWorkspaceFiles(term.cwd, paths[1])
      mkdirSync(dirname(dst.abs), { recursive: true })
      copyFileSync(src.abs, dst.abs)
      return ''
    }

    case 'mv': {
      const paths = args.filter((a) => !a.startsWith('-'))
      if (paths.length < 2) throw new Error('mv: 用法 mv <src> <dst>')
      const src = resolveInsideWorkspaceFiles(term.cwd, paths[0])
      const dst = resolveInsideWorkspaceFiles(term.cwd, paths[1])
      mkdirSync(dirname(dst.abs), { recursive: true })
      copyFileSync(src.abs, dst.abs)
      rmSync(src.abs, { recursive: true, force: true })
      return ''
    }

    case 'rm': {
      const recursive = args.some((a) => a.startsWith('-') && (a.includes('r') || a.includes('R')))
      const targets = args.filter((a) => !a.startsWith('-'))
      if (!targets.length) throw new Error('rm: 请指定要删除的路径')
      for (const t of targets) {
        const resolved = resolveInsideWorkspaceFiles(term.cwd, t)
        if (resolved.abs === resolve(WORKSPACE_FILES)) throw new Error('rm: 禁止删除工作区根目录')
        rmSync(resolved.abs, { recursive, force: true })
      }
      return ''
    }

    case 'echo': {
      const redirectIdx = args.findIndex((a) => a === '>' || a === '>>')
      if (redirectIdx >= 0 && args[redirectIdx + 1]) {
        const op = args[redirectIdx]
        const text = args.slice(0, redirectIdx).join(' ') + '\n'
        const target = resolveInsideWorkspaceFiles(term.cwd, args[redirectIdx + 1])
        mkdirSync(dirname(target.abs), { recursive: true })
        const existing = op === '>>' && existsSync(target.abs) ? readFileSync(target.abs, 'utf8') : ''
        writeFileSync(target.abs, existing + text, 'utf8')
        return ''
      }
      return args.join(' ')
    }

    case 'find': {
      const startArg = args[0] && !args[0].startsWith('-') ? args[0] : '.'
      const nameIdx = args.indexOf('-name')
      const pattern = nameIdx >= 0 && args[nameIdx + 1] ? args[nameIdx + 1].replace(/\*/g, '.*') : null
      const regex = pattern ? new RegExp(`^${pattern}$`, 'i') : null
      const resolved = resolveInsideWorkspaceFiles(term.cwd, startArg)
      const files = walkWorkspaceTree(resolved.abs, resolved.abs)
      return files
        .filter((f) => !regex || regex.test(basename(f.path)))
        .map((f) => `./${f.path}`)
        .join('\n') || '(无匹配文件)'
    }

    case 'grep': {
      const nonFlags = args.filter((a) => !a.startsWith('-'))
      if (!nonFlags.length) throw new Error('grep: 用法 grep <pattern> [path]')
      const query = nonFlags[0]
      const targetArg = nonFlags[1] || '.'
      const resolved = resolveInsideWorkspaceFiles(term.cwd, targetArg)
      const st = statSync(resolved.abs)
      const hits = []
      const scanFile = (absPath, display) => {
        try {
          const text = readFileSync(absPath, 'utf8')
          text.split(/\r?\n/).forEach((l, idx) => {
            if (l.toLowerCase().includes(query.toLowerCase()) && hits.length < 100) {
              hits.push(`${display}:${idx + 1}: ${l.slice(0, 300)}`)
            }
          })
        } catch { /* ignore */ }
      }
      if (st.isFile()) {
        scanFile(resolved.abs, targetArg)
      } else {
        for (const f of walkWorkspaceTree(resolved.abs, resolved.abs)) {
          scanFile(join(resolved.abs, f.path), f.path)
          if (hits.length >= 100) break
        }
      }
      return hits.join('\n') || `(未找到匹配 "${query}" 的行)`
    }

    case 'node':
    case 'js': {
      const code = cmd === 'node' && (args[0] === '-e' || args[0] === '-p')
        ? args.slice(1).join(' ')
        : args.join(' ')
      if (!code.trim()) throw new Error('用法: node -e "<JavaScript 表达式>"')
      const logs = []
      const sandbox = {
        console: {
          log: (...items) => logs.push(items.map((x) => typeof x === 'string' ? x : JSON.stringify(x)).join(' ')),
          error: (...items) => logs.push(items.map((x) => typeof x === 'string' ? x : JSON.stringify(x)).join(' ')),
        },
        Math, Date, JSON, Number, String, Boolean, Array, Object,
      }
      const result = vm.runInNewContext(code, sandbox, { timeout: 3_000 })
      if (result !== undefined) logs.push(typeof result === 'string' ? result : JSON.stringify(result, null, 2))
      return logs.join('\n')
    }

    case 'python':
    case 'python3': {
      let code = ''
      if (args[0] === '-c') {
        code = args.slice(1).join(' ')
      } else if (args[0]) {
        const resolved = resolveInsideWorkspaceFiles(term.cwd, args[0])
        code = readFileSync(resolved.abs, 'utf8')
      } else {
        throw new Error('用法: python -c "<Python 代码>" 或 python <file.py>')
      }
      const res = await executeIOSPython({
        code,
        botId: 'terminal',
        turnId: `term_${Date.now()}`,
      })
      return String(res?.output ?? '')
    }

    case 'git': {
      const sub = args[0] || 'status'
      if (sub === 'status') {
        const st = computeWorkspaceGitStatus()
        const lines = [
          `On branch ${st.branch}${st.repo ? ` (${st.repo})` : ''}`,
          st.snapshotAt ? `Baseline snapshot: ${st.snapshotAt}` : '尚未建立基线快照（可运行 git commit -m "init" 创建基线）',
        ]
        if (!st.changes.length) {
          lines.push('nothing to commit, working tree clean')
        } else {
          lines.push('Changes not staged for commit:')
          for (const c of st.changes) lines.push(`  ${c.status}  ${c.path}`)
        }
        return lines.join('\n')
      }
      if (sub === 'diff') {
        return computeWorkspaceGitDiff(args[1])
      }
      if (sub === 'log') {
        const st = computeWorkspaceGitStatus()
        if (!st.commits.length) return '尚无本地快照提交记录。'
        return st.commits.map((c) => `commit ${c.id} (${c.timestamp})\n    ${c.message} [${c.fileCount} files]`).join('\n\n')
      }
      if (sub === 'commit' || sub === 'snapshot') {
        const mIdx = args.indexOf('-m')
        const msg = mIdx >= 0 && args[mIdx + 1] ? args.slice(mIdx + 1).join(' ') : 'Workspace snapshot'
        const st = takeWorkspaceGitSnapshot(msg)
        return `[${st.branch} ${st.commits[0]?.id ?? ''}] ${msg} (${st.totalWorkspaceFiles} files snapshotted)`
      }
      throw new Error(`git: 支持子命令 status | diff [file] | log | commit -m "<msg>"`)
    }

    default:
      throw new Error(`${cmd}: 未找到命令（输入 help 查看 iOS 沙盒持久终端支持的命令）`)
  }
}

async function executeVirtualTerminalCommand(sessionId, commandLine) {
  const term = getVirtualTerminalSession(sessionId)
  const raw = String(commandLine ?? '').trim()
  if (!raw) return { cwd: term.cwd, output: '', exitCode: 0 }
  term.history.push({ command: raw, timestamp: new Date().toISOString() })
  if (term.history.length > 100) term.history.splice(0, term.history.length - 100)
  pushDevtoolsLog('info', 'terminal', `[${term.id}] $ ${raw}`)

  const segments = raw.split(/\s*&&\s*/).filter(Boolean)
  const outputs = []
  let exitCode = 0
  for (const seg of segments) {
    try {
      const out = await runSingleVirtualCommand(term, seg)
      if (out) outputs.push(out)
    } catch (error) {
      outputs.push(error instanceof Error ? error.message : String(error))
      exitCode = 1
      break
    }
  }
  return {
    sessionId: term.id,
    cwd: `/workspace${term.cwd === '/' ? '' : term.cwd}`,
    output: outputs.join('\n'),
    exitCode,
    historyCount: term.history.length,
  }
}

runtime.executeVirtualTerminal = async (args, exec) => {
  const sessionId = exec?.agent?.session?.id ?? 'default'
  const command = String(args?.command ?? '').trim()
  if (!command) throw new Error('terminal_exec requires a non-empty command')
  const active = runtime.activeTurns.get(sessionId)
  if (active && active.permissionMode !== 'autoReview') {
    const isMutating = /\b(rm|mv|cp|mkdir|touch|export|commit|node|python|python3)\b|>/.test(command)
    if (isMutating || active.permissionMode === 'readOnly') {
      if (active.permissionMode === 'readOnly' && isMutating) {
        throw new Error(`Read-only mode blocked terminal command: ${command}`)
      }
      const outcome = await ctx.approval.request({
        agent: exec.agent,
        toolName: 'terminal_exec',
        ...(exec.callId ? { callId: exec.callId } : {}),
        reason: `Execute sandboxed virtual terminal command: ${command}`,
        displayReason: `允许在 iOS 沙盒持久终端执行命令？\n$ ${command}`,
        signal: exec.signal,
      })
      if (outcome !== 'allowed-once') throw new Error('User did not approve terminal_exec command')
    }
  }
  const res = await executeVirtualTerminalCommand(sessionId, command)
  return { output: `[cwd: ${res.cwd}] (exit ${res.exitCode})\n${res.output || '(done)'}` }
}

runtime.executeGitWorkspaceTool = async (args) => {
  const action = String(args?.action ?? 'status')
  if (action === 'status') {
    const st = computeWorkspaceGitStatus()
    return { output: JSON.stringify(st, null, 2) }
  }
  if (action === 'diff') {
    return { output: computeWorkspaceGitDiff(args?.path) }
  }
  if (action === 'snapshot') {
    const st = takeWorkspaceGitSnapshot('Agent workspace snapshot')
    return { output: JSON.stringify(st, null, 2) }
  }
  if (action === 'pr_list') {
    const prs = await fetchGithubPullRequests(args?.repo)
    return { output: JSON.stringify(prs, null, 2) }
  }
  throw new Error(`Unsupported git_workspace action: ${action}`)
}

rpc.handle('terminal.exec', async ({ sessionId = 'default', command }) => {
  return await executeVirtualTerminalCommand(sessionId, command)
})

rpc.handle('terminal.state', async ({ sessionId = 'default' } = {}) => {
  const term = getVirtualTerminalSession(sessionId)
  return {
    sessionId: term.id,
    cwd: `/workspace${term.cwd === '/' ? '' : term.cwd}`,
    env: term.env,
    history: term.history.slice(-30),
  }
})

rpc.handle('terminal.reset', async ({ sessionId = 'default' } = {}) => {
  virtualTerminals.delete(sessionId)
  const term = getVirtualTerminalSession(sessionId)
  return {
    sessionId: term.id,
    cwd: `/workspace${term.cwd === '/' ? '' : term.cwd}`,
    reset: true,
  }
})

rpc.handle('git.status', async () => computeWorkspaceGitStatus())
rpc.handle('git.diff', async ({ path } = {}) => ({ diff: computeWorkspaceGitDiff(path) }))
rpc.handle('git.snapshot', async ({ message } = {}) => takeWorkspaceGitSnapshot(message))
rpc.handle('git.pullRequests', async ({ repo } = {}) => await fetchGithubPullRequests(repo))

rpc.handle('devtools.inspect', async () => {
  const mem = process.memoryUsage()
  const entries = [...(ctx?.loader?.entries?.() ?? [])].map((entry) => ({
    id: String(entry.options?.id ?? ''),
    name: String(entry.options?.name ?? ''),
    disabled: Boolean(entry.disabled),
    state: entry.fiber?.state === 2 ? 'active' : entry.fiber?.state === 1 ? 'loading' : 'inactive',
  }))
  const tools = (ctx?.tools?.definitions?.() ?? []).map((t) => ({
    name: String(t.name ?? ''),
    description: String(t.description ?? '').slice(0, 140),
  }))
  return {
    nodeVersion: process.versions.node,
    dshVersion: '0.2.2-rc.5',
    uptimeSeconds: Math.round(process.uptime()),
    memory: {
      rssMB: Math.round((mem.rss / 1048576) * 10) / 10,
      heapUsedMB: Math.round((mem.heapUsed / 1048576) * 10) / 10,
      heapTotalMB: Math.round((mem.heapTotal / 1048576) * 10) / 10,
      externalMB: Math.round((mem.external / 1048576) * 10) / 10,
    },
    activeSessions: runtime.activeAgents.size,
    activeTurns: runtime.activeTurns.size,
    webPort: ctx?.webServer?.port ?? 0,
    cordisEntries: entries,
    registeredTools: tools,
    recentLogs: devtoolsLogs.slice(-60).reverse(),
  }
})

rpc.handle('devtools.eval', async ({ expression } = {}) => {
  const expr = String(expression ?? '').trim()
  if (!expr) throw new Error('请输入要评估的诊断表达式')
  pushDevtoolsLog('info', 'devtools.eval', expr)
  const sandbox = {
    process: {
      version: process.version,
      versions: process.versions,
      platform: process.platform,
      arch: process.arch,
      uptime: () => process.uptime(),
      memoryUsage: () => process.memoryUsage(),
      env: {
        DSH_HOME: process.env.DSH_HOME,
        DSH_BASE: process.env.DSH_BASE,
        DS_BOT_IOS_HOST: process.env.DS_BOT_IOS_HOST,
      },
    },
    runtime: {
      activePlugins: runtime.activePlugins,
      activePluginRows: runtime.activePluginRows,
      activeAgents: [...runtime.activeAgents.keys()],
      activeTurns: [...runtime.activeTurns.keys()],
      redteamToolsEnabled: runtime.redteamToolsEnabled,
    },
    tools: (ctx?.tools?.definitions?.() ?? []).map((t) => t.name),
    cordisEntries: [...(ctx?.loader?.entries?.() ?? [])].map((e) => ({ id: e.options?.id, name: e.options?.name, state: e.fiber?.state })),
    JSON, Math, Date, Object, Array, String, Number, Boolean,
  }
  const result = vm.runInNewContext(expr, sandbox, { timeout: 2_000 })
  const formatted = typeof result === 'string' ? result : JSON.stringify(result, null, 2)
  return { output: String(formatted ?? 'undefined').slice(0, 16_000) }
})

// Approval notifications stay inside Swift and do not transit Node.

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

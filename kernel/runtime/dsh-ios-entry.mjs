import { EventEmitter } from 'node:events'
import { existsSync, mkdirSync, readdirSync, writeFileSync } from 'node:fs'
import { readdir, readFile } from 'node:fs/promises'
import { join } from 'node:path'
import { parentPort, workerData } from 'node:worker_threads'
import net from 'node:net'
import { fileURLToPath, pathToFileURL } from 'node:url'
import { configureIOSHost } from '@dsbot/dsh-ios-host'
import { auditStartupEntries, initProfile, loadLayeredEnv, loadProfileDirectory, readProfileManifest, resolveProfileDir, writeProfileBundles } from '@deepseek-ai/dsh-app-boot'
import { installModelSelection } from '@deepseek-ai/dsh-agent'
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
import { installCustomEndpointCompatFetch } from './ios-openai-compat-adapter.mjs'
import { parseEchoRedirection, splitTerminalSegments, tokenizeShellWords } from './ios-host-package/virtual-terminal-policy.mjs'

const IPC_FD = Number(process.argv.find((arg) => arg.startsWith('--ipc-fd='))?.slice('--ipc-fd='.length))
const WORKSPACE = process.argv.find((arg) => arg.startsWith('--workspace='))?.slice('--workspace='.length)
let WORKSPACE_FILES = WORKSPACE ? join(WORKSPACE, 'files') : undefined
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
try { WORKSPACE_FILES = realpathSync(WORKSPACE_FILES) } catch {}
process.env.DSH_AGENTS_HOME = WORKSPACE_FILES
const WORKSPACE_ROOT_MARKER = join(WORKSPACE_FILES, '.dsbot-ios-workspace-root')
if (!existsSync(WORKSPACE_ROOT_MARKER)) {
  try { writeFileSync(WORKSPACE_ROOT_MARKER, '', { flag: 'wx' }) } catch (error) {
    if (error?.code !== 'EEXIST') throw error
  }
}

function syncLegacySkillsToWorkspaceFiles() {
  if (!WORKSPACE || !WORKSPACE_FILES) return
  const legacySkillsDir = join(WORKSPACE, 'skills')
  const sandboxSkillsDir = join(WORKSPACE_FILES, 'skills')
  if (!existsSync(legacySkillsDir)) return
  try {
    const entries = readdirSync(legacySkillsDir, { withFileTypes: true })
    for (const entry of entries) {
      if (entry.name.startsWith('.') || entry.isSymbolicLink()) continue
      if (entry.isDirectory()) {
        const srcSkill = join(legacySkillsDir, entry.name, 'SKILL.md')
        const dstDir = join(sandboxSkillsDir, entry.name)
        const dstSkill = join(dstDir, 'SKILL.md')
        if (existsSync(srcSkill) && !existsSync(dstSkill)) {
          mkdirSync(dstDir, { recursive: true })
          copyFileSync(srcSkill, dstSkill)
        }
      } else if (entry.isFile() && entry.name.toLowerCase().endsWith('.md')) {
        const folder = entry.name.replace(/\.md$/i, '')
        const srcFile = join(legacySkillsDir, entry.name)
        const dstDir = join(sandboxSkillsDir, folder)
        const dstSkill = join(dstDir, 'SKILL.md')
        if (!existsSync(dstSkill)) {
          mkdirSync(dstDir, { recursive: true })
          copyFileSync(srcFile, dstSkill)
        }
      }
    }
  } catch {}
}
syncLegacySkillsToWorkspaceFiles()

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
  allAgentHandles: new Map(),
  botPolicies: new Map(),
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
  if (!['http:', 'https:'].includes(url.protocol) || url.username || url.password || url.search || url.hash) {
    throw new Error('DSH requires an HTTP(S) API address without credentials, query, or fragment')
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

export function flattenToolSchema(schema, defs = undefined, depth = 0) {
  if (!schema || typeof schema !== 'object' || Array.isArray(schema) || depth > 12) return schema
  const rootDefs = defs ?? schema.$defs ?? schema.definitions ?? {}
  if (typeof schema.$ref === 'string') {
    const key = schema.$ref.replace(/^#\/(\$defs|definitions)\//, '')
    if (Object.hasOwn(rootDefs, key)) {
      return flattenToolSchema(rootDefs[key], rootDefs, depth + 1)
    }
  }
  const out = {}
  for (const [k, v] of Object.entries(schema)) {
    if (k === '$defs' || k === 'definitions' || k === '$schema' || k === '$ref') continue
    if (k === 'const') {
      out.enum = [v]
      continue
    }
    if ((k === 'anyOf' || k === 'oneOf' || k === 'allOf') && Array.isArray(v)) {
      const nonNull = v.filter((item) => item && item.type !== 'null')
      if (nonNull.length === 1) {
        Object.assign(out, flattenToolSchema(nonNull[0], rootDefs, depth + 1))
        continue
      }
      out[k] = v.map((item) => flattenToolSchema(item, rootDefs, depth + 1))
      continue
    }
    if (k === 'properties' && v && typeof v === 'object' && !Array.isArray(v)) {
      const props = {}
      for (const [pk, pv] of Object.entries(v)) {
        props[pk] = flattenToolSchema(pv, rootDefs, depth + 1)
      }
      out.properties = props
      continue
    }
    if (k === 'items' && v && typeof v === 'object') {
      out.items = flattenToolSchema(v, rootDefs, depth + 1)
      continue
    }
    out[k] = v
  }
  return out
}

function eventMessages(events, botId) {
  const messages = []
  for (const event of events) {
    if (event.type === 'user/message') {
      const sourceKind = event.data?.source?.kind
      if (sourceKind === 'model-selection' || sourceKind === 'tool-jobs') continue
      if (sourceKind === 'compaction') {
        messages.push({
          id: event.data?.id ?? `compact-${event.seq}`,
          sessionId: botId,
          role: 'assistant',
          content: '📦 **上下文已压缩检查点**\n\n历史对话已由 DSH 自动压缩以节省上下文窗口。',
          reasoning: '',
          timestamp: event.time,
          sequence: event.seq,
        })
        continue
      }
      if (!sourceKind || sourceKind === 'user' || sourceKind === 'schedule') {
        const raw = messageText(event.data.content)
        const content = sourceKind === 'schedule' && raw ? `⏰ [定时任务] ${raw}` : raw
        if (content) messages.push({ id: event.data.id, sessionId: botId, role: 'user', content, reasoning: '', timestamp: event.time, sequence: event.seq })
      }
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
  const uncachedInput = Math.max(0, input)
  return {
    inputTokens: input,
    uncachedInputTokens: uncachedInput,
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
  return { calls: 0, inputTokens: 0, uncachedInputTokens: 0, cacheReadTokens: 0, cacheWriteTokens: 0, outputTokens: 0, totalTokens: 0 }
}

function addUsageTotals(totals, usage) {
  const add = (left, right) => left > Number.MAX_SAFE_INTEGER - right ? Number.MAX_SAFE_INTEGER : left + right
  totals.calls = add(totals.calls, 1)
  totals.inputTokens = add(totals.inputTokens, usage.inputTokens)
  totals.uncachedInputTokens = add(totals.uncachedInputTokens, usage.uncachedInputTokens ?? usage.inputTokens)
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
    const sessionId = String(snapshot.header.id)
    const botId = ownerBotId(snapshot) ?? (sessionId.startsWith('session-') ? 'web-workbench' : undefined)
    if (!botId) continue
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

function isValidSessionKey(value) {
  if (typeof value !== 'string' || value.length === 0 || value.length > 161) return false
  const parts = value.split(':')
  if (parts.length === 1) return /^[A-Za-z0-9_-]{1,80}$/.test(parts[0])
  if (parts.length === 2) return /^[A-Za-z0-9_-]{1,80}$/.test(parts[0]) && /^[A-Za-z0-9_-]{1,80}$/.test(parts[1])
  return false
}
function rootBotIdOf(value) {
  return typeof value === 'string' ? value.split(':')[0] : ''
}
function isPrivateBotOrThread(sessionKey) {
  return runtime.privateBotIds.has(rootBotIdOf(sessionKey))
}
function inferCustomModelCapabilities(id) {
  const lower = String(id || '').toLowerCase()
  const isVision = /(?:vl|vision|4o|claude|gemini|glm-4v|glm-5|deepseek-v4|gpt-5|qwen2\.5-vl|llava|pixtral)/i.test(lower)
  const isFlagship = /(?:v4|pro|reasoner|r1|thinking|claude|gpt-5|gpt-4|glm-5|o1|o3|qwq)/i.test(lower)
  return {
    id,
    name: id,
    maxTokens: isFlagship ? 16384 : 8192,
    inputModalities: isVision ? ['text', 'image'] : ['text'],
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
  'browser_open', 'browser_snapshot', 'browser_click', 'browser_type', 'browser_select', 'browser_press_key', 'browser_scroll', 'browser_screenshot',
  'browser_back', 'browser_wait', 'browser_eval', 'browser_handoff',
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

function redteamToolFlags(name) {
  const isKnownRead = REDTEAM_READ_TOOL_NAMES.has(name)
  const isKnownWrite = REDTEAM_WRITE_TOOL_NAMES.has(name)
  const isKnownSensitive = REDTEAM_SENSITIVE_TOOL_NAMES.has(name)
  if (isKnownRead || isKnownWrite || isKnownSensitive) {
    return {
      known: true,
      read: isKnownRead && !isKnownWrite && !isKnownSensitive,
      write: isKnownWrite,
      sensitive: isKnownSensitive,
    }
  }
  // Future-proof heuristic fallback for newly added dsh-purge-safe `redteam_*` tools:
  // keeps strict read/write/sensitive/3-tier governance without hard-breaking on plugin upgrades.
  if (typeof name !== 'string' || !/^redteam_[a-z0-9_]{2,64}$/.test(name)) {
    return { known: false, read: false, write: false, sensitive: false }
  }
  const sensitive = /(?:credential|access|session|webshell|tunnel|poc|pivot|cleanup|proof|proxy|attack_file|agent_slot|template_refresh)/.test(name)
  const readOnlySuffix = /(?:_list|_get|_query|_search|_stats|_status|_info|_graph|_report|_timeline|_index|_check|_catalog|_digest|_targets|_next|_action|_path|_chain|_roles|_prompt)$/.test(name)
  const writeVerb = /(?:_add|_update|_delete|_remove|_save|_set|_open|_bind|_reset|_create|_edit|_run|_use|_probe|_hit|_assess|_batch|_import|_refresh|_sync|_ack)/.test(name)
  const write = writeVerb || (sensitive && !readOnlySuffix)
  const read = !write && !sensitive && readOnlySuffix
  if (!read && !write && !sensitive) {
    // Unknown verb defaults conservatively to write so it cannot bypass readOnly or ask approval
    return { known: true, read: false, write: true, sensitive: false }
  }
  return { known: true, read, write, sensitive }
}

function redteamToolDenial(policy, name) {
  const flags = redteamToolFlags(name)
  if (!flags.known) return `iOS 未审核红队工具 ${name}，默认拒绝。`
  if (!policy.enabled || !runtime.redteamToolsEnabled) return '红队工具宿主或本 Bot 授权已关闭。'
  if (policy.botId && isPrivateBotOrThread(policy.botId)) return '私密会话禁止调用 dsh-purge-safe 工具。'
  if (flags.sensitive && policy.permissionMode === 'readOnly') {
    return '只读保护模式禁止调用红队敏感工具。'
  }
  if (flags.sensitive && !policy.sensitive) return `本 Bot 未获准访问敏感红队数据：${name}。`
  if (flags.write && (!policy.write || policy.permissionMode === 'readOnly')) {
    if (policy.permissionMode === 'readOnly') return '只读保护模式禁止修改红队演练数据。'
    return flags.sensitive
      ? '敏感数据写入需要同时授予演练台写入权限。'
      : `本 Bot 未获准写入红队演练数据：${name}。`
  }
  return undefined
}

function redteamToolNeedsApproval(policy, name) {
  const flags = redteamToolFlags(name)
  // Three-tier alignment: readOnly is blocked above; ask prompts on write/sensitive;
  // autoReview (沙盒免打扰) auto-allows explicitly authorized redteam tools.
  return policy.permissionMode === 'ask' && (flags.write || flags.sensitive)
}

function redteamApprovalKey(sessionId, callId) {
  return `${String(sessionId ?? '')}:${String(callId ?? '')}`
}

function resolveRedteamPolicyForAgent(agent) {
  const sessionId = String(agent?.session?.id ?? '')
  if (!sessionId) return undefined
  const direct = runtime.redteamTurnPolicies.get(sessionId)
  if (direct) return direct
  // Walk parentSession chain (depth <= 8) so authorized RedTeam Subagents inherit parent policy
  try {
    const sessionsSvc = ctx?.get?.('sessions')
    const allRows = typeof sessionsSvc?.list === 'function' ? sessionsSvc.list() : []
    const byId = new Map(allRows.map((row) => [String(row?.id ?? row?.header?.id ?? ''), row]))
    let cursor = String(agent?.session?.header?.parentSession ?? byId.get(sessionId)?.header?.parentSession ?? '')
    const visited = new Set([sessionId])
    for (let depth = 0; cursor && depth < 8 && !visited.has(cursor); depth += 1) {
      visited.add(cursor)
      const inherited = runtime.redteamTurnPolicies.get(cursor)
      if (inherited) {
        return { ...inherited, inheritedFrom: cursor }
      }
      cursor = String(byId.get(cursor)?.header?.parentSession ?? '')
    }
  } catch { /* fall through */ }
  // Non-native Web UI session: honor explicit iOS Web RedTeam permissions
  if (!sessionId.startsWith('ios:') && runtime.redteamToolsEnabled && runtime.redteamWebPermissions.read) {
    return {
      botId: '',
      enabled: true,
      write: runtime.redteamWebPermissions.write === true,
      sensitive: runtime.redteamWebPermissions.sensitive === true,
      permissionMode: 'ask',
      isWeb: true,
    }
  }
  return undefined
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

function setupAgent({ botId, systemPrompt, pinnedMemories = '', legacyHistory, agentPreset, toolsEnabled, subagentEnabled, webSearchEnabled,
  redteamMode = false, redteamWriteEnabled = false, redteamSensitiveDataEnabled = false, permissionMode = 'ask' }) {
  const id = dshSessionId(botId)
  let setPersona = () => {}
  let setToolsEnabled = () => {}
  let redteamPolicy = { botId, enabled: false, write: false, sensitive: false, permissionMode: 'ask' }
  const setup = async (agentCtx) => {
    agentCtx.__dsbotToolsMounted = true
    installModelSelection(agentCtx)
    if (agentPreset !== 'minimal') {
      if (agentPreset !== 'ptc-python') mountIOSPythonTool(agentCtx)
      if (agentPreset === 'standard' || agentPreset === 'cordis' || agentPreset === 'redteam') mountIOSPythonJobTool(agentCtx)
      mountIOSScheduleTools(agentCtx)
    }
    await ctx.agentPresets.mount(agentCtx, agentPreset)
    let personaDisposer
    let pinnedMemoriesDisposer
    let rulesDisposer
    let reasoningDisposer
    let redteamPromptDisposer
    let toolRestriction
    let toolGuard
    let redteamPreExecuteDisposer
    let lastToolsPolicyKey = ''
    let lastRulesHash = ''
    let lastReasoningEffort = ''

    const refreshWorkspaceRules = () => {
      const isPrivate = isPrivateBotOrThread(botId)
      if (isPrivate) {
        rulesDisposer?.()
        rulesDisposer = undefined
        lastRulesHash = ''
        return
      }
      const chunks = []
      for (const candidate of [join(WORKSPACE, 'files', 'AGENTS.md'), join(WORKSPACE, 'files', 'CLAUDE.md')]) {
        try {
          if (existsSync(candidate)) {
            const raw = readFileSync(candidate, 'utf8').trim()
            if (raw) {
              chunks.push(`工作区规则（${candidate.endsWith('CLAUDE.md') ? 'files/CLAUDE.md' : 'files/AGENTS.md'}）：\n${raw.slice(0, 4096)}`)
              break
            }
          }
        } catch {}
      }
      try {
        syncLegacySkillsToWorkspaceFiles()
        const skillsDir = join(WORKSPACE_FILES, 'skills')
        if (existsSync(skillsDir)) {
          const entries = readdirSync(skillsDir, { withFileTypes: true }).slice(0, 20)
          const names = []
          for (const entry of entries) {
            if (entry.name.startsWith('.')) continue
            if (entry.isDirectory() && existsSync(join(skillsDir, entry.name, 'SKILL.md'))) {
              names.push(entry.name)
            } else if (entry.isFile() && entry.name.endsWith('.md')) {
              names.push(entry.name.replace(/\.md$/i, ''))
            }
          }
          if (names.length > 0) {
            chunks.push(`工作区可用用户 Skills（位于 skills/<名称>/SKILL.md）：${names.join(', ')}。当用户提及相关技能时可读取对应 skills/<名称>/SKILL.md 遵循其流程。`)
          }
        }
      } catch {}
      const combined = chunks.join('\n\n')
      if (combined === lastRulesHash) return
      lastRulesHash = combined
      rulesDisposer?.()
      rulesDisposer = undefined
      if (combined) {
        rulesDisposer = agentCtx.systemPrompt.section({ name: 'dsbot-ios-workspace-rules', order: 860, text: combined })
      }
    }

    const setReasoningEffort = (effort) => {
      const normalized = ['low', 'medium', 'high'].includes(effort) ? effort : 'medium'
      if (normalized === lastReasoningEffort) return
      lastReasoningEffort = normalized
      reasoningDisposer?.()
      reasoningDisposer = undefined
      if (normalized === 'low') {
        reasoningDisposer = agentCtx.systemPrompt.section({
          name: 'dsbot-ios-reasoning-effort',
          order: 870,
          text: '推理等级：低（快速模式）。请保持思考精炼，直接给出清晰结论与可执行步骤。',
        })
      } else if (normalized === 'high') {
        reasoningDisposer = agentCtx.systemPrompt.section({
          name: 'dsbot-ios-reasoning-effort',
          order: 870,
          text: '推理等级：高（深度模式）。请在回答与工具调用前充分推演边界条件、依赖与潜在风险，确保方案严谨完整。',
        })
      }
    }

    setPersona = (value, memories = undefined) => {
      personaDisposer?.()
      personaDisposer = undefined
      if (typeof value === 'string' && value.trim()) {
        personaDisposer = agentCtx.systemPrompt.section({ name: 'dsbot-ios-persona', order: 900, text: value.trim() })
      }
      if (memories !== undefined) {
        pinnedMemoriesDisposer?.()
        pinnedMemoriesDisposer = undefined
        if (!isPrivateBotOrThread(botId) && typeof memories === 'string' && memories.trim()) {
          pinnedMemoriesDisposer = agentCtx.systemPrompt.section({
            name: 'dsbot-ios-pinned-memories',
            order: 880,
            text: `用户常驻记忆：\n${memories.trim()}`,
          })
        }
      }
    }
    setPersona(systemPrompt, pinnedMemories)
    refreshWorkspaceRules()
    let groupContextDisposer
    let lastGroupContext = ''
    setToolsEnabled = (enabled, allowSubagent, allowWebSearch, allowRedteam = false,
      allowRedteamWrites = false, allowRedteamSensitive = false, redteamPermissionMode = 'ask',
      reasoningEffort = 'medium', disabledTools = [], isGroupSession = false, groupContextText = '') => {
      refreshWorkspaceRules()
      setReasoningEffort(reasoningEffort)
      const normalizedGroupContext = isGroupSession && typeof groupContextText === 'string' ? groupContextText.trim().slice(0, 6_000) : ''
      if (normalizedGroupContext !== lastGroupContext) {
        lastGroupContext = normalizedGroupContext
        groupContextDisposer?.()
        groupContextDisposer = undefined
        if (normalizedGroupContext) {
          groupContextDisposer = agentCtx.systemPrompt.section({
            name: 'dsbot-ios-group-context',
            order: 858,
            text: normalizedGroupContext,
          })
        }
      }
      const normalizedPermissionMode = ['ask', 'autoReview', 'readOnly'].includes(redteamPermissionMode) ? redteamPermissionMode : 'ask'
      const normalizedDisabledTools = Array.isArray(disabledTools) ? [...new Set(disabledTools.map(String).filter(Boolean))].sort() : []
      const rtTools = registeredRedteamToolNames()
      const policyKey = JSON.stringify({
        enabled,
        allowSubagent,
        allowWebSearch,
        allowRedteam,
        allowRedteamWrites,
        allowRedteamSensitive,
        normalizedPermissionMode,
        rtTools,
        normalizedDisabledTools,
        isGroupSession,
      })
      // Keep system prompt prefix and Cordis guards untouched across identical turns to maximize Prompt Cache hits
      if (policyKey === lastToolsPolicyKey) {
        return
      }
      lastToolsPolicyKey = policyKey

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
        permissionMode: normalizedPermissionMode,
      }
      const globalToolDefs = ctx.tools.definitions()
      const globalToolNames = new Set(globalToolDefs.map((tool) => tool.name))
      const thirdPartyTools = enabled
        ? globalToolDefs
            .filter((tool) => tool?.name && !DISABLED_TOOL_NAMES.has(tool.name) && tool.name !== 'subagent' && !tool.name.startsWith('redteam_'))
            .map((tool) => ({
              name: String(tool.name),
              description: String(tool.description ?? '').replace(/\s+/g, ' ').trim().slice(0, 120),
            }))
        : []
      const deny = enabled ? [...normalizedDisabledTools] : [...DISABLED_TOOL_NAMES].filter((name) => globalToolNames.has(name))
      if (!isGroupSession && !deny.includes('group_todo_add')) deny.push('group_todo_add')
      if (agentPreset === 'minimal') {
        for (const restricted of ['workspace_write', 'workspace_edit', 'terminal_exec', 'git_workspace', 'js_eval', 'python_exec', 'python_job_start']) {
          if (globalToolNames.has(restricted) && !deny.includes(restricted)) deny.push(restricted)
        }
      }
      if (!allowSubagent || !enabled) deny.push('subagent')
      if (enabled && !allowWebSearch) deny.push('web_search')
      if (!allowRedteam || !enabled) {
        deny.push(...rtTools)
      } else {
        for (const name of rtTools) {
          if (redteamToolDenial(redteamPolicy, name)) deny.push(name)
        }
      }
      const allowedRedteamTools = rtTools.filter((name) => !redteamToolDenial(redteamPolicy, name))
      const promptParts = []
      if (enabled && !isPrivateBotOrThread(botId)) {
        promptParts.push('App 内置浏览器可用：需要交互浏览网页、点击、填表、下拉选择、等待动态渲染或截图识图时，可直接调用 browser_open / browser_snapshot / browser_click / browser_type / browser_select / browser_press_key / browser_wait / browser_eval / browser_screenshot；遇到登录、2FA 或人机验证时必须立即调用 browser_handoff 请用户在内置浏览器中手动接管。')
      }
      if (thirdPartyTools.length > 0) {
        const listed = thirdPartyTools.slice(0, 24).map((t) => t.description ? `- ${t.name}: ${t.description}` : `- ${t.name}`).join('\n')
        promptParts.push(`当前已加载 ${thirdPartyTools.length} 个第三方插件工具，可在相关任务中直接调用：\n${listed}`)
      }
      if (allowedRedteamTools.length > 0) {
        promptParts.push(`dsh-purge-safe 红队演练工具已获本 Bot 授权。只允许在用户明确授权的演练范围内查询与记录；不得自行扩大范围。当前可用工具（${allowedRedteamTools.length} 项）：${allowedRedteamTools.join(', ')}。`)
      }
      if (promptParts.length > 0) {
        redteamPromptDisposer = agentCtx.systemPrompt.section({
          name: 'dsbot-ios-plugin-tools',
          order: 850,
          text: promptParts.join('\n\n'),
        })
      }
      if (deny.length) toolRestriction = agentCtx.tools.restrict({ deny })
      toolGuard = agentCtx.tools.guard((execution) => {
        if (execution.name === 'subagent') {
          const activeTurn = runtime.activeTurns.get(id)
          if (activeTurn?.isGroup) {
            activeTurn.groupHandoffCount = (activeTurn.groupHandoffCount ?? 0) + 1
            if (activeTurn.groupHandoffCount > 12) {
              return { reason: '群聊协作已达到单轮最大交接上限（12 次），已安全停止以防止无限循环。' }
            }
          }
        }
        if (String(execution.name ?? '').startsWith('redteam_')) {
          const denial = redteamToolDenial(redteamPolicy, execution.name)
          if (denial) return { reason: denial }
        }
        if (normalizedPermissionMode === 'readOnly'
          && !DISABLED_TOOL_NAMES.has(execution.name)
          && execution.name !== 'subagent'
          && !String(execution.name ?? '').startsWith('redteam_')
          && /(?:write|edit|delete|remove|create|update|set|exec|run|patch|send|post|push)/i.test(String(execution.name ?? ''))) {
          return { reason: `当前处于只读保护模式，已拦截写入/执行类第三方插件工具 ${execution.name}。` }
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
    let pendingContent = ''
    let pendingReasoning = ''
    let pendingTurnId = ''
    let deltaFlushTimer = null
    function flushPendingDeltas() {
      if (deltaFlushTimer) {
        clearTimeout(deltaFlushTimer)
        deltaFlushTimer = null
      }
      if (!pendingContent && !pendingReasoning) return
      const active = runtime.activeTurns.get(id)
      const content = pendingContent
      const reasoning = pendingReasoning
      const turnIdForFlush = pendingTurnId || active?.turnId || ''
      pendingContent = ''
      pendingReasoning = ''
      pendingTurnId = ''
      if (!turnIdForFlush || !active || active.done) return
      rpc.notify('chat.delta', { sessionId: botId, turnId: turnIdForFlush, content, reasoning })
    }
    agentCtx.on('agent/assistant-stream', ({ frame }) => {
      if (frame?.type !== 'chunk') return
      const active = runtime.activeTurns.get(id)
      if (!active || active.done) return
      active.flushDelta = flushPendingDeltas
      const chunk = frame.chunk
      if (chunk.type === 'text-delta' && chunk.text) {
        pendingTurnId = active.turnId
        pendingContent += chunk.text
      } else if (chunk.type === 'reasoning-delta' && chunk.text) {
        pendingTurnId = active.turnId
        pendingReasoning += chunk.text
      } else {
        return
      }
      if (pendingContent.length + pendingReasoning.length >= 512) {
        flushPendingDeltas()
      } else if (!deltaFlushTimer) {
        deltaFlushTimer = setTimeout(flushPendingDeltas, 24)
      }
    })
    const toolNamesByCall = new Map()
    const toolStartedAtByCall = new Map()
    const approvalToolsById = new Map()
    agentCtx.on('session/event', (session, event) => {
      if (session?.id !== id) return
      const active = runtime.activeTurns.get(id)
      if (!active || active.done) return
      if (event?.type === 'tool/call' || event?.type === 'approval/asked' || event?.type === 'turn/end') {
        flushPendingDeltas()
      }
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
        toolStartedAtByCall.set(callId, Number.isSafeInteger(event.time) ? event.time : Date.now())
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
      const startedAt = toolStartedAtByCall.get(callId)
      const finishedAt = Number.isSafeInteger(event.time) ? event.time : Date.now()
      const durationMs = typeof startedAt === 'number' ? Math.max(0, finishedAt - startedAt) : undefined
      toolNamesByCall.delete(callId)
      toolStartedAtByCall.delete(callId)
      rpc.notify('dsh.tool.event', {
        sessionId: botId, turnId: active.turnId, callId, toolName,
        phase: event.data?.error || message?.isError ? 'failed' : 'completed',
        result: toolResultText(message, event.data?.error),
        timestamp: event.time, sequence: event.seq,
        ...(durationMs !== undefined ? { durationMs } : {}),
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
      allowRedteamWrites = false, allowRedteamSensitive = false, redteamPermissionMode = 'ask',
      reasoningEffort = 'medium', disabledTools = []) =>
      setToolsEnabled(enabled, allowSubagent, allowWebSearch, allowRedteam,
        allowRedteamWrites, allowRedteamSensitive, redteamPermissionMode, reasoningEffort, disabledTools),
    id,
  }
}

async function boot() {
  runtime.providerBaseURL = routeForApiBase(runtime.apiBaseURL)
  process.env.DS_BOT_PROVIDER_BASE_URL = runtime.providerBaseURL
  installCustomEndpointCompatFetch({
    getProviderBaseURL: () => runtime.providerBaseURL,
    isOfficialBase: (base) => {
      try { return isOfficialDeepSeekBase(base) } catch { return false }
    },
  })
  initProfile(PROFILE_DIR, [PROFILE_BUNDLE])
  if (workerData?.safeMode || workerData?.recoveringRevision) await settlePluginRevision(PROFILE_DIR, true)
  const safeMode = workerData?.safeMode === true
  const compatibilityPatch = await preparePurgeSafeIOSOverlay(!safeMode)
  const userConfigPatch = prepareUserPluginConfigsOverlay(!safeMode)
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
    patchFiles: [compatibilityPatch, userConfigPatch],
    args: [],
  })
  ctx = application.ctx
  ctx.on('tools/pre-execute', async (execution, next) => {
    const name = String(execution?.name ?? '')
    if (!name.startsWith('redteam_')) return typeof next === 'function' ? next() : { kind: 'allow' }
    const downstream = typeof next === 'function' ? await next() : { kind: 'allow' }
    if (downstream?.kind && downstream.kind !== 'allow') return downstream
    const policy = resolveRedteamPolicyForAgent(execution.agent)
    if (!policy) return { kind: 'deny', reason: '当前会话尚未获得 dsh-purge-safe 红队工具授权。' }
    const denial = redteamToolDenial(policy, name)
    if (denial) return { kind: 'deny', reason: denial }
    if (policy.isWeb && redteamToolNeedsApproval(policy, name)) {
      if (!execution?.callId) return { kind: 'deny', reason: '红队工具调用缺少审批关联编号，已拒绝执行。' }
      return {
        kind: 'ask',
        reason: `dsh-purge-safe 工具 ${name} 需要当前 Web 会话用户审批。`,
        displayReason: { en: `Approve dsh-purge-safe tool ${name} for this session?`, zh: `允许当前会话调用红队工具 ${name}？` },
      }
    }
    return downstream ?? { kind: 'allow' }
  }, { global: true })
  ctx.tools.guard((execution) => {
    const name = String(execution?.name ?? '')
    if (!name.startsWith('redteam_')) return undefined
    const sessionId = String(execution.agent?.session?.id ?? '')
    const policy = resolveRedteamPolicyForAgent(execution.agent)
    if (!policy) return { reason: '当前会话尚未获得 dsh-purge-safe 红队工具授权。' }
    const denial = redteamToolDenial(policy, name)
    if (denial) return { reason: denial }
    if (redteamToolNeedsApproval(policy, name)) {
      const key = redteamApprovalKey(sessionId, execution.callId)
      const parentKey = policy.inheritedFrom ? redteamApprovalKey(policy.inheritedFrom, execution.callId) : ''
      const approved = runtime.redteamApprovalGrants.get(key) === true
        || (parentKey && runtime.redteamApprovalGrants.get(parentKey) === true)
      runtime.redteamApprovalGrants.delete(key)
      if (parentKey) runtime.redteamApprovalGrants.delete(parentKey)
      if (!approved) return { reason: '此红队工具调用没有通过会话审批，已拒绝执行。' }
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
  runtime.defaultModelFiber = mountedRows.get('agent-default-model')
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
  try {
    const IOS_CONTAINER_WS_RE = /^(\/private)?\/var\/mobile\/Containers\/Data\/Application\/[^/]+\/Documents\/dsh-home\/files(\/.*)?$/
    const wsRegistry = ctx?.get?.('workspaceRegistry')
    const wsController = ctx?.get?.('workspaceController')
    const filterVisibleWorkspaceSessions = (sessionIds = []) => {
      if (!Array.isArray(sessionIds)) return []
      return sessionIds.filter((sid) => {
        if (typeof sid !== 'string' || !sid) return false
        if (sid.startsWith('ios:') && isPrivateBotOrThread(botIdFromSession(sid))) return false
        return true
      })
    }
    if (wsRegistry && typeof wsRegistry.list === 'function') {
      const existingList = wsRegistry.list()
      const staleWorkspaces = []
      for (const ws of existingList) {
        const wsPath = String(ws?.path ?? '')
        if (!wsPath || wsPath === WORKSPACE_FILES) continue
        let isMissing = false
        try {
          if (typeof ws.status === 'function') {
            isMissing = (await ws.status()) === 'missing-dir'
          }
        } catch {}
        if (IOS_CONTAINER_WS_RE.test(wsPath) && (isMissing || !existsSync(wsPath))) {
          staleWorkspaces.push(ws)
        }
      }
      if (staleWorkspaces.length > 0 && typeof wsRegistry.create === 'function') {
        let currentWs = wsRegistry.list().find((ws) => ws.path === WORKSPACE_FILES)
        if (!currentWs) {
          const created = await wsRegistry.create(WORKSPACE_FILES)
          currentWs = created?.workspace ?? created
        }
        if (currentWs) {
          for (const stale of staleWorkspaces) {
            const ids = Array.isArray(stale.sessionIds) ? stale.sessionIds : []
            for (const sid of ids) {
              if (typeof currentWs.attachSession === 'function') {
                await currentWs.attachSession(sid).catch(() => {})
              }
            }
            const staleId = stale.id ?? stale.workspaceId
            if (staleId && typeof wsRegistry.delete === 'function') {
              await wsRegistry.delete(staleId).catch(() => {})
            }
          }
          ctx?.logger?.info?.(`Migrated ${staleWorkspaces.length} stale iOS container workspace(s) to ${WORKSPACE_FILES}`)
        }
      }
    }
    if (wsController && wsRegistry && !wsController.__dsbotDefaultWorkspacePatched) {
      wsController.initializeDefault = async function iosInitializeDefaultWorkspace() {
        let workspace = await wsRegistry.initializeDefault(async () => WORKSPACE_FILES)
        if (!workspace && wsRegistry.list().length === 0 && typeof wsRegistry.create === 'function') {
          const created = await wsRegistry.create(WORKSPACE_FILES)
          workspace = created?.workspace ?? created
        }
        workspace ??= wsRegistry.list().find((ws) => ws.path === WORKSPACE_FILES) ?? wsRegistry.list()[0]
        if (!workspace) return undefined
        return {
          workspace: {
            workspaceId: workspace.id ?? workspace.workspaceId,
            path: workspace.path,
            title: workspace.title,
            sessionIds: filterVisibleWorkspaceSessions(workspace.sessionIds ?? []),
            createdAt: workspace.createdAt,
            updatedAt: workspace.updatedAt,
          },
        }
      }
      wsController.__dsbotDefaultWorkspacePatched = true
    }
    if (wsRegistry && typeof wsRegistry.list === 'function' && wsRegistry.list().length === 0) {
      if (typeof wsRegistry.initializeDefault === 'function') {
        await wsRegistry.initializeDefault(async () => WORKSPACE_FILES)
      }
      // initializeDefault() intentionally no-ops when native Bot sessions already exist in SQLite;
      // explicitly register WORKSPACE_FILES so the Web UI always has a ready default workspace.
      if (wsRegistry.list().length === 0 && typeof wsRegistry.create === 'function') {
        await wsRegistry.create(WORKSPACE_FILES)
      }
    }
    // Anchor unscoped Web session creation (`session/create` without workspaceId/cwd) inside WORKSPACE_FILES
    // and report desktop native file openers as unavailable on iOS.
    const sessionController = ctx?.get?.('sessionController')
    if (sessionController) {
      if (sessionController.commands) {
        sessionController.commands.defaultCwd = WORKSPACE_FILES
      }
      sessionController.canOpenPath = () => false
    }
  } catch (error) {
    ctx?.logger?.warn?.(`Default iOS workspace initialization skipped: ${String(error)}`)
  }
  // Track every live AgentHandle (Native, Web ApiSessionAgentController, Subagent) in one coordinator map
  // so cross-surface handoff and background suspend cleanly dispose agents without leaving zombie sessions.
  try {
    const agentsSvc = ctx?.get?.('agents')
    if (agentsSvc && !agentsSvc.__dsbotHandleTrackerInstalled) {
      const origCreate = typeof agentsSvc.create === 'function' ? agentsSvc.create.bind(agentsSvc) : undefined
      const origResume = typeof agentsSvc.resume === 'function' ? agentsSvc.resume.bind(agentsSvc) : undefined
      if (origCreate) {
        agentsSvc.create = async function iosTrackedCreate(options) {
          const handle = await origCreate(options)
          if (handle?.agent?.id) runtime.allAgentHandles.set(handle.agent.id, handle)
          return handle
        }
      }
      if (origResume) {
        agentsSvc.resume = async function iosTrackedResume(options) {
          const handle = await origResume(options)
          if (handle?.agent?.id) runtime.allAgentHandles.set(handle.agent.id, handle)
          return handle
        }
      }
      agentsSvc.__dsbotHandleTrackerInstalled = true
    }
    ctx.on('agent/disposed', ({ agent } = {}) => {
      const id = agent?.id ?? agent?.session?.id
      if (typeof id === 'string' && id) {
        const tracked = runtime.allAgentHandles.get(id)
        if (!tracked || tracked.agent === agent) runtime.allAgentHandles.delete(id)
      }
    }, { global: true })
  } catch (error) {
    ctx?.logger?.warn?.(`Unified AgentHandle tracker install skipped: ${String(error)}`)
  }
  // Push lightweight revision change notifications to Swift whenever an ios:* session is mutated
  // outside an active Native chat.send turn (e.g. from Web Workbench, schedule, or background jobs).
  const SESSION_CHANGE_EVENT_TYPES = new Set(['user/message', 'assistant/message', 'turn/end', 'compaction/end', 'session/title'])
  ctx.on('session/event', (event) => {
    const sid = String(event?.sessionId ?? event?.session?.id ?? '')
    if (!sid.startsWith('ios:') || !SESSION_CHANGE_EVENT_TYPES.has(event?.type)) return
    if (runtime.activeTurns.has(sid)) return
    const botSessionId = botIdFromSession(sid)
    if (isPrivateBotOrThread(botSessionId)) return
    rpc.notify('session.changed', {
      sessionId: botSessionId,
      dshSessionId: sid,
      eventType: event.type,
      seq: Number.isSafeInteger(event.seq) ? event.seq : undefined,
      time: Number.isSafeInteger(event.time) ? event.time : Date.now(),
    })
  }, { global: true })
  if (!safeMode && redteamStatus().installed) {
    await ensureRedteamPresetRegistered()
  }
  // Redirect Web UI Settings configEditor writes away from the read-only iOS .app bundle
  // into $DSH_HOME/web-config-overrides.json with fast in-memory fiber.update() hot-apply.
  try {
    const configEditorSvc = ctx?.get?.('configEditor')
    const overridesPath = join(WORKSPACE, 'web-config-overrides.json')
    const loadOverrides = () => {
      try {
        if (!existsSync(overridesPath)) return {}
        const parsed = JSON.parse(readFileSync(overridesPath, 'utf8'))
        return parsed && typeof parsed === 'object' && !Array.isArray(parsed) ? parsed : {}
      } catch { return {} }
    }
    const savedOverrides = loadOverrides()
    for (const [rowId, cfg] of Object.entries(savedOverrides)) {
      if (rowId === 'llm-deepseek' || !cfg || typeof cfg !== 'object') continue
      const fiber = mountedRows.get(rowId)
      if (fiber && fiber.state === 2) {
        try { await fiber.update(cfg) } catch {}
      }
    }
    if (configEditorSvc && typeof configEditorSvc.edit === 'function' && !configEditorSvc.__dsbotWritableSandboxPatched) {
      configEditorSvc.edit = async function iosSandboxConfigEdit(entry, change) {
        const fiber = entry?.fiber
        if (!fiber || fiber.state !== 2) throw new Error('Configuration plugin is no longer active')
        const current = structuredClone(entry.options?.config ?? {})
        const next = change(current, current)
        fiber.resolveConfig(next)
        await fiber.update(next)
        const entryId = entry?.options?.id
        if (typeof entryId === 'string' && entryId) {
          const all = loadOverrides()
          all[entryId] = next
          try {
            writeFileSync(overridesPath, JSON.stringify(all, null, 2), 'utf8')
          } catch {}
        }
      }
      configEditorSvc.__dsbotWritableSandboxPatched = true
    }
  } catch (error) {
    ctx?.logger?.warn?.(`Writable configEditor sandbox override skipped: ${String(error)}`)
  }
  try {
    const wsFiles = ctx?.get?.('workspaceFiles')
    if (wsFiles && typeof wsFiles.search === 'function') {
      const VCS_NAMES = new Set(['.git', '.svn', '.hg', '.bzr', '.jj', '.sl', 'node_modules'])
      wsFiles.search = async function iosPureJsWorkspaceFileSearch(workspaceFileScope, request, signal) {
        const query = String(request?.query ?? '').trim()
        if (!query) throw new Error('query must not be blank')
        signal?.throwIfAborted?.()
        let root = WORKSPACE_FILES
        try {
          const resolvedRoot = await ctx.fs.resolve(workspaceFileScope?.workspaceRoot || WORKSPACE_FILES, { signal })
          root = ctx.fs.processPath(resolvedRoot)
        } catch {
          root = WORKSPACE_FILES
        }
        const maxResults = Number.isInteger(request?.maxResults) && request.maxResults > 0 ? Math.min(request.maxResults, 500) : 200
        const maxEntries = 10_000
        const includeHidden = request?.includeHidden === true
        const excludedRaw = Array.isArray(request?.excludedPaths) ? request.excludedPaths.filter((p) => typeof p === 'string' && p.length > 0) : []
        const excludedNames = new Set(excludedRaw.filter((p) => !p.includes('/')))
        const excludedRelPaths = new Set(excludedRaw.filter((p) => p.includes('/')).map((p) => p.replace(/^\/+|\/+$/g, '')))
        const needle = query.toLowerCase()
        const byPath = query.includes('/')
        const entries = new Map()
        const admit = (relPath, type) => {
          const name = relPath.slice(relPath.lastIndexOf('/') + 1)
          if ((byPath ? relPath : name).toLowerCase().includes(needle)) {
            entries.set(relPath, { path: relPath, type })
          }
        }
        let scanned = 0
        let incomplete = false
        const queue = ['']
        while (queue.length > 0 && scanned < maxEntries) {
          signal?.throwIfAborted?.()
          const relDir = queue.shift()
          const absDir = relDir ? join(root, relDir) : root
          let dirents
          try {
            dirents = await readdir(absDir, { withFileTypes: true })
          } catch {
            incomplete = true
            continue
          }
          for (const dirent of dirents) {
            if (scanned >= maxEntries) {
              incomplete = true
              break
            }
            const name = dirent.name
            if (name === '.dsbot-ios-workspace-root' || name === '.DS_Store') continue
            if (VCS_NAMES.has(name) || excludedNames.has(name) || dirent.isSymbolicLink()) continue
            if (!includeHidden && name.startsWith('.')) continue
            const relPath = relDir ? `${relDir}/${name}` : name
            if (excludedRelPaths.has(relPath)) continue
            if (dirent.isDirectory()) {
              admit(relPath, 'directory')
              queue.push(relPath)
            } else if (dirent.isFile()) {
              admit(relPath, 'file')
              scanned += 1
            }
          }
        }
        const matches = [...entries.values()].sort((a, b) =>
          a.path.split('/').length - b.path.split('/').length || (a.path < b.path ? -1 : 1)
        )
        return {
          matches: matches.slice(0, maxResults),
          truncated: matches.length > maxResults,
          incomplete,
        }
      }
    }
  } catch (error) {
    ctx?.logger?.warn?.(`Pure-JS workspaceFiles.search patch skipped: ${String(error)}`)
  }
  ctx.on('agent/created', function ({ agent } = {}) {
    const agentCtx = this?.tools ? this : agent?.ctx
    if (!agentCtx || agentCtx.__dsbotToolsMounted) return
    agentCtx.__dsbotToolsMounted = true
    const sid = String(agent?.session?.id ?? '')
    const presetId = typeof ctx?.agentPresets?.presetForSession === 'function'
      ? ctx.agentPresets.presetForSession(agent?.session)
      : 'standard'
    if (presetId !== 'minimal') {
      if (presetId !== 'ptc-python') {
        try { mountIOSPythonTool(agentCtx) } catch {}
      }
      if (!isPrivateBotOrThread(botIdFromSession(sid)) && ['standard', 'cordis', 'redteam'].includes(presetId)) {
        try { mountIOSPythonJobTool(agentCtx) } catch {}
      }
      try { mountIOSScheduleTools(agentCtx) } catch {}
    }
    // Enforce synced Bot persona, pinned memories, readOnly protection, and disabledTools
    // even when an ios:* session is cold-resumed from the Web Workbench.
    if (sid.startsWith('ios:')) {
      const botKey = botIdFromSession(sid)
      const rootBotId = rootBotIdOf(botKey)
      const policy = runtime.botPolicies.get(rootBotId)
      if (policy) {
        if (policy.systemPrompt && typeof agentCtx.systemPrompt?.section === 'function') {
          try {
            agentCtx.systemPrompt.section({ name: 'dsbot-ios-persona', order: 850, text: policy.systemPrompt })
          } catch {}
        }
        if (policy.pinnedMemories && typeof agentCtx.systemPrompt?.section === 'function') {
          try {
            agentCtx.systemPrompt.section({ name: 'dsbot-ios-pinned-memories', order: 855, text: policy.pinnedMemories })
          } catch {}
        }
        const blockedTools = new Set(Array.isArray(policy.disabledTools) ? policy.disabledTools : [])
        if (!policy.isGroup) blockedTools.add('group_todo_add')
        if (policy.permissionMode === 'readOnly') {
          for (const writeTool of ['write', 'edit', 'delete', 'terminal_exec', 'python_exec', 'python_job_start', 'schedule_create', 'schedule_edit', 'schedule_delete']) {
            blockedTools.add(writeTool)
          }
        }
        if (blockedTools.size > 0 && typeof agentCtx.tools?.restrict === 'function') {
          try {
            agentCtx.tools.restrict((tool) => !blockedTools.has(tool.name))
          } catch {}
        }
      }
    }
    // Restore interactive approval prompts for subagents delegated from an active Native 'ask' turn
    // (upstream dsh-subagent appends approval/policy = 'never' by default).
    const parentSid = agent?.session?.header?.parentSession
    if (typeof parentSid === 'string' && parentSid && typeof agent?.session?.append === 'function') {
      let cursor = parentSid
      const seen = new Set([sid])
      const allSessions = typeof ctx?.sessions?.list === 'function' ? ctx.sessions.list() : []
      const byId = new Map(allSessions.map((s) => [String(s?.id ?? s?.header?.id ?? ''), s]))
      let rootTurn
      for (let depth = 0; cursor && depth < 8 && !seen.has(cursor); depth += 1) {
        seen.add(cursor)
        const activeTurn = runtime.activeTurns.get(cursor)
        if (activeTurn && !activeTurn.done) {
          rootTurn = activeTurn
          break
        }
        cursor = byId.get(cursor)?.header?.parentSession
      }
      if (rootTurn && rootTurn.permissionMode === 'ask') {
        try {
          if (ctx?.approval?.overrideOf?.(agent.session) === 'never') {
            agent.session.append('approval/policy', { policy: 'ask', source: 'ios-native-inherit' })
          }
        } catch {}
      }
    }
  }, { global: true })
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
  bootError: typeof workerData?.lastBootError === 'string' ? workerData.lastBootError : '',
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
  if (!isValidSessionKey(normalizedBotId)
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

const MAX_CONCURRENT_TURNS = 2

rpc.handle('chat.send', async (params) => {
  const targetId = dshSessionId(String(params.sessionId ?? ''))
  if (runtime.preparingTurn && runtime.preparingTurn.botId === String(params.sessionId ?? '')) {
    throw new Error('Another DSH turn is already preparing for this session')
  }
  if (runtime.activeTurns.has(targetId) || runtime.activeTurns.size >= MAX_CONCURRENT_TURNS) {
    throw new Error('Another DSH turn is already running')
  }
  if (ctx?.agents?.get?.(targetId)?.status === 'running') {
    throw new Error('该会话正在 Web 工作台运行中，请等待完成或停止后再发送。')
  }
  if (runtime.pluginMutationInProgress || runtime.profileRestartRequired) throw new Error('The DSH profile is changing')
  const preparation = {
    turnId: String(params.turnId ?? ''),
    botId: String(params.sessionId ?? ''),
    cancelled: false,
  }
  runtime.preparingTurn = preparation
  preparation.finished = startTurn(params, preparation).finally(() => {
    if (runtime.preparingTurn === preparation) runtime.preparingTurn = undefined
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
  if (!isValidSessionKey(botId) || !turnId || !model || !text) throw new TypeError('Invalid chat request')
  if (Buffer.byteLength(text, 'utf8') > 262_144) throw new RangeError('Message exceeds 256 KB')
  if (runtime.activeTurns.has(dshSessionId(botId)) || runtime.activeTurns.size >= MAX_CONCURRENT_TURNS) {
    throw new Error('Another DSH turn is already running')
  }
  const isPrivateRequest = isPrivateBotOrThread(botId)
  if (!isPrivateRequest && Array.isArray(params.endpointModels) && params.endpointModels.length > 0) {
    runtime.customCatalogModels = params.endpointModels.map(String).filter(Boolean)
  }
  const nextApiBaseURL = typeof params.apiBaseURL === 'string' ? params.apiBaseURL : runtime.apiBaseURL
  const nextProviderBaseURL = routeForApiBase(nextApiBaseURL)
  runtime.apiBaseURL = nextApiBaseURL
  if (nextProviderBaseURL !== runtime.providerBaseURL) {
    // Guard against clobbering providerBaseURL while a Web session is actively streaming on the current endpoint.
    const busyWebAgent = (typeof ctx?.agents?.list === 'function' ? ctx.agents.list() : [])
      .find((a) => a?.status === 'running' && !runtime.activeTurns.has(a.id))
    if (busyWebAgent) {
      throw new Error('Web 工作台正在另一接口上运行对话，请等待 Web 回复完成后再切换自定义服务商。')
    }
    for (const [id, active] of runtime.activeAgents) await drainAndDispose(id, active)
    // Cordis validates the plain config and owns the volatile references.
    // Always preserve thinking: 'enabled' so reasoning_effort stays functional across switches.
    const nextConfig = { baseURL: nextProviderBaseURL, thinking: 'enabled' }
    if (!isOfficialDeepSeekBase(nextApiBaseURL) && !isPrivateRequest && Array.isArray(runtime.customCatalogModels) && runtime.customCatalogModels.length > 0) {
      nextConfig.models = runtime.customCatalogModels.map((id) => inferCustomModelCapabilities(id))
    }
    await runtime.providerFiber.update(nextConfig)
    runtime.providerBaseURL = nextProviderBaseURL
    process.env.DS_BOT_PROVIDER_BASE_URL = nextProviderBaseURL
  }
  const dshModel = model === 'deepseek-flash-thinking' ? 'deepseek-flash' : model
  const reasoningEnabled = model === 'deepseek-flash-thinking' || model === 'deepseek-v4-pro'
  const officialDeepSeek = isOfficialDeepSeekBase(runtime.apiBaseURL)
  const toolsEnabled = params.supportsTools !== false && (officialDeepSeek || params.customTools === true)
  const webSearchEnabled = officialDeepSeek && params.webSearchEnabled === true
  const permissionMode = ['ask', 'autoReview', 'readOnly'].includes(params.permissionMode) ? params.permissionMode : 'ask'
  const redteamMode = params.redteamMode === true && runtime.redteamToolsEnabled && !isPrivateBotOrThread(botId)
  const redteamWriteEnabled = redteamMode && params.redteamWriteEnabled === true
  const redteamSensitiveDataEnabled = redteamMode && params.redteamSensitiveDataEnabled === true
  const agentPreset = typeof params.agentPreset === 'string' ? params.agentPreset : ctx.agentPresets.defaultId
  if (agentPreset === 'redteam' && !redteamMode) {
    throw new Error('红队模式要求开启全局红队宿主并授予本 Bot 红队工具权限（私密会话不可使用）。')
  }
  if (redteamMode) {
    const rtMountStatus = await setRedteamToolsMounted(true)
    if (agentPreset === 'redteam' && !rtMountStatus.redteamModeActive) {
      throw new Error(`dsh-purge-safe 红队工具未能挂载：${rtMountStatus.compatibilityWarning || '请检查插件状态并重启引擎'}`)
    }
  }
  const availablePresets = await ctx.agentPresets.list()
  if (!availablePresets.some((preset) => preset.id === agentPreset && !preset.broken)) {
    throw new Error(`Unknown or unavailable DSH mode: ${agentPreset}`)
  }
  const id = dshSessionId(botId)
  let active = runtime.activeAgents.get(id)
  if (active && active.agentPreset !== agentPreset) {
    await drainAndDispose(id, active)
    active = undefined
  }
  const rawEffort = typeof params.reasoningEffort === 'string' ? params.reasoningEffort : 'medium'
  const requestedEffort = ['low', 'medium', 'high'].includes(rawEffort) ? rawEffort : 'medium'
  const dshReasoningEffort = rawEffort === 'low' ? 'low' : (rawEffort === 'max' ? 'max' : 'high')
  const disabledTools = Array.isArray(params.disabledTools) ? params.disabledTools.map(String).filter(Boolean) : []
  const options = {
    provider: 'deepseek-official',
    model: dshModel,
    ...(officialDeepSeek ? { reasoningEffort: reasoningEnabled ? dshReasoningEffort : 'off' } : {}),
  }
  if (!active) {
    try {
      const wsRegistry = ctx?.get?.('workspaceRegistry')
      if (wsRegistry?.archivedSessionIds?.includes(id) && typeof wsRegistry.unarchiveSession === 'function') {
        await wsRegistry.unarchiveSession(id)
      }
    } catch {}
    if (ctx?.agents?.get?.(id) || runtime.allAgentHandles.has(id)) {
      await releaseSessionAgent(id)
    }
    const composition = setupAgent({
      botId, systemPrompt: params.systemPrompt, pinnedMemories: params.pinnedMemories,
      legacyHistory: params.legacyHistory, agentPreset,
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
      } else if (String(error?.name || '').includes('SessionAlreadyOwned') || String(error?.message || '').includes('already owned')) {
        if (!runtime.activeTurns.has(id) && ctx?.agents?.get?.(id)?.status !== 'running') {
          await releaseSessionAgent(id)
          handle = await ctx.agents.resume({ resumeSessionId: id, agentOptions: options, setup: composition.setup })
        } else {
          throw new Error('该会话当前正被 Web 工作台占用，请返回或关闭 Web 工作台页面后重试。')
        }
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
    if (selection !== agentPreset) {
      try {
        await ctx.agentPresets.select(handle.agent, agentPreset)
      } catch {
        // Preset already mounted via setupAgent; ignore if session header is immutable
      }
    }
    active = {
      handle,
      agent: handle.agent,
      setPersona: composition.setPersona,
      setToolsEnabled: composition.setToolsEnabled,
      botId,
      agentPreset,
      frozenSystemPrompt: typeof params.systemPrompt === 'string' ? params.systemPrompt : '',
      lastUsedAt: Date.now(),
    }
    guardIOSBackgroundFollowups(active.agent)
    runtime.activeAgents.set(id, active)
    await evictIdleAgentsIfNeeded(id)
  } else {
    active.lastUsedAt = Date.now()
    active.agent.model.select(options)
    // Memory Freeze Semantics: keep the active session's system prompt prefix
    // immutable across turns so DeepSeek Prompt Cache (~29x savings) stays hot.
    // Only refresh when the caller explicitly requests a checkpoint refresh.
    if (params.forceRefreshPersona === true) {
      active.frozenSystemPrompt = typeof params.systemPrompt === 'string' ? params.systemPrompt : ''
      active.setPersona(active.frozenSystemPrompt, params.pinnedMemories)
    }
    active.setToolsEnabled(toolsEnabled, params.subagentEnabled === true, webSearchEnabled,
      redteamMode, redteamWriteEnabled, redteamSensitiveDataEnabled, permissionMode,
      requestedEffort, disabledTools, params.isGroup === true, typeof params.groupContext === 'string' ? params.groupContext : '')
  }

  if (preparation.cancelled || runtime.suspended) {
    rpc.notify('chat.done', { sessionId: botId, turnId, status: 'aborted' })
    return { turnId, status: 'accepted', engine: 'node+dsh' }
  }
  const contentBlocks = [{ type: 'text', text }]
  if (Array.isArray(params.imagePaths) && params.imagePaths.length > 0 && WORKSPACE_FILES) {
    const attachmentsSvc = ctx?.get?.('attachments')
    const filesRoot = resolve(WORKSPACE_FILES)
    const mimeByExt = {
      '.jpg': 'image/jpeg', '.jpeg': 'image/jpeg', '.png': 'image/png',
      '.webp': 'image/webp', '.gif': 'image/gif',
    }
    for (const rel of params.imagePaths.slice(0, 6)) {
      if (typeof rel !== 'string' || !rel.trim()) continue
      const cleanRel = rel.replace(/^files\//, '').replace(/^\/+/, '')
      const fullPath = resolve(filesRoot, cleanRel)
      if (!fullPath.startsWith(filesRoot + '/')) continue
      const extMatch = fullPath.toLowerCase().match(/\.(jpg|jpeg|png|webp|gif)$/)
      if (!extMatch) continue
      const mediaType = mimeByExt[`.${extMatch[1]}`]
      try {
        const bytes = await readFile(fullPath)
        if (!bytes || bytes.byteLength === 0 || bytes.byteLength > 20 * 1024 * 1024) continue
        if (attachmentsSvc && typeof attachmentsSvc.saveImage === 'function') {
          const stored = await attachmentsSvc.saveImage({ data: bytes, mediaType, name: basename(fullPath) })
          if (stored?.attachmentId) {
            contentBlocks.push({ type: 'image', attachment: stored })
          }
        }
      } catch {}
    }
  }
  const userMessage = createUserMessage({ content: contentBlocks, source: { kind: 'user' } })
  const turn = { turnId, botId, isGroup: params.isGroup === true, webSearchEnabled, toolsEnabled, permissionMode, done: false, startedAt: Date.now() }
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
    let turnUsage
    let finalContent = ''
    let finalReasoning = ''
    let persistedUserMessage
    let persistedAssistantMessages = []
    let nextSeq
    try {
      await active.agent.whenIdle()
      await ctx.sessions.flush(active.agent.session)
      const events = active.agent.session.snapshotEvents()
      nextSeq = active.agent.session.seq
      const turnEvents = events.filter((event) => event.seq >= startSeq)
      const assistantParts = []
      const reasoningParts = []
      for (const event of turnEvents) {
        if (event.type === 'user/message' && !persistedUserMessage && (!event.data?.source || event.data.source.kind === 'user')) {
          persistedUserMessage = {
            id: `dsh-${id}-${event.seq}`,
            seq: event.seq,
            timestamp: event.time,
          }
          continue
        }
        if (event.type !== 'assistant/message') continue
        const blocks = event.data?.message?.content
        const textPart = messageText(blocks)
        if (textPart) assistantParts.push(textPart)
        let thinkPart = ''
        if (Array.isArray(blocks)) {
          thinkPart = blocks
            .filter((b) => b?.type === 'thinking' && typeof b.thinking === 'string')
            .map((b) => b.thinking)
            .join('')
          if (thinkPart) reasoningParts.push(thinkPart)
        }
        if (textPart || thinkPart) {
          persistedAssistantMessages.push({
            id: `dsh-${id}-${event.seq}`,
            seq: event.seq,
            content: textPart,
            reasoning: thinkPart,
            timestamp: event.time,
          })
        }
      }
      finalContent = assistantParts.join('\n\n')
      finalReasoning = reasoningParts.join('\n\n')
      const end = [...turnEvents].reverse().find((event) => event.type === 'turn/end')
      const reason = end?.data.reason
      if (reason?.kind !== 'completed') {
        status = reason?.kind === 'aborted' ? 'aborted' : reason?.kind === 'error' ? 'error' : 'incomplete'
        if (typeof reason?.error?.message === 'string') error = reason.error.message
      } else {
        const hasAssistantOutput = turnEvents.some((event) => {
          if (event.type === 'assistant/message') {
            const blocks = event.data?.message?.content
            if (typeof blocks === 'string' && blocks.trim().length > 0) return true
            if (Array.isArray(blocks) && blocks.some((b) => (b?.type === 'text' && b.text?.trim()) || (b?.type === 'thinking' && b.thinking?.trim()) || b?.type === 'tool_use')) return true
          }
          return event.type === 'tool/call' || event.type === 'tool/result'
        })
        if (!hasAssistantOutput) {
          status = 'error'
          error = '模型返回空响应（0 输出），请重试或切换模型。'
        }
      }
      let inputTokens = 0
      let cacheReadTokens = 0
      let outputTokens = 0
      for (const event of turnEvents) {
        const u = event.data?.message?.usage ?? event.data?.usage ?? usageFromStream(event.data?.stream)
        if (u && typeof u === 'object') {
          inputTokens += Number(u.input_tokens ?? u.inputTokens ?? u.prompt_tokens ?? u.promptTokens ?? 0) || 0
          cacheReadTokens += Number(u.cache_read_input_tokens ?? u.cacheReadTokens ?? u.prompt_cache_hit_tokens ?? 0) || 0
          outputTokens += Number(u.output_tokens ?? u.outputTokens ?? u.completion_tokens ?? u.completionTokens ?? 0) || 0
        }
      }
      if (inputTokens > 0 || cacheReadTokens > 0 || outputTokens > 0) {
        turnUsage = { model, inputTokens, cacheReadTokens, outputTokens }
      }
    } catch (reason) {
      status = 'error'
      error = reason instanceof Error ? reason.message : String(reason)
    } finally {
      turn.flushDelta?.()
      turn.done = true
      runtime.activeTurns.delete(id)
      clearRedteamApprovalGrants(id)
      const durationMs = Math.max(1, Date.now() - (turn.startedAt ?? Date.now()))
      rpc.notify('chat.done', {
        sessionId: botId,
        turnId,
        status,
        durationMs,
        ...(finalContent ? { finalContent } : {}),
        ...(finalReasoning ? { finalReasoning } : {}),
        ...(persistedUserMessage ? { userMessage: persistedUserMessage } : {}),
        ...(persistedAssistantMessages.length > 0 ? { assistantMessages: persistedAssistantMessages } : {}),
        ...(Number.isSafeInteger(nextSeq) ? { nextSeq } : {}),
        ...(error ? { error } : {}),
        ...(turnUsage ? { usage: turnUsage } : {}),
      })
    }
  })()
  return { turnId, status: 'accepted', engine: 'node+dsh' }
}

rpc.handle('session.refreshPersona', async ({ sessionId, systemPrompt, pinnedMemories } = {}) => {
  const botId = String(sessionId ?? '').trim()
  if (!botId) return { refreshed: false }
  const rootId = dshSessionId(rootBotIdOf(botId))
  const exactId = dshSessionId(botId)
  const nextPrompt = typeof systemPrompt === 'string' ? systemPrompt : ''
  const nextMemories = typeof pinnedMemories === 'string' ? pinnedMemories : undefined
  let count = 0
  for (const [key, active] of runtime.activeAgents.entries()) {
    if (key === exactId || key === rootId || key.startsWith(`${rootId}:`)) {
      active.frozenSystemPrompt = nextPrompt
      active.setPersona(nextPrompt, nextMemories)
      count += 1
    }
  }
  return { refreshed: count > 0, count }
})

async function drainAndDispose(id, active) {
  await ctx.subagents.drainDescendants([active.agent])
  await active.agent.whenIdle()
  await ctx.sessions.flush(active.agent.session)
  await active.handle.dispose()
  runtime.activeAgents.delete(id)
  runtime.allAgentHandles.delete(id)
}

async function releaseSessionAgent(id, { forceCancel = false } = {}) {
  const active = runtime.activeAgents.get(id)
  if (active) {
    if (forceCancel && active.agent?.status === 'running') {
      try { active.agent.cancel({ kind: 'user' }) } catch {}
    }
    await drainAndDispose(id, active)
    return true
  }
  const tracked = runtime.allAgentHandles.get(id)
  if (tracked) {
    const agent = tracked.agent
    if (forceCancel && agent?.status === 'running') {
      try { agent.cancel({ kind: 'user' }) } catch {}
    }
    if (agent) {
      await ctx.subagents?.drainDescendants?.([agent]).catch(() => {})
      await agent.whenIdle?.().catch(() => {})
      if (agent.session) await ctx.sessions?.flush?.(agent.session).catch(() => {})
    }
    await tracked.dispose?.().catch(() => {})
    runtime.allAgentHandles.delete(id)
    return true
  }
  return false
}

const MAX_ACTIVE_AGENTS = 3

async function evictIdleAgentsIfNeeded(keepId) {
  if (runtime.activeAgents.size <= MAX_ACTIVE_AGENTS) return
  const candidates = [...runtime.activeAgents.entries()]
    .filter(([id, active]) => {
      if (id === keepId) return false
      if (runtime.activeTurns.has(id)) return false
      if (active.agent?.status === 'running') return false
      const ownsJobs = (ctx.jobs?.list(id) ?? []).some((job) => job.owner === id)
      return !ownsJobs
    })
    .sort((a, b) => (a[1].lastUsedAt ?? 0) - (b[1].lastUsedAt ?? 0))
  for (const [id, active] of candidates) {
    if (runtime.activeAgents.size <= MAX_ACTIVE_AGENTS) break
    try {
      await drainAndDispose(id, active)
    } catch {
      // Best-effort eviction; keep going if another idle agent can be freed.
    }
  }
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

function prepareUserPluginConfigsOverlay(enabled) {
  const path = join(WORKSPACE, '.dsbot-ios-user-plugin-configs.patch.yml')
  const entries = []
  if (enabled) {
    const configPath = join(PROFILE_DIR, 'ios-plugin-configs.json')
    if (existsSync(configPath)) {
      try {
        const parsed = JSON.parse(readFileSync(configPath, 'utf8'))
        if (parsed && typeof parsed === 'object' && !Array.isArray(parsed)) {
          for (const [pluginId, cfg] of Object.entries(parsed)) {
            if (!pluginId || !cfg || typeof cfg !== 'object' || Array.isArray(cfg) || Object.keys(cfg).length === 0) continue
            const safeConfig = { ...cfg }
            if (pluginId === 'dsh-purge-safe') {
              // Never let user JSON override iOS security boundary keys for dsh-purge-safe
              delete safeConfig.toolGateBypass
              delete safeConfig.subagentControl
              delete safeConfig.autoApplyOnStart
              delete safeConfig.autoUpdateOnStart
            }
            if (Object.keys(safeConfig).length > 0) {
              entries.push({ id: pluginId, config: safeConfig })
            }
          }
        }
      } catch {
        // Ignore malformed user config file and boot cleanly
      }
    }
  }
  writeFileSync(path, `${JSON.stringify(entries, null, 2)}\n`, { mode: 0o600 })
  return path
}

rpc.handle('plugins.runtime.capabilities', async () => {
  const defs = typeof ctx?.tools?.definitions === 'function' ? ctx.tools.definitions() : []
  const thirdPartyTools = defs
    .filter((tool) => tool?.name && !DISABLED_TOOL_NAMES.has(tool.name) && tool.name !== 'subagent' && !String(tool.name).startsWith('redteam_'))
    .map((tool) => ({
      name: String(tool.name),
      description: String(tool.description ?? '').replace(/\s+/g, ' ').trim().slice(0, 200),
    }))
    .sort((a, b) => a.name.localeCompare(b.name))
  return {
    thirdPartyTools,
    activePlugins: runtime.activePlugins ?? [],
    webReady: webUiInfo().ready === true,
  }
})

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
  if (active) {
    await active.agent.whenIdle().catch(() => {})
    await ctx.sessions.flush(active.agent.session).catch(() => {})
  }
  return { aborted: true, sessionId: activeTurn.botId }
})

rpc.handle('chat.steer', async ({ sessionId, text } = {}) => {
  const botId = String(sessionId ?? '').trim()
  const cleanText = typeof text === 'string' ? text.trim() : ''
  if (!isValidSessionKey(botId) || !cleanText) throw new TypeError('Invalid chat.steer request')
  const id = dshSessionId(botId)
  if (!runtime.activeTurns.has(id)) return { steered: false }
  const active = runtime.activeAgents.get(id)
  if (!active?.agent || typeof active.agent.steer !== 'function') return { steered: false }
  const userMessage = createUserMessage({ content: [{ type: 'text', text: cleanText }], source: { kind: 'user' } })
  active.agent.steer(userMessage)
  return { steered: true }
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
  // Also release any Web-owned or detached live agents so no SQLite write handles remain open on suspend.
  for (const [id] of [...runtime.allAgentHandles.entries()]) {
    if (runtime.activeAgents.has(id)) continue
    await releaseSessionAgent(id, { forceCancel: true }).catch(() => {})
    if (runtime.suspendGeneration !== suspendGeneration || !runtime.suspended) {
      return { suspended: false }
    }
  }
  // Close session-query.sqlite handle lazily so it reopens on next search without holding locks in background.
  try {
    const sq = ctx?.get?.('sessionQuery')
    if (sq && sq._db) {
      await sq._tail?.catch(() => {})
      try { sq._db.close() } catch {}
      sq._db = undefined
      sq._ready = undefined
    }
  } catch {}
  let sqliteClosed = false
  if (typeof runtime.persistence?.suspendDatabase === 'function') {
    const res = await runtime.persistence.suspendDatabase()
    sqliteClosed = res?.closed === true
  } else {
    await runtime.persistence.flush({ truncate: true })
  }
  return { suspended: runtime.suspendGeneration === suspendGeneration && runtime.suspended, sqliteClosed }
})
rpc.handle('agent.resume', async () => {
  runtime.suspendGeneration += 1
  runtime.suspended = false
  if (typeof runtime.persistence?.resumeDatabase === 'function') {
    runtime.persistence.resumeDatabase()
  }
  return { suspended: false }
})
rpc.handle('runtime.health', async () => {
  const mem = process.memoryUsage()
  const webPort = ctx?.webServer?.port
  let webServerAlive = false
  if (Number.isInteger(webPort) && webPort > 0) {
    const listener = ctx?.webServer?.server
    webServerAlive = listener ? listener.listening !== false : true
  }
  return {
    ok: !runtime.shuttingDown,
    suspended: runtime.suspended,
    uptimeSeconds: Math.round(process.uptime()),
    rssMB: Math.round((mem.rss / 1_048_576) * 10) / 10,
    heapUsedMB: Math.round((mem.heapUsed / 1_048_576) * 10) / 10,
    heapTotalMB: Math.round((mem.heapTotal / 1_048_576) * 10) / 10,
    activeAgents: runtime.activeAgents.size,
    activeTurns: runtime.activeTurns.size,
    webPort: Number.isInteger(webPort) ? webPort : 0,
    webServerAlive,
  }
})

rpc.handle('session.list', async () => {
  const sessions = (await runtime.persistence.list({ scope: 'ios', orderBy: 'activity' }))
    .map((item) => {
      const botId = botIdFromSession(item.header.id)
      return {
        sessionId: botId,
        createdAt: item.header.createdAt,
        eventCount: item.eventCount,
        ...(!isPrivateBotOrThread(botId) ? {
          lastActivityAt: item.lastActivityAt,
          lastMessagePreview: item.lastMessagePreview,
        } : {}),
      }
    })
  return { sessions }
})

rpc.handle('web.sessions.list', async () => {
  const all = await runtime.persistence.list({
    scope: 'web-root',
    orderBy: 'activity',
    limit: 80,
    excludeRootIds: [...runtime.privateBotIds],
  })
  const sessions = all.map((item) => ({
      sessionId: item.header.id,
      title: item.title ?? '',
      createdAt: item.header.createdAt,
      eventCount: item.eventCount,
      lastActivityAt: item.lastActivityAt ?? item.header.createdAt,
      lastMessagePreview: item.lastMessagePreview ?? '',
    }))
  return { sessions }
})

function resolveAnyHistorySessionId(raw) {
  const value = String(raw ?? '').trim()
  if (value.startsWith('ios:') || /^session-[A-Za-z0-9_-]{1,120}$/.test(value)) return value
  return dshSessionId(value)
}

rpc.handle('session.history', async ({ sessionId }) => {
  const id = resolveAnyHistorySessionId(sessionId)
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
  if (typeof sessionId === 'string' && /^session-[A-Za-z0-9_-]{1,120}$/.test(sessionId)) {
    return sessionId
  }
  if (!isValidSessionKey(sessionId)) {
    throw new TypeError('Invalid native session identifier')
  }
  return dshSessionId(sessionId)
}

// Keep native search on the same DSH index as Web, with a native Bot allowlist (including all child threads).
rpc.handle('session.search', async ({ query, botIds, cursor } = {}) => {
  if (typeof query !== 'string' || !query.trim() || Array.from(query).length > 160
    || !Array.isArray(botIds) || botIds.length > 5000
    || (cursor !== undefined && (typeof cursor !== 'string' || cursor.length > 8192))) {
    throw new TypeError('Invalid native session search request')
  }
  const allowedRoots = new Set()
  const allowed = new Set()
  for (const botId of botIds) {
    if (isPrivateBotOrThread(botId)) continue
    const id = nativeHistorySessionId(botId)
    allowed.add(id)
    if (id.startsWith('ios:')) allowedRoots.add(id)
  }
  // Expand root Bot IDs to include all persisted non-private child threads (ios:<botId>:<threadId>).
  if (allowedRoots.size > 0 && typeof runtime.persistence?.list === 'function') {
    const allPersisted = await runtime.persistence.list()
    for (const item of allPersisted) {
      const sid = String(item?.header?.id ?? '')
      if (!sid.startsWith('ios:')) continue
      const botKey = botIdFromSession(sid)
      if (isPrivateBotOrThread(botKey)) continue
      const rootId = dshSessionId(rootBotIdOf(botKey))
      if (allowedRoots.has(rootId)) allowed.add(sid)
    }
  }
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
    if (!allowed.has(header.id) || isPrivateBotOrThread(botId) || header.origin === 'subagent') continue
    results.push({
      botId, sequence: bestMatch.seq, timestamp: bestMatch.time, snippet: bestMatch.snippet,
    })
  }
  return { results, nextCursor: page.nextCursor }
})

rpc.handle('session.search.context', async ({ sessionId, sequence } = {}) => {
  const id = nativeHistorySessionId(sessionId)
  if (!Number.isSafeInteger(sequence) || sequence < 0 || isPrivateBotOrThread(sessionId)) {
    throw new Error('Search result is unavailable')
  }
  await runtime.persistence.flushSession(id)
  const summary = await runtime.persistence.stat(id)
  if (!summary || summary.header.origin === 'subagent' || sequence >= summary.eventCount) {
    throw new Error('Search result is unavailable')
  }
  const start = Math.max(0, sequence - 20)
  const end = Math.min(summary.eventCount, sequence + 21)
  const handle = await runtime.persistence.open(id, 'read')
  try {
    const { events } = await handle.read(start, end - start)
    const messages = eventMessages(events, sessionId)
    if (!messages.some((message) => message.sequence === sequence) || isPrivateBotOrThread(sessionId)) {
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
  if (beforeSeq !== undefined && (!Number.isSafeInteger(beforeSeq) || beforeSeq < 0)) {
    throw new TypeError('Invalid session history cursor')
  }
  const id = nativeHistorySessionId(sessionId)
  await runtime.persistence.flushSession(id)
  const summary = await runtime.persistence.stat(id)
  const end = Math.min(beforeSeq ?? Infinity, summary?.eventCount ?? 0)
  if (!summary || end <= 0) return { messages: [], toolActivities: [], hasMore: false }
  const handle = await runtime.persistence.open(id, 'read')
  try {
    let start = end
    let events = []
    let visibleMessages = []
    const minVisible = 15
    const maxScan = 500
    while (start > 0 && visibleMessages.length < minVisible && (end - start) < maxScan) {
      const nextStart = Math.max(0, start - 50)
      const chunk = await handle.read(nextStart, start - nextStart)
      events = [...chunk.events, ...events]
      start = nextStart
      visibleMessages = eventMessages(events, sessionId)
    }
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
      messages: visibleMessages.map(historyMessagePreview),
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
  if (!isValidSessionKey(botId)) throw new TypeError('Invalid Bot id')
  const sessionId = dshSessionId(botId)
  const tasks = (await ctx.schedule.catalog())
    .filter((task) => iosScheduleTaskVisible(task, sessionId))
    .map(iosSchedulePublicTask)
  return { tasks }
})

function iosJobsOwner(botId) {
  if (!isValidSessionKey(botId)) throw new TypeError('Invalid Bot id')
  if (isPrivateBotOrThread(botId)) throw new Error('Background Jobs are disabled for private Bot sessions')
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

function iosJobBelongsToOwner(jobOwner, rootOwner) {
  const value = String(jobOwner ?? '')
  return value === rootOwner || value.startsWith(`${rootOwner}:`)
}

rpc.handle('jobs.list', async ({ botId } = {}) => {
  const owner = iosJobsOwner(botId)
  if (!ctx.jobs) throw new Error('DSH Jobs is unavailable in this runtime')
  const allJobs = typeof ctx.jobs.listAll === 'function' ? ctx.jobs.listAll() : ctx.jobs.list(owner)
  const jobs = allJobs
    .filter((job) => iosJobBelongsToOwner(job.owner, owner))
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
  const allJobs = typeof ctx.jobs.listAll === 'function' ? ctx.jobs.listAll() : ctx.jobs.list(owner)
  const matched = allJobs.find((j) => String(j.id) === jobId && iosJobBelongsToOwner(j.owner, owner))
  const effectiveOwner = matched?.owner ?? owner
  let job
  try { job = ctx.jobs.get(jobId, effectiveOwner) } catch { return { found: false } }
  if (!iosJobBelongsToOwner(job.owner, owner) || from > job.output.total) return { found: false }
  const output = ctx.jobs.readAt(jobId, from, effectiveOwner)
  return {
    found: true,
    job: iosJobPublicView(ctx.jobs.get(jobId, effectiveOwner)),
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
  const allJobs = typeof ctx.jobs.listAll === 'function' ? ctx.jobs.listAll() : ctx.jobs.list(owner)
  const matched = allJobs.find((j) => String(j.id) === jobId && iosJobBelongsToOwner(j.owner, owner))
  const effectiveOwner = matched?.owner ?? owner
  let current
  try { current = ctx.jobs.get(jobId, effectiveOwner) } catch { return { found: false } }
  if (!iosJobBelongsToOwner(current.owner, owner)) return { found: false }
  const result = ctx.jobs.kill(jobId, effectiveOwner, reason ?? 'Cancelled from the iOS Jobs manager')
  return { found: true, result, job: iosJobPublicView(ctx.jobs.get(jobId, effectiveOwner)) }
})

rpc.handle('command.execute', async ({ sessionId, commandLine } = {}) => {
  const botId = String(sessionId ?? '').trim()
  const line = typeof commandLine === 'string' ? commandLine.trim() : ''
  if (!isValidSessionKey(botId) || !line.startsWith('/')) {
    throw new TypeError('Invalid DSH slash command request')
  }
  if (!ctx?.commands || typeof ctx.commands.execute !== 'function') {
    throw new Error('DSH command service is unavailable')
  }
  const id = dshSessionId(botId)
  if (runtime.activeTurns.has(id) || ctx?.agents?.get?.(id)?.status === 'running') {
    throw new Error('当前会话正在生成中，请等待本轮完成后再执行斜杠命令。')
  }
  let agent = runtime.activeAgents.get(id)?.agent ?? ctx?.agents?.get?.(id)
  let tempHandle
  if (!agent) {
    const policy = runtime.botPolicies.get(rootBotIdOf(botId))
    const preset = policy?.agentPreset || ctx.agentPresets.defaultId
    const composition = setupAgent({
      botId,
      systemPrompt: policy?.systemPrompt ?? '',
      pinnedMemories: policy?.pinnedMemories ?? '',
      agentPreset: preset,
      toolsEnabled: true,
      subagentEnabled: false,
      webSearchEnabled: false,
      permissionMode: policy?.permissionMode ?? 'ask',
    })
    const options = { provider: 'deepseek-official', model: 'deepseek-flash' }
    if (await runtime.persistence.stat(id)) {
      tempHandle = await ctx.agents.resume({ resumeSessionId: id, agentOptions: options, setup: composition.setup })
    } else {
      tempHandle = await ctx.agents.create({ sessionId: id, meta: { cwd: WORKSPACE_FILES }, agentOptions: options, setup: composition.setup })
    }
    agent = tempHandle.agent
  }
  const controller = new AbortController()
  const timer = setTimeout(() => controller.abort(new Error('Command timed out')), 60_000)
  try {
    const result = await ctx.commands.execute(agent, line, [], controller.signal)
    await ctx.sessions.flush(agent.session).catch(() => {})
    return {
      ok: true,
      command: line,
      result: typeof result === 'string' ? result : (result?.message ?? result?.text ?? ''),
    }
  } finally {
    clearTimeout(timer)
    if (tempHandle) {
      await tempHandle.dispose?.().catch(() => {})
      runtime.allAgentHandles.delete(id)
    }
  }
})

rpc.handle('session.ensureWebReady', async ({ sessionId, title } = {}) => {
  const botId = String(sessionId ?? '').trim()
  if (!isValidSessionKey(botId)) throw new TypeError('Invalid sessionId')
  if (isPrivateBotOrThread(botId)) throw new Error('Private Bot sessions cannot be opened in Web Workbench')
  const id = dshSessionId(botId)
  const cleanTitle = typeof title === 'string' ? title.trim().slice(0, 120) : ''
  const existing = await runtime.persistence.stat(id)
  if (!existing) {
    const handle = await ctx.agents.create({
      sessionId: id,
      meta: { cwd: WORKSPACE_FILES },
      agentOptions: { provider: 'deepseek-official', model: 'deepseek-flash' },
      setup: async (agentCtx) => {
        installModelSelection(agentCtx)
        await ctx.agentPresets.mount(agentCtx, ctx.agentPresets.defaultId)
      },
    })
    try {
      if (cleanTitle) {
        try { handle.agent.session.append('session/title', { title: cleanTitle, source: 'user' }) } catch {}
      }
      await ctx.sessions.flush(handle.agent.session)
    } finally {
      await handle.dispose?.().catch(() => {})
      runtime.allAgentHandles.delete(id)
    }
  } else if (cleanTitle && !existing.title) {
    const live = ctx?.agents?.get?.(id)
    if (live?.session) {
      try {
        live.session.append('session/title', { title: cleanTitle, source: 'user' })
        await ctx.sessions.flush(live.session)
      } catch {}
    }
  }
  try {
    const wsRegistry = ctx?.get?.('workspaceRegistry')
    if (wsRegistry && typeof wsRegistry.list === 'function') {
      let ws = wsRegistry.list().find((item) => item.path === WORKSPACE_FILES) ?? wsRegistry.list()[0]
      if (!ws && typeof wsRegistry.create === 'function') {
        const created = await wsRegistry.create(WORKSPACE_FILES)
        ws = created?.workspace ?? created
      }
      if (ws && typeof ws.attachSession === 'function') {
        await ws.attachSession(id).catch(() => {})
      }
      if (wsRegistry.archivedSessionIds?.includes(id) && typeof wsRegistry.unarchiveSession === 'function') {
        await wsRegistry.unarchiveSession(id).catch(() => {})
      }
    }
  } catch {}
  return { ready: true, dshSessionId: id }
})

rpc.handle('schedule.edit', async ({ botId, id, action, title, prompt, rrule, expectedUpdatedAt }) => {
  if (!isValidSessionKey(botId)
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
  if (!isValidSessionKey(botId)
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
    || botIds.some((id) => !isValidSessionKey(id))) {
    throw new TypeError('Invalid private Bot id list')
  }
  runtime.privateBotIds = new Set(botIds.map((id) => rootBotIdOf(id)))
  process.env.DS_BOT_IOS_PRIVATE_BOT_IDS = JSON.stringify([...runtime.privateBotIds])
  for (const botId of runtime.privateBotIds) {
    const owner = dshSessionId(botId)
    for (const job of ctx.jobs?.list(owner) ?? []) {
      if ((job.owner === owner || String(job.owner).startsWith(`${owner}:`))
        && (job.status === 'running' || job.status === 'stopping')) {
        try { ctx.jobs.kill(job.id, job.owner, 'Bot session was marked private') } catch { /* settled during the privacy update */ }
      }
    }
  }
  ctx?.emit('ios/private-sessions/changed', [...runtime.privateBotIds])
  return { updated: runtime.privateBotIds.size }
})

rpc.handle('bots.policy.sync', async ({ bots } = {}) => {
  if (!Array.isArray(bots) || bots.length > 2_000) {
    throw new TypeError('Invalid bots policy list')
  }
  const next = new Map()
  for (const entry of bots) {
    const id = typeof entry?.id === 'string' ? rootBotIdOf(entry.id) : ''
    if (!id || !isValidSessionKey(id)) continue
    const permissionMode = ['ask', 'autoReview', 'readOnly'].includes(entry.permissionMode) ? entry.permissionMode : 'ask'
    next.set(id, {
      id,
      name: typeof entry.name === 'string' ? entry.name.slice(0, 120) : '',
      systemPrompt: typeof entry.systemPrompt === 'string' ? entry.systemPrompt.slice(0, 32_768) : '',
      pinnedMemories: typeof entry.pinnedMemories === 'string' ? entry.pinnedMemories.slice(0, 16_384) : '',
      permissionMode,
      agentPreset: typeof entry.agentPreset === 'string' ? entry.agentPreset : 'standard',
      disabledTools: Array.isArray(entry.disabledTools) ? entry.disabledTools.map(String).filter(Boolean).slice(0, 200) : [],
      isGroup: entry.isGroup === true,
    })
  }
  runtime.botPolicies = next
  return { synced: next.size }
})

function purgeSessionQueryRows(sessionId) {
  try {
    const sq = ctx?.get?.('sessionQuery')
    if (sq?._db) {
      try { sq._db.prepare('DELETE FROM search_events WHERE session_id = ?').run(sessionId) } catch {}
      try { sq._db.prepare('DELETE FROM search_sessions WHERE session_id = ?').run(sessionId) } catch {}
    }
  } catch {}
}

rpc.handle('session.clear', async ({ sessionId }) => {
  const id = resolveAnyHistorySessionId(sessionId)
  await releaseSessionAgent(id, { forceCancel: true })
  await runtime.persistence.delete(id)
  try {
    const wsRegistry = ctx?.get?.('workspaceRegistry')
    if (wsRegistry && typeof wsRegistry.list === 'function') {
      for (const ws of wsRegistry.list()) {
        if (typeof ws.detachSession === 'function') await ws.detachSession(id).catch(() => {})
      }
    }
  } catch {}
  purgeSessionQueryRows(id)
  ctx?.emit?.('ios/session/mutated', { sessionId: id, kind: 'clear' })
  return { cleared: true }
})

rpc.handle('session.truncateFromSeq', async ({ sessionId, sequence } = {}) => {
  const id = nativeHistorySessionId(sessionId)
  if (!Number.isSafeInteger(sequence) || sequence < 0) {
    throw new TypeError('Invalid truncation sequence')
  }
  if (runtime.activeTurns.has(id) || ctx?.agents?.get?.(id)?.status === 'running') {
    throw new Error('Cannot truncate an active session turn')
  }
  await releaseSessionAgent(id)
  if (typeof runtime.persistence?.truncateFromSeq !== 'function') {
    throw new Error('Session truncation is unavailable in this runtime')
  }
  const result = await runtime.persistence.truncateFromSeq(id, sequence)
  purgeSessionQueryRows(id)
  ctx?.emit?.('ios/session/mutated', { sessionId: id, kind: 'truncate' })
  return result
})

// UI-owned workspace methods (memory, connectors, approvals, speech, local JS) are routed by
// Swift directly to its native workspace and are intentionally not reachable through this process.

let redteamToolsFork = null
let redteamPresetDisposer = null
let redteamMountInFlight = null
let redteamMountError = ''
let redteamMountDurationMs = 0
let redteamSkillsCache = { dir: '', mtimeMs: 0, count: 0 }

async function ensureRedteamPresetRegistered() {
  if (!ctx?.agentPresets || typeof ctx.agentPresets.register !== 'function') return
  try {
    const existing = await ctx.agentPresets.list()
    const current = existing.find((p) => p.id === 'redteam')
    if (current && !current.broken) return
    if (current && current.broken) disposeRedteamPreset()

    const stdRecord = ctx.agentPresets.definitions?.get?.('standard')
    const regCtx = stdRecord?.context ?? ctx
    const basePlugins = Array.isArray(stdRecord?.config?.plugins)
      ? stdRecord.config.plugins.map((entry) => {
          if (entry && entry.id === 'persona' && entry.name === '@deepseek-ai/dsh-persona') {
            return {
              ...entry,
              config: {
                ...(entry.config || {}),
                prefix: 'You are an authorized security assessment and red-team operator powered by the {{model}} model inside the iOS DSH sandbox with dsh-purge-safe tools. Always stay strictly within authorized targets, record findings clearly, and respect tool approval tiers.',
              },
            }
          }
          return entry
        })
      : [
          {
            id: 'persona',
            name: '@deepseek-ai/dsh-persona',
            config: {
              prefix: 'You are an authorized security assessment and red-team operator powered by the {{model}} model inside the iOS DSH sandbox with dsh-purge-safe tools.',
            },
          },
          { id: 'time-context', name: '@deepseek-ai/dsh-time-context' },
          { id: 'tool-fs', name: '@deepseek-ai/dsh-tool-fs', config: { readImage: false, applyPatch: true } },
        ]

    redteamPresetDisposer = await regCtx.agentPresets.register({
      id: 'redteam',
      name: '红队模式',
      description: 'dsh-purge-safe 安全演练与渗透测试模式；自动挂载红队演练台工具集并遵循三档审批策略。',
      order: 5,
      plugins: basePlugins,
    })
  } catch (err) {
    ctx?.logger?.warn?.(`RedTeam preset registration skipped: ${String(err)}`)
  }
}

function disposeRedteamPreset() {
  if (typeof redteamPresetDisposer === 'function') {
    try { redteamPresetDisposer() } catch { /* ignore */ }
  }
  redteamPresetDisposer = null
}

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
        const mtimeMs = statSync(dir).mtimeMs
        if (redteamSkillsCache.dir === dir && redteamSkillsCache.mtimeMs === mtimeMs) {
          return redteamSkillsCache.count
        }
        const count = readdirSync(dir).filter((f) => f.endsWith('.md')).length
        redteamSkillsCache = { dir, mtimeMs, count }
        return count
      } catch { /* ignore */ }
    }
  }
  return 0
}

async function performSetRedteamToolsMounted(enabled) {
  runtime.redteamToolsEnabled = enabled === true
  process.env.DS_BOT_IOS_REDTEAM_ENABLED = runtime.redteamToolsEnabled ? '1' : '0'
  if (!enabled) {
    redteamMountError = ''
    redteamMountDurationMs = 0
    runtime.redteamApprovalGrants.clear()
    for (const policy of runtime.redteamTurnPolicies.values()) policy.enabled = false
    disposeRedteamPreset()
    if (redteamToolsFork) {
      try { await redteamToolsFork.dispose() } catch { /* ignore */ }
      redteamToolsFork = null
    }
    return redteamStatus()
  }
  // Self-heal stale Cordis fork if tools were unexpectedly unregistered or fork disposed
  if (redteamToolsFork && registeredRedteamToolNames().length === 0) {
    try { await redteamToolsFork.dispose?.() } catch { /* ignore */ }
    redteamToolsFork = null
  }
  if (!redteamToolsFork) {
    const toolsPath = redteamToolsModulePath()
    if (!toolsPath) {
      redteamMountError = '未找到 dsh-purge-safe/lib/redteam/tools.js'
      return redteamStatus()
    }
    const startedAt = Date.now()
    try {
      redteamMountError = ''
      const rev = (() => { try { return Math.floor(statSync(toolsPath).mtimeMs) } catch { return Date.now() } })()
      const mod = await import(`${pathToFileURL(toolsPath).href}?rev=${rev}`)
      const plugin = mod?.default ?? mod
      if (plugin && ctx) {
        const fork = ctx.plugin(plugin)
        redteamToolsFork = fork
        try {
          await fork.await?.()
        } catch (err) {
          redteamToolsFork = null
          try { await fork.dispose?.() } catch { /* ignore */ }
          throw err
        }
      }
      redteamMountDurationMs = Math.max(1, Date.now() - startedAt)
    } catch (err) {
      redteamToolsFork = null
      redteamMountDurationMs = 0
      redteamMountError = err instanceof Error ? err.message : String(err)
    }
  }
  if (redteamToolsFork && !redteamMountError) {
    await ensureRedteamPresetRegistered()
  }
  return redteamStatus()
}

async function setRedteamToolsMounted(enabled) {
  const prev = redteamMountInFlight ?? Promise.resolve()
  const run = prev.catch(() => {}).then(() => performSetRedteamToolsMounted(enabled))
  redteamMountInFlight = run
  try {
    return await run
  } finally {
    if (redteamMountInFlight === run) redteamMountInFlight = null
  }
}

function redteamStatus() {
  const installed = Boolean(redteamToolsModulePath())
  const layerActive = runtime.activePlugins.includes('dsh-purge-safe')
  const webLayerActive = runtime.activePluginRows.includes('dsh-purge-safe-redteam-ui')
  const storeReady = Boolean(ctx?.get?.('redteam'))
  const tools = registeredRedteamToolNames()
  const compatibilityWarning = redteamMountError
    || runtime.redteamCompatibility.reason
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
    mountDurationMs: redteamMountDurationMs,
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
      searchApiKeyEnv: 'DEEPSEEK_SEARCH_API_KEY',
      searchBilling: 'api-key',
      sendOriginalQuestion: next.webSearchSendOriginalQuestion,
      count: next.webSearchCount,
    }, {
      searchBaseURL: 'https://api.deepseek.com/v1/tools',
      searchApiKeyEnv: 'DEEPSEEK_SEARCH_API_KEY',
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

async function syncProviderModelCatalog({ apiBaseURL, models, defaultModel } = {}) {
  if (!runtime.providerFiber) {
    return { ok: false, syncedCount: 0, baseURL: runtime.providerBaseURL ?? '' }
  }
  const nextApiBaseURL = typeof apiBaseURL === 'string' && apiBaseURL.trim()
    ? apiBaseURL.trim()
    : runtime.apiBaseURL
  const nextProviderBaseURL = routeForApiBase(nextApiBaseURL)
  const official = isOfficialDeepSeekBase(nextApiBaseURL)
  const seen = new Set()
  const uniqueIds = []
  if (Array.isArray(models)) {
    for (const entry of models) {
      const id = typeof entry === 'string' ? entry.trim() : ''
      if (!id || seen.has(id)) continue
      seen.add(id)
      uniqueIds.push(id)
      if (uniqueIds.length >= 200) break
    }
  }
  const effectiveIds = !official
    ? (uniqueIds.length > 0
        ? uniqueIds
        : (nextProviderBaseURL === runtime.providerBaseURL && Array.isArray(runtime.customCatalogModels)
            ? runtime.customCatalogModels
            : []))
    : []

  const nextConfig = { baseURL: nextProviderBaseURL, thinking: 'enabled' }
  if (!official && effectiveIds.length > 0) {
    nextConfig.models = effectiveIds.map((id) => inferCustomModelCapabilities(id))
  }
  if (nextProviderBaseURL !== runtime.providerBaseURL) {
    for (const [id, active] of runtime.activeAgents) await drainAndDispose(id, active)
  }
  // Update runtime.apiBaseURL BEFORE providerFiber.update so any volatile-update listener
  // resolving Keychain credentials immediately queries the new endpoint.
  runtime.apiBaseURL = nextApiBaseURL
  runtime.providerBaseURL = nextProviderBaseURL
  runtime.customCatalogModels = effectiveIds
  process.env.DS_BOT_PROVIDER_BASE_URL = nextProviderBaseURL
  await runtime.providerFiber.update(nextConfig)

  // Guarantee ctx.llm.listModels('deepseek-official') always includes synced custom models
  // so Web UI selectModel() never rejects a visible custom model with session/model-unavailable.
  try {
    const llmSvc = ctx?.get?.('llm') ?? ctx?.llm
    if (llmSvc && typeof llmSvc.listModels === 'function' && !llmSvc.__dsbotCustomListModelsPatched) {
      const origListModels = llmSvc.listModels.bind(llmSvc)
      llmSvc.listModels = async function patchedListModels(providerId) {
        const listed = await origListModels(providerId)
        if (providerId === 'deepseek-official'
          && !isOfficialDeepSeekBase(runtime.apiBaseURL)
          && Array.isArray(runtime.customCatalogModels)
          && runtime.customCatalogModels.length > 0) {
          const listedIds = new Set(listed.map((m) => m.id))
          const merged = [...listed]
          for (const id of runtime.customCatalogModels) {
            if (!listedIds.has(id)) {
              merged.push({
                provider: 'deepseek-official',
                id,
                name: id,
                inputModalities: ['text', 'image'],
              })
            }
          }
          return merged
        }
        return listed
      }
      llmSvc.__dsbotCustomListModelsPatched = true
    }
  } catch {}

  // Prevent agentDefaultModel.saveSelection() from invoking configEditor against the read-only
  // iOS .app bundle or triggering a Cordis reload mid-request (which causes WebKit "Load failed").
  try {
    const defaultModelSvc = ctx?.get?.('agentDefaultModel') ?? ctx?.agentDefaultModel
    if (defaultModelSvc && typeof defaultModelSvc.saveSelection === 'function' && !defaultModelSvc.__dsbotInMemorySavePatched) {
      defaultModelSvc.saveSelection = async function inMemorySaveSelection(next) {
        if (!runtime.defaultModelFiber || !next?.provider || !next?.model) return
        const payload = {
          provider: String(next.provider),
          model: String(next.model),
          ...(next.reasoningEffort === undefined ? {} : { reasoningEffort: String(next.reasoningEffort) }),
        }
        try {
          await runtime.defaultModelFiber.update(payload)
        } catch {}
      }
      defaultModelSvc.__dsbotInMemorySavePatched = true
    }
  } catch {}

  // Keep DSH Web UI's agent-default-model aligned with the active endpoint & chosen default model.
  if (runtime.defaultModelFiber) {
    const requestedDefault = typeof defaultModel === 'string' ? defaultModel.trim() : ''
    let targetModel = ''
    if (official) {
      targetModel = requestedDefault === 'deepseek-flash-thinking' ? 'deepseek-flash' : (requestedDefault || 'deepseek-flash')
      const reasoningEffort = (requestedDefault === 'deepseek-flash-thinking' || requestedDefault === 'deepseek-v4-pro') ? 'high' : 'off'
      try {
        await runtime.defaultModelFiber.update({
          provider: 'deepseek-official',
          model: targetModel,
          reasoningEffort,
        })
      } catch {}
    } else {
      targetModel = (requestedDefault && (effectiveIds.length === 0 || effectiveIds.includes(requestedDefault)))
        ? requestedDefault
        : (effectiveIds[0] || requestedDefault)
      if (targetModel) {
        try {
          await runtime.defaultModelFiber.update({
            provider: 'deepseek-official',
            model: targetModel,
          })
        } catch {}
      }
    }
  }

  try {
    ctx.emit('llm/models-updated', 'deepseek-official')
  } catch {}
  return {
    ok: true,
    baseURL: nextProviderBaseURL,
    official,
    syncedCount: effectiveIds.length,
  }
}

rpc.handle('models.catalog.sync', async (params = {}) => {
  return await syncProviderModelCatalog(params)
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

// ── iOS Experimental Capabilities: Sandboxed Virtual Command Interpreter, Git Worktree & PR Tracker, and Cordis/Node DevTools Inspector ──

import { copyFileSync, lstatSync, readFileSync, realpathSync, renameSync, rmSync, statSync } from 'node:fs'
import { createHash } from 'node:crypto'
import { basename, dirname, isAbsolute, relative, resolve, sep } from 'node:path'
import vm from 'node:vm'

const virtualTerminals = new Map()
const devtoolsLogs = []
const MAX_DEVTOOLS_LOGS = 200
const MAX_TERMINAL_READ_BYTES = 1_048_576
const MAX_WALK_FILES = 1_500
const MAX_WALK_DEPTH = 12

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

function canonicalizeWorkspacePath(targetPath) {
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
  const rawRoot = resolve(WORKSPACE_FILES)
  mkdirSync(rawRoot, { recursive: true })
  const root = canonicalizeWorkspacePath(rawRoot)
  const raw = String(targetPath || '.').trim()
  if (raw.includes('\0')) throw new Error('权限拒绝：路径包含非法空字节')
  const baseVirtual = virtualCwd.startsWith('/') ? virtualCwd.slice(1) : virtualCwd
  const candidate = raw.startsWith('/workspace')
    ? resolve(root, raw.slice('/workspace'.length).replace(/^\/+/, ''))
    : raw.startsWith('/')
      ? resolve(root, raw.replace(/^\/+/, ''))
      : resolve(root, baseVirtual, raw)
  const combined = canonicalizeWorkspacePath(candidate)
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

function walkWorkspaceTree(dirAbs, baseAbs = resolve(WORKSPACE_FILES), out = [], opts = {}, depth = 0) {
  const includeContent = opts.includeContent !== false
  if (depth > MAX_WALK_DEPTH || out.length >= MAX_WALK_FILES) return out
  let entries = []
  try { entries = readdirSync(dirAbs, { withFileTypes: true }) } catch { return out }
  for (const entry of entries) {
    if (out.length >= MAX_WALK_FILES) break
    if (entry.name === '.DS_Store' || entry.name === '.dsbot-ios-workspace-root' || entry.name === '.dsbot-git-tracker.json' || entry.isSymbolicLink()) continue
    const full = join(dirAbs, entry.name)
    const rel = relative(baseAbs, full).split(sep).join('/')
    if (entry.isDirectory()) {
      walkWorkspaceTree(full, baseAbs, out, opts, depth + 1)
    } else if (entry.isFile()) {
      try {
        const st = statSync(full)
        if (!includeContent) {
          out.push({ path: rel, size: st.size, mtimeMs: Math.round(st.mtimeMs), sha: '', content: null })
          continue
        }
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
  return depth === 0 ? out.sort((a, b) => a.path.localeCompare(b.path)) : out
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
  const baseline = tracker.files || {}
  // Avoid reading every file into memory: reuse the baseline SHA when (size, mtime) match.
  const currentFiles = walkWorkspaceTree(resolve(WORKSPACE_FILES), resolve(WORKSPACE_FILES), [], { includeContent: false })
  for (const file of currentFiles) {
    const prev = baseline[file.path]
    if (prev && prev.size === file.size && prev.mtimeMs === file.mtimeMs && prev.sha) {
      file.sha = prev.sha
      continue
    }
    try {
      const abs = join(resolve(WORKSPACE_FILES), file.path)
      file.sha = file.size <= 524_288
        ? createHash('sha1').update(readFileSync(abs)).digest('hex')
        : `size:${file.size}`
    } catch { file.sha = `size:${file.size}` }
  }
  const currentMap = new Map(currentFiles.map((f) => [f.path, f]))
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
        'DS Bot iOS 沙盒虚拟命令解释器（不是 Shell/PTY）支持命令：',
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
        if (!existsSync(resolved.abs)) throw new Error(`cat: 无法读取文件: ${arg}`)
        const st = statSync(resolved.abs)
        if (st.isDirectory()) throw new Error(`cat: 无法读取目录: ${arg}`)
        if (st.size > MAX_TERMINAL_READ_BYTES) throw new Error(`cat: 文件超过 1 MiB 限制 (${arg})`)
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
      const st = statSync(resolved.abs)
      if (!st.isFile() || st.size > MAX_TERMINAL_READ_BYTES) throw new Error(`${cmd}: 仅支持 1 MiB 以内的普通文件`)
      const lines = readFileSync(resolved.abs, 'utf8').split(/\r?\n/)
      return (cmd === 'head' ? lines.slice(0, count) : lines.slice(-count)).join('\n')
    }

    case 'wc': {
      if (!args.length) throw new Error('wc: 请指定文件名')
      const fileArg = args.find((a) => !a.startsWith('-'))
      const resolved = resolveInsideWorkspaceFiles(term.cwd, fileArg)
      const st = statSync(resolved.abs)
      if (!st.isFile() || st.size > MAX_TERMINAL_READ_BYTES) throw new Error('wc: 仅支持 1 MiB 以内的普通文件')
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
      if (src.abs === canonicalizeWorkspacePath(WORKSPACE_FILES)) throw new Error('mv: 禁止移动工作区根目录')
      mkdirSync(dirname(dst.abs), { recursive: true })
      try {
        renameSync(src.abs, dst.abs)
      } catch (err) {
        if (err?.code === 'EXDEV') {
          copyFileSync(src.abs, dst.abs)
          rmSync(src.abs, { recursive: true, force: true })
        } else {
          throw err
        }
      }
      return ''
    }

    case 'rm': {
      const recursive = args.some((a) => a.startsWith('-') && (a.includes('r') || a.includes('R')))
      const targets = args.filter((a) => !a.startsWith('-'))
      if (!targets.length) throw new Error('rm: 请指定要删除的路径')
      const rootCanonical = canonicalizeWorkspacePath(WORKSPACE_FILES)
      for (const t of targets) {
        const resolved = resolveInsideWorkspaceFiles(term.cwd, t)
        if (resolved.abs === rootCanonical) throw new Error('rm: 禁止删除工作区根目录')
        rmSync(resolved.abs, { recursive, force: true })
      }
      return ''
    }

    case 'echo': {
      const redirection = parseEchoRedirection(line)
      if (redirection) {
        const text = redirection.content + '\n'
        const target = resolveInsideWorkspaceFiles(term.cwd, redirection.path)
        mkdirSync(dirname(target.abs), { recursive: true })
        const existing = redirection.append && existsSync(target.abs) ? readFileSync(target.abs, 'utf8') : ''
        writeFileSync(target.abs, existing + text, 'utf8')
        return ''
      }
      return args.join(' ')
    }

    case 'find': {
      const startArg = args[0] && !args[0].startsWith('-') ? args[0] : '.'
      const nameIdx = args.indexOf('-name')
      let regex = null
      if (nameIdx >= 0 && args[nameIdx + 1]) {
        const rawGlob = String(args[nameIdx + 1]).slice(0, 128)
        const escaped = rawGlob
          .replace(/[\\^$.+()[\]{}|]/g, '\\$&')
          .replace(/\*{2,}/g, '*')
          .replace(/\*/g, '.*')
          .replace(/\?/g, '.')
        regex = new RegExp(`^${escaped}$`, 'i')
      }
      const resolved = resolveInsideWorkspaceFiles(term.cwd, startArg)
      const files = walkWorkspaceTree(resolved.abs, resolved.abs, [], { includeContent: false })
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
          if (statSync(absPath).size > 262_144) return
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
        for (const f of walkWorkspaceTree(resolved.abs, resolved.abs, [], { includeContent: false })) {
          scanFile(join(resolved.abs, f.path), f.path)
          if (hits.length >= 100) break
        }
      }
      return hits.join('\n') || `(未找到匹配 "${query}" 的行)`
    }

    case 'node':
    case 'js': {
      if (cmd === 'node' && (args[0] === '--test' || args[0]?.startsWith('--test-'))) {
        throw new Error('node --test is disabled: iOS has no isolated Node test runner.')
      }
      let code = ''
      if (cmd === 'node' && (args[0] === '-e' || args[0] === '-p')) {
        code = args.slice(1).join(' ')
      } else if (cmd === 'node' && args[0] && /\.(?:m?js|cjs)$/i.test(args[0])) {
        const resolved = resolveInsideWorkspaceFiles(term.cwd, args[0])
        const st = statSync(resolved.abs)
        if (!st.isFile() || st.size > 262_144) throw new Error('node: 脚本文件超过 256 KB 限制')
        code = readFileSync(resolved.abs, 'utf8')
      } else {
        code = args.join(' ')
      }
      if (!code.trim()) throw new Error('用法: node -e "<JavaScript 表达式>" 或 node <file.js>')
      if (rpc && typeof rpc.request === 'function') {
        const res = await rpc.request('sandbox.js_eval', { script: code, timeoutMs: 3_000 }, 8_000)
        if (res?.ok === false) throw new Error(String(res.error || 'JavaScript 执行失败'))
        return String(res?.output ?? '')
      }
      throw new Error('Native QuickJS bridge is unavailable; JavaScript execution failed closed.')
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
      throw new Error(`${cmd}: 未找到命令（输入 help 查看 iOS 沙盒虚拟命令解释器支持的命令）`)
  }
}

async function executeVirtualTerminalCommand(sessionId, commandLine) {
  const term = getVirtualTerminalSession(sessionId)
  const raw = String(commandLine ?? '').trim()
  if (!raw) return { cwd: term.cwd, output: '', exitCode: 0 }
  term.history.push({ command: raw, timestamp: new Date().toISOString() })
  if (term.history.length > 100) term.history.splice(0, term.history.length - 100)
  pushDevtoolsLog('info', 'terminal', `[${term.id}] $ ${raw}`)

  const segments = splitTerminalSegments(raw)
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
  if (command.length > 8_000 || Buffer.byteLength(command, 'utf8') > 32_000) {
    throw new Error('terminal_exec command is too long to review safely (maximum 8,000 characters / 32 KiB UTF-8).')
  }
  if (/[\x00-\x08\x09\x0b-\x1f\x7f]/.test(command)) {
    throw new Error('terminal_exec commands may not contain invisible control characters or tabs.')
  }
  if (/[\u061c\u200b-\u200f\u2028-\u202e\u2060-\u206f\ufeff]/u.test(command)) {
    throw new Error('terminal_exec commands may not contain invisible or bidirectional Unicode controls.')
  }
  if (!exec?.callId) {
    throw new Error('terminal_exec requires a tool-call ID so the command approval can be audited.')
  }
  const active = runtime.activeTurns.get(sessionId)
  if (active?.done) throw new Error('The Bot turn is already closed.')
  if (active?.permissionMode === 'readOnly') {
    throw new Error('只读保护模式已禁用终端命令；请使用受限的只读工作区工具。')
  }
  if (typeof ctx.approval?.request !== 'function') {
    throw new Error('terminal_exec is disabled because a user approval surface is unavailable.')
  }
  // Every model-generated command requires a separate, one-time human decision.
  // This deliberately ignores autoReview: full-shell syntax cannot be classified
  // safely by parsing command strings, and approval must bind to this exact call.
  const outcome = await ctx.approval.request({
    agent: exec.agent,
    toolName: 'terminal_exec',
    callId: exec.callId,
    reason: `Execute sandboxed virtual command: ${command}`,
    displayReason: `每条 Bot 命令都必须单独审批。将执行以下完整命令：\n${command}`,
    signal: exec.signal,
  })
  if (outcome !== 'allowed-once') throw new Error('User did not approve terminal_exec command')
  const res = await executeVirtualTerminalCommand(sessionId, command)
  return { output: `[cwd: ${res.cwd}] (exit ${res.exitCode})\n${res.output || '(done)'}` }
}

runtime.executeGitWorkspaceTool = async (args, exec) => {
  const action = String(args?.action ?? 'status')
  const sessionId = exec?.agent?.session?.id
  const active = typeof sessionId === 'string' ? runtime.activeTurns.get(sessionId) : undefined
  if (action === 'status') {
    const st = computeWorkspaceGitStatus()
    return { output: JSON.stringify(st, null, 2) }
  }
  if (action === 'diff') {
    return { output: computeWorkspaceGitDiff(args?.path) }
  }
  if (action === 'snapshot') {
    if (active?.permissionMode === 'readOnly') {
      throw new Error('只读保护模式已拦截 git_workspace snapshot')
    }
    if ((!active || active.permissionMode !== 'autoReview') && ctx.approval?.request) {
      const outcome = await ctx.approval.request({
        agent: exec.agent,
        toolName: 'git_workspace',
        ...(exec.callId ? { callId: exec.callId } : {}),
        reason: 'Create a workspace Git baseline snapshot',
        displayReason: '允许创建工作区 Git 基线快照？',
        signal: exec.signal,
      })
      if (outcome !== 'allowed-once') throw new Error('User did not approve git_workspace snapshot')
    }
    const st = takeWorkspaceGitSnapshot('Agent workspace snapshot')
    return { output: JSON.stringify(st, null, 2) }
  }
  if (action === 'pr_list') {
    if (ctx.approval?.request && (!active || active.permissionMode !== 'autoReview')) {
      const outcome = await ctx.approval.request({
        agent: exec.agent,
        toolName: 'git_workspace',
        ...(exec.callId ? { callId: exec.callId } : {}),
        reason: `Fetch public GitHub PR list for ${String(args?.repo ?? 'bound repo')}`,
        displayReason: `允许联网查询 GitHub Pull Requests（${String(args?.repo ?? '已绑定仓库')}）？`,
        signal: exec.signal,
      })
      if (outcome !== 'allowed-once') throw new Error('User did not approve git_workspace pr_list')
    }
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

function redactDiagnosticSecrets(text) {
  return String(text ?? '')
    .replace(/\b(?:sk-[A-Za-z0-9_-]{16,}|ghp_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|AIza[0-9A-Za-z\-_]{30,})\b/g, '[secret:REDACTED]')
    .replace(/Bearer\s+[A-Za-z0-9._-]{16,}/g, 'Bearer [secret:REDACTED]')
}

rpc.handle('devtools.eval', async ({ expression } = {}) => {
  const expr = String(expression ?? '').trim()
  if (!expr) throw new Error('请输入要评估的诊断表达式')
  pushDevtoolsLog('info', 'devtools.eval', expr)
  // Deep JSON-snapshot into an isolated null-prototype VM context with string codegen disabled
  // so diagnostic expressions can inspect runtime telemetry without host prototype escape.
  const snapshotJSON = JSON.stringify({
    process: {
      version: process.version,
      versions: process.versions,
      platform: process.platform,
      arch: process.arch,
      uptimeSeconds: Math.round(process.uptime()),
      memoryUsage: process.memoryUsage(),
      env: {
        DSH_HOME: process.env.DSH_HOME ?? '',
        DSH_BASE: process.env.DSH_BASE ?? '',
        DS_BOT_IOS_HOST: process.env.DS_BOT_IOS_HOST ?? '',
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
    cordisEntries: [...(ctx?.loader?.entries?.() ?? [])].map((e) => ({
      id: e.options?.id,
      name: e.options?.name,
      state: e.fiber?.state,
    })),
  })
  const sandboxCtx = vm.createContext(Object.create(null), { codeGeneration: { strings: false, wasm: false } })
  sandboxCtx.__snapshotJSON = snapshotJSON
  vm.runInContext(
    'const __s = JSON.parse(__snapshotJSON); globalThis.process = __s.process; globalThis.process.uptime = () => __s.process.uptimeSeconds; globalThis.process.memoryUsage = () => __s.process.memoryUsage; globalThis.runtime = __s.runtime; globalThis.tools = __s.tools; globalThis.cordisEntries = __s.cordisEntries; delete globalThis.__snapshotJSON;',
    sandboxCtx,
    { timeout: 500 }
  )
  const result = vm.runInContext(expr, sandboxCtx, { timeout: 2_000 })
  const formatted = typeof result === 'string' ? result : JSON.stringify(result, null, 2)
  return { output: redactDiagnosticSecrets(String(formatted ?? 'undefined')).slice(0, 16_000) }
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
  const baseMsg = error instanceof Error ? error.message : String(error)
  const causeMsg = error instanceof Error && error.cause
    ? ` :: ${error.cause instanceof Error ? error.cause.message : String(error.cause)}`
    : ''
  rpc.notify('runtime.failed', { message: `${baseMsg}${causeMsg}` })
  throw error
}

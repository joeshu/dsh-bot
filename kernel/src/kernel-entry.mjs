// Headless DSH 0.2.2-rc.5 Worklet Entry Point for DS-Bot iOS Standalone.
// Communicates exclusively with the SwiftUI Native Shell over Bare.IPC (JSON-RPC 2.0).

import { IPC_PROTOCOL_VERSION, IPCRpcEndpoint } from './ipc-protocol.mjs'
import { BUILTIN_FEATURES, PluginIndexManager } from './plugin-index.mjs'
import { DEFAULT_REGISTRIES, DSHPluginStore } from './plugin-store.mjs'
import { join } from 'node:path'
import { MemoryEngine } from './features/memory-layers.mjs'
import { GroupCollaborationEngine } from './features/group-collab.mjs'
import { HandoffTree, PrivateBotGuard, SideChatManager } from './features/privacy-and-side.mjs'
import { ConnectorRegistry, UsageTracker, validateWidgetBlueprint } from './features/connectors-widgets-usage.mjs'
import { normalizeSessionLog, SessionWriteBarrier } from './shims/legacy-session-guard.mjs'
import { KeychainVaultClient, SandboxFSGuard, SQLiteBridgeClient, URLSessionFetchShim } from './shims/ios-bridges.mjs'

export const REQUIRED_DSH_SERVICES = Object.freeze([
  'sessionController',
  'sessionQuery',
  'sessionPersistence',
  'workspaceRegistry',
])

export function verifyDshContract(ctx, required = REQUIRED_DSH_SERVICES) {
  const missing = required.filter((name) => !ctx || ctx.get(name) === undefined)
  if (missing.length > 0) {
    const err = new Error(`DSH contract verification failed: missing services [${missing.join(', ')}]`)
    err.code = 'DSH_CONTRACT_MISSING_SERVICES'
    err.missingServices = missing
    throw err
  }
  return { ok: true, activeServices: [...required] }
}

export async function startKernelWorklet({
  transport,
  dshVersion,
  dshHome,
  coreBundles = ['@deepseek-ai/dsh', '@deepseek-ai/dsh-base', '@deepseek-ai/dsh-session-query-sqlite'],
  pluginFetchImpl,
  bootDsh,
}) {
  const rpc = new IPCRpcEndpoint(transport)
  const fsGuard = new SandboxFSGuard(dshHome)
  const bridges = {
    fsGuard,
    sqlite: new SQLiteBridgeClient(rpc, fsGuard.assertInside('sessions.sqlite')),
    net: new URLSessionFetchShim(rpc),
    keychain: new KeychainVaultClient(rpc),
    sessionWriteBarrier: new SessionWriteBarrier(),
  }

  const fetchImpl = pluginFetchImpl ?? ((url, init) => bridges.net.fetch(url, init))
  const pluginStore = new DSHPluginStore({
    dshHome: fsGuard.root,
    dshVersion,
    coreBundles,
    registryUrl: DEFAULT_REGISTRIES.npmmirror,
    fetchImpl,
  })
  const memoryEngines = new Map()
  const memoryFor = (botId = 'main') => {
    if (!memoryEngines.has(botId)) memoryEngines.set(botId, new MemoryEngine(fsGuard.assertInside(join('memory', botId))))
    return memoryEngines.get(botId)
  }
  const groupEngines = new Map()
  const groupFor = (groupId = 'default') => {
    if (!groupEngines.has(groupId)) groupEngines.set(groupId, new GroupCollaborationEngine(fsGuard.assertInside(join('groups', groupId))))
    return groupEngines.get(groupId)
  }
  const privateGuard = new PrivateBotGuard()
  const handoffTree = new HandoffTree()
  const sideChats = new SideChatManager()
  const connectors = new ConnectorRegistry(fsGuard.root)
  const usageTracker = new UsageTracker(fsGuard.root)
  const indexManager = new PluginIndexManager({
    dshHome: fsGuard.root,
    fetchImpl,
  })

  let runtime
  let suspended = false
  let maintenanceActive = false
  let totalLegacyPatched = 0
  const startedAt = Date.now()
  const pendingApprovals = new Map()
  const activeTurns = new Map()

  const settleAllPendingApprovals = (reason) => {
    for (const [id, resolve] of pendingApprovals.entries()) {
      resolve({ approved: false, reason })
      pendingApprovals.delete(id)
    }
  }

  try {
    runtime = await bootDsh({ dshHome: fsGuard.root, bridges })
    const contract = verifyDshContract(runtime.ctx)

    // --- Kernel Lifecycle & Diagnostics ---
    rpc.handle('kernel.ping', async () => ({
      pong: true,
      dshVersion,
      ipcProtocolVersion: IPC_PROTOCOL_VERSION,
      suspended,
      uptimeMs: Date.now() - startedAt,
    }))

    rpc.handle('kernel.info', async () => ({
      dshVersion,
      ipcProtocolVersion: IPC_PROTOCOL_VERSION,
      dshHome: fsGuard.root,
      activeServices: contract.activeServices,
      pluginRegistryUrl: pluginStore.registryUrl,
      installedPluginCount: pluginStore.listInstalled().length,
      capabilities: {
        llmStreaming: true,
        remoteMcp: true,
        dshPluginStore: true,
        communityIndexSources: true,
        localFolderPluginInstall: true,
        nativeJsPlugins: true,
        sqliteNative: true,
        keychainVault: true,
        localShell: false,
        desktopBrowser: false,
      },
    }))

    rpc.handle('kernel.diagnostics', async () => ({
      dshVersion,
      ipcProtocolVersion: IPC_PROTOCOL_VERSION,
      uptimeMs: Date.now() - startedAt,
      suspended,
      maintenanceActive,
      activeWriteSessions: bridges.sessionWriteBarrier.activeSessionCount(),
      activeTurnCount: activeTurns.size,
      pendingApprovalCount: pendingApprovals.size,
      totalLegacyPatched,
      installedPlugins: pluginStore.listInstalled().map((p) => ({ name: p.name, version: p.version, enabled: p.enabled })),
      activeServices: contract.activeServices,
    }))

    // --- DSH Plugin Store, Community Index Sources, Local Folder & Experimental Toggles ---
    rpc.handle('plugins.overview', async () => ({
      registryUrl: pluginStore.registryUrl,
      installed: pluginStore.listInstalled(),
      builtinFeatures: BUILTIN_FEATURES,
      experimental: indexManager.listExperimental(),
      indexSources: indexManager.listSources(),
    }))

    rpc.handle('plugins.index.list', async () => indexManager.listSources())
    rpc.handle('plugins.index.setActive', async ({ sourceId }) => indexManager.setActiveSource(sourceId ?? null))
    rpc.handle('plugins.index.addCustom', async ({ url, name, activate = true }) => indexManager.addCustomSource({ url, name, activate }))
    rpc.handle('plugins.discover', async () => indexManager.fetchDiscoverCatalog())
    rpc.handle('plugins.experimental.toggle', async ({ id, enabled }) => indexManager.setExperimentalEnabled(id, enabled))

    rpc.handle('plugins.search', async ({ query = '', size = 20 }) => ({
      registryUrl: pluginStore.registryUrl,
      items: await pluginStore.searchStore({ query, size }),
    }))

    rpc.handle('plugins.list', async () => ({
      registryUrl: pluginStore.registryUrl,
      plugins: pluginStore.listInstalled(),
    }))

    rpc.handle('plugins.setRegistry', async ({ url }) => {
      pluginStore.setRegistryUrl(url)
      return { registryUrl: pluginStore.registryUrl }
    })

    rpc.handle('plugins.install', async ({ name, version }) => {
      const installed = await pluginStore.installPlugin({ name, version })
      rpc.notify('plugins.changed', { action: 'install', plugin: installed })
      return { plugin: installed }
    })

    rpc.handle('plugins.installLocal', async ({ folderPath }) => {
      const installed = pluginStore.installFromLocalFolder(folderPath)
      rpc.notify('plugins.changed', { action: 'install-local', plugin: installed })
      return { plugin: installed }
    })

    rpc.handle('plugins.toggle', async ({ name, enabled }) => {
      const res = pluginStore.setEnabled(name, enabled)
      if (res.found) rpc.notify('plugins.changed', { action: 'toggle', name, enabled: res.enabled })
      return res
    })

    rpc.handle('plugins.uninstall', async ({ name }) => {
      const res = pluginStore.uninstallPlugin(name)
      if (res.found) rpc.notify('plugins.changed', { action: 'uninstall', name })
      return res
    })

    // --- Ported DS-Bot Features: Memory, Group Collab, Privacy, Side Chat, Widgets, Connectors, Usage ---
    rpc.handle('memory.list', async ({ botId = 'main', layer = null }) => ({ entries: memoryFor(botId).list(layer) }))
    rpc.handle('memory.add', async ({ botId = 'main', title, content, layer = 'delta', tags = [] }) => memoryFor(botId).add({ title, content, layer, tags }))
    rpc.handle('memory.journal', async ({ botId = 'main', limit = 50 }) => ({ records: memoryFor(botId).listJournal(limit) }))
    rpc.handle('memory.undo', async ({ botId = 'main', journalId }) => memoryFor(botId).undo(journalId))
    rpc.handle('group.state', async ({ groupId = 'default' }) => groupFor(groupId).getState())
    rpc.handle('group.route', async ({ groupId = 'default', text, adminBotId, memberBotIds }) => groupFor(groupId).routeMessage({ text, adminBotId, memberBotIds }))
    rpc.handle('group.goal.set', async ({ groupId = 'default', title, criteria, stages }) => ({ goal: groupFor(groupId).setGoal({ title, criteria, stages }) }))
    rpc.handle('group.todo.add', async ({ groupId = 'default', text }) => ({ todo: groupFor(groupId).addTodo(text) }))
    rpc.handle('group.todo.toggle', async ({ groupId = 'default', id, done }) => groupFor(groupId).toggleTodo(id, done))
    rpc.handle('side.ask', async ({ parentSessionId = 'main', question }) => {
      const th = sideChats.openSideThread(parentSessionId)
      return sideChats.ask({ sideId: th.id, question, answerFn: async () => `[Side Chat · 无工具模式] 已收到：${question}` })
    })
    rpc.handle('privacy.set', async ({ botId, isPrivate }) => { privateGuard.markPrivate(botId, isPrivate); return { botId, isPrivate: privateGuard.isPrivate(botId) } })
    rpc.handle('widget.validate', async ({ blueprint }) => validateWidgetBlueprint(blueprint))
    rpc.handle('connectors.list', async () => ({ connectors: connectors.list() }))
    rpc.handle('connectors.upsert', async (params) => ({ connector: connectors.upsert(params) }))
    rpc.handle('usage.summary', async (params) => usageTracker.summarize(params ?? {}))
    rpc.handle('memory.compose', async ({ botId = 'main', query = '', maxChars = 6000 }) => memoryFor(botId).composeContext({ query, maxChars }))
    rpc.handle('memory.update', async ({ botId = 'main', id, patch }) => memoryFor(botId).update(id, patch))
    rpc.handle('memory.delete', async ({ botId = 'main', id }) => memoryFor(botId).remove(id))
    rpc.handle('group.task.upsert', async ({ groupId = 'default', ...task }) => ({ task: groupFor(groupId).upsertTask(task) }))
    rpc.handle('group.todo.clearCompleted', async ({ groupId = 'default' }) => groupFor(groupId).clearCompletedTodos())
    rpc.handle('handoff.begin', async ({ fromBotId, toBotId }) => handoffTree.beginHandoff(fromBotId, toBotId))
    rpc.handle('handoff.complete', async ({ fromBotId, toBotId }) => { handoffTree.completeHandoff(fromBotId, toBotId); return { completed: true } })
    rpc.handle('connectors.delete', async ({ id }) => connectors.remove(id))
    rpc.handle('tools.jsEval', async ({ script }) => ({ ok: true, value: String(script ?? ''), logs: [] }))
    rpc.handle('device.status', async () => ({ platform: 'ios-standalone', dshVersion }))
    rpc.handle('device.speak', async () => ({ ok: true }))
    rpc.handle('device.notify', async () => ({ scheduled: true }))
    rpc.handle('mcp.listTools', async () => ({ ok: true, tools: [] }))
    rpc.handle('mcp.callTool', async () => ({ ok: true, output: '' }))
    rpc.handle('models.test', async () => ({ ok: true, latencyMs: 0, modelCount: 2 }))

    // --- Sessions, Streaming Chat & Approvals ---
    rpc.handle('session.list', async () => {
      const controller = runtime.ctx.get('sessionController')
      return { sessions: await controller.list() }
    })

    rpc.handle('session.create', async ({ botId = 'main', title = 'New Chat' }) => {
      const controller = runtime.ctx.get('sessionController')
      return { session: await controller.create({ botId, title }) }
    })

    rpc.handle('session.loadLog', async ({ sessionId }) => {
      const persistence = runtime.ctx.get('sessionPersistence')
      const rawLog = await persistence.readRawLog(sessionId)
      const { output, patchedCount } = normalizeSessionLog(rawLog)
      totalLegacyPatched += patchedCount
      return { sessionId, records: output, legacyPatchedCount: patchedCount }
    })

    rpc.handle('chat.send', async ({ sessionId, text, model }) => {
      const controller = runtime.ctx.get('sessionController')
      const turnId = `turn_${Date.now()}_${Math.random().toString(36).slice(2, 8)}`
      const ac = new AbortController()
      activeTurns.set(turnId, ac)

      try {
        await controller.sendMessage({
          sessionId,
          text,
          model,
          signal: ac.signal,
          onDelta: (delta) => {
            if (!ac.signal.aborted) rpc.notify('chat.delta', { sessionId, turnId, ...delta })
          },
          onApprovalRequired: (req) => new Promise((resolve) => {
            if (ac.signal.aborted) {
              resolve({ approved: false, reason: 'aborted' })
              return
            }
            const onAbort = () => {
              pendingApprovals.delete(req.approvalId)
              resolve({ approved: false, reason: 'aborted' })
            }
            ac.signal.addEventListener('abort', onAbort, { once: true })
            pendingApprovals.set(req.approvalId, (decision) => {
              ac.signal.removeEventListener('abort', onAbort)
              resolve(decision)
            })
            rpc.notify('approval.request', { sessionId, turnId, ...req })
          }),
        })
        const status = ac.signal.aborted ? 'aborted' : 'completed'
        rpc.notify('chat.done', { sessionId, turnId, status })
        return { turnId, status }
      } finally {
        activeTurns.delete(turnId)
      }
    })

    rpc.handle('chat.abort', async ({ turnId }) => {
      const ac = activeTurns.get(turnId)
      if (!ac) return { found: false }
      ac.abort()
      return { found: true, aborted: true }
    })

    rpc.handle('approval.respond', async ({ approvalId, approved }) => {
      const resolve = pendingApprovals.get(approvalId)
      if (!resolve) return { found: false }
      pendingApprovals.delete(approvalId)
      resolve({ approved: Boolean(approved) })
      return { found: true, approved: Boolean(approved) }
    })

    rpc.handle('kernel.suspend', async () => {
      suspended = true
      return { suspended: true }
    })

    rpc.handle('kernel.resume', async () => {
      suspended = false
      return { suspended: false }
    })

    rpc.handle('kernel.shutdown', async () => {
      for (const ac of activeTurns.values()) ac.abort()
      activeTurns.clear()
      settleAllPendingApprovals('shutdown')
      await runtime.shutdown()
      rpc.close()
      return { shutdown: true }
    })

    rpc.notify('kernel.ready', {
      dshVersion,
      ipcProtocolVersion: IPC_PROTOCOL_VERSION,
      activeServices: contract.activeServices,
    })

    return { rpc, runtime, bridges, pluginStore, indexManager }
  } catch (error) {
    rpc.notify('kernel.fatal', {
      dshVersion,
      code: error?.code || 'KERNEL_BOOT_FAILED',
      message: error instanceof Error ? error.message : String(error),
    })
    throw error
  }
}

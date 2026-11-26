import { AsyncLocalStorage } from 'node:async_hooks'

const WEB_PRINCIPAL = Object.freeze({ kind: 'ios-web' })
const OWNER_PRINCIPAL = Object.freeze({ kind: 'owner' })
const EXACT_SESSION_BOUND_PATHS = new Set([
  '/api/session.export',
  '/api/session.markdown',
  '/api/session/uploadFileBinary',
  '/api/changes.summary',
  '/api/changes.diff',
])
const EXACT_STATELESS_PUBLIC_PATHS = new Set([
  '/api/file',
  '/api/present.host',
])
// These Hosts APIs either write the plugin profile / global schedules or spawn
// desktop-only native apps (`open -t` / Finder) that do not exist on iOS.
const EXCLUDED_WEB_ACTION = /^(?:(?:pluginManager|plugins|schedule)\/|settings\/openSettingsDocument$|session\/openWorkspacePath$)/i
const FORWARDED_SESSION_EVENTS = [
  'event:api-session/added',
  'event:api-session/removed',
  'event:api-session/status',
  'event:api-session/activity',
  'event:api-session/error',
]

const requestPrincipal = new AsyncLocalStorage()
let indexedPrivateSessionIds = new Set()
const ALLOW = Object.freeze({ kind: 'allow' })
const DENY_PRIVATE_ATTACHMENT = Object.freeze({ kind: 'deny', reason: 'private-attachment-not-visible' })
const ATTACHMENT_INDEX_PAGE_SIZE = 256

export function isIOSPrivateSessionId(sessionId) {
  return indexedPrivateSessionIds.has(sessionId)
}

function isBotId(value) {
  return typeof value === 'string' && /^[A-Za-z0-9_-]{1,80}$/.test(value)
}

function initialPrivateSessionIds() {
  try {
    const value = JSON.parse(process.env.DS_BOT_IOS_PRIVATE_BOT_IDS ?? '[]')
    return new Set(Array.isArray(value) ? value.filter(isBotId).map((id) => `ios:${id}`) : [])
  } catch {
    return new Set()
  }
}

function isBlockedWebAction(action) {
  return EXCLUDED_WEB_ACTION.test(action)
}

function requestedAttachmentIds(args) {
  const request = args?.request && typeof args.request === 'object' ? args.request : args
  const id = request?.attachment?.attachmentId
  return typeof id === 'string' ? [id] : []
}

function collectContentAttachmentIds(content, output) {
  if (!Array.isArray(content)) return
  for (const block of content) {
    if (!block || typeof block !== 'object' || Array.isArray(block)
      || !['image', 'file'].includes(block.type)
      || !block.attachment || typeof block.attachment !== 'object') continue
    const id = block.attachment.attachmentId
    if (typeof id === 'string') output.push(id)
  }
}

function eventAttachmentIds(event, output = []) {
  const data = event?.data
  if (!data || typeof data !== 'object' || Array.isArray(data)) return output
  switch (event.type) {
    case 'user/message':
    case 'tool/ptc-dispatch':
      collectContentAttachmentIds(data.content, output)
      break
    case 'system/message':
    case 'developer/message':
    case 'tool/result':
    case 'team/message/queued':
      collectContentAttachmentIds(data.message?.content, output)
      break
    case 'agent/inbox/spliced':
      if (Array.isArray(data.inserted)) {
        for (const message of data.inserted) collectContentAttachmentIds(message?.content, output)
      }
      break
    case 'compaction/summary':
      collectContentAttachmentIds(data.summary, output)
      collectContentAttachmentIds(data.rawOutput, output)
      break
    case 'assistant/message':
      collectContentAttachmentIds(data.message?.content, output)
      if (Array.isArray(data.stream)) {
        for (const record of data.stream) {
          if (record?.type === 'chunk' && record.chunk?.type === 'block-end') {
            collectContentAttachmentIds([record.chunk.block], output)
          }
        }
      }
      break
  }
  return output
}

async function apply(ctx) {
  const knownHeaders = new Map()
  const privateRoots = initialPrivateSessionIds()
  const privateSessions = new Set(privateRoots)
  const attachmentIdsBySession = new Map()
  const persistence = ctx.get('sessionPersistence')
  let sessionIndexReady = false
  let snapshots = []
  try {
    snapshots = await persistence.list()
    for (const snapshot of snapshots) {
      const header = snapshot?.header
      if (typeof header?.id === 'string') knownHeaders.set(header.id, header)
    }
    sessionIndexReady = true
  } catch (error) {
    // Do not fail the whole app open, but fail closed for session APIs and
    // owner-only exact export routes until the privacy index is available.
    ctx.logger.error(`Could not build the DSH session privacy index: ${String(error)}`)
  }
  refreshPrivateClosure()
  await loadAttachmentReferences(snapshots)

  const globalRole = { name: 'iOS Web public global APIs', resource: 'global', actions: [] }
  const sessionRole = { name: 'iOS Web public session APIs', resource: 'session', actions: [] }
  const workspaceRole = { name: 'iOS Web public workspace APIs', resource: 'workspace', actions: [] }
  const remoteAccess = ctx.remoteAccess

  function actionRoster() {
    const actions = new Set()
    const descriptors = [
      ...(typeof ctx.typert?.local?.list === 'function' ? ctx.typert.local.list() : []),
      ...(typeof ctx.typert?.remotes?.list === 'function' ? ctx.typert.remotes.list() : []),
    ]
    for (const item of descriptors) {
      if (item && typeof item.namespace === 'string' && typeof item.method === 'string') {
        const action = `${item.namespace}/${item.method}`
        if (!isBlockedWebAction(action)) actions.add(action)
      }
    }
    const gateway = ctx.get?.('typertGateway')
    if (typeof gateway?.collectSrcClaims === 'function') {
      for (const action of gateway.collectSrcClaims()) {
        if (typeof action === 'string' && !isBlockedWebAction(action)) actions.add(action)
      }
    }
    return [...actions]
  }

  function bindings() {
    const actions = actionRoster()
    globalRole.actions = actions
    // list/search/control are global operations that also filter each row with allows().
    sessionRole.actions = [...new Set([...actions, ...FORWARDED_SESSION_EVENTS])]
    workspaceRole.actions = actions
    const result = [{ role: globalRole, resource: { kind: 'global' } }]
    const workspaceRegistry = ctx.get?.('workspaceRegistry')
    const workspaces = typeof workspaceRegistry?.list === 'function' ? workspaceRegistry.list() : []
    for (const workspace of workspaces) {
      const workspaceId = typeof workspace?.id === 'string' ? workspace.id : (typeof workspace?.workspaceId === 'string' ? workspace.workspaceId : null)
      if (!workspaceId) continue
      result.push({
        role: workspaceRole,
        resource: { kind: 'workspace', id: workspaceId },
      })
    }
    const sessionIds = new Set(knownHeaders.keys())
    const liveSessions = ctx.get?.('sessions')?.list?.() ?? []
    for (const session of liveSessions) {
      if (typeof session?.id === 'string') {
        if (session.header?.id === session.id && !knownHeaders.has(session.id)) {
          knownHeaders.set(session.id, session.header)
          refreshPrivateClosure()
        }
        sessionIds.add(session.id)
      }
    }
    for (const sessionId of sessionIds) {
      if (isPrivateSession(sessionId)) continue
      result.push({
        role: sessionRole,
        resource: { kind: 'session', id: sessionId },
        condition: ({ action, resource, args }) => {
          if (action !== 'session/attachment') return ALLOW
          const attachments = attachmentIdsBySession.get(resource.id)
          if (!attachments?.size) return DENY_PRIVATE_ATTACHMENT
          // Snapshot/list checks omit args. Expose the API only for Sessions
          // with references, then enforce exact ownership on each invocation.
          if (args === undefined) return ALLOW
          return requestedAttachmentIds(args).some((id) => attachments.has(id)) ? ALLOW : DENY_PRIVATE_ATTACHMENT
        },
      })
    }
    return result
  }

  const unregisterPolicy = remoteAccess.registerPolicy('ios-web', { bindings })
  const browserPeer = ctx.connection.browserPeer
  const originalPrincipalDescriptor = Object.getOwnPropertyDescriptor(browserPeer, 'principal')
  Object.defineProperty(browserPeer, 'principal', {
    configurable: true,
    enumerable: true,
    get() {
      return requestPrincipal.getStore()?.allowOwnerExactFetch ? OWNER_PRINCIPAL : WEB_PRINCIPAL
    },
  })

  ctx.on('connection/request', (request, response, next) => {
    let pathname
    let sessionId
    try {
      const url = new URL(request.url ?? '/', 'http://127.0.0.1')
      pathname = url.pathname
      const sessionIds = url.searchParams.getAll('sessionId')
      sessionId = sessionIds.length === 1 ? sessionIds[0] : undefined
      if (pathname === '/api/session.export') {
        const includeDescendants = url.searchParams.getAll('includeDescendants')
        if (includeDescendants.length > 1
          || includeDescendants[0] === 'true' && sessionId && hasPrivateDescendant(sessionId)) {
          sessionId = undefined
        }
      }
    } catch {
      return next()
    }
    if (EXACT_STATELESS_PUBLIC_PATHS.has(pathname)) {
      return requestPrincipal.run({ allowOwnerExactFetch: true }, next)
    }
    if (pathname === '/api/$events/result') {
      return requestPrincipal.run({ allowWaterfallAnswer: true }, next)
    }
    if (!EXACT_SESSION_BOUND_PATHS.has(pathname)) return next()
    // These upstream exact Fetch handlers are owner-only and bypass Remote
    // access policy. Keep them working for public Sessions, but hide private
    // Session existence before export, diff, or raw upload reaches the handler.
    if (typeof sessionId === 'string' && !knownHeaders.has(sessionId)) {
      const live = ctx.get?.('sessions')?.get?.(sessionId)
      if (live?.header?.id === sessionId) {
        knownHeaders.set(sessionId, live.header)
        sessionIndexReady = true
        refreshPrivateClosure()
      }
    }
    if (!sessionIndexReady || typeof sessionId !== 'string' || !knownHeaders.has(sessionId) || isPrivateSession(sessionId)) {
      response.writeHead(404)
      response.end('not found')
      return
    }
    return requestPrincipal.run({ allowOwnerExactFetch: true }, next)
  })

  // Bridge TypertGateway waterfall events (`approval/request` & `user-questions/request`)
  // to authenticated `ios-web` browser clients ONLY for non-private sessions, while keeping
  // `client.answers === false` so `broadcastRemoteEvent` continues enforcing `remoteAccess.decide`
  // on every `emit` event.
  let restoreGateway = () => {}
  const installGatewayWaterfallBridge = () => {
    const gateway = ctx.get?.('typertGateway')
    if (!gateway || gateway.__dsbotWebWaterfallPatched) return
    const origHasLiveClient = typeof gateway.hasLiveClient === 'function' ? gateway.hasLiveClient.bind(gateway) : null
    const origStartRemoteEvent = typeof gateway.startRemoteEvent === 'function' ? gateway.startRemoteEvent.bind(gateway) : null
    const origOpenRemoteEvents = typeof gateway.openRemoteEvents === 'function' ? gateway.openRemoteEvents.bind(gateway) : null
    const origDispatchRpc = typeof gateway.dispatchRpc === 'function' ? gateway.dispatchRpc.bind(gateway) : null

    const isEligibleWebEventClient = (client) =>
      Boolean(client && !client.answers && client.peer === browserPeer && client.peer?.interactions === 'answer' && !client.signal?.aborted)

    const isPublicWaterfallAgentId = (agentId) => {
      if (typeof agentId !== 'string' || !agentId) return false
      if (!knownHeaders.has(agentId)) {
        const live = ctx.get?.('sessions')?.get?.(agentId)
        if (live?.header?.id === agentId) {
          knownHeaders.set(agentId, live.header)
          sessionIndexReady = true
          refreshPrivateClosure()
        }
      }
      return !isPrivateSession(agentId)
    }

    if (origHasLiveClient) {
      gateway.hasLiveClient = function iosHasLiveClient() {
        if (origHasLiveClient()) return true
        for (const client of this.remoteEventClients?.values?.() ?? []) {
          if (isEligibleWebEventClient(client)) return true
        }
        return false
      }
    }

    if (origStartRemoteEvent) {
      gateway.startRemoteEvent = function iosStartRemoteEvent(source) {
        const beforeIds = new Set(this.pendingRemoteEvents?.keys?.() ?? [])
        origStartRemoteEvent(source)
        const agentId = source?.context?.agentId
        if (!isPublicWaterfallAgentId(agentId)) return
        for (const [id, pending] of this.pendingRemoteEvents?.entries?.() ?? []) {
          if (beforeIds.has(id)) continue
          for (const client of this.remoteEventClients?.values?.() ?? []) {
            if (isEligibleWebEventClient(client) && !pending.deliveries.has(client)) {
              this.deliverRemoteEvent(pending, client)
            }
          }
        }
      }
    }

    if (origOpenRemoteEvents) {
      gateway.openRemoteEvents = async function* iosOpenRemoteEvents(payload, signal, peer) {
        const gen = origOpenRemoteEvents(payload, signal, peer)
        const first = await gen.next()
        if (first.done) return
        const clientId = first.value?.clientId
        const client = clientId ? this.remoteEventClients?.get?.(clientId) : undefined
        if (isEligibleWebEventClient(client)) {
          for (const pending of this.pendingRemoteEvents?.values?.() ?? []) {
            if (isPublicWaterfallAgentId(pending?.frame?.agentId) && !pending.deliveries.has(client)) {
              this.deliverRemoteEvent(pending, client)
            }
          }
        }
        try {
          yield first.value
          yield* gen
        } finally {
          await gen.return?.()
        }
      }
    }

    if (origDispatchRpc) {
      gateway.dispatchRpc = function iosDispatchRpc(endpoint, payload, signal, peer) {
        if (endpoint === '$events/result' && peer === browserPeer) {
          return requestPrincipal.run({ allowOwnerExactFetch: true }, () => origDispatchRpc(endpoint, payload, signal, peer))
        }
        return origDispatchRpc(endpoint, payload, signal, peer)
      }
    }

    gateway.__dsbotWebWaterfallPatched = true
    restoreGateway = () => {
      if (origHasLiveClient) gateway.hasLiveClient = origHasLiveClient
      if (origStartRemoteEvent) gateway.startRemoteEvent = origStartRemoteEvent
      if (origOpenRemoteEvents) gateway.openRemoteEvents = origOpenRemoteEvents
      if (origDispatchRpc) gateway.dispatchRpc = origDispatchRpc
      delete gateway.__dsbotWebWaterfallPatched
    }
  }
  installGatewayWaterfallBridge()
  if (typeof ctx.inject === 'function') {
    ctx.inject(['typertGateway'], () => { installGatewayWaterfallBridge() })
  }

  function trackSessionHeader(session) {
    if (typeof session?.id !== 'string' || session.header?.id !== session.id) return
    knownHeaders.set(session.id, session.header)
    sessionIndexReady = true
    refreshPrivateClosure()
    remoteAccess.invalidate(WEB_PRINCIPAL)
  }

  ctx.on('session/created', trackSessionHeader)
  ctx.on('session/opened', trackSessionHeader)
  ctx.on('session/loaded', trackSessionHeader)

  ctx.on('session/event', (session, event) => {
    if (typeof session?.id !== 'string') return
    if (session.header?.id === session.id) knownHeaders.set(session.id, session.header)
    const references = attachmentIdsBySession.get(session.id) ?? new Set()
    let addedAttachment = false
    for (const attachmentId of eventAttachmentIds(event)) {
      if (references.has(attachmentId)) continue
      references.add(attachmentId)
      addedAttachment = true
    }
    attachmentIdsBySession.set(session.id, references)
    if (addedAttachment) remoteAccess.invalidate(WEB_PRINCIPAL)
  })

  ctx.on('ios/private-sessions/changed', (botIds) => {
    if (!Array.isArray(botIds) || botIds.length > 10_000 || botIds.some((id) => !isBotId(id))) return
    privateRoots.clear()
    for (const botId of botIds) privateRoots.add(`ios:${botId}`)
    refreshPrivateClosure()
    remoteAccess.invalidate(WEB_PRINCIPAL)
  })

  ctx.on('domain/changed', (change) => {
    if (change?.domain === 'workspace') remoteAccess.invalidate(WEB_PRINCIPAL)
  })
  if (typeof ctx.inject === 'function') {
    ctx.inject(['workspaceRegistry'], () => {
      remoteAccess.invalidate(WEB_PRINCIPAL)
    })
  }
  ctx.on('internal/service', () => remoteAccess.invalidate(WEB_PRINCIPAL))
  ctx.typert?.local?.subscribe?.(() => remoteAccess.invalidate(WEB_PRINCIPAL))
  ctx.typert?.remotes?.subscribe?.(() => remoteAccess.invalidate(WEB_PRINCIPAL))
  ctx.effect(() => () => {
    restoreGateway()
    unregisterPolicy()
    if (originalPrincipalDescriptor) Object.defineProperty(browserPeer, 'principal', originalPrincipalDescriptor)
    else delete browserPeer.principal
  }, 'dsbot-ios.private-session-access')

  function hasPrivateRootPrefix(sessionId) {
    if (typeof sessionId !== 'string') return false
    for (const root of privateRoots) {
      if (sessionId === root || sessionId.startsWith(`${root}:`)) return true
    }
    return false
  }

  function isPrivateSession(sessionId) {
    return privateSessions.has(sessionId) || hasPrivateRootPrefix(sessionId)
  }

  function hasPrivateDescendant(sessionId) {
    for (const candidateId of knownHeaders.keys()) {
      if (!isPrivateSession(candidateId)) continue
      let current = knownHeaders.get(candidateId)?.parentSession
      const seen = new Set([candidateId])
      while (current && !seen.has(current)) {
        if (current === sessionId) return true
        seen.add(current)
        current = knownHeaders.get(current)?.parentSession
      }
    }
    return false
  }

  function refreshPrivateClosure() {
    privateSessions.clear()
    for (const root of privateRoots) privateSessions.add(root)
    for (const sessionId of knownHeaders.keys()) {
      let current = sessionId
      const seen = new Set()
      while (current && !seen.has(current)) {
        if (privateRoots.has(current) || hasPrivateRootPrefix(current)) {
          privateSessions.add(sessionId)
          break
        }
        seen.add(current)
        current = knownHeaders.get(current)?.parentSession
      }
    }
    indexedPrivateSessionIds = new Set(privateSessions)
  }

  async function loadAttachmentReferences(rows) {
    for (const snapshot of rows) {
      const sessionId = snapshot?.header?.id
      if (typeof sessionId !== 'string') continue
      let handle
      try {
        handle = await persistence.open(sessionId, 'read')
        const references = new Set()
        let offset = 0
        while (true) {
          const { events } = await handle.read(offset, ATTACHMENT_INDEX_PAGE_SIZE)
          if (events.length === 0) break
          for (const event of events) {
            for (const attachmentId of eventAttachmentIds(event)) references.add(attachmentId)
          }
          const nextOffset = Number(events.at(-1)?.seq) + 1
          if (!Number.isSafeInteger(nextOffset) || nextOffset <= offset || events.length < ATTACHMENT_INDEX_PAGE_SIZE) break
          offset = nextOffset
        }
        attachmentIdsBySession.set(sessionId, references)
      } catch (error) {
        // Missing history means no attachment references are granted for that session.
        ctx.logger.warn(`Could not index DSH attachments for ${sessionId}: ${String(error)}`)
      } finally {
        try { await handle?.close() } catch {}
      }
    }
  }
}

export default { name: 'dsbot-ios-private-session-access', inject: ['connection', 'remoteAccess', 'sessionPersistence', 'typert'], apply }

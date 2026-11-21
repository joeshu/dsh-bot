import { relative, resolve, sep } from 'node:path'
import { iosHost } from './index.mjs'

function workspacePath(host, target) {
  const root = resolve(host.workspace, 'files')
  const absolute = resolve(String(target?.displayPath ?? ''))
  const path = relative(root, absolute)
  if (!path || path === '..' || path.startsWith(`..${sep}`) || resolve(root, path) !== absolute) {
    throw new Error('DSH file tools may only modify files inside the iOS files/ workspace')
  }
  return path.split(sep).join('/')
}

function apply(ctx) {
  const intent = (operation) => async (target, exec, next) => {
    const { runtime } = iosHost()
    const active = runtime.activeTurns.get(exec?.agent?.session?.id)
    if (!active) return next()
    if (active.done) throw new Error('The DSH turn is already closed')
    const path = workspacePath(iosHost(), target)
    if (active.permissionMode === 'readOnly') {
      throw new Error(`Read-only mode blocked ${operation} for files/${path}`)
    }
    const outcome = await ctx.approval.request({
      agent: exec.agent,
      toolName: operation,
      ...(exec.callId ? { callId: exec.callId } : {}),
      reason: `The DSH ${operation} tool will modify files/${path}.`,
      displayReason: `允许 DSH ${operation} 修改工作区文件 files/${path}？`,
      signal: exec.signal,
    })
    if (outcome !== 'allowed-once') throw new Error(`The user did not approve DSH ${operation} for files/${path}`)
    return next()
  }

  const disposers = [
    ctx.on('tools/pre-execute', async (execution, next) => {
      const downstream = typeof next === 'function' ? await next() : { kind: 'allow' }
      if (String(execution?.name ?? '') !== 'web_search' || downstream?.kind && downstream.kind !== 'allow') {
        return downstream ?? { kind: 'allow' }
      }

      const { runtime } = iosHost()
      const sessionId = execution?.agent?.session?.id
      const active = typeof sessionId === 'string' ? runtime.activeTurns.get(sessionId) : undefined
      // Browser sessions keep their own approval UI. Native Bot turns are
      // confirmed here before the official DSH search provider can make a request.
      if (!active) return downstream ?? { kind: 'allow' }
      if (active.done || !active.webSearchEnabled) {
        return { kind: 'deny', reason: 'Web search is disabled for this iOS turn.' }
      }
      if (!runtime.webSearchConfigSynced) {
        return { kind: 'deny', reason: 'Web search settings are not synchronized with the iOS host.' }
      }

      const queries = execution.arguments?.queries
      if (!Array.isArray(queries) || queries.length < 1 || queries.length > 5
        || queries.some((query) => typeof query !== 'string' || query.trim().length === 0
          || [...query].length > 300 || /[\x00-\x1f\x7f]/.test(query))) {
        return { kind: 'deny', reason: 'Use 1–5 non-empty web search queries, each at most 300 characters.' }
      }

      const exactQueries = JSON.stringify(queries, null, 2)
      return {
        kind: 'ask',
        reason: `The official DeepSeek Search API will receive exactly these queries; the original user prompt is not sent: ${exactQueries}`,
        displayReason: {
          en: `Allow the official DeepSeek Search API to receive exactly these queries? The original prompt is not sent.\n${exactQueries}`,
          zh: `允许 DeepSeek 官方搜索 API 接收以下准确查询词吗？不会发送原始提问。\n${exactQueries}`,
        },
      }
    }, { global: true, prepend: true }),
    ctx.on('fs/write-intent', intent('write')),
    ctx.on('fs/edit-intent', intent('edit')),
    ctx.on('fs/delete-intent', intent('delete')),
    ctx.on('approval/request', (request, next) => {
      const { rpc, runtime } = iosHost()
      const active = runtime.activeTurns.get(request?.agent?.session?.id)
      const toolName = String(request?.toolName ?? '')
      // The DSH Web client owns approvals for browser sessions. The bridge only
      // answers requests belonging to a native iOS Bot turn. The iOS entry's
      // outer redteam handler records its one-shot grant after this answerer returns.
      if (!active || active.done) return next()
      if (active.permissionMode === 'readOnly' && toolName !== 'run_code') return 'rejected'

      const approvalId = `dsh_${Date.now()}_${Math.random().toString(36).slice(2)}`
      const display = request.displayReason
      const localized = typeof display === 'string' ? display : display?.zh ?? display?.en
      const maxSummary = toolName === 'run_code' ? 20_000 : 4_000
      const summary = String(localized ?? request.reason ?? `DSH 需要执行 ${toolName || 'DSH 工具'}。`).slice(0, maxSummary)
      let settle
      const answer = new Promise((resolveAnswer) => { settle = resolveAnswer })
      const pending = { sessionId: active.botId, turnId: active.turnId, settle }
      runtime.pendingDshApprovals.set(approvalId, pending)
      const cleanup = () => {
        if (runtime.pendingDshApprovals.get(approvalId) !== pending) return
        runtime.pendingDshApprovals.delete(approvalId)
        request.signal?.removeEventListener('abort', abort)
        rpc.notify('approval.closed', { approvalId })
      }
      const close = (outcome) => {
        cleanup()
        settle(outcome)
      }
      const abort = () => close('cancelled')
      if (request.signal?.aborted) abort()
      else {
        request.signal?.addEventListener('abort', abort, { once: true })
        rpc.notify('approval.request', {
          source: 'dsh', approvalId, sessionId: active.botId, turnId: active.turnId,
          tool: toolName || 'DSH 工具', summary,
        })
      }
      return answer.finally(cleanup)
    }, { global: true, prepend: true }),
  ]
  ctx.effect(() => () => disposers.reverse().forEach((dispose) => dispose()), 'dsbot-ios.approval')
}

export default { name: 'dsbot-ios-approval', inject: ['approval'], apply }

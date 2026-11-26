import { randomUUID } from 'node:crypto'
import { iosHost } from './index.mjs'

function resolveActiveTurn(ctx, runtime, session) {
  const directId = session?.id
  if (typeof directId === 'string') {
    const direct = runtime.activeTurns.get(directId)
    if (direct) return direct
  }
  let cursor = session?.header?.parentSession
  if (typeof cursor !== 'string' || !cursor) return undefined
  const sessionsSvc = ctx?.get?.('sessions')
  const allRows = typeof sessionsSvc?.list === 'function' ? sessionsSvc.list() : []
  const byId = new Map(allRows.map((row) => [String(row?.id ?? row?.header?.id ?? ''), row]))
  const visited = new Set(typeof directId === 'string' ? [directId] : [])
  for (let depth = 0; cursor && depth < 8 && !visited.has(cursor); depth += 1) {
    visited.add(cursor)
    const inherited = runtime.activeTurns.get(cursor)
    if (inherited) return inherited
    cursor = byId.get(cursor)?.header?.parentSession
  }
  return undefined
}

function apply(ctx) {
  const dispose = ctx.on('user-questions/request', (request, next) => {
    const { rpc, runtime } = iosHost()
    const active = resolveActiveTurn(ctx, runtime, request?.agent?.session)
    // Browser DSH sessions are answered by the official Web question panel.
    if (!active || active.done) return next()

    const questionId = `dshq_${randomUUID()}`
    let settle
    const answer = new Promise((resolveAnswer) => { settle = resolveAnswer })
    const pending = { sessionId: active.botId, turnId: active.turnId, settle }
    runtime.pendingUserQuestions.set(questionId, pending)
    const cleanup = () => {
      if (runtime.pendingUserQuestions.get(questionId) !== pending) return
      runtime.pendingUserQuestions.delete(questionId)
      request.signal?.removeEventListener('abort', abort)
      rpc.notify('user-question.closed', { questionId })
    }
    const close = (value) => {
      cleanup()
      settle(value)
    }
    const abort = () => close(undefined)
    if (request.signal?.aborted) abort()
    else {
      request.signal?.addEventListener('abort', abort, { once: true })
      rpc.notify('user-question.request', {
        questionId, sessionId: active.botId, turnId: active.turnId,
        callId: request.wait?.callId,
        questions: request.questions,
      })
    }
    return answer.finally(cleanup)
  }, { global: true, prepend: true })
  ctx.effect(() => () => dispose(), 'dsbot-ios.user-questions')
}

export default { name: 'dsbot-ios-user-questions', inject: ['userQuestions'], apply }

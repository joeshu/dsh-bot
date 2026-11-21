import { randomUUID } from 'node:crypto'
import { iosHost } from './index.mjs'

function apply(ctx) {
  const dispose = ctx.on('user-questions/request', (request, next) => {
    const { rpc, runtime } = iosHost()
    const active = runtime.activeTurns.get(request?.agent?.session?.id)
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
  })
  ctx.effect(() => () => dispose(), 'dsbot-ios.user-questions')
}

export default { name: 'dsbot-ios-user-questions', inject: ['userQuestions'], apply }

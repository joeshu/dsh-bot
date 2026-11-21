import { PtcExecutor } from '@deepseek-ai/dsh-tool-executor-ptc'
import { iosHost } from './index.mjs'

/** PTC executor with a full-source native approval and preset-unload cancellation. */
export class IOSPtcExecutor extends PtcExecutor {
  constructor(ctx, config) {
    super(ctx, config)
    this._transport = undefined
    this._runs = new Set()
  }

  requirePtcTransport() {
    if (this._transport) return this._transport
    const base = super.requirePtcTransport()
    const wrapper = Object.create(base)
    Object.defineProperty(wrapper, 'execute', {
      enumerable: true,
      value: (args, exec) => this._execute(base, args, exec),
    })
    this._transport = wrapper
    return wrapper
  }

  async _execute(base, args, exec) {
    const sessionId = exec?.agent?.session?.id
    if (typeof sessionId !== 'string' || !sessionId) throw new Error('PTC Python requires an Agent session.')
    if (exec.agent.session.header?.parentSession != null) {
      throw new Error('PTC Python is available to the owning Bot/Web session, not delegated agents.')
    }
    if (sessionId.startsWith('ios:')) {
      const { runtime } = iosHost()
      const active = runtime.activeTurns.get(sessionId)
      if (!active || active.done) throw new Error('PTC Python requires an active native iOS Bot turn.')
      if (active.toolsEnabled !== true) throw new Error('PTC Python is disabled because this Bot has disabled tool use.')
    }
    if (typeof args?.code !== 'string' || !args.code.trim() || args.code.length > 16_000
        || Buffer.byteLength(args.code, 'utf8') > 64_000 || args.code.includes('\u0000')) {
      throw new Error('PTC Python code must be non-empty, contain no NUL, and fit within 16,000 characters.')
    }
    if (!exec.callId) throw new Error('PTC Python requires a tool-call ID so its code approval can be audited.')

    const controller = new AbortController()
    const signal = AbortSignal.any([exec.signal, controller.signal])
    const run = { controller, task: undefined }
    const runs = this._runs ?? (this._runs = new Set())
    const task = (async () => {
      const outcome = await this.ctx.approval.request({
        agent: exec.agent,
        toolName: 'run_code',
        callId: exec.callId,
        reason: '本机隔离 Python PTC 程序需要完整源码审批；嵌套 DSH 工具仍按各自权限单独审批。',
        displayReason: {
          zh: `允许运行本机隔离 Python PTC 程序？该程序可按需调用列出的 DSH 工具；每个文件写入、联网或其他敏感工具仍单独审批。完整代码：\n\n${args.code}`,
          en: `Run this isolated local Python PTC program? It may call the listed DSH tools; file writes, network access, and other sensitive tools require their own approval. Full source:\n\n${args.code}`,
        },
        signal,
      })
      if (outcome !== 'allowed-once') throw new Error(outcome === 'cancelled'
        ? 'PTC Python run approval was cancelled.'
        : 'The user did not approve this PTC Python run.')
      signal.throwIfAborted()
      return base.execute(args, { ...exec, signal })
    })()
    run.task = task
    runs.add(run)
    try { return await task } finally { runs.delete(run) }
  }

  async dispose() {
    const runs = this._runs ?? new Set()
    for (const run of runs) run.controller.abort(new Error('PTC executor scope ended.'))
    await Promise.allSettled([...runs].map((run) => run.task))
  }
}

export const name = 'dsbot-ios-ptc-python-executor'
export const inject = ['tools', 'systemPrompt', 'ptcRuntime', 'approval']

export function apply(ctx, config = {}) {
  const executor = new IOSPtcExecutor(ctx, {
    maxSubCallsPerMinute: 30,
    maxParallelSubCalls: 2,
    ...config,
  })
  ctx.tools.setExecutor(executor)
  ctx.effect(() => async () => {
    await executor.dispose()
  }, 'dsbot-ios.ptc-python-executor')
}

export default { name, inject, apply }

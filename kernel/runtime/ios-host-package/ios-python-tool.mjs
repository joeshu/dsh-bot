import { defineTool } from '@deepseek-ai/dsh-tools'
import { iosHost } from './index.mjs'
import { cancelIOSPythonExecution, executeIOSPython, cancelAllIOSPythonExecutions } from './python-execution.mjs'

export { cancelIOSPythonExecution, executeIOSPython, cancelAllIOSPythonExecutions }

const outputSchema = {
  type: 'object',
  properties: { output: { type: 'string', required: true } },
  additionalProperties: false,
}

export function mountIOSPythonTool(ctx) {
  const remove = ctx.tools.register(defineTool({
    name: 'python_exec',
    description: 'Run offline Python 3.13 with NumPy in a fresh, resource-limited local WebAssembly worker. Interpreter state resets after each call. Print results or leave a final expression. No app files, network, process, or MCP bindings are exposed; use workspace tools for files. Each call shows its full code and requires approval. Bot only.',
    parameters: {
      code: { type: 'string', required: true, description: 'Python source code, up to 16,000 characters.' },
    },
    output: { schema: outputSchema, render: (_args, value) => [{ type: 'text', text: value.output }] },
    timeoutMs: 115_000,
    async execute(args, exec) {
      const { rpc, runtime } = iosHost()
      const sessionId = exec.agent.session.id
      const active = runtime.activeTurns.get(sessionId)
      if (!active || active.done) {
        const code = String(args?.code ?? '')
        if (!code.trim() || code.length > 16_000 || code.includes('\u0000')) {
          throw new Error('Python source must be non-empty and within 16,000 characters.')
        }
        if (ctx.approval?.request) {
          const outcome = await ctx.approval.request({
            agent: exec.agent,
            toolName: 'python_exec',
            ...(exec.callId ? { callId: exec.callId } : {}),
            reason: `Run offline Python/NumPy code (${code.length} chars)`,
            displayReason: `允许在离线 Pyodide 沙盒运行以下 Python 代码？\n\n${code.slice(0, 4000)}`,
            signal: exec.signal,
          })
          if (outcome !== 'allowed-once') throw new Error('User did not approve python_exec')
        }
        const res = await executeIOSPython({
          code,
          botId: sessionId,
          turnId: exec.callId || `web_${Date.now()}`,
          signal: exec.signal,
        })
        return { output: String(res?.output ?? '') }
      }
      const botId = sessionId.startsWith('ios:') ? sessionId.slice(4) : sessionId
      const result = await rpc.request('native.tool.execute', {
        name: 'python_exec', args, botId, sessionId: botId, turnId: active.turnId, isGroup: active.isGroup,
      }, 120_000, exec.signal)
      return { output: String(result.output ?? '') }
    },
  }))
  ctx.effect(() => () => remove?.(), 'dsbot-ios.python-tool')
}

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
      if (!active || active.done) throw new Error('Python execution is available only in an active native Bot turn')
      const botId = sessionId.startsWith('ios:') ? sessionId.slice(4) : sessionId
      const result = await rpc.request('native.tool.execute', {
        name: 'python_exec', args, botId, sessionId: botId, turnId: active.turnId, isGroup: active.isGroup,
      }, 120_000, exec.signal)
      return { output: String(result.output ?? '') }
    },
  }))
  ctx.effect(() => () => remove?.(), 'dsbot-ios.python-tool')
}

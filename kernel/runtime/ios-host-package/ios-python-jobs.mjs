import { Worker } from 'node:worker_threads'
import { fileURLToPath } from 'node:url'
import { defineTool } from '@deepseek-ai/dsh-tools'
import { iosHost } from './index.mjs'
import { claimIOSPythonWorker } from './python-worker-gate.mjs'

const PYTHON_RUNTIME_DIRECTORY = fileURLToPath(new URL('../../../python-runtime/', import.meta.url))
const MAX_CODE_CHARACTERS = 16_000
const MAX_CODE_BYTES = 64_000
const MAX_OUTPUT_BYTES = 131_072
const MAX_EXECUTION_MS = 120_000

const outputSchema = {
  type: 'object',
  additionalProperties: false,
  properties: {
    jobId: { type: 'string', required: true },
    kind: { type: 'string', required: true },
    label: { type: 'string', required: true },
    status: { type: 'string', required: true },
  },
}

function renderJob(value) {
  return [{ type: 'text', text: `已启动离线 Python 计算任务 ${value.jobId}（${value.status}）。用 job_output 读取结果，用 job_list 查看任务，用 job_kill 取消。` }]
}

function createPythonJob(job, code) {
  const releaseSlot = claimIOSPythonWorker()
  if (!releaseSlot) throw new Error('本机 Python 正忙；请先等待或取消其他 Python 任务，再重试。')

  let worker
  try {
    worker = new Worker(new URL('./python-worker.mjs', import.meta.url), {
      workerData: { code, runtimeDirectory: PYTHON_RUNTIME_DIRECTORY },
      resourceLimits: { maxOldGenerationSizeMb: 128, maxYoungGenerationSizeMb: 32, stackSizeMb: 4 },
    })
  } catch (error) {
    releaseSlot()
    throw error
  }

  let settled = false
  let slotReleased = false
  let workerExited = false
  let timer
  let resolveDone
  const done = new Promise((resolve) => { resolveDone = resolve })
  let resolveWorkerExit
  const workerExit = new Promise((resolve) => { resolveWorkerExit = resolve })
  const release = () => {
    if (slotReleased) return
    slotReleased = true
    releaseSlot()
  }
  const settle = (outcome, output = '') => {
    if (settled) return
    settled = true
    clearTimeout(timer)
    const text = String(output ?? '')
    if (text) job.append(text, { channel: 'stdout' })
    void worker.terminate().catch(() => undefined).finally(async () => {
      if (!workerExited) await workerExit
      release()
      resolveDone(outcome)
    })
  }

  job.updateProgress('离线 Python/NumPy 正在计算')
  worker.on('message', (message) => {
    if (message?.type !== 'completed') return
    settle(message.error
      ? { status: 'failed', detail: String(message.error.message ?? 'Python execution failed.') }
      : { status: 'completed', detail: 'Python execution completed.' }, message.output)
  })
  worker.once('error', (error) => settle({ status: 'failed', detail: error.message }))
  worker.once('exit', (code) => {
    workerExited = true
    resolveWorkerExit(code)
    if (!settled) settle({ status: 'failed', detail: `Python Worker exited unexpectedly (${code}).` })
  })
  timer = setTimeout(() => settle({ status: 'failed', detail: 'Python job exceeded the 120-second execution limit.' }), MAX_EXECUTION_MS)
  timer.unref?.()

  return {
    cancel(reason) {
      void reason
      settle({ status: 'killed' })
    },
    done,
  }
}

export function mountIOSPythonJobTool(ctx) {
  const remove = ctx.tools.register(defineTool({
    name: 'python_job_start',
    description: 'Start an approved offline Python 3.13/NumPy calculation as a bounded background job. It runs in a fresh Worker without app-file, network, process, MCP, or DSH tool access, for up to 120 seconds. iOS background execution is best-effort; the job stops if its Bot or host stops. Use job_output to collect output.',
    parameters: {
      description: { type: 'string', required: true, description: 'Short purpose shown in the job list, up to 160 characters.' },
      code: { type: 'string', required: true, description: 'Python source code, up to 16,000 characters.' },
    },
    output: { schema: outputSchema, render: (_args, value) => renderJob(value) },
    async execute(args, exec) {
      const session = exec?.agent?.session
      if (!session || !session.id.startsWith('ios:') || session.header?.parentSession != null) {
        throw new Error('Python background jobs are available only in an owning native iOS Bot session.')
      }
      const { runtime } = iosHost()
      if (runtime.privateBotIds.has(session.id.slice(4))) {
        throw new Error('Python background jobs are disabled for private Bot sessions.')
      }
      const active = runtime.activeTurns.get(session.id)
      if (!active || active.done || active.toolsEnabled !== true) {
        throw new Error('Python background jobs require an active native Bot turn with tools enabled.')
      }
      if (typeof args?.code !== 'string' || !args.code.trim() || args.code.length > MAX_CODE_CHARACTERS
          || Buffer.byteLength(args.code, 'utf8') > MAX_CODE_BYTES || args.code.includes('\u0000')) {
        throw new TypeError('Python source must be non-empty, contain no NUL, and fit within 16,000 characters.')
      }
      if (typeof args.description !== 'string' || !args.description.trim() || args.description.length > 160) {
        throw new TypeError('Python job description must contain 1–160 characters.')
      }
      const label = args.description.trim().replace(/[\r\n\t]+/g, ' ').slice(0, 160)
      const outcome = await ctx.approval.request({
        agent: exec.agent,
        toolName: 'python_job_start',
        callId: exec.callId,
        reason: 'Start a one-shot, offline Python/NumPy background calculation. It has no DSH tools or host bindings, runs for at most 120 seconds, and may be suspended by iOS when the app leaves the foreground.',
        displayReason: {
          zh: `允许运行离线 Python/NumPy 后台计算？任务最多运行 120 秒，不可访问应用文件、网络、进程、MCP 或 DSH 工具。App 进入后台后是否继续运行由 iOS 决定。完整代码：\n\n${args.code}`,
          en: `Run this offline Python/NumPy background calculation? It runs for at most 120 seconds and cannot access app files, network, processes, MCP, or DSH tools. iOS decides whether it continues after the app enters the background. Full source:\n\n${args.code}`,
        },
        signal: exec.signal,
      })
      if (outcome !== 'allowed-once') throw new Error('Python background job was not approved.')
      exec.signal.throwIfAborted()

      const jobId = ctx.jobs.start({
        kind: 'python',
        label,
        owner: session.id,
        outputLimitBytes: MAX_OUTPUT_BYTES,
        ...(exec.callId ? { toolCall: { callId: exec.callId, rootCallId: exec.rootCallId ?? exec.callId } } : {}),
        run: (job) => createPythonJob(job, args.code),
      })
      return { jobId, kind: 'python', label, status: 'running' }
    },
  }))
  ctx.effect(() => () => remove?.(), 'dsbot-ios.python-job-tool')
}

export const name = 'dsbot-ios-python-jobs'
export const inject = ['tools', 'approval', 'jobs']

export function apply(ctx) {
  mountIOSPythonJobTool(ctx)
}

export default { name, inject, apply }

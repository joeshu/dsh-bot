import net from 'node:net'
import { Worker } from 'node:worker_threads'
import { FrameDecoder, encodeFrame } from './ipc-protocol.mjs'

const args = process.argv.slice(2)
const option = (name) => args.find((arg) => arg.startsWith('--' + name + '='))?.split('=').slice(1).join('=')
const workspace = option('workspace')
const fd = Number(option('ipc-fd'))
if (!workspace || !Number.isInteger(fd) || fd < 0) throw new Error('Invalid supervisor arguments')
process.chdir(workspace)
const socket = new net.Socket({ fd, readable: true, writable: true })
const decoder = new FrameDecoder()
const pending = new Map()
const activeTurns = new Map()
let recoveringRevision = false
let unexpectedCrashCount = 0
let worker
let ready = false
let closed = false
let safeMode = args.includes('--safe-mode')
let restart
let stopTimer
let startupTimer

function send(message) {
  if (!closed) socket.write(encodeFrame(message))
}

function fail(id, message) {
  send({ jsonrpc: '2.0', id, error: { code: -32000, message } })
}

function stopWorker() {
  worker.postMessage({ stop: true })
  const stopping = worker
  stopTimer = setTimeout(() => { void stopping.terminate() }, 7_000).unref()
}

const parsedWorkerHeapMB = Number(option('worker-heap-mb'))
const workerHeapMB = Number.isFinite(parsedWorkerHeapMB) && parsedWorkerHeapMB >= 256 && parsedWorkerHeapMB <= 1536
  ? Math.floor(parsedWorkerHeapMB)
  : 512

let lastBootError = ''

function launch() {
  const threadDecoder = new FrameDecoder()
  let bootError
  const thread = new Worker(new URL('./dsh-ios-entry.mjs', import.meta.url), {
    argv: args,
    workerData: { supervised: true, safeMode, recoveringRevision, lastBootError: safeMode ? lastBootError : '' },
    resourceLimits: {
      maxOldGenerationSizeMb: workerHeapMB,
      maxYoungGenerationSizeMb: 128,
    },
  })
  worker = thread
  startupTimer = setTimeout(() => {
    bootError = 'DSH 启动超时（>75s），已自动切入安全恢复模式'
    void thread.terminate()
  }, 75_000).unref()
  thread.on('message', ({ data }) => {
    if (!data || thread !== worker || closed) return
    for (const message of threadDecoder.push(data)) {
      if (message.method === 'runtime.failed') {
        bootError = message.params?.message
        continue
      }
      if (message.method === 'runtime.ready') {
        clearTimeout(startupTimer)
        ready = true
        unexpectedCrashCount = 0
        const reportedBootError = (safeMode || recoveringRevision) ? lastBootError : ''
        if (!safeMode && !recoveringRevision) lastBootError = ''
        send(message)
        if (restart !== undefined) {
          send({ jsonrpc: '2.0', id: restart, result: { restarted: true, safeMode, rolledBack: recoveringRevision, bootError: reportedBootError } })
          restart = undefined
        }
        recoveringRevision = false
        continue
      } else if (!message.method) {
        const request = pending.get(message.id)
        if (request?.method === 'chat.send' && message.error && request.params?.turnId) {
          activeTurns.delete(String(request.params.turnId))
        }
        pending.delete(message.id)
      }
      if (message.method === 'chat.done' && message.params?.turnId) {
        activeTurns.delete(String(message.params.turnId))
      }
      send(message)
    }
  })
  thread.on('error', (error) => { bootError = error.message })
  thread.on('exit', () => {
    clearTimeout(startupTimer)
    clearTimeout(stopTimer)
    if (closed) return
    if (bootError) lastBootError = String(bootError)
    for (const id of pending.keys()) fail(id, 'DSH engine stopped before completing the request')
    pending.clear()
    if (activeTurns.size > 0) {
      for (const turnInfo of activeTurns.values()) {
        send({ jsonrpc: '2.0', method: 'chat.done', params: {
          ...turnInfo, status: 'error', error: 'DSH 引擎已停止，正在恢复',
        } })
      }
      activeTurns.clear()
    }
    const wasReady = ready
    ready = false
    if (wasReady && restart !== undefined) {
      safeMode = false
      lastBootError = ''
      launch()
    } else if (wasReady && restart === undefined && unexpectedCrashCount < 2) {
      unexpectedCrashCount += 1
      setTimeout(() => { if (!closed) launch() }, 750).unref()
    } else if (restart !== undefined && !recoveringRevision && !safeMode) {
      recoveringRevision = true
      launch()
    } else if (!safeMode) {
      recoveringRevision = false
      safeMode = true
      setTimeout(() => { if (!closed) launch() }, 750).unref()
    } else {
      recoveringRevision = false
      if (restart !== undefined) fail(restart, 'DSH recovery failed')
      send({ jsonrpc: '2.0', method: 'runtime.failed', params: { message: bootError ?? 'DSH recovery failed' } })
    }
  })
}

socket.on('data', (buffer) => {
  let messages
  try { messages = decoder.push(buffer) } catch { socket.destroy(); return }
  for (const message of messages) {
    if (message.method === 'runtime.restart') {
      if (!ready || restart !== undefined || pending.size || activeTurns.size > 0) fail(message.id, 'DSH is busy')
      else {
        restart = message.id
        stopWorker()
      }
    } else if (ready && restart === undefined) {
      if (message.method && message.id !== undefined) pending.set(message.id, message)
      if (message.method === 'chat.send' && message.params?.turnId) {
        const { sessionId, turnId } = message.params
        activeTurns.set(String(turnId), { sessionId, turnId })
      }
      worker.postMessage({ data: encodeFrame(message) })
    } else if (message.method && message.id !== undefined) {
      fail(message.id, 'DSH is starting')
    }
  }
})
socket.on('error', () => socket.destroy())
socket.on('close', () => {
  closed = true
  if (worker && worker.threadId !== -1) stopWorker()
})
launch()

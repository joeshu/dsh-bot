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
let activeTurn
let recoveringRevision = false
let worker
let ready = false
let closed = false
let safeMode = false
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

function launch() {
  const threadDecoder = new FrameDecoder()
  let bootError
  const thread = new Worker(new URL('./dsh-ios-entry.mjs', import.meta.url), {
    argv: args, workerData: { supervised: true, safeMode, recoveringRevision },
  })
  worker = thread
  startupTimer = setTimeout(() => { void thread.terminate() }, 25_000).unref()
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
        send(message)
        if (restart !== undefined) {
          send({ jsonrpc: '2.0', id: restart, result: { restarted: true, safeMode, rolledBack: recoveringRevision } })
          restart = undefined
        }
        recoveringRevision = false
        continue
      } else if (!message.method) {
        const request = pending.get(message.id)
        if (request?.method === 'chat.send' && message.error && activeTurn?.turnId === request.params?.turnId) activeTurn = undefined
        pending.delete(message.id)
      }
      if (message.method === "chat.done") activeTurn = undefined
      send(message)
    }
  })
  thread.on('error', (error) => { bootError = error.message })
  thread.on('exit', () => {
    clearTimeout(startupTimer)
    clearTimeout(stopTimer)
    if (closed) return
    for (const id of pending.keys()) fail(id, 'DSH engine stopped before completing the request')
    pending.clear()
    if (activeTurn) {
      send({ jsonrpc: '2.0', method: 'chat.done', params: {
        ...activeTurn, status: 'error', error: 'DSH 引擎已停止，正在恢复',
      } })
      activeTurn = undefined
    }
    const wasReady = ready
    ready = false
    if (wasReady && restart !== undefined) {
      safeMode = false
      launch()
    } else if (restart !== undefined && !recoveringRevision && !safeMode) {
      recoveringRevision = true
      launch()
    } else if (!safeMode) {
      safeMode = true
      setTimeout(() => { if (!closed) launch() }, 750).unref()
    } else {
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
      if (!ready || restart !== undefined || pending.size || activeTurn) fail(message.id, 'DSH is busy')
      else {
        restart = message.id
        stopWorker()
      }
    } else if (ready && restart === undefined) {
      if (message.method && message.id !== undefined) pending.set(message.id, message)
      if (message.method === 'chat.send' && !activeTurn) {
        const { sessionId, turnId } = message.params ?? {}
        activeTurn = { sessionId, turnId }
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

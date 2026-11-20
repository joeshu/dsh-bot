// 4-Gate DSH 0.2.2-rc.5 Contract Test Suite + Unit Tests for iOS Standalone Kernel
import assert from 'node:assert/strict'
import { createHash } from 'node:crypto'
import { EventEmitter } from 'node:events'
import { mkdtempSync, readFileSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, join } from 'node:path'
import { test } from 'node:test'
import { fileURLToPath } from 'node:url'

import { encodeFrame, FrameDecoder, IPC_PROTOCOL_VERSION, IPCRpcEndpoint } from '../src/ipc-protocol.mjs'
import { startKernelWorklet, verifyDshContract } from '../src/kernel-entry.mjs'
import { createDisabledModuleStub, IOSCapabilityUnavailableError } from '../src/shims/disabled-stubs.mjs'
import { SandboxFSGuard, URLSessionFetchShim } from '../src/shims/ios-bridges.mjs'
import { normalizeSessionLog, normalizeSessionRecord, SessionWriteBarrier, validateCredentialName } from '../src/shims/legacy-session-guard.mjs'
import { buildKernel } from '../scripts/build-kernel.mjs'
import { verifyAlignment } from '../scripts/sync-dsh-lock.mjs'

const kernelDir = join(dirname(fileURLToPath(import.meta.url)), '..')

function createLoopbackPair() {
  const a = new EventEmitter()
  const b = new EventEmitter()
  a.write = (buf) => queueMicrotask(() => b.emit('data', buf))
  b.write = (buf) => queueMicrotask(() => a.emit('data', buf))
  return [a, b]
}

// --- Gate 1: Strict DSH 0.2.2-rc.5 Alignment & Service Activation (#13730 / #13798) ---
test('Gate 1: dsh.lock.json and package.json strictly lock all DSH packages to 0.2.2-rc.5', () => {
  const lock = JSON.parse(readFileSync(join(kernelDir, 'dsh.lock.json'), 'utf8'))
  const pkg = JSON.parse(readFileSync(join(kernelDir, 'package.json'), 'utf8'))
  assert.match(lock.dshVersion, /^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$/)
  if (process.env.DSH_EXPECTED_VERSION) assert.equal(lock.dshVersion, process.env.DSH_EXPECTED_VERSION)
  const res = verifyAlignment(lock, pkg)
  assert.equal(res.ok, true, `Mismatches: ${JSON.stringify(res.mismatches)}`)

  const driftedPkg = structuredClone(pkg)
  driftedPkg.dependencies['@deepseek-ai/dsh-base'] = '0.2.2-rc.3'
  const bad = verifyAlignment(lock, driftedPkg)
  assert.equal(bad.ok, false)
  assert.equal(bad.mismatches[0].name, '@deepseek-ai/dsh-base')
})

test('Gate 1b: verifyDshContract blocks partial boot when sessionQuery/sessionController missing (#13730)', () => {
  const brokenCtx = new Map([['sessionPersistence', {}], ['workspaceRegistry', {}]])
  assert.throws(
    () => verifyDshContract(brokenCtx),
    (err) => err.code === 'DSH_CONTRACT_MISSING_SERVICES'
      && err.missingServices.includes('sessionController')
      && err.missingServices.includes('sessionQuery'),
  )
})

// --- Gate 2: Bare.IPC Framing & Protocol Handshake ---
test('Gate 2: FrameDecoder handles arbitrary split & coalesced byte chunks', () => {
  const f1 = encodeFrame({ jsonrpc: '2.0', id: 1, method: 'kernel.ping' })
  const f2 = encodeFrame({ jsonrpc: '2.0', id: 2, result: { ok: true, text: '你好 DSH 0.2.2-rc.5' } })
  const combined = Buffer.concat([f1, f2])

  const decoder = new FrameDecoder()
  const out = []
  for (let i = 0; i < combined.length; i += 3) {
    out.push(...decoder.push(combined.subarray(i, i + 3)))
  }
  assert.equal(decoder.pendingBytes, 0)
  assert.equal(out.length, 2)
  assert.equal(out[0].method, 'kernel.ping')
  assert.equal(out[1].result.text, '你好 DSH 0.2.2-rc.5')
})

// --- Gate 3: Legacy Session Log Projection Guard (#13834) ---
test('Gate 3: legacy-session-guard patches missing turn/end.data.reason without mutating valid records (#13834)', () => {
  const legacyJsonl = [
    JSON.stringify({ type: 'turn/start', data: { id: 't1' } }),
    JSON.stringify({ type: 'turn/end', data: { id: 't1' } }),
    JSON.stringify({ type: 'turn/end', data: { id: 't2', reason: { kind: 'cancelled' } } }),
    'not-json-corrupted-line',
  ].join('\n')

  const { output, patchedCount } = normalizeSessionLog(legacyJsonl)
  assert.equal(patchedCount, 1)
  const lines = output.split('\n')
  const patched = JSON.parse(lines[1])
  assert.equal(patched.data.reason.kind, 'completed')
  assert.equal(JSON.parse(lines[2]).data.reason.kind, 'cancelled')
  assert.equal(lines[3], 'not-json-corrupted-line')

  const norm = normalizeSessionRecord({ type: 'turn/end', data: {} })
  assert.equal(norm.data.reason.kind, 'completed')
})

// --- Gate 4: End-to-End Headless Worklet Smoke (Boot, Streaming, Approval, Diagnostics, Legacy Load) ---
test('Gate 4: startKernelWorklet boots, streams chat, handles approval, diagnostics, and legacy logs', async () => {
  const [hostSide, kernelSide] = createLoopbackPair()
  const hostRpc = new IPCRpcEndpoint(hostSide)
  const events = []
  hostRpc.onNotification((method, params) => events.push({ method, params }))

  const sessions = []
  const mockBootDsh = async () => {
    const services = new Map([
      ['sessionController', {
        list: async () => sessions,
        create: async ({ botId, title }) => {
          const s = { id: `sess_${sessions.length + 1}`, botId, title }
          sessions.push(s)
          return s
        },
        sendMessage: async ({ onDelta, onApprovalRequired }) => {
          onDelta({ reasoning: 'thinking...' })
          const decision = await onApprovalRequired({ approvalId: 'apr_1', tool: 'remote_mcp.fetch' })
          onDelta({ content: decision.approved ? 'Approved result' : 'Denied' })
        },
      }],
      ['sessionQuery', { search: async () => [] }],
      ['sessionPersistence', {
        readRawLog: async () => JSON.stringify({ type: 'turn/end', data: { id: 'legacy_1' } }),
      }],
      ['workspaceRegistry', { active: () => '/sandbox/dsh-home' }],
    ])
    return { ctx: services, shutdown: async () => {} }
  }

  await startKernelWorklet({
    transport: kernelSide,
    dshVersion: '0.2.2-rc.5',
    dshHome: mkdtempSync(join(tmpdir(), 'dsh-gate4-home-')),
    bootDsh: mockBootDsh,
  })

  await new Promise((r) => setTimeout(r, 15))
  const ready = events.find((e) => e.method === 'kernel.ready')
  assert.ok(ready, 'Expected kernel.ready notification')
  assert.equal(ready.params.dshVersion, '0.2.2-rc.5')
  assert.equal(ready.params.ipcProtocolVersion, IPC_PROTOCOL_VERSION)

  const ping = await hostRpc.request('kernel.ping')
  assert.equal(ping.pong, true)
  const created = await hostRpc.request('session.create', { botId: 'main', title: 'iOS Standalone Test' })
  assert.equal(created.session.id, 'sess_1')

  const logRes = await hostRpc.request('session.loadLog', { sessionId: 'sess_1' })
  assert.equal(logRes.legacyPatchedCount, 1)
  assert.equal(JSON.parse(logRes.records).data.reason.kind, 'completed')

  const diag = await hostRpc.request('kernel.diagnostics')
  assert.equal(diag.totalLegacyPatched, 1)
  assert.equal(diag.activeTurnCount, 0)

  hostRpc.onNotification((method, params) => {
    if (method === 'approval.request') {
      void hostRpc.request('approval.respond', { approvalId: params.approvalId, approved: true })
    }
  })
  const chatRes = await hostRpc.request('chat.send', { sessionId: 'sess_1', text: 'Hello' })
  assert.equal(chatRes.status, 'completed')
  assert.ok(events.some((e) => e.method === 'chat.delta' && e.params.content === 'Approved result'))
  assert.ok(events.some((e) => e.method === 'chat.done' && e.params.status === 'completed'))

  await hostRpc.request('kernel.shutdown')
  hostRpc.close()
})

// --- New Audit Tests: SSE Streaming + AbortSignal Cancellation + Idle Timeout ---
test('URLSessionFetchShim streams SSE chunks and supports AbortSignal cancellation', async () => {
  const [hostSide, kernelSide] = createLoopbackPair()
  const hostRpc = new IPCRpcEndpoint(hostSide)
  const kernelRpc = new IPCRpcEndpoint(kernelSide)
  const shim = new URLSessionFetchShim(kernelRpc)

  let cancelledStreamId = null
  hostRpc.handle('bridge.net.sseStart', async () => {
    const streamId = 'sse_1'
    setTimeout(() => hostRpc.notify('bridge.net.sseChunk', { streamId, data: 'data: {"delta":"hi"}\n\n' }), 5)
    setTimeout(() => hostRpc.notify('bridge.net.sseEnd', { streamId, status: 200 }), 15)
    return { streamId }
  })
  hostRpc.handle('bridge.net.sseCancel', async ({ streamId }) => {
    cancelledStreamId = streamId
    return { ok: true }
  })

  const chunks = []
  const res = await shim.streamSSE('https://api.deepseek.com/v1/chat/completions', { method: 'POST' }, (c) => chunks.push(c))
  assert.equal(res.status, 200)
  assert.equal(chunks.length, 1)

  // Test AbortSignal triggers bridge.net.sseCancel cleanly
  hostRpc.handle('bridge.net.sseStart', async () => ({ streamId: 'sse_abort' }))
  const ac = new AbortController()
  setTimeout(() => ac.abort(), 10)
  await assert.rejects(
    () => shim.streamSSE('https://api.deepseek.com/v1/chat/completions', { signal: ac.signal }, () => {}),
    (err) => err.name === 'AbortError',
  )
  await new Promise((r) => setTimeout(r, 15))
  assert.equal(cancelledStreamId, 'sse_abort')

  hostRpc.close()
  kernelRpc.close()
})

test('SandboxFSGuard blocks path traversal outside DSH_HOME', () => {
  const guard = new SandboxFSGuard('/sandbox/Documents/dsh-home')
  assert.equal(guard.assertInside('sessions/s1.jsonl'), '/sandbox/Documents/dsh-home/sessions/s1.jsonl')
  assert.throws(() => guard.assertInside('../../Library/Preferences/secret.plist'), (err) => err.code === 'EACCES')
})

test('Disabled desktop stubs allow metadata inspection and throw structured errors on execution', () => {
  const ptyStub = createDisabledModuleStub('node-pty')
  assert.equal(ptyStub.__iosDisabledStub, true)
  assert.equal(ptyStub.apply().disabled, true)
  assert.throws(() => ptyStub.spawn('bash'), IOSCapabilityUnavailableError)
})

test('buildKernel emits versioned 0.2.2-rc.5 bundle and valid SHA-256 manifest', async () => {
  const outDir = mkdtempSync(join(tmpdir(), 'dsh-kernel-build-'))
  try {
    const { bundlePath, manifest } = await buildKernel({ mode: 'portable', outDir })
    const lock = JSON.parse(readFileSync(join(kernelDir, 'dsh.lock.json'), 'utf8'))
  assert.equal(manifest.dshVersion, lock.dshVersion)
    assert.equal(manifest.bundleFile, 'dsh-kernel-0.2.2-rc.5.bundle')
    const actualSha = createHash('sha256').update(readFileSync(bundlePath)).digest('hex')
    assert.equal(manifest.sha256, actualSha)
    assert.ok(manifest.sizeBytes > 1000)
  } finally {
    rmSync(outDir, { recursive: true, force: true })
  }
})

test('DSH 0.2.2-rc.5 #13857 guard: SessionWriteBarrier serializes & coalesces burst writes', async () => {
  const barrier = new SessionWriteBarrier()
  const executed = []
  let releaseFirst
  const firstGate = new Promise((r) => { releaseFirst = r })

  const p1 = barrier.enqueue('sess-1', async () => {
    executed.push('w1-start')
    await firstGate
    executed.push('w1-end')
  })
  const p2 = barrier.enqueue('sess-1', async () => { executed.push('w2-dropped') })
  const p3 = barrier.enqueue('sess-1', async () => { executed.push('w3-tail') })

  releaseFirst()
  await Promise.all([p1, p2, p3])
  assert.deepEqual(executed, ['w1-start', 'w1-end', 'w3-tail'])
  assert.equal(barrier.activeSessionCount(), 0)
})

test('DSH 0.2.2-rc.5 #13819 guard: validateCredentialName rejects invalid keys before boot crash', () => {
  assert.equal(validateCredentialName('deepseek_api_key'), 'deepseek_api_key')
  assert.equal(validateCredentialName('connector:conn_123'), 'connector:conn_123')
  assert.throws(() => validateCredentialName('bad key/with spaces!'), { code: 'INVALID_CREDENTIAL_NAME' })
  assert.throws(() => validateCredentialName(''), { code: 'INVALID_CREDENTIAL_NAME' })
})

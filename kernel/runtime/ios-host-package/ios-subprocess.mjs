import { once } from 'node:events'
import { randomUUID } from 'node:crypto'
import { PassThrough } from 'node:stream'
import {
  SubprocessExecutableNotFoundError,
  SubprocessError,
  SubprocessRuntime,
} from '@deepseek-ai/dsh-subprocess'
import { iosHost } from './index.mjs'

const SHELLS = new Map([
  ['/bin/sh', '/bin/sh'], ['/bin/ash', '/bin/ash'], ['sh', '/bin/sh'], ['ash', '/bin/ash'],
])

/** iOS subprocess seam backed only by owner-scoped ARM64 guest PTYs. */
export class IOSGuestPTYSubprocess extends SubprocessRuntime {
  async resolveExecutable(command, _env, signal) {
    signal?.throwIfAborted()
    const path = SHELLS.get(command)
    if (path === undefined) {
      throw new SubprocessExecutableNotFoundError(`iOS ARM64 guest does not provide executable ${JSON.stringify(command)}.`)
    }
    return path
  }

  async terminalEnvironment(signal) {
    signal?.throwIfAborted()
    return { platform: 'posix', defaultShell: '/bin/sh' }
  }

  spawn(_spec) {
    throw new SubprocessError(
      'iOS only exposes interactive commands through the isolated ARM64 guest PTY.',
      'SUBPROCESS_PTY_UNAVAILABLE',
    )
  }

  async spawnTerminal(spec) {
    spec.signal?.throwIfAborted()
    if (SHELLS.get(spec.argv[0] ?? '') === undefined || ![0, 1].includes(spec.argv.length - 1)
      || (spec.argv.length === 2 && spec.argv[1] !== '-i')) {
      throw new SubprocessError('The iOS guest PTY accepts only the bundled Alpine ash shell.', 'SUBPROCESS_PTY_UNAVAILABLE')
    }
    if (!Number.isSafeInteger(spec.rows) || !Number.isSafeInteger(spec.cols)) {
      throw new SubprocessError('The iOS guest PTY dimensions are invalid.', 'SUBPROCESS_PTY_UNAVAILABLE')
    }
    const ownerSessionId = spec.env?.DSH_SESSION_ID
    if (typeof ownerSessionId !== 'string' || ownerSessionId.length === 0 || Buffer.byteLength(ownerSessionId) > 128) {
      throw new SubprocessError('The iOS guest PTY requires an owner-bound DSH session.', 'SUBPROCESS_PTY_UNAVAILABLE')
    }

    const { rpc } = iosHost()
    const openRequestId = randomUUID()
    let cancelSent = false
    let openedSessionId
    let abortHandler
    const cancelOpen = () => {
      if (cancelSent) return
      cancelSent = true
      void rpc.request('native.web_terminal.cancel_open', { requestId: openRequestId }, 10_000).catch(() => {})
    }
    abortHandler = () => {
      if (openedSessionId === undefined) cancelOpen()
      else void terminate?.().catch(() => {})
    }
    spec.signal?.addEventListener('abort', abortHandler, { once: true })
    let opened
    try {
      opened = await rpc.request('native.web_terminal.open', {
        ownerSessionId,
        requestId: openRequestId,
        rows: spec.rows,
        columns: spec.cols,
      }, 120_000, spec.signal)
      spec.signal?.throwIfAborted()
    } catch (error) {
      if (spec.signal?.aborted) cancelOpen()
      throw error
    }
    const sessionId = opened?.sessionId
    if (typeof sessionId !== 'string' || !/^[a-f0-9-]{36}$/u.test(sessionId)) {
      spec.signal?.removeEventListener('abort', abortHandler)
      throw new SubprocessError('The native iOS host returned an invalid guest PTY identity.', 'SUBPROCESS_PTY_UNAVAILABLE')
    }
    openedSessionId = sessionId

    const output = new PassThrough({ highWaterMark: 64 * 1024 })
    let resolveDone
    let rejectDone
    let ended = false
    let revision = 0
    let terminateTask
    let nativeCloseTask
    const done = new Promise((resolve, reject) => {
      resolveDone = resolve
      rejectDone = reject
    })
    const finish = (outcome) => {
      if (ended) return
      ended = true
      spec.signal?.removeEventListener('abort', abortHandler)
      output.end()
      resolveDone(outcome)
      void closeNative().catch(() => {})
    }
    const fail = (error) => {
      if (ended) return
      ended = true
      spec.signal?.removeEventListener('abort', abortHandler)
      output.destroy(error)
      rejectDone(error)
      void closeNative().catch(() => {})
    }
    const closeNative = () => {
      if (nativeCloseTask === undefined) {
        nativeCloseTask = rpc.request('native.web_terminal.close', { sessionId }, 10_000)
      }
      return nativeCloseTask
    }
    const pump = async () => {
      try {
        while (!ended) {
          const result = await rpc.request(
            'native.web_terminal.read', { sessionId }, 10_000,
          )
          revision += 1
          if (result.truncated === true) {
            if (!output.write(Buffer.from('\r\n[terminal output truncated]\r\n'))) await once(output, 'drain')
          }
          if (typeof result.output === 'string' && result.output.length > 0) {
            const bytes = Buffer.from(result.output, 'base64')
            if (bytes.length > 0 && !output.write(bytes)) await once(output, 'drain')
          }
          if (typeof result.error === 'string' && result.error.length > 0) {
            fail(new SubprocessError(`The iOS guest PTY ended with a transport error: ${result.error}`, 'SUBPROCESS_PTY_UNAVAILABLE'))
            return
          }
          if (result.done === true) {
            const exitCode = Number.isInteger(result.exitCode) ? result.exitCode : null
            finish({ exitCode, signal: null })
            return
          }
        }
      } catch (error) {
        if (!ended) fail(error)
      }
    }
    void pump()

    const terminate = (signal = 'SIGTERM') => {
      if (terminateTask !== undefined) return terminateTask
      terminateTask = (async () => {
        if (!ended) {
          try {
            await closeNative()
            finish({ exitCode: null, signal })
          } catch (error) {
            fail(error)
            throw error
          }
        } else await closeNative()
      })()
      return terminateTask
    }
    return {
      pid: 0,
      output,
      done,
      async write(data) {
        if (ended) throw new SubprocessError('The iOS guest PTY has exited.', 'SUBPROCESS_PTY_UNAVAILABLE')
        await rpc.request('native.web_terminal.write', { sessionId, text: data }, 10_000)
        revision += 1
      },
      async resize(cols, rows) {
        if (ended) return
        await rpc.request('native.web_terminal.resize', { sessionId, rows, columns: cols }, 10_000)
      },
      async inspectForeground() {
        return undefined
      },
      async inspectActivity() {
        return { state: 'unknown', revision }
      },
      async signalForeground(signal) {
        if (signal === 'SIGINT') {
          await rpc.request('native.web_terminal.write', { sessionId, text: '\u0003' }, 10_000)
          revision += 1
          return 0
        }
        if (signal === 'SIGTSTP') {
          await rpc.request('native.web_terminal.write', { sessionId, text: '\u001a' }, 10_000)
          revision += 1
          return 0
        }
        if (signal === 'SIGTERM' || signal === 'SIGKILL') {
          await terminate(signal)
          return 0
        }
        if (signal === 'SIGHUP') {
          await terminate(signal)
          return 0
        }
        throw new SubprocessError(`The iOS guest PTY cannot deliver ${signal} to a verified foreground group.`, 'SUBPROCESS_PTY_UNAVAILABLE')
      },
      terminate,
    }
  }
}

export const name = '@dsbot/dsh-ios-host/ios-subprocess'
export const inject = []
export function apply(ctx) {
  new IOSGuestPTYSubprocess(ctx)
}

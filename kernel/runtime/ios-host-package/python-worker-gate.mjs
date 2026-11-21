let claimed = false
const waiters = []

function createReleaseToken() {
  let released = false
  return () => {
    if (released) return
    released = true
    while (waiters.length > 0) {
      const next = waiters.shift()
      if (!next.cancelled) {
        next.grant(createReleaseToken())
        return
      }
    }
    claimed = false
  }
}

/** A process-wide single slot for the memory-heavy offline Python interpreter. */
export function claimIOSPythonWorker() {
  if (claimed) return undefined
  claimed = true
  return createReleaseToken()
}

/** Wait in FIFO order for the single Python worker slot instead of failing immediately on transient overlap. */
export function acquireIOSPythonWorker({ signal, timeoutMs = 30_000 } = {}) {
  if (signal?.aborted) return Promise.resolve(undefined)
  const immediate = claimIOSPythonWorker()
  if (immediate) return Promise.resolve(immediate)

  return new Promise((resolve) => {
    const waiter = { cancelled: false, grant: undefined }
    let timer
    const cancel = () => {
      if (waiter.cancelled) return
      waiter.cancelled = true
      clearTimeout(timer)
      signal?.removeEventListener('abort', cancel)
      const idx = waiters.indexOf(waiter)
      if (idx >= 0) waiters.splice(idx, 1)
      resolve(undefined)
    }
    waiter.grant = (release) => {
      clearTimeout(timer)
      signal?.removeEventListener('abort', cancel)
      resolve(release)
    }
    if (Number.isFinite(timeoutMs) && timeoutMs > 0) {
      timer = setTimeout(cancel, timeoutMs)
      timer.unref?.()
    }
    signal?.addEventListener('abort', cancel, { once: true })
    waiters.push(waiter)
  })
}


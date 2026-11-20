// Defensive read-time normalizer for DSH 0.2.2-rc.5 regression (Discussion #13834):
// In 0.2.2-rc.5, @deepseek-ai/dsh-api-session-controller/lib/index.js:501 accesses
// `turn/end.data.reason.kind` without guarding undefined `reason`, crashing session projection
// when loading legacy session logs written before `reason` was introduced.
// This guard normalizes records non-destructively in memory without forking DSH.

export const DEFAULT_LEGACY_TURN_END_REASON = Object.freeze({
  kind: 'completed',
  legacyNormalized: true,
})

/**
 * Normalize a single parsed session event record.
 * @param {any} record
 * @returns {any}
 */
export function normalizeSessionRecord(record) {
  if (!record || typeof record !== 'object') return record
  if (record.type === 'turn/end') {
    const data = record.data && typeof record.data === 'object' ? record.data : {}
    if (!data.reason || typeof data.reason !== 'object' || typeof data.reason.kind !== 'string') {
      return {
        ...record,
        data: {
          ...data,
          reason: { ...DEFAULT_LEGACY_TURN_END_REASON },
        },
      }
    }
  }
  return record
}

/**
 * Normalize an entire JSONL session log string or array of event records.
 * Malformed lines are preserved verbatim so DSH's own corruption handling stays intact.
 * @param {string | any[]} input
 * @returns {{ output: string | any[], patchedCount: number }}
 */
export function normalizeSessionLog(input) {
  if (Array.isArray(input)) {
    let patchedCount = 0
    const output = input.map((rec) => {
      const next = normalizeSessionRecord(rec)
      if (next !== rec) patchedCount += 1
      return next
    })
    return { output, patchedCount }
  }

  let patchedCount = 0
  const lines = String(input).split('\n')
  const normalized = lines.map((line) => {
    if (!line.trim() || !line.includes('turn/end')) return line
    try {
      const parsed = JSON.parse(line)
      const next = normalizeSessionRecord(parsed)
      if (next !== parsed) {
        patchedCount += 1
        return JSON.stringify(next)
      }
    } catch {
      // Leave malformed JSONL untouched
    }
    return line
  })
  return { output: normalized.join('\n'), patchedCount }
}

// Defensive per-session single-flight write barrier with tail-write coalescing
// for DSH 0.2.2-rc.5 (Discussion #13857: dsh-session-projection-cache installWritePath
// concurrent flush & table.put re-entrancy under high-frequency streaming events).
export class SessionWriteBarrier {
  #inFlight = new Map()
  #pending = new Map()

  /**
   * Enqueue a projection/persistence write for `sessionId`.
   * Guarantees at most one active write per session and coalesces bursts to the latest tail write.
   * @param {string} sessionId
   * @param {() => Promise<any>} writeFn
   */
  async enqueue(sessionId, writeFn) {
    if (this.#inFlight.has(sessionId)) {
      this.#pending.set(sessionId, writeFn)
      return this.#inFlight.get(sessionId)
    }
    const run = (async () => {
      let nextFn = writeFn
      while (nextFn) {
        this.#pending.delete(sessionId)
        await nextFn()
        nextFn = this.#pending.get(sessionId) ?? null
      }
    })().finally(() => {
      this.#inFlight.delete(sessionId)
    })
    this.#inFlight.set(sessionId, run)
    return run
  }

  activeSessionCount() {
    return this.#inFlight.size
  }
}

// Defensive credential name validator for DSH 0.2.2-rc.5 (Discussion #13819:
// a single invalid credential key causes hard startup crash with truncated error).
const VALID_CREDENTIAL_RE = /^[A-Za-z0-9._:-]{1,128}$/u

export function validateCredentialName(account) {
  const name = String(account ?? '').trim()
  if (!VALID_CREDENTIAL_RE.test(name)) {
    const err = new Error(`Invalid credential name "${name}" (blocked by DSH 0.2.2-rc.5 #13819 guard).`)
    err.code = 'INVALID_CREDENTIAL_NAME'
    throw err
  }
  return name
}

import { DatabaseSync } from 'node:sqlite'
import {
  SessionAlreadyExistsError,
  SessionAlreadyOwnedError,
  SessionHandleClosedError,
  SessionPersistenceNotFoundError,
  SessionReadOnlyError,
  SessionPersistence,
  SessionPersistenceRevision,
  assertContiguous,
  assertStoredId,
  assertVersion,
  materializeAppendBatch,
  materializeCreateHeader,
  validateStoredEvents,
} from '@deepseek-ai/dsh-session-persistence'

const databasePath = process.argv.find((arg) => arg.startsWith('--database='))?.slice('--database='.length)
if (!databasePath) throw new Error('Missing --database argument for DSH SQLite persistence')

function abortIfRequested(signal) {
  if (signal?.aborted) throw signal.reason ?? new Error('Operation aborted')
}

function snapshot(row) {
  if (!row) return undefined
  const header = JSON.parse(row.header_json)
  return {
    header,
    revision: SessionPersistenceRevision(`sqlite:${row.id}:${row.revision}:${row.next_seq}`),
    eventCount: row.next_seq,
    sizeBytes: undefined,
    location: { kind: 'sqlite', path: databasePath },
  }
}

class SQLiteSessionHandle {
  constructor(owner, row, access) {
    this.owner = owner
    this.id = row.id
    this.header = JSON.parse(row.header_json)
    this.inheritedEventCount = row.inherited_event_count
    this.access = access
    this.closed = false
    this.pendingLive = []
    this.draining = false
    this.liveError = undefined
    this.flushPromise = undefined
  }

  assertOpen(operation) {
    if (this.closed) throw new SessionHandleClosedError(this.id, operation)
  }

  async read(offset = 0, length = undefined, options = {}) {
    this.assertOpen('read')
    abortIfRequested(options.signal)
    if (!Number.isSafeInteger(offset) || offset < 0) throw new RangeError('Session read offset must be a non-negative safe integer')
    if (length !== undefined && (!Number.isSafeInteger(length) || length < 0)) throw new RangeError('Session read length must be a non-negative safe integer')
    await this.owner.flushHandleLive(this)
    const rows = length === undefined
      ? this.owner.db.prepare('SELECT event_json FROM session_events WHERE session_id = ? AND seq >= ? ORDER BY seq').all(this.id, offset)
      : this.owner.db.prepare('SELECT event_json FROM session_events WHERE session_id = ? AND seq >= ? ORDER BY seq LIMIT ?').all(this.id, offset, length)
    abortIfRequested(options.signal)
    const events = rows.map((row) => JSON.parse(row.event_json))
    assertContiguous(this.id, events, offset)
    validateStoredEvents(this.header, events)
    return { eventState: 'detached', events }
  }

  async append(events, options = {}) {
    this.assertOpen('append')
    if (this.access !== 'write') throw new SessionReadOnlyError(this.id, 'append')
    abortIfRequested(options.signal)
    const batch = materializeAppendBatch(events)
    if (batch.length === 0) return
    const row = this.owner.db.prepare('SELECT next_seq FROM sessions WHERE id = ?').get(this.id)
    if (!row) throw new SessionPersistenceNotFoundError(this.id)
    assertContiguous(this.id, batch, row.next_seq)
    this.owner.db.exec('BEGIN IMMEDIATE')
    try {
      const current = this.owner.db.prepare('SELECT next_seq FROM sessions WHERE id = ?').get(this.id)
      if (!current) throw new SessionPersistenceNotFoundError(this.id)
      assertContiguous(this.id, batch, current.next_seq)
      const insert = this.owner.db.prepare('INSERT INTO session_events(session_id, seq, event_json) VALUES (?, ?, ?)')
      for (const event of batch) insert.run(this.id, event.seq, JSON.stringify(event))
      this.owner.db.prepare('UPDATE sessions SET next_seq = ?, revision = revision + 1 WHERE id = ?')
        .run(current.next_seq + batch.length, this.id)
      this.owner.db.exec('COMMIT')
    } catch (error) {
      try { this.owner.db.exec('ROLLBACK') } catch {}
      throw error
    }
  }

  enqueueLive(event) {
    if (this.closed || this.access !== 'write') return
    this.pendingLive.push(event)
    if (!this.draining) void this.drainLive().catch((error) => {
      this.liveError = error
      this.owner.ctx.logger.warn(`DSH SQLite persistence buffered a live event for ${this.id}: ${String(error)}`)
    })
  }

  async drainLive() {
    if (this.draining) {
      while (this.draining) await new Promise((resolve) => setTimeout(resolve, 0))
      if (this.liveError) throw this.liveError
      if (this.pendingLive.length) return this.drainLive()
      return
    }
    this.draining = true
    try {
      while (this.pendingLive.length) {
        const batch = this.pendingLive.slice()
        await this.append(batch)
        this.pendingLive.splice(0, batch.length)
        this.liveError = undefined
      }
    } catch (error) {
      this.liveError = error
      throw error
    } finally {
      this.draining = false
    }
  }

  async flush(options = {}) {
    this.assertOpen('flush')
    if (this.access !== 'write') throw new SessionReadOnlyError(this.id, 'flush')
    abortIfRequested(options.signal)
    await this.drainLive()
    this.owner.checkpoint()
    abortIfRequested(options.signal)
  }

  async close() {
    if (this.flushPromise) return this.flushPromise
    if (this.closed) return
    this.flushPromise = (async () => {
      if (this.access === 'write') await this.flush()
      this.closed = true
      this.owner.release(this)
    })()
    try { await this.flushPromise } catch (error) {
      this.flushPromise = undefined
      throw error
    }
  }
}

export class SQLiteSessionPersistence extends SessionPersistence {
  constructor(ctx) {
    super(ctx)
    this.db = new DatabaseSync(databasePath)
    this.db.exec('PRAGMA journal_mode = WAL; PRAGMA synchronous = FULL; PRAGMA foreign_keys = ON; PRAGMA busy_timeout = 5000;')
    this.db.exec(`
      CREATE TABLE IF NOT EXISTS sessions (
        id TEXT PRIMARY KEY NOT NULL,
        header_json TEXT NOT NULL,
        inherited_event_count INTEGER NOT NULL,
        next_seq INTEGER NOT NULL DEFAULT 0,
        revision INTEGER NOT NULL DEFAULT 0,
        created_at INTEGER NOT NULL
      );
      CREATE TABLE IF NOT EXISTS session_events (
        session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
        seq INTEGER NOT NULL,
        event_json TEXT NOT NULL,
        PRIMARY KEY (session_id, seq)
      );
    `)
    this.handles = new Set()
    this.writeOwners = new Map()
    const persistence = this
    ctx.effect(function* () {
      yield async () => {
        const errors = []
        for (const handle of [...persistence.handles]) {
          try { await handle.close() } catch (error) { errors.push(error) }
        }
        try { persistence.checkpoint(); persistence.db.close() } catch (error) { errors.push(error) }
        if (errors.length) throw new AggregateError(errors, 'DSH SQLite persistence shutdown failed')
      }
      yield ctx.on('session/event', (session, event) => {
        persistence.writeOwners.get(session.id)?.enqueueLive(event)
      })
      yield ctx.on('session/flush', (session) => persistence.flushSession(session.id))
      yield ctx.on('session/disposed', (session) => {
        const writer = persistence.writeOwners.get(session.id)
        if (writer) void writer.close().catch((error) => ctx.logger.warn(`DSH SQLite final flush failed for ${session.id}: ${String(error)}`))
      })
    }, 'dsh-ios.sqliteSessionPersistence')
  }

  handlesFor(id) { return [...this.handles].filter((handle) => handle.id === id) }
  async flushHandleLive(handle) {
    if (handle.access === 'write') return handle.drainLive()
    await this.writeOwners.get(handle.id)?.drainLive()
  }
  release(handle) {
    this.handles.delete(handle)
    if (this.writeOwners.get(handle.id) === handle) this.writeOwners.delete(handle.id)
  }
  checkpoint() { this.db.exec('PRAGMA wal_checkpoint(FULL)') }

  async create(header, options = {}) {
    abortIfRequested(options.signal)
    const snapshot = materializeCreateHeader(header)
    assertVersion(snapshot)
    const inherited = options.inheritedEventCount ?? 0
    if (!Number.isSafeInteger(inherited) || inherited < 0 || (!snapshot.isSeeded && inherited !== 0)) throw new TypeError('Invalid inherited event count')
    try {
      this.db.prepare('INSERT INTO sessions(id, header_json, inherited_event_count, created_at) VALUES (?, ?, ?, ?)')
        .run(snapshot.id, JSON.stringify(snapshot), inherited, Date.now())
    } catch (error) {
      if (String(error).includes('UNIQUE constraint failed')) throw new SessionAlreadyExistsError(snapshot.id)
      throw error
    }
    return this.openHandle(snapshot.id, 'write')
  }

  async open(id, access, options = {}) {
    abortIfRequested(options.signal)
    if (access !== 'read' && access !== 'write') throw new TypeError('Session access must be read or write')
    return this.openHandle(id, access)
  }

  openHandle(id, access) {
    const row = this.db.prepare('SELECT id, header_json, inherited_event_count, next_seq, revision FROM sessions WHERE id = ?').get(id)
    if (!row) throw new SessionPersistenceNotFoundError(id)
    const header = JSON.parse(row.header_json)
    assertStoredId(id, header)
    assertVersion(header)
    if (access === 'write' && this.writeOwners.has(id)) throw new SessionAlreadyOwnedError(id)
    const handle = new SQLiteSessionHandle(this, row, access)
    this.handles.add(handle)
    if (access === 'write') this.writeOwners.set(id, handle)
    return handle
  }

  async stat(id, options = {}) {
    abortIfRequested(options.signal)
    return snapshot(this.db.prepare('SELECT id, header_json, next_seq, revision FROM sessions WHERE id = ?').get(id))
  }

  async list(options = {}) {
    abortIfRequested(options.signal)
    return this.db.prepare('SELECT id, header_json, next_seq, revision FROM sessions ORDER BY created_at DESC, id').all()
      .map((row) => snapshot(row))
  }

  async flushSession(id) {
    const writer = this.writeOwners.get(id)
    if (writer) await writer.flush()
  }

  async flush() {
    const errors = []
    for (const handle of [...this.writeOwners.values()]) {
      try { await handle.flush() } catch (error) { errors.push(error) }
    }
    if (errors.length) throw new AggregateError(errors, 'DSH SQLite session flush failed')
    this.checkpoint()
  }

  async delete(id) {
    const writer = this.writeOwners.get(id)
    if (writer) await writer.close()
    this.db.prepare('DELETE FROM sessions WHERE id = ?').run(id)
  }

  async history(id) {
    const handle = await this.open(id, 'read')
    try { return (await handle.read()).events } finally { await handle.close() }
  }
}

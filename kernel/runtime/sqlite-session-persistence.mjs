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
    lastActivityAt: Number.isSafeInteger(row.last_activity_at) ? row.last_activity_at : undefined,
    lastMessagePreview: typeof row.last_message_preview === 'string' ? row.last_message_preview : undefined,
    sizeBytes: undefined,
    location: { kind: 'sqlite', path: databasePath },
  }
}

function lastMessagePreview(event) {
  let blocks
  if (event?.type === 'user/message') {
    if (event.data?.source && event.data.source.kind !== 'user') return undefined
    blocks = event.data?.content
  } else if (event?.type === 'assistant/message') {
    blocks = event.data?.message?.content
  } else {
    return undefined
  }
  const text = typeof blocks === 'string'
    ? blocks
    : Array.isArray(blocks)
      ? blocks.filter((block) => block?.type === 'text' && typeof block.text === 'string')
        .map((block) => block.text).join('')
      : ''
  const preview = Array.from(text).slice(0, 180).join('').trim()
  return preview || undefined
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
      const lastActivityAt = batch.at(-1)?.time
      let preview
      for (let index = batch.length - 1; index >= 0 && preview === undefined; index -= 1) {
        preview = lastMessagePreview(batch[index])
      }
      this.owner.db.prepare(`UPDATE sessions
        SET last_activity_at = COALESCE(?, last_activity_at),
            last_message_preview = COALESCE(?, last_message_preview)
        WHERE id = ?`).run(Number.isSafeInteger(lastActivityAt) ? lastActivityAt : null, preview ?? null, this.id)
      this.owner.db.exec('COMMIT')
    } catch (error) {
      try { this.owner.db.exec('ROLLBACK') } catch {}
      throw error
    }
  }

  enqueueLive(event) {
    if (this.closed || this.access !== 'write') return
    this.pendingLive.push(event)
    if (!this.drainPromise) void this.drainLive().catch((error) => {
      this.liveError = error
      this.owner.ctx.logger.warn(`DSH SQLite persistence buffered a live event for ${this.id}: ${String(error)}`)
    })
  }

  async drainLive() {
    if (this.drainPromise) {
      await this.drainPromise.catch(() => {})
      if (this.liveError) throw this.liveError
      if (this.pendingLive.length) return this.drainLive()
      return
    }
    this.draining = true
    const current = (async () => {
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
        if (this.drainPromise === current) this.drainPromise = null
      }
    })()
    this.drainPromise = current
    return await current
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
    this._db = null
    this.openDatabase({ runMigrations: true })
    this.handles = new Set()
    this.writeOwners = new Map()
    const persistence = this
    ctx.effect(function* () {
      yield async () => {
        const errors = []
        for (const handle of [...persistence.handles]) {
          try { await handle.close() } catch (error) { errors.push(error) }
        }
        try { persistence.closeDatabaseHandle() } catch (error) { errors.push(error) }
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

  get db() {
    if (!this._db) this.openDatabase({ runMigrations: false })
    return this._db
  }

  openDatabase({ runMigrations = false } = {}) {
    if (this._db) return this._db
    const db = new DatabaseSync(databasePath)
    db.exec('PRAGMA journal_mode = WAL; PRAGMA synchronous = FULL; PRAGMA foreign_keys = ON; PRAGMA busy_timeout = 5000; PRAGMA cache_size = -4000; PRAGMA temp_store = MEMORY; PRAGMA mmap_size = 0;')
    this._db = db
    if (runMigrations) {
      db.exec(`
        CREATE TABLE IF NOT EXISTS sessions (
          id TEXT PRIMARY KEY NOT NULL,
          header_json TEXT NOT NULL,
          inherited_event_count INTEGER NOT NULL,
          next_seq INTEGER NOT NULL DEFAULT 0,
          revision INTEGER NOT NULL DEFAULT 0,
          created_at INTEGER NOT NULL,
          last_activity_at INTEGER,
          last_message_preview TEXT
        );
        CREATE TABLE IF NOT EXISTS session_events (
          session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
          seq INTEGER NOT NULL,
          event_json TEXT NOT NULL,
          PRIMARY KEY (session_id, seq)
        );
      `)
      const sessionColumns = new Set(db.prepare('PRAGMA table_info(sessions)').all().map((row) => row.name))
      if (!sessionColumns.has('last_activity_at')) db.exec('ALTER TABLE sessions ADD COLUMN last_activity_at INTEGER')
      if (!sessionColumns.has('last_message_preview')) db.exec('ALTER TABLE sessions ADD COLUMN last_message_preview TEXT')
      this.backfillSessionSummaries()
    }
    return db
  }

  closeDatabaseHandle() {
    if (!this._db) return
    try {
      this._db.exec('PRAGMA wal_checkpoint(TRUNCATE)')
    } finally {
      const db = this._db
      this._db = null
      db.close()
    }
  }

  async suspendDatabase() {
    await this.flush({ truncate: true })
    if (this.handles.size === 0) {
      this.closeDatabaseHandle()
      return { closed: true }
    }
    return { closed: false, openHandles: this.handles.size }
  }

  resumeDatabase() {
    this.openDatabase({ runMigrations: false })
    return { open: Boolean(this._db) }
  }

  handlesFor(id) { return [...this.handles].filter((handle) => handle.id === id) }

  backfillSessionSummaries() {
    const pending = this.db.prepare(`SELECT id FROM sessions
      WHERE (last_activity_at IS NULL OR last_message_preview IS NULL)
        AND next_seq > 0`).all()
    const lastEvent = this.db.prepare(`SELECT json_extract(event_json, '$.time') AS time
      FROM session_events WHERE session_id = ? ORDER BY seq DESC LIMIT 1`)
    const lastMessage = this.db.prepare(`SELECT event_json FROM session_events
      WHERE session_id = ?
        AND (json_extract(event_json, '$.type') = 'assistant/message'
          OR (json_extract(event_json, '$.type') = 'user/message'
            AND (json_type(event_json, '$.data.source') IS NULL
              OR json_extract(event_json, '$.data.source.kind') = 'user')))
      ORDER BY seq DESC LIMIT 1`)
    const update = this.db.prepare(`UPDATE sessions
      SET last_activity_at = COALESCE(last_activity_at, ?),
          last_message_preview = COALESCE(last_message_preview, ?)
      WHERE id = ?`)
    for (const { id } of pending) {
      const activity = lastEvent.get(id)
      const message = lastMessage.get(id)
      const preview = message ? lastMessagePreview(JSON.parse(message.event_json)) ?? '' : ''
      update.run(Number.isSafeInteger(activity?.time) ? activity.time : null, preview, id)
    }
  }

  async flushHandleLive(handle) {
    if (handle.access === 'write') return handle.drainLive()
    await this.writeOwners.get(handle.id)?.drainLive()
  }
  release(handle) {
    this.handles.delete(handle)
    if (this.writeOwners.get(handle.id) === handle) this.writeOwners.delete(handle.id)
  }
  checkpoint(mode = 'FULL') {
    const safeMode = mode === 'TRUNCATE' || mode === 'RESTART' || mode === 'PASSIVE' ? mode : 'FULL'
    this.db.exec(`PRAGMA wal_checkpoint(${safeMode})`)
  }

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
    return snapshot(this.db.prepare(`SELECT id, header_json, next_seq, revision,
      last_activity_at, last_message_preview FROM sessions WHERE id = ?`).get(id))
  }

  async list(options = {}) {
    abortIfRequested(options.signal)
    return this.db.prepare(`SELECT id, header_json, next_seq, revision,
      last_activity_at, last_message_preview FROM sessions ORDER BY created_at DESC, id`).all()
      .map((row) => snapshot(row))
  }

  async flushSession(id) {
    const writer = this.writeOwners.get(id)
    if (writer) await writer.flush()
  }

  async flush(options = {}) {
    const errors = []
    for (const handle of [...this.writeOwners.values()]) {
      try { await handle.flush() } catch (error) { errors.push(error) }
    }
    if (errors.length) throw new AggregateError(errors, 'DSH SQLite session flush failed')
    this.checkpoint(options?.truncate ? 'TRUNCATE' : 'FULL')
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

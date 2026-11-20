// 4-Layer Memory Engine + Reversible `journal.jsonl` Audit Log (ported from joeshu/DS-Bot).
// Layers:
//   1. pinned    - Always injected into system prompt (within token/char budget)
//   2. delta     - Recent incremental entries since last compaction
//   3. recall    - Keyword/BM25-lite auto-recalled entries matching current query
//   4. on_demand - Explicitly fetched by ID or topic tag
// Every add / update / delete appends a reversible entry to `journal.jsonl`,
// enabling exact single-record undo (`undo(journalId)`).

import { appendFileSync, existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { randomUUID } from 'node:crypto'
import { dirname, join } from 'node:path'

export const MEMORY_LAYERS = Object.freeze(['pinned', 'delta', 'recall', 'on_demand'])

export class MemoryEngine {
  #rootDir
  #storeFile
  #journalFile

  /** @param {string} scopeDir - e.g. `<DSH_HOME>/memory/<botId>` */
  constructor(scopeDir) {
    this.#rootDir = scopeDir
    this.#storeFile = join(scopeDir, 'entries.json')
    this.#journalFile = join(scopeDir, 'journal.jsonl')
  }

  list(layer = null) {
    const entries = Object.values(this.#readStore())
    return layer ? entries.filter((e) => e.layer === layer) : entries
  }

  get(id) {
    return this.#readStore()[id] ?? null
  }

  add({ title, content, layer = 'delta', tags = [] }) {
    if (!MEMORY_LAYERS.includes(layer)) {
      throw new Error(`Invalid memory layer: ${layer}`)
    }
    const store = this.#readStore()
    const now = new Date().toISOString()
    const entry = {
      id: `mem_${randomUUID().slice(0, 8)}`,
      title: String(title ?? '').trim(),
      content: String(content ?? ''),
      layer,
      tags: Array.isArray(tags) ? tags.map(String) : [],
      createdAt: now,
      updatedAt: now,
    }
    store[entry.id] = entry
    this.#writeStore(store)
    const journalId = this.#appendJournal({ op: 'add', entryId: entry.id, before: null, after: entry })
    return { entry, journalId }
  }

  update(id, patch) {
    const store = this.#readStore()
    const existing = store[id]
    if (!existing) throw new Error(`Memory entry not found: ${id}`)
    if (patch.layer !== undefined && !MEMORY_LAYERS.includes(patch.layer)) {
      throw new Error(`Invalid memory layer: ${patch.layer}`)
    }
    const before = structuredClone(existing)
    const after = {
      ...existing,
      ...(patch.title !== undefined ? { title: String(patch.title).trim() } : {}),
      ...(patch.content !== undefined ? { content: String(patch.content) } : {}),
      ...(patch.layer !== undefined ? { layer: patch.layer } : {}),
      ...(patch.tags !== undefined ? { tags: patch.tags.map(String) } : {}),
      updatedAt: new Date().toISOString(),
    }
    store[id] = after
    this.#writeStore(store)
    const journalId = this.#appendJournal({ op: 'update', entryId: id, before, after })
    return { entry: after, journalId }
  }

  remove(id) {
    const store = this.#readStore()
    const existing = store[id]
    if (!existing) return { removed: false }
    delete store[id]
    this.#writeStore(store)
    const journalId = this.#appendJournal({ op: 'delete', entryId: id, before: existing, after: null })
    return { removed: true, journalId }
  }

  /**
   * Read the 4-layer memory context view for a turn within character budget.
   */
  composeContext({ query = '', maxChars = 6000 } = {}) {
    const all = this.list()
    const pinned = all.filter((e) => e.layer === 'pinned')
    const delta = all.filter((e) => e.layer === 'delta').slice(-10)
    const tokens = String(query).toLowerCase().split(/\s+/u).filter((t) => t.length >= 2)
    const recall = tokens.length === 0
      ? []
      : all
          .filter((e) => e.layer === 'recall' || e.layer === 'on_demand')
          .map((e) => {
            const hay = `${e.title} ${e.content} ${e.tags.join(' ')}`.toLowerCase()
            const score = tokens.reduce((acc, tok) => acc + (hay.includes(tok) ? 1 : 0), 0)
            return { entry: e, score }
          })
          .filter((x) => x.score > 0)
          .sort((a, b) => b.score - a.score)
          .slice(0, 5)
          .map((x) => x.entry)

    let used = 0
    const pick = (list) => list.filter((e) => {
      const len = e.title.length + e.content.length + 16
      if (used + len > maxChars) return false
      used += len
      return true
    })

    return {
      pinned: pick(pinned),
      delta: pick(delta),
      recall: pick(recall),
      usedChars: used,
    }
  }

  listJournal(limit = 50) {
    if (!existsSync(this.#journalFile)) return []
    const lines = readFileSync(this.#journalFile, 'utf8').split('\n').filter(Boolean)
    return lines.slice(-limit).map((l) => JSON.parse(l)).reverse()
  }

  /**
   * Exact inverse undo of a single journal record by ID (ported from `2026-11-01-memory-restore.md`).
   */
  undo(journalId) {
    const records = this.listJournal(1000)
    const target = records.find((r) => r.journalId === journalId)
    if (!target) throw new Error(`Journal record not found: ${journalId}`)

    const store = this.#readStore()
    if (target.op === 'add') {
      const prev = store[target.entryId] ?? null
      delete store[target.entryId]
      this.#writeStore(store)
      const undoId = this.#appendJournal({ op: 'undo', revertedJournalId: journalId, entryId: target.entryId, before: prev, after: null })
      return { undone: true, op: 'delete', entryId: target.entryId, journalId: undoId }
    }
    if (target.op === 'update' || target.op === 'delete') {
      const prev = store[target.entryId] ?? null
      store[target.entryId] = target.before
      this.#writeStore(store)
      const undoId = this.#appendJournal({ op: 'undo', revertedJournalId: journalId, entryId: target.entryId, before: prev, after: target.before })
      return { undone: true, op: 'restore', entryId: target.entryId, journalId: undoId }
    }
    throw new Error(`Cannot undo journal record of type: ${target.op}`)
  }

  #readStore() {
    if (!existsSync(this.#storeFile)) return {}
    try {
      return JSON.parse(readFileSync(this.#storeFile, 'utf8'))
    } catch {
      return {}
    }
  }

  #writeStore(store) {
    mkdirSync(this.#rootDir, { recursive: true })
    const tmp = `${this.#storeFile}.tmp`
    writeFileSync(tmp, `${JSON.stringify(store, null, 2)}\n`, 'utf8')
    writeFileSync(this.#storeFile, readFileSync(tmp, 'utf8'), 'utf8')
    rmSync(tmp, { force: true })
  }

  #appendJournal(record) {
    mkdirSync(dirname(this.#journalFile), { recursive: true })
    const entry = {
      journalId: `jrn_${randomUUID().slice(0, 8)}`,
      at: new Date().toISOString(),
      ...record,
    }
    appendFileSync(this.#journalFile, `${JSON.stringify(entry)}\n`, 'utf8')
    return entry.journalId
  }
}

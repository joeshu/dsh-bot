// Group Collaboration Engine (ported from joeshu/DS-Bot):
// - Admin-first cost-control routing (default only group admin responds unless @mentioned)
// - Append-only Message Ledger (prevents losing tool outputs on refresh)
// - Long Message Externalization (>20,000 chars saved to sandbox file, summary kept in state)
// - Group Goal staged tracker, Task Board (`group_task`), and Shared Todos (`group_todo`, cap 100)

import { appendFileSync, existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { randomUUID } from 'node:crypto'
import { join } from 'node:path'

export const LONG_MESSAGE_THRESHOLD = 20_000
export const GROUP_TODO_LIMIT = 100

export class GroupCollaborationEngine {
  #groupDir
  #ledgerFile
  #stateFile
  #filesDir

  /** @param {string} groupDir - e.g. `<DSH_HOME>/groups/<groupId>` */
  constructor(groupDir) {
    this.#groupDir = groupDir
    this.#ledgerFile = join(groupDir, 'ledger.jsonl')
    this.#stateFile = join(groupDir, 'state.json')
    this.#filesDir = join(groupDir, 'files')
  }

  /**
   * Cost-control router: if the message explicitly `@mentions` member bots, route only to them;
   * otherwise route strictly to the group admin bot (prevents multi-bot Token explosion).
   * @param {{ text: string, adminBotId: string, memberBotIds: string[] }} input
   */
  routeMessage({ text, adminBotId, memberBotIds }) {
    const mentioned = []
    const memberSet = new Set(memberBotIds)
    const regex = /@([A-Za-z0-9_-]+)/gu
    let m
    while ((m = regex.exec(String(text))) !== null) {
      if (memberSet.has(m[1]) && !mentioned.includes(m[1])) {
        mentioned.push(m[1])
      }
    }
    return {
      targets: mentioned.length > 0 ? mentioned : [adminBotId],
      mode: mentioned.length > 0 ? 'direct-mention' : 'admin-default',
    }
  }

  /**
   * Append a message to the append-only ledger.
   * Replies exceeding 20,000 chars are externalized to `files/<id>.md` to protect iOS Jetsam memory.
   */
  appendMessage({ senderId, senderRole = 'bot', content, toolRange = null }) {
    mkdirSync(this.#groupDir, { recursive: true })
    const seq = this.readLedger().length + 1
    const id = `msg_${seq}_${randomUUID().slice(0, 6)}`
    const fullText = String(content ?? '')

    let externalFile = null
    let storedText = fullText
    if (fullText.length > LONG_MESSAGE_THRESHOLD) {
      mkdirSync(this.#filesDir, { recursive: true })
      const filename = `${id}.md`
      const absPath = join(this.#filesDir, filename)
      writeFileSync(absPath, fullText, 'utf8')
      externalFile = `files/${filename}`
      storedText = `${fullText.slice(0, 1200)}\n\n… [长回复共 ${fullText.length} 字，已外置保存至 ${externalFile}]`
    }

    const record = {
      seq,
      id,
      senderId,
      senderRole,
      text: storedText,
      externalFile,
      fullLength: fullText.length,
      toolRange,
      at: new Date().toISOString(),
    }
    appendFileSync(this.#ledgerFile, `${JSON.stringify(record)}\n`, 'utf8')
    return record
  }

  readFullMessage(record) {
    if (!record?.externalFile) return record?.text ?? ''
    const absPath = join(this.#groupDir, record.externalFile)
    return existsSync(absPath) ? readFileSync(absPath, 'utf8') : record.text
  }

  readLedger(limit = 200) {
    if (!existsSync(this.#ledgerFile)) return []
    const lines = readFileSync(this.#ledgerFile, 'utf8').split('\n').filter(Boolean)
    return lines.slice(-limit).map((l) => JSON.parse(l))
  }

  // --- Group Goal ---
  setGoal({ title, criteria, stages = [] }) {
    const state = this.#readState()
    state.goal = {
      id: `goal_${randomUUID().slice(0, 8)}`,
      title,
      criteria,
      status: 'active',
      stages: stages.map((s, idx) => ({
        index: idx + 1,
        title: s.title,
        ownerBotId: s.ownerBotId ?? null,
        status: s.status ?? 'pending',
        evidence: null,
      })),
      updatedAt: new Date().toISOString(),
    }
    this.#writeState(state)
    return state.goal
  }

  updateGoalStage(index, { status, evidence = null }) {
    const state = this.#readState()
    if (!state.goal) throw new Error('No active group goal')
    const stage = state.goal.stages.find((s) => s.index === index)
    if (!stage) throw new Error(`Goal stage #${index} not found`)
    stage.status = status
    if (evidence !== null) stage.evidence = evidence
    if (state.goal.stages.every((s) => s.status === 'done')) {
      state.goal.status = 'completed'
    }
    state.goal.updatedAt = new Date().toISOString()
    this.#writeState(state)
    return state.goal
  }

  // --- Group Task Board (`group_task`) ---
  upsertTask({ id, ownerBotId, goal, status = 'in_progress', summary = '' }) {
    const state = this.#readState()
    const taskId = id || `task_${randomUUID().slice(0, 6)}`
    const existing = state.tasks.find((t) => t.id === taskId)
    const now = new Date().toISOString()
    if (existing) {
      existing.ownerBotId = ownerBotId ?? existing.ownerBotId
      existing.goal = goal ?? existing.goal
      existing.status = status
      existing.summary = summary
      existing.updatedAt = now
    } else {
      state.tasks.push({ id: taskId, ownerBotId, goal, status, summary, createdAt: now, updatedAt: now })
    }
    this.#writeState(state)
    return state.tasks.find((t) => t.id === taskId)
  }

  // --- Group Shared Todos (`group_todo`, cap 100) ---
  addTodo(text) {
    const state = this.#readState()
    if (state.todos.length >= GROUP_TODO_LIMIT) {
      const err = new Error(`Group todo limit (${GROUP_TODO_LIMIT}) reached; clear completed items first.`)
      err.code = 'GROUP_TODO_LIMIT_REACHED'
      throw err
    }
    const item = { id: `todo_${randomUUID().slice(0, 6)}`, text: String(text).trim(), done: false, createdAt: new Date().toISOString() }
    state.todos.push(item)
    this.#writeState(state)
    return item
  }

  toggleTodo(id, done) {
    const state = this.#readState()
    const item = state.todos.find((t) => t.id === id)
    if (!item) return { found: false }
    item.done = Boolean(done)
    this.#writeState(state)
    return { found: true, item }
  }

  clearCompletedTodos() {
    const state = this.#readState()
    const before = state.todos.length
    state.todos = state.todos.filter((t) => !t.done)
    this.#writeState(state)
    return { removed: before - state.todos.length, remaining: state.todos.length }
  }

  getState() {
    return this.#readState()
  }

  #readState() {
    if (!existsSync(this.#stateFile)) return { goal: null, tasks: [], todos: [] }
    try {
      const parsed = JSON.parse(readFileSync(this.#stateFile, 'utf8'))
      return { goal: parsed.goal ?? null, tasks: parsed.tasks ?? [], todos: parsed.todos ?? [] }
    } catch {
      return { goal: null, tasks: [], todos: [] }
    }
  }

  #writeState(state) {
    mkdirSync(this.#groupDir, { recursive: true })
    const tmp = `${this.#stateFile}.tmp`
    writeFileSync(tmp, `${JSON.stringify(state, null, 2)}\n`, 'utf8')
    writeFileSync(this.#stateFile, readFileSync(tmp, 'utf8'), 'utf8')
    rmSync(tmp, { force: true })
  }
}

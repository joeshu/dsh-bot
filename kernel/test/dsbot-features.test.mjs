// Automated tests for all 7 ported joeshu/DS-Bot features on iOS Standalone (v0.5.0).
import assert from 'node:assert/strict'
import { existsSync, mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { test } from 'node:test'

import { MemoryEngine } from '../src/features/memory-layers.mjs'
import { GROUP_TODO_LIMIT, GroupCollaborationEngine, LONG_MESSAGE_THRESHOLD } from '../src/features/group-collab.mjs'
import { HandoffTree, PrivateBotGuard, SideChatManager } from '../src/features/privacy-and-side.mjs'
import { ConnectorRegistry, UsageTracker, validateWidgetBlueprint } from '../src/features/connectors-widgets-usage.mjs'

test('MemoryEngine supports 4-layer context composition and exact journal.jsonl single-record undo', () => {
  const dir = mkdtempSync(join(tmpdir(), 'dsh-mem-'))
  try {
    const mem = new MemoryEngine(dir)
    const { entry: pinned } = mem.add({ title: 'User Style', content: 'Prefer concise Chinese responses.', layer: 'pinned' })
    const { entry: recall, journalId: addJrn } = mem.add({ title: 'iOS Sideload', content: 'Use SideStore and LiveContainer.', layer: 'recall', tags: ['ios'] })

    const ctx = mem.composeContext({ query: 'ios sidestore' })
    assert.equal(ctx.pinned.length, 1)
    assert.equal(ctx.recall.length, 1)
    assert.equal(ctx.recall[0].id, recall.id)

    // Update then undo update -> restores exact previous content
    const { journalId: updJrn } = mem.update(pinned.id, { content: 'Wrong overwrite' })
    assert.equal(mem.get(pinned.id).content, 'Wrong overwrite')
    mem.undo(updJrn)
    assert.equal(mem.get(pinned.id).content, 'Prefer concise Chinese responses.')

    // Undo add -> removes entry cleanly
    mem.undo(addJrn)
    assert.equal(mem.get(recall.id), null)
    assert.ok(mem.listJournal().length >= 4)
  } finally {
    rmSync(dir, { recursive: true, force: true })
  }
})

test('GroupCollaborationEngine routes admin-first, externalizes >20k replies, and tracks Goal/Tasks/Todos', () => {
  const dir = mkdtempSync(join(tmpdir(), 'dsh-grp-'))
  try {
    const grp = new GroupCollaborationEngine(dir)

    // Admin-first cost control routing
    const defRoute = grp.routeMessage({ text: '请整理本周进展', adminBotId: 'chief', memberBotIds: ['chief', 'coder', 'writer'] })
    assert.deepEqual(defRoute.targets, ['chief'])
    assert.equal(defRoute.mode, 'admin-default')

    const mentionRoute = grp.routeMessage({ text: '@coder 跑单测 @writer 写总结', adminBotId: 'chief', memberBotIds: ['chief', 'coder', 'writer'] })
    assert.deepEqual(mentionRoute.targets, ['coder', 'writer'])
    assert.equal(mentionRoute.mode, 'direct-mention')

    // Long message (>20,000 chars) externalizes to sandbox file and reads back verbatim
    const longBody = 'A'.repeat(LONG_MESSAGE_THRESHOLD + 500)
    const rec = grp.appendMessage({ senderId: 'writer', content: longBody })
    assert.ok(rec.externalFile)
    assert.ok(rec.text.length < 2000)
    assert.ok(existsSync(join(dir, rec.externalFile)))
    assert.equal(grp.readFullMessage(rec).length, longBody.length)

    // Group Goal stages + Task Board + Shared Todos (cap 100)
    grp.setGoal({ title: 'Release v0.5.0', criteria: 'All green', stages: [{ title: 'Code', ownerBotId: 'coder' }, { title: 'QA', ownerBotId: 'chief' }] })
    const g1 = grp.updateGoalStage(1, { status: 'done', evidence: '18/18 tests passed' })
    assert.equal(g1.status, 'active')
    const g2 = grp.updateGoalStage(2, { status: 'done', evidence: 'IPA verified' })
    assert.equal(g2.status, 'completed')

    const task = grp.upsertTask({ ownerBotId: 'coder', goal: 'Port features', status: 'done', summary: 'Completed' })
    assert.equal(task.status, 'done')

    for (let i = 0; i < GROUP_TODO_LIMIT; i += 1) grp.addTodo(`Item ${i}`)
    assert.throws(() => grp.addTodo('Overflow'), (err) => err.code === 'GROUP_TODO_LIMIT_REACHED')
    const firstId = grp.getState().todos[0].id
    grp.toggleTodo(firstId, true)
    assert.equal(grp.clearCompletedTodos().removed, 1)
  } finally {
    rmSync(dir, { recursive: true, force: true })
  }
})

test('PrivateBotGuard, HandoffTree deadlock detection, and non-interrupting SideChatManager', async () => {
  const priv = new PrivateBotGuard()
  priv.markPrivate('vault_bot', true)
  assert.throws(() => priv.assertCanSetMainBot('vault_bot'), (e) => e.code === 'PRIVATE_BOT_MAIN_FORBIDDEN')
  assert.throws(() => priv.assertCanJoinGroup('vault_bot'), (e) => e.code === 'PRIVATE_BOT_GROUP_FORBIDDEN')
  assert.throws(() => priv.assertCanReadBotData({ requesterBotId: 'chief', targetBotId: 'vault_bot' }), (e) => e.code === 'PRIVATE_BOT_ACCESS_DENIED')
  assert.equal(priv.requiresOutboundApproval('vault_bot'), true)

  const tree = new HandoffTree()
  tree.beginHandoff('chief', 'coder')
  tree.beginHandoff('coder', 'reviewer')
  assert.throws(() => tree.beginHandoff('reviewer', 'chief'), (e) => e.code === 'HANDOFF_CYCLE_BLOCKED')
  tree.completeHandoff('coder', 'reviewer')
  tree.completeHandoff('chief', 'coder')

  const side = new SideChatManager()
  const thread = side.openSideThread('sess_main')
  const res = await side.ask({
    sideId: thread.id,
    question: 'What model am I using?',
    answerFn: async ({ toolsEnabled }) => {
      assert.equal(toolsEnabled, false)
      return 'deepseek-reasoner'
    },
  })
  assert.equal(res.reply, 'deepseek-reasoner')
  assert.equal(res.messageCount, 2)
})

test('Widget Views validator, Keychain-only ConnectorRegistry, and UsageTracker cache-hit metrics', () => {
  const dir = mkdtempSync(join(tmpdir(), 'dsh-conn-usage-'))
  try {
    assert.equal(validateWidgetBlueprint({ kind: 'metric-row', items: [{ label: 'Tokens', value: '12k' }] }).valid, true)
    assert.equal(validateWidgetBlueprint({ kind: 'arbitrary-script' }).valid, false)

    const conn = new ConnectorRegistry(dir)
    const saved = conn.upsert({ type: 'remote-mcp', name: 'Office MCP', endpoint: 'https://mcp.example.com/sse' })
    assert.equal(saved.keychainAccount, `connector:${saved.id}`)
    assert.equal(conn.list().length, 1)

    const usage = new UsageTracker(dir)
    usage.record({ botId: 'chief', model: 'deepseek-reasoner', inputTokens: 10_000, cachedInputTokens: 7_500, outputTokens: 2_000, at: '2026-11-19T10:00:00Z' })
    usage.record({ botId: 'coder', model: 'deepseek-chat', inputTokens: 5_000, cachedInputTokens: 2_500, outputTokens: 1_000, at: '2026-11-19T11:00:00Z' })

    const summary = usage.summarize({ sinceDay: '2026-11-19' })
    assert.equal(summary.turns, 2)
    assert.equal(summary.totalTokens, 18_000)
    assert.equal(summary.cacheHitRate, 0.6667)
    assert.equal(summary.byBot.chief, 12_000)
  } finally {
    rmSync(dir, { recursive: true, force: true })
  }
})

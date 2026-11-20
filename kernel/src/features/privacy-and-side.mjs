// Private Bot Isolation, Deadlock-Free Handoff Tree, and Side Chat (`/side`) Engine
// Ported from joeshu/DS-Bot (`2026-10-27-private-bots.md`, `2026-10-16-bot-handoffs.md`, `2026-10-21-btw.md`).

/**
 * Enforces Private Bot isolation rules:
 * - Cannot be designated as Main Bot
 * - Cannot join group chats
 * - Other bots cannot read its workspace/memory/history
 * - Outbound messages to other bots or external files require explicit user approval
 */
export class PrivateBotGuard {
  #privateBotIds = new Set()

  markPrivate(botId, isPrivate = true) {
    if (isPrivate) this.#privateBotIds.add(botId)
    else this.#privateBotIds.delete(botId)
  }

  isPrivate(botId) {
    return this.#privateBotIds.has(botId)
  }

  assertCanSetMainBot(botId) {
    if (this.#privateBotIds.has(botId)) {
      const err = new Error(`Private bot "${botId}" cannot be promoted to Main Bot.`)
      err.code = 'PRIVATE_BOT_MAIN_FORBIDDEN'
      throw err
    }
  }

  assertCanJoinGroup(botId) {
    if (this.#privateBotIds.has(botId)) {
      const err = new Error(`Private bot "${botId}" cannot join group chats.`)
      err.code = 'PRIVATE_BOT_GROUP_FORBIDDEN'
      throw err
    }
  }

  assertCanReadBotData({ requesterBotId, targetBotId }) {
    if (requesterBotId !== targetBotId && this.#privateBotIds.has(targetBotId)) {
      const err = new Error(`Access denied: "${requesterBotId}" cannot read Private Bot "${targetBotId}" data.`)
      err.code = 'PRIVATE_BOT_ACCESS_DENIED'
      throw err
    }
  }

  requiresOutboundApproval(botId) {
    return this.#privateBotIds.has(botId)
  }
}

/**
 * Deadlock-free Bot-to-Bot Handoff Tree:
 * Prevents sending a handoff to any bot currently waiting on an ancestor in the active call chain.
 */
export class HandoffTree {
  #waitingOn = new Map() // callerBotId -> Set<calleeBotId>

  beginHandoff(fromBotId, toBotId) {
    if (fromBotId === toBotId || this.#isAncestorWaiting(toBotId, fromBotId)) {
      const err = new Error(`Deadlock prevented: "${toBotId}" is already waiting on "${fromBotId}" in the active handoff tree.`)
      err.code = 'HANDOFF_CYCLE_BLOCKED'
      throw err
    }
    if (!this.#waitingOn.has(fromBotId)) this.#waitingOn.set(fromBotId, new Set())
    this.#waitingOn.get(fromBotId).add(toBotId)
    return { fromBotId, toBotId, active: true }
  }

  completeHandoff(fromBotId, toBotId) {
    this.#waitingOn.get(fromBotId)?.delete(toBotId)
  }

  #isAncestorWaiting(node, target, seen = new Set()) {
    if (seen.has(node)) return false
    seen.add(node)
    const children = this.#waitingOn.get(node)
    if (!children) return false
    if (children.has(target)) return true
    for (const child of children) {
      if (this.#isAncestorWaiting(child, target, seen)) return true
    }
    return false
  }
}

/**
 * Side Chat (`/side`) Manager:
 * Allows the user to ask an aside question while a Bot is busy working,
 * without interrupting the active turn, without executing tools, and without polluting main history.
 */
export class SideChatManager {
  #threads = new Map() // sideId -> { id, parentSessionId, messages: [] }

  openSideThread(parentSessionId) {
    const id = `side_${Date.now().toString(36)}_${Math.random().toString(36).slice(2, 6)}`
    const thread = { id, parentSessionId, messages: [], createdAt: new Date().toISOString() }
    this.#threads.set(id, thread)
    return thread
  }

  async ask({ sideId, question, answerFn }) {
    const thread = this.#threads.get(sideId)
    if (!thread) throw new Error(`Side chat thread not found: ${sideId}`)
    thread.messages.push({ role: 'user', text: question, at: new Date().toISOString() })
    // Explicitly passes `toolsEnabled: false` so side chat never mutates workspace or interrupts main turn
    const reply = await answerFn({
      parentSessionId: thread.parentSessionId,
      history: [...thread.messages],
      toolsEnabled: false,
    })
    thread.messages.push({ role: 'assistant', text: reply, at: new Date().toISOString() })
    return { sideId, reply, messageCount: thread.messages.length }
  }

  getThread(sideId) {
    return this.#threads.get(sideId) ?? null
  }
}

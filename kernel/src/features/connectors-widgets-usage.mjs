// Widget Views Blueprint Validator, Universal Connectors (GitHub / Mail / Remote MCP),
// and Token Usage & Cache-Hit Tracker (ported from joeshu/DS-Bot).

import { existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { dirname, join } from 'node:path'

// --- 1. Widget Views JSON Blueprint Validator (`2026-10-20-widget-views.md`) ---
export const SUPPORTED_WIDGET_KINDS = Object.freeze(['metric-row', 'table', 'bar-chart', 'form', 'confirm-card'])
const MAX_WIDGET_DEPTH = 6
const MAX_WIDGET_BYTES = 64 * 1024

function measureDepth(obj, current = 0) {
  if (current > MAX_WIDGET_DEPTH) return current
  if (!obj || typeof obj !== 'object') return current
  let max = current
  for (const val of Object.values(obj)) {
    const d = measureDepth(val, current + 1)
    if (d > max) max = d
  }
  return max
}

export function validateWidgetBlueprint(blueprint) {
  if (!blueprint || typeof blueprint !== 'object') {
    return { valid: false, reason: 'Blueprint must be a JSON object.' }
  }
  const serialized = JSON.stringify(blueprint)
  if (Buffer.byteLength(serialized, 'utf8') > MAX_WIDGET_BYTES) {
    return { valid: false, reason: `Blueprint exceeds ${MAX_WIDGET_BYTES} byte safety cap.` }
  }
  if (measureDepth(blueprint) > MAX_WIDGET_DEPTH) {
    return { valid: false, reason: `Blueprint exceeds max nesting depth (${MAX_WIDGET_DEPTH}).` }
  }
  if (!SUPPORTED_WIDGET_KINDS.includes(blueprint.kind)) {
    return { valid: false, reason: `Unsupported widget kind "${blueprint.kind}"; render in sandboxed WebView.` }
  }
  return { valid: true, kind: blueprint.kind }
}

// --- 2. Universal Connectors Registry (GitHub / Mail / Remote MCP, Keychain-backed) ---
export const CONNECTOR_TYPES = Object.freeze(['github', 'mail', 'remote-mcp'])

export class ConnectorRegistry {
  #file

  constructor(dshHome) {
    this.#file = join(dshHome, 'connectors.json')
  }

  list() {
    return Object.values(this.#read())
  }

  upsert({ id, type, name, endpoint, keychainAccount, enabled = true }) {
    if (!CONNECTOR_TYPES.includes(type)) {
      throw new Error(`Unsupported connector type: ${type}`)
    }
    const store = this.#read()
    const key = id || `conn_${type}_${Date.now().toString(36)}`
    // Never store raw secret values in connectors.json — only the iOS Keychain account reference!
    store[key] = {
      id: key,
      type,
      name: String(name || key),
      endpoint: String(endpoint || ''),
      keychainAccount: String(keychainAccount || `connector:${key}`),
      enabled: Boolean(enabled),
      updatedAt: new Date().toISOString(),
    }
    this.#write(store)
    return store[key]
  }

  remove(id) {
    const store = this.#read()
    if (!store[id]) return { removed: false }
    delete store[id]
    this.#write(store)
    return { removed: true, id }
  }

  #read() {
    if (!existsSync(this.#file)) return {}
    try { return JSON.parse(readFileSync(this.#file, 'utf8')) } catch { return {} }
  }

  #write(data) {
    mkdirSync(dirname(this.#file), { recursive: true })
    const tmp = `${this.#file}.tmp`
    writeFileSync(tmp, `${JSON.stringify(data, null, 2)}\n`, 'utf8')
    writeFileSync(this.#file, readFileSync(tmp, 'utf8'), 'utf8')
    rmSync(tmp, { force: true })
  }
}

// --- 3. Token Usage & Cache-Hit Tracker (`usage.js`) ---
export class UsageTracker {
  #file

  constructor(dshHome) {
    this.#file = join(dshHome, 'usage.json')
  }

  record({ botId, model, inputTokens = 0, cachedInputTokens = 0, outputTokens = 0, at = new Date().toISOString() }) {
    const rows = this.#read()
    rows.push({
      botId: String(botId),
      model: String(model),
      inputTokens: Number(inputTokens) || 0,
      cachedInputTokens: Number(cachedInputTokens) || 0,
      outputTokens: Number(outputTokens) || 0,
      day: String(at).slice(0, 10),
      at,
    })
    this.#write(rows)
  }

  summarize({ botId = null, model = null, sinceDay = null } = {}) {
    const filtered = this.#read().filter((r) =>
      (botId === null || r.botId === botId)
      && (model === null || r.model === model)
      && (sinceDay === null || r.day >= sinceDay),
    )
    let inputTokens = 0
    let cachedInputTokens = 0
    let outputTokens = 0
    const byBot = {}
    const byModel = {}

    for (const r of filtered) {
      inputTokens += r.inputTokens
      cachedInputTokens += r.cachedInputTokens
      outputTokens += r.outputTokens
      byBot[r.botId] = (byBot[r.botId] ?? 0) + r.inputTokens + r.outputTokens
      byModel[r.model] = (byModel[r.model] ?? 0) + r.inputTokens + r.outputTokens
    }
    const cacheHitRate = inputTokens > 0 ? Number((cachedInputTokens / inputTokens).toFixed(4)) : 0
    return {
      turns: filtered.length,
      inputTokens,
      cachedInputTokens,
      outputTokens,
      totalTokens: inputTokens + outputTokens,
      cacheHitRate,
      byBot,
      byModel,
    }
  }

  #read() {
    if (!existsSync(this.#file)) return []
    try { return JSON.parse(readFileSync(this.#file, 'utf8')) } catch { return [] }
  }

  #write(rows) {
    mkdirSync(dirname(this.#file), { recursive: true })
    const tmp = `${this.#file}.tmp`
    writeFileSync(tmp, `${JSON.stringify(rows, null, 2)}\n`, 'utf8')
    writeFileSync(this.#file, readFileSync(tmp, 'utf8'), 'utf8')
    rmSync(tmp, { force: true })
  }
}

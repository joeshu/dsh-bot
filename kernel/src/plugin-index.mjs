// DSH Community Plugin Index Source Manager (matches Fish Pocket / DSH index.json ecosystem).
// Supports built-in third-party community indexes (disabled by default, mutually exclusive)
// plus arbitrary user-added `https://.../index.json` sources.

import { existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { dirname, join } from 'node:path'

export const EXAMPLE_INDEX_SOURCES = Object.freeze([
  {
    id: 'dsh-market',
    name: 'dsh-market',
    badge: '第三方',
    description: '社区维护的 DSH 插件目录，发布在 GitHub 上，通过 jsDelivr 访问。',
    host: 'cdn.jsdelivr.net',
    url: 'https://cdn.jsdelivr.net/gh/dsh-market/index@main/index.json',
    builtInExample: true,
  },
  {
    id: 'dshfind',
    name: 'dshfind',
    badge: '第三方',
    description: '社区维护的 DSH 插件目录，由 dshfind.com 提供。',
    host: 'api.dshfind.com',
    url: 'https://api.dshfind.com/v1/index.json',
    builtInExample: true,
  },
])

export const BUILTIN_FEATURES = Object.freeze([
  { id: 'subagents', title: '子智能体', description: '设置子智能体的递归层级、数量和模型。', icon: 'person.2' },
  { id: 'web-search-fetch', title: '网页搜索与获取', description: '选择搜索和读取网页各用哪个提供方。', icon: 'magnifyingglass' },
  { id: 'agent-loop', title: 'Agent 循环', description: '控制 Agent 派发工具调用的方式。', icon: 'arrow.triangle.2.circlepath' },
  { id: 'terminal', title: '终端', description: '限制每条命令最多能跑多久、最多输出多少（iOS 映射远程 MCP/沙盒）。', icon: 'terminal' },
])

export const EXPERIMENTAL_PLUGINS = Object.freeze([
  { id: 'auto-auth-review', name: '@deepseek-ai/dsh-experimental-auto-review', title: '自动授权审查', description: '提供“自动审查”访问模式：每次工具调用前自动评估风险。', defaultEnabled: true },
  { id: 'dev-tools', name: '@deepseek-ai/dsh-experimental-devtools', title: '开发者工具', description: '用于排查问题：在「会话数据诊断」中查看原始事件与状态。', defaultEnabled: false },
  { id: 'deepseek-session-import', name: '@deepseek-ai/dsh-experimental-session-import', title: 'DeepSeek 会话导入', description: '点击“新建会话”旁的按钮上传历史会话记录。', defaultEnabled: false },
  { id: 'changes-worktree', name: '@deepseek-ai/dsh-experimental-changes', title: '变更请求与工作树', description: '在会话侧栏中集中跟踪关联的 Git 变更。', defaultEnabled: true },
  { id: 'liveshare', name: '@deepseek-ai/dsh-experimental-liveshare', title: 'LiveShare 会话分享', description: '把当前会话分享给同事，对方可只读或协作查看。', defaultEnabled: false },
  { id: 'personalization', name: '@deepseek-ai/dsh-experimental-personalization', title: '个性化推荐', description: '针对你对 DSH 的个性化需求提供提示与推荐。', defaultEnabled: true },
  { id: 'git-worktree', name: '@deepseek-ai/dsh-experimental-git-worktree', title: 'Git 工作树', description: '要求在新分支上工作时自动管理工作树。', defaultEnabled: true },
])

/**
 * Manages mutually-exclusive plugin index sources (dsh-market, dshfind, custom index.json)
 * and fetches/normalizes plugin catalog entries for the Discover ("发现") tab.
 */
export class PluginIndexManager {
  #stateFile
  #fetchImpl

  /**
   * @param {{ dshHome: string, fetchImpl: Function }} options
   */
  constructor({ dshHome, fetchImpl }) {
    this.#stateFile = join(dshHome, 'user-plugins', 'index-sources.json')
    this.#fetchImpl = fetchImpl
  }

  listSources() {
    const state = this.#readState()
    const all = [
      ...EXAMPLE_INDEX_SOURCES.map((s) => ({ ...s, enabled: state.activeSourceId === s.id })),
      ...state.customSources.map((s) => ({ ...s, badge: '自定义', builtInExample: false, enabled: state.activeSourceId === s.id })),
    ]
    return {
      activeSourceId: state.activeSourceId,
      sources: all,
    }
  }

  /**
   * Enable a single index source (mutually exclusive: enabling one replaces the active one)
   * or pass `null` to disable all index sources.
   * @param {string | null} sourceId
   */
  setActiveSource(sourceId) {
    const state = this.#readState()
    if (sourceId === null || sourceId === '') {
      state.activeSourceId = null
      this.#writeState(state)
      return this.listSources()
    }
    const valid = EXAMPLE_INDEX_SOURCES.some((s) => s.id === sourceId)
      || state.customSources.some((s) => s.id === sourceId)
    if (!valid) throw new Error(`Unknown plugin index source: "${sourceId}"`)
    state.activeSourceId = sourceId
    this.#writeState(state)
    return this.listSources()
  }

  /**
   * Add a custom `https://.../index.json` plugin index source and optionally activate it.
   * @param {{ url: string, name?: string, activate?: boolean }} input
   */
  addCustomSource({ url, name, activate = true }) {
    let parsed
    try {
      parsed = new URL(url)
    } catch {
      throw new Error(`Invalid index source URL: "${url}"`)
    }
    if (parsed.protocol !== 'https:') {
      throw new Error('Custom plugin index sources must use HTTPS.')
    }
    const state = this.#readState()
    const id = `custom-${parsed.hostname.replace(/[^a-z0-9.-]/giu, '_')}-${Date.now().toString(36)}`
    const entry = {
      id,
      name: (name && name.trim()) || parsed.hostname,
      description: `自定义索引源 (${parsed.hostname})`,
      host: parsed.hostname,
      url: parsed.toString(),
    }
    state.customSources = [...state.customSources.filter((s) => s.url !== entry.url), entry]
    if (activate) state.activeSourceId = id
    this.#writeState(state)
    return this.listSources()
  }

  /**
   * Fetch catalog entries from the currently enabled index source for the "发现" tab.
   */
  async fetchDiscoverCatalog() {
    const { activeSourceId, sources } = this.listSources()
    if (!activeSourceId) {
      return { activeSource: null, items: [] }
    }
    const active = sources.find((s) => s.id === activeSourceId)
    if (!active) return { activeSource: null, items: [] }

    const res = await this.#fetchImpl(active.url, { method: 'GET' })
    if (!res.ok) throw new Error(`Failed to fetch index source "${active.name}" (HTTP ${res.status})`)
    const data = await res.json()
    const rawList = Array.isArray(data) ? data : (data.plugins ?? data.packages ?? data.items ?? [])

    const items = rawList.map((entry) => ({
      name: entry.name ?? entry.package ?? '',
      title: entry.title ?? entry.name ?? '',
      version: entry.version ?? 'latest',
      description: entry.description ?? '',
      author: entry.author ?? '',
      repository: entry.repository ?? entry.github ?? null,
      keywords: entry.keywords ?? [],
      sourceId: active.id,
    })).filter((item) => item.name)

    return { activeSource: active, items }
  }

  /**
   * Toggle an experimental built-in plugin flag.
   */
  listExperimental() {
    const state = this.#readState()
    return EXPERIMENTAL_PLUGINS.map((p) => ({
      ...p,
      enabled: state.experimental[p.id] ?? p.defaultEnabled,
    }))
  }

  setExperimentalEnabled(id, enabled) {
    const exists = EXPERIMENTAL_PLUGINS.some((p) => p.id === id)
    if (!exists) return { found: false }
    const state = this.#readState()
    state.experimental[id] = Boolean(enabled)
    this.#writeState(state)
    return { found: true, id, enabled: state.experimental[id] }
  }

  #readState() {
    if (!existsSync(this.#stateFile)) {
      return { schemaVersion: 1, activeSourceId: null, customSources: [], experimental: {} }
    }
    try {
      const parsed = JSON.parse(readFileSync(this.#stateFile, 'utf8'))
      return {
        schemaVersion: 1,
        activeSourceId: parsed.activeSourceId ?? null,
        customSources: Array.isArray(parsed.customSources) ? parsed.customSources : [],
        experimental: parsed.experimental && typeof parsed.experimental === 'object' ? parsed.experimental : {},
      }
    } catch {
      return { schemaVersion: 1, activeSourceId: null, customSources: [], experimental: {} }
    }
  }

  #writeState(state) {
    mkdirSync(dirname(this.#stateFile), { recursive: true })
    const tmp = `${this.#stateFile}.tmp`
    writeFileSync(tmp, `${JSON.stringify(state, null, 2)}\n`, 'utf8')
    writeFileSync(this.#stateFile, readFileSync(tmp, 'utf8'), 'utf8')
    rmSync(tmp, { force: true })
  }
}

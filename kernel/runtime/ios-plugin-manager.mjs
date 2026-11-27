import { randomUUID, createHash } from 'node:crypto'
import { copyFile, lstat, mkdir, readFile, readdir, realpath, rename, rm, writeFile } from 'node:fs/promises'
import { isIP } from 'node:net'
import { basename, dirname, extname, isAbsolute, join, relative, resolve, sep } from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'
import { createGunzip } from 'node:zlib'
import semver from 'semver'
import {
  createRuntimeResolution,
  loadProfileDirectory,
  readProfileManifest,
  readProfilePlugins,
} from '@deepseek-ai/dsh-app-boot'

const MAX_INDEX_BYTES = 32 * 1024 * 1024
const MAX_ARCHIVE_BYTES = 48 * 1024 * 1024
const MAX_UNPACKED_BYTES = 128 * 1024 * 1024
const MAX_PACKAGE_FILES = 20_000
const PROFILE_BUNDLE = '@dsbot/dsh-ios-profile'
const PENDING_REMOVALS_FILE = 'ios-plugin-pending-removals.json'
const IOS_PRIVATE_API_MARKER = 'DSBOT_IOS_PRIVATE_API_GUARD_V1'
const IOS_WEB_SCOPE_MARKER = 'DSBOT_IOS_WEB_SCOPE_GUARD_V1'
const IOS_REDTEAM_WEB_OPERATION_TIER = `function iosRedteamWebOperationTier(op) {
  if (['updateApply', 'proxyPoolConnect', 'proxyProfileConnect'].includes(op)) return 'unsupported'
  const tiers = {
    read: new Set(['bootstrap', 'teamBoard', 'agentsStatus', 'orchestratorSettings', 'platformConfigGet', 'platformEnvAdaptStatus', 'skillCatalog', 'skillRead', 'version', 'updateCheck', 'sessionBinding', 'sessionBindings', 'snapshot', 'assets', 'asset', 'graph', 'attackGraph', 'stats', 'vulns', 'vulnStats', 'domains', 'web', 'httpEvidence', 'chain', 'report', 'reportTargets', 'scoreChain', 'scoreReport', 'scores', 'testStats', 'consoleDigest', 'discoveryTimeline', 'prompts', 'stages', 'activeTests', 'attention', 'intelStatus', 'shots']),
    sensitiveRead: new Set(['credentials', 'access', 'sessions', 'webshells', 'tunnels', 'dataProofs', 'cleanup', 'attackFiles', 'readAttackFile', 'shotData', 'pocSearch', 'pocList', 'pocGet', 'pocStats', 'templateSearch', 'templateStats', 'cveSearch', 'cveLookup', 'templateCatalogStatus', 'proxyPoolGet']),
    write: new Set(['openEngagement', 'activateEngagement', 'bindSessionEngagement', 'savePrompt', 'resetPrompts', 'updateVuln', 'saveScorePoint', 'deleteScorePoint', 'addScoreHit', 'setAgentsMax', 'setOrchestratorSettings', 'platformConfigSave', 'platformAssignToolkit', 'platformEnvAdaptSkip', 'addVuln', 'shotAdd', 'shotDelete', 'addHttpEvidence', 'addChainStep', 'assetTest', 'assessAsset', 'saveStage', 'attentionAck', 'import', 'updateCleanup']),
    sensitiveWrite: new Set(['probeSessions', 'intelRefresh', 'intelSync', 'addCredential', 'addAccess', 'addWebshell', 'updateWebshell', 'addTunnel', 'updateTunnel', 'addDataProof', 'addCleanup', 'addAttackFile', 'pocSave', 'pocUpdate', 'pocDelete', 'pocUse', 'proxyConfigImport', 'proxyPoolImport', 'proxyPoolSave', 'proxyPoolDisconnect', 'proxyProfileSave', 'proxyProfileDelete', 'proxyProfilesDelete', 'proxyProfileTest', 'proxyPoolTest']),
  }
  if (tiers.sensitiveWrite.has(op)) return 'sensitiveWrite'
  if (tiers.write.has(op)) return 'write'
  if (tiers.sensitiveRead.has(op)) return 'sensitiveRead'
  if (tiers.read.has(op)) return 'read'
  return undefined
}`
const IOS_PRIVATE_API_HELPERS = `/* ${IOS_PRIVATE_API_MARKER} */
function iosPrivateSessionRoots() {
  if (process.env.DS_BOT_IOS_HOST !== '1') return null
  try {
    const values = JSON.parse(process.env.DS_BOT_IOS_PRIVATE_BOT_IDS || '[]')
    if (!Array.isArray(values) || values.some((id) => typeof id !== 'string')) return new Set(['*'])
    return new Set(values.map((id) => id.startsWith('ios:') ? id : 'ios:' + id))
  } catch { return new Set(['*']) }
}
function iosPrivateSessionClosure(rows) {
  const roots = iosPrivateSessionRoots()
  if (roots === null) return new Set()
  if (roots.has('*')) return new Set(rows.map((row) => String(row?.id ?? row?.header?.id ?? '')).filter(Boolean))
  const byId = new Map(rows.map((row) => [String(row?.id ?? row?.header?.id ?? ''), row]))
  const hidden = new Set()
  for (const row of rows) {
    const id = String(row?.id ?? row?.header?.id ?? '')
    let cursor = id
    const seen = new Set()
    for (let depth = 0; cursor && depth < 64 && !seen.has(cursor); depth += 1) {
      if (roots.has(cursor)) { hidden.add(id); break }
      seen.add(cursor)
      cursor = String(byId.get(cursor)?.header?.parentSession ?? '')
    }
  }
  return hidden
}
function visibleIOSSessions(sessions) {
  const rows = sessions.list()
  const hidden = iosPrivateSessionClosure(rows)
  return rows.filter((row) => !hidden.has(String(row?.id ?? row?.header?.id ?? '')))
}
function isPrivateIOSSessionReference(ctx, sessionId) {
  if (process.env.DS_BOT_IOS_HOST !== '1' || typeof sessionId !== 'string' || !sessionId) return false
  let sessions
  try { sessions = ctx.get('sessions') } catch { return true }
  if (!sessions || typeof sessions.list !== 'function') return true
  const roots = iosPrivateSessionRoots()
  if (roots?.has('*')) return true
  const aliases = new Set([sessionId, sessionId.startsWith('ios:') ? sessionId.slice(4) : 'ios:' + sessionId])
  if ([...aliases].some((id) => roots?.has(id))) return true
  const rows = sessions.list()
  const hidden = iosPrivateSessionClosure(rows)
  return [...hidden].some((id) => aliases.has(id))
}
${IOS_REDTEAM_WEB_OPERATION_TIER}
`
const DESKTOP_ONLY_BUNDLES = new Set([
  '@deepseek-ai/dsh',
  '@deepseek-ai/dsh-base',
  '@deepseek-ai/dsh-web-app',
  '@deepseek-ai/dsh-web-frontend',
  '@deepseek-ai/dsh-shell',
  '@deepseek-ai/dsh-terminal',
  '@deepseek-ai/dsh-cordis-client-runner',
  '@deepseek-ai/dsh-cordis-host-runner',
  '@deepseek-ai/dsh-sdk-app',
  '@deepseek-ai/dsh-sdk-minimal',
  '@deepseek-ai/dsh-experimental-terminal-bundle',
  '@deepseek-ai/dsh-cua-bundle',
])
const DEFAULT_SOURCES = [
  {
    id: 'dsh-market', name: 'dsh-market',
    url: 'https://cdn.jsdelivr.net/npm/dsh-plugin-catalog/index.json', enabled: true, builtIn: true,
  },
  {
    id: 'dshfind', name: 'dshfind',
    url: 'https://api.dshfind.com/market/dsh-index.json', enabled: false, builtIn: true,
  },
]

function packageName(value) {
  return typeof value === 'string'
    && /^(?:@[a-z0-9._-]+\/)?[a-z0-9][a-z0-9._-]*$/i.test(value)
    && !value.split('/').some((part) => part === '.' || part === '..')
}

function isBlockedPluginHost(rawHost) {
  const host = String(rawHost ?? '').trim().toLowerCase().replace(/^\[|\]$/g, '').split('%')[0]
  if (!host || host === 'localhost' || host.endsWith('.local') || host.endsWith('.internal')) return true
  const ver = isIP(host)
  if (ver === 4) {
    const [a, b] = host.split('.').map(Number)
    return a === 0 || a === 10 || a === 127
      || (a === 100 && b >= 64 && b <= 127)
      || (a === 169 && b === 254)
      || (a === 172 && b >= 16 && b <= 31)
      || (a === 192 && b === 168)
      || a >= 224
  }
  if (ver === 6) {
    return host === '::' || host === '::1'
      || host.startsWith('fc') || host.startsWith('fd')
      || /^fe[89ab]/.test(host) || host.startsWith('ff')
      || host.startsWith('::ffff:')
  }
  return false
}

function httpsURL(value) {
  let url
  try { url = new URL(value) } catch { throw new TypeError('需要完整的 HTTPS URL') }
  if (url.protocol !== 'https:' || !url.hostname || url.username || url.password) {
    throw new TypeError('插件索引与包下载只接受 HTTPS 地址')
  }
  if (isBlockedPluginHost(url.hostname)) {
    throw new TypeError('插件索引与包下载禁止访问本机或内网地址')
  }
  return url
}

function assertInside(root, path) {
  const rel = relative(root, path)
  if (!rel || rel.startsWith(`..${sep}`) || rel === '..' || isAbsolute(rel)) {
    if (rel === '') return
    throw new Error('插件包包含越界路径')
  }
}

function replaceCompatibilityAnchor(source, before, after, label) {
  const first = source.indexOf(before)
  if (first < 0 || source.indexOf(before, first + before.length) >= 0) {
    throw new Error(`dsh-purge-safe 的 iOS 适配点不匹配：${label}；为避免 Web API 泄露私密会话，已拒绝安装此版本`)
  }
  return `${source.slice(0, first)}${after}${source.slice(first + before.length)}`
}

const IOS_CORE_WRITABLE_MARKER = 'DSBOT_IOS_WRITABLE_AI_BASE_V1'

async function stageWritablePurgeSafeAiBase(pluginRoot, dshHomeFallback = '') {
  const dshHome = process.env.DSH_HOME || dshHomeFallback || resolve(pluginRoot, '..', '..', '..', '..')
  const bundledNodeModules = fileURLToPath(new URL('./node_modules', import.meta.url))
  const bundledAiBase = join(bundledNodeModules, '@deepseek-ai')
  const writableRoot = join(dshHome, 'dsh-purge-safe', 'writable-host', 'node_modules')
  const writableAiBase = join(writableRoot, '@deepseek-ai')
  const sentinelTarget = join(writableAiBase, 'dsh-agent-instructions', 'lib', 'index.js')
  await mkdir(join(writableAiBase, 'dsh-agent-instructions', 'lib'), { recursive: true })
  process.env.DSH_BASE = writableAiBase

  const stampPath = join(dshHome, 'dsh-purge-safe', 'writable-host', '.ios-stage-stamp')
  const pluginPkg = await readFile(join(pluginRoot, 'package.json'), 'utf8').then(JSON.parse).catch(() => ({}))
  const bundledStampMtime = await lstat(join(bundledAiBase, 'dsh-agent-instructions', 'lib', 'index.js'))
    .then((st) => Math.floor(st.mtimeMs))
    .catch(() => 0)
  const expectedStamp = `${pluginPkg.version ?? '0'}|0.2.2-rc.5|${bundledStampMtime}|${IOS_CORE_WRITABLE_MARKER}`
  const currentStamp = await readFile(stampPath, 'utf8').catch(() => '')
  const sentinelExists = await lstat(sentinelTarget).then(() => true).catch(() => false)
  if (currentStamp.trim() === expectedStamp && sentinelExists) {
    return writableAiBase
  }

  let coreMod
  const coreFilePath = join(pluginRoot, 'lib', 'core.js')
  try {
    const coreRev = await lstat(coreFilePath).then((st) => Math.floor(st.mtimeMs)).catch(() => Date.now())
    coreMod = await import(`${pathToFileURL(coreFilePath).href}?rev=${coreRev}`)
  } catch {
    return writableAiBase
  }
  if (typeof coreMod?.targetFiles !== 'function') return writableAiBase

  const targetMap = coreMod.targetFiles(bundledAiBase, dshHome)
  const relFiles = new Set(['@deepseek-ai/dsh-agent-instructions/lib/index.js'])
  for (const val of Object.values(targetMap || {})) {
    const list = Array.isArray(val) ? val : [val]
    for (const filePath of list) {
      if (typeof filePath === 'string' && filePath.startsWith(bundledNodeModules)) {
        const rel = relative(bundledNodeModules, filePath)
        if (rel && !rel.startsWith('..')) {
          relFiles.add(rel)
          const parts = rel.split(sep)
          if (parts.length >= 2) {
            relFiles.add(join(parts[0], parts[1], 'package.json'))
          }
        }
      }
    }
  }
  for (const apiFile of ['openai-completions.js', 'openai-responses-shared.js', 'anthropic-messages.js']) {
    relFiles.add(join('@earendil-works', 'pi-ai', 'dist', 'api', apiFile))
  }

  // Parallel staging copy (3-5x faster cold boot after plugin install/upgrade)
  const copyList = [...relFiles]
  await Promise.all(copyList.map(async (rel) => {
    const src = join(bundledNodeModules, rel)
    const dst = join(writableRoot, rel)
    try {
      await lstat(src)
    } catch {
      return
    }
    const dstExists = await lstat(dst).then(() => true).catch(() => false)
    if (!dstExists || currentStamp.trim() !== expectedStamp) {
      await mkdir(dirname(dst), { recursive: true })
      await copyFile(src, dst)
    }
  }))
  await writeFile(stampPath, `${expectedStamp}\n`, 'utf8').catch(() => {})
  return writableAiBase
}

async function adaptPurgeSafeCoreForIOS(pluginRoot) {
  const corePath = resolve(pluginRoot, 'lib', 'core.js')
  let source
  try { source = await readFile(corePath, 'utf8') } catch (error) {
    if (error.code !== 'ENOENT') throw error
  }
  if (source && !source.includes(IOS_CORE_WRITABLE_MARKER)) {
    const thisProcAnchor = 'function thisProcessAiBase() {'
    if (source.includes(thisProcAnchor)) {
      source = source.replace(
        thisProcAnchor,
        `function thisProcessAiBase() {\n  /* ${IOS_CORE_WRITABLE_MARKER} */\n  if (process.env.DS_BOT_IOS_HOST === '1' && process.env.DSH_BASE && isAiBase(path.normalize(process.env.DSH_BASE))) return path.normalize(process.env.DSH_BASE);`,
      )
    }
    const webNpmAnchor = 'export function findAiBaseWebNpm() {'
    if (source.includes(webNpmAnchor)) {
      source = source.replace(
        webNpmAnchor,
        `export function findAiBaseWebNpm() {\n  if (process.env.DS_BOT_IOS_HOST === '1' && process.env.DSH_BASE && isAiBase(path.normalize(process.env.DSH_BASE))) return path.normalize(process.env.DSH_BASE);`,
      )
    }
    await writeFile(corePath, source, 'utf8')
  }

  const toolsPath = resolve(pluginRoot, 'lib', 'redteam', 'tools.js')
  let toolsSource
  try { toolsSource = await readFile(toolsPath, 'utf8') } catch (error) {
    if (error.code !== 'ENOENT') throw error
  }
  if (toolsSource && !toolsSource.includes(IOS_CORE_WRITABLE_MARKER)) {
    const toolsAnchor = 'function loadDefineTool() {\n  const candidates = []'
    if (toolsSource.includes(toolsAnchor)) {
      const runtimePackageJson = JSON.stringify(fileURLToPath(new URL('./package.json', import.meta.url)))
      toolsSource = toolsSource.replace(
        toolsAnchor,
        `function loadDefineTool() {\n  /* ${IOS_CORE_WRITABLE_MARKER} */\n  const candidates = [${runtimePackageJson}]`,
      )
      await writeFile(toolsPath, toolsSource, 'utf8')
    }
  }
}

/** Apply host-only routing/privacy changes without altering the upstream plugin on disk. */
export async function ensurePurgeSafeIOSCompatibility(pluginRoot, dshHomeFallback = '') {
  await adaptPurgeSafeCoreForIOS(pluginRoot)
  const writableAiBase = await stageWritablePurgeSafeAiBase(pluginRoot, dshHomeFallback)
  const uiPath = resolve(pluginRoot, 'lib', 'redteam', 'ui.js')
  let source
  try { source = await readFile(uiPath, 'utf8') } catch (error) {
    if (error.code === 'ENOENT') return { webWorkbenchAvailable: false, reason: '插件包未包含 lib/redteam/ui.js', writableAiBase }
    throw error
  }
  if (!source.includes(IOS_PRIVATE_API_MARKER)) {
    const rowAnchor = 'function sessionRowsOf(sessions) {\n  return sessions.list().map((s) => {'
    source = replaceCompatibilityAnchor(
      source,
      rowAnchor,
      `${IOS_PRIVATE_API_HELPERS}\nfunction sessionRowsOf(sessions) {\n  return visibleIOSSessions(sessions).map((s) => {`,
      'teamBoard 会话列表',
    )
    source = replaceCompatibilityAnchor(
      source,
      'const roots = sessions.list().filter((s) => {',
      'const roots = visibleIOSSessions(sessions).filter((s) => {',
      'agentsStatus 会话列表',
    )
    source = replaceCompatibilityAnchor(
      source,
      "if (k && k.kind === 'child') children.push({ id: String(k.id), parent: String(root.id), label: k.label || String(k.id), activity: k.activity, mode: k.mode })",
      "if (k && k.kind === 'child' && !isPrivateIOSSessionReference(ctx, String(k.id))) children.push({ id: String(k.id), parent: String(root.id), label: k.label || String(k.id), activity: k.activity, mode: k.mode })",
      'agentsStatus 子会话列表',
    )
    source = replaceCompatibilityAnchor(
      source,
      '      /* 来源校验：本机回环一律放行（官方桌面端 Origin 常是 app:// / file://，',
      `      if (process.env.DS_BOT_IOS_HOST === '1' && process.env.DS_BOT_IOS_REDTEAM_ENABLED !== '1') {\n        sendJson(res, 503, { ok: false, error: 'iOS 插件工具宿主尚未启用' })\n        return\n      }\n      /* 来源校验：本机回环一律放行（官方桌面端 Origin 常是 app:// / file://，`,
      'Web 演练台宿主开关',
    )
    source = replaceCompatibilityAnchor(
      source,
      '        const request = raw.trim() ? JSON.parse(raw) : {}',
      `        const request = raw.trim() ? JSON.parse(raw) : {}\n        if (isPrivateIOSSessionReference(ctx, request?.session) || isPrivateIOSSessionReference(ctx, request?.session_id)) {\n          sendJson(res, 404, { ok: false, error: 'not found' })\n          return\n        }`,
      'Web API 私密会话引用检查',
    )
  } else {
    const legacyPrivateCheck = `  const hidden = iosPrivateSessionClosure(rows)\n  const aliases = new Set([sessionId, sessionId.startsWith('ios:') ? sessionId.slice(4) : 'ios:' + sessionId])\n  return [...hidden].some((id) => aliases.has(id))`
    if (source.includes(legacyPrivateCheck)) {
      source = source.replace(legacyPrivateCheck, `  const roots = iosPrivateSessionRoots()\n  if (roots?.has('*')) return true\n  const aliases = new Set([sessionId, sessionId.startsWith('ios:') ? sessionId.slice(4) : 'ios:' + sessionId])\n  if ([...aliases].some((id) => roots?.has(id))) return true\n  const hidden = iosPrivateSessionClosure(rows)\n  return [...hidden].some((id) => aliases.has(id))`)
    }
    source = source.replace(
      'if (isPrivateIOSSessionReference(ctx, request?.session)) {',
      'if (isPrivateIOSSessionReference(ctx, request?.session) || isPrivateIOSSessionReference(ctx, request?.session_id)) {',
    )
  }

  if (!source.includes('function iosRedteamWebOperationTier(op) {')) {
    source = replaceCompatibilityAnchor(
      source,
      'function sessionRowsOf(sessions) {',
      `${IOS_REDTEAM_WEB_OPERATION_TIER}\nfunction sessionRowsOf(sessions) {`,
      'Web 演练台授权分类表',
    )
  }

  if (!source.includes(IOS_WEB_SCOPE_MARKER)) {
    const requestAnchor = `        const request = raw.trim() ? JSON.parse(raw) : {}\n        if (isPrivateIOSSessionReference(ctx, request?.session) || isPrivateIOSSessionReference(ctx, request?.session_id)) {\n          sendJson(res, 404, { ok: false, error: 'not found' })\n          return\n        }`
    source = replaceCompatibilityAnchor(
      source,
      requestAnchor,
      `${requestAnchor}\n        /* ${IOS_WEB_SCOPE_MARKER} */\n        const tier = iosRedteamWebOperationTier(request?.op)\n        const scopes = { read: process.env.DS_BOT_IOS_REDTEAM_WEB_READ === '1', write: process.env.DS_BOT_IOS_REDTEAM_WEB_WRITE === '1', sensitive: process.env.DS_BOT_IOS_REDTEAM_WEB_SENSITIVE === '1' }\n        const permitted = tier === 'read' ? scopes.read\n          : tier === 'sensitiveRead' ? scopes.read && scopes.sensitive\n          : tier === 'write' ? scopes.read && scopes.write\n          : tier === 'sensitiveWrite' ? scopes.read && scopes.write && scopes.sensitive\n          : false\n        if (!permitted) {\n          sendJson(res, 403, { ok: false, error: tier ? 'iOS Web 演练台未获此操作权限' : 'iOS 未审核此 Web API 操作，默认拒绝' })\n          return\n        }`,
      'Web 演练台逐类授权',
    )
    source = replaceCompatibilityAnchor(
      source,
      '        sendJson(res, 200, skillResult === undefined ? await dispatchAsync(store, withRoot) : skillResult)',
      `        const response = skillResult === undefined ? await dispatchAsync(store, withRoot) : skillResult\n        if (request.op === 'sessionBindings' && response?.agents && typeof response.agents === 'object') {\n          response.agents = Object.fromEntries(Object.entries(response.agents).filter(([id]) => !isPrivateIOSSessionReference(ctx, id)))\n        }\n        sendJson(res, 200, response)`,
      'Web API 私密绑定结果过滤',
    )
  }
  await writeFile(uiPath, source, 'utf8')
  return { webWorkbenchAvailable: true, writableAiBase }
}

function parsePax(data) {
  const values = {}
  let offset = 0
  while (offset < data.length) {
    const space = data.indexOf(0x20, offset)
    if (space < 0) throw new Error('插件包含有损坏的 PAX 标头')
    const length = Number(data.subarray(offset, space).toString('ascii'))
    if (!Number.isSafeInteger(length) || length <= space - offset + 1 || offset + length > data.length) {
      throw new Error('插件包含有损坏的 PAX 标头')
    }
    const record = data.subarray(space + 1, offset + length - 1).toString('utf8')
    const split = record.indexOf('=')
    if (split > 0) values[record.slice(0, split)] = record.slice(split + 1)
    offset += length
  }
  return values
}

function tarString(header, start, length) {
  return header.subarray(start, start + length).toString('utf8').replace(/\0.*$/s, '')
}

function tarNumber(header, start, length) {
  const bytes = header.subarray(start, start + length)
  if (bytes[0] & 0x80) throw new Error('插件包使用了不支持的扩展文件大小')
  const value = bytes.toString('ascii').replace(/\0.*$/s, '').trim()
  if (!value) return 0
  if (!/^[0-7]+$/.test(value)) throw new Error('插件包含有无效的 tar 大小')
  const parsed = Number.parseInt(value, 8)
  if (!Number.isSafeInteger(parsed) || parsed < 0) throw new Error('插件包文件太大')
  return parsed
}

async function unpackNpmTarball(compressed, destination, { stripSingleRoot = false } = {}) {
  if (compressed.byteLength > MAX_ARCHIVE_BYTES) throw new RangeError('插件压缩包超过 48 MiB')
  const tar = await new Promise((resolveTar, rejectTar) => {
    const gunzip = createGunzip()
    const chunks = []
    let total = 0
    gunzip.on('data', (chunk) => {
      total += chunk.length
      if (total > MAX_UNPACKED_BYTES) {
        gunzip.destroy(new RangeError('插件解压后超过 128 MiB'))
        return
      }
      chunks.push(chunk)
    })
    gunzip.once('error', rejectTar)
    gunzip.once('end', () => resolveTar(Buffer.concat(chunks, total)))
    gunzip.end(compressed)
  })
  let offset = 0
  let unpacked = 0
  let fileCount = 0
  let paxPath
  let longPath
  let detectedRoot
  while (offset + 512 <= tar.length) {
    const header = tar.subarray(offset, offset + 512)
    if (header.every((byte) => byte === 0)) break
    const size = tarNumber(header, 124, 12)
    const start = offset + 512
    const end = start + size
    if (end > tar.length) throw new Error('插件 tar 文件被截断')
    const type = String.fromCharCode(header[156] || 48)
    const prefix = tarString(header, 345, 155)
    const base = tarString(header, 0, 100)
    let name = paxPath ?? longPath ?? [prefix, base].filter(Boolean).join('/')
    paxPath = undefined
    longPath = undefined
    if (type === 'x' || type === 'g') {
      const pax = parsePax(tar.subarray(start, end))
      if (pax.path) paxPath = pax.path
      offset = start + Math.ceil(size / 512) * 512
      continue
    }
    if (type === 'L') {
      longPath = tar.subarray(start, end).toString('utf8').replace(/\0.*$/s, '')
      offset = start + Math.ceil(size / 512) * 512
      continue
    }
    if (type === '1' || type === '2' || type === '3' || type === '4' || type === '6' || type === 'S') {
      throw new Error('插件包包含符号链接或特殊文件，已拒绝安装')
    }
    if (type !== '0' && type !== '\0' && type !== '5' && type !== '7') {
      throw new Error(`插件包包含不支持的 tar 条目类型 ${JSON.stringify(type)}`)
    }
    name = name.replace(/\\/g, '/')
    const parts = name.split('/').filter(Boolean)
    if (!parts.length || parts.some((part) => part === '.' || part === '..')) {
      throw new Error('插件包包含非法路径条目')
    }
    if (stripSingleRoot) {
      if (detectedRoot === undefined) detectedRoot = parts[0]
      else if (parts[0] !== detectedRoot) throw new Error('GitHub 压缩包必须包含单一顶层目录')
    } else if (parts[0] !== 'package') {
      throw new Error('NPM 插件包条目必须位于 package/ 目录内')
    }
    const output = resolve(destination, ...parts.slice(1))
    assertInside(destination, output)
    if (output !== destination) {
      if (type === '5' || name.endsWith('/')) {
        await mkdir(output, { recursive: true })
      } else {
        const lowerExt = extname(output).toLowerCase()
        if (['.node', '.dylib', '.so', '.dll', '.exe'].includes(lowerExt)) {
          throw new Error(`插件包含原生二进制文件 (${parts.slice(1).join('/')})，iOS 沙箱不支持未签名原生模块`)
        }
        fileCount++
        unpacked += size
        if (fileCount > MAX_PACKAGE_FILES || unpacked > MAX_UNPACKED_BYTES) throw new RangeError('插件包解压后超过安全上限')
        await mkdir(dirname(output), { recursive: true })
        const mode = tarNumber(header, 100, 8) & 0o777
        await writeFile(output, tar.subarray(start, end), { flag: 'wx', mode: mode & 0o755 })
      }
    }
    offset = start + Math.ceil(size / 512) * 512
  }
  if (fileCount === 0) throw new Error('插件压缩包中没有文件')
}

async function verifyIntegrity(buffer, integrity) {
  if (typeof integrity !== 'string' || !integrity.trim()) throw new Error('NPM 包缺少 dist.integrity，无法验证下载内容')
  const candidates = integrity.split(/\s+/).map((item) => item.split('-', 2)).filter(([algorithm]) => algorithm === 'sha512')
  if (!candidates.length) throw new Error('NPM 包没有 SHA-512 完整性摘要')
  const actual = createHash('sha512').update(buffer).digest('base64')
  if (!candidates.some(([, expected]) => expected === actual)) throw new Error('插件包的 SHA-512 校验失败')
}

async function fetchBuffer(value, maxBytes, timeoutMs = 20_000) {
  const url = httpsURL(value)
  const signal = AbortSignal.timeout(timeoutMs)
  let next = url
  let response
  for (let hop = 0; ; hop++) {
    response = await fetch(next, { redirect: 'manual', signal })
    if (![301, 302, 303, 307, 308].includes(response.status)) break
    const location = response.headers.get('location')
    await response.body?.cancel()
    if (!location || hop >= 3) throw new Error('下载发生了无效或过多的跳转')
    next = httpsURL(new URL(location, next).href)
    if (next.origin !== url.origin) throw new Error('下载发生了跨域跳转，已拒绝')
  }
  if (!response.ok) throw new Error(`下载失败：HTTP ${response.status}`)
  const declared = Number(response.headers.get('content-length') || 0)
  if (declared > maxBytes) throw new RangeError('下载内容超过大小上限')
  const reader = response.body?.getReader()
  if (!reader) throw new Error('服务器没有返回可读取的下载流')
  const chunks = []
  let total = 0
  while (true) {
    const { done, value } = await reader.read()
    if (done) break
    total += value.byteLength
    if (total > maxBytes) {
      await reader.cancel().catch(() => {})
      throw new RangeError('下载内容超过大小上限')
    }
    chunks.push(Buffer.from(value))
  }
  return Buffer.concat(chunks, total)
}

function latestVersion(versions) {
  const available = (Array.isArray(versions) ? versions : [])
    .filter((entry) => entry && typeof entry.version === 'string' && semver.valid(entry.version) === entry.version)
  available.sort((left, right) => semver.rcompare(left.version, right.version))
  return available[0]
}

function textOf(value) {
  if (typeof value === 'string') return value
  if (value && typeof value === 'object') {
    if (typeof value.zh === 'string') return value.zh
    if (typeof value.en === 'string') return value.en
    return Object.values(value).find((item) => typeof item === 'string') || ''
  }
  return ''
}

function localizedTitle(entry) {
  const title = textOf(entry.title)
  return title || entry.name
}

async function writeManifest(profileDir, manifest, bundles) {
  const next = bundles === undefined ? manifest : {
    ...manifest,
    dsh: { ...manifest.dsh, profile: { ...manifest.dsh?.profile, bundles } },
  }
  const destination = join(profileDir, 'package.json')
  const temporary = `${destination}.${randomUUID()}.tmp`
  try {
    await writeFile(temporary, `${JSON.stringify(next, null, 2)}\n`, { mode: 0o600, flush: true })
    await rename(temporary, destination)
  } finally {
    await rm(temporary, { force: true })
  }
}

const REVISION_FILE = 'ios-plugin-revision.json'

async function writeRevision(profileDir, value) {
  const path = join(profileDir, REVISION_FILE)
  const temp = `${path}.${randomUUID()}.tmp`
  try {
    await writeFile(temp, JSON.stringify(value), { mode: 0o600, flush: true })
    await rename(temp, path)
  } finally {
    await rm(temp, { force: true })
  }
}

export async function settlePluginRevision(profileDir, rollback) {
  const path = join(profileDir, REVISION_FILE)
  let revision
  try {
    revision = JSON.parse(await readFile(path, 'utf8'))
  } catch (error) {
    if (error.code === 'ENOENT') return false
    throw error
  }
  const backupInfo = revision.backup && typeof revision.backup.path === 'string' && typeof revision.backup.target === 'string'
    ? revision.backup : undefined
  if (backupInfo) {
    const backupPath = resolve(backupInfo.path)
    const targetPath = resolve(backupInfo.target)
    assertInside(profileDir, backupPath)
    assertInside(resolve(profileDir, 'node_modules'), targetPath)
    if (rollback) {
      // Restore the previous plugin version instead of leaving the crashed upgrade in place.
      await rm(targetPath, { recursive: true, force: true })
      await rename(backupPath, targetPath).catch((error) => { if (error?.code !== 'ENOENT') throw error })
    } else {
      await rm(backupPath, { recursive: true, force: true }).catch(() => {})
    }
  }
  const configBackup = revision.configBackup && typeof revision.configBackup === 'object'
    ? revision.configBackup : undefined
  if (configBackup) {
    const configPath = resolve(profileDir, 'ios-plugin-configs.json')
    const backupPath = resolve(String(configBackup.path ?? ''))
    const targetPath = resolve(String(configBackup.target ?? ''))
    assertInside(profileDir, backupPath)
    if (targetPath !== configPath) throw new Error('插件配置恢复目标无效')
    if (rollback) {
      if (configBackup.existed === true) {
        await rename(backupPath, targetPath)
      } else {
        await rm(targetPath, { force: true })
      }
    } else {
      await rm(backupPath, { force: true }).catch(() => {})
    }
  }
  if (rollback) {
    await writeManifest(profileDir, revision.previous)
    if (packageName(revision.added)) {
      const modules = resolve(profileDir, 'node_modules')
      const target = resolve(modules, ...revision.added.split('/'))
      assertInside(modules, target)
      await rm(target, { recursive: true, force: true })
    }
  }
  await rm(path, { force: true })
  return true
}

async function readPendingRemovals(profileDir) {
  try {
    const pending = JSON.parse(await readFile(join(profileDir, PENDING_REMOVALS_FILE), 'utf8'))
    if (!Array.isArray(pending) || pending.some((name) => !packageName(name))) {
      throw new Error('待清理插件记录无效')
    }
    return [...new Set(pending)]
  } catch (error) {
    if (error.code === 'ENOENT') return []
    throw error
  }
}

async function writePendingRemovals(profileDir, pending) {
  await mkdir(profileDir, { recursive: true })
  const path = join(profileDir, PENDING_REMOVALS_FILE)
  const temp = `${path}.${randomUUID()}.tmp`
  await writeFile(temp, `${JSON.stringify([...new Set(pending)])}\n`, { mode: 0o600 })
  await rename(temp, path)
}

export async function cleanupPendingPluginRemovals(profileDir) {
  try {
    const entries = await readdir(profileDir, { withFileTypes: true })
    for (const entry of entries) {
      if (/^\.ios-plugin-(?:staging|download|github|backup)-/.test(entry.name)) {
        const orphan = resolve(profileDir, entry.name)
        assertInside(profileDir, orphan)
        await rm(orphan, { recursive: true, force: true }).catch(() => {})
      }
    }
  } catch { /* ignore */ }
  const pending = await readPendingRemovals(profileDir)
  if (!pending.length) return
  const manifest = readProfileManifest('dsh', profileDir)
  const nodeModules = resolve(profileDir, 'node_modules')
  for (const name of pending) {
    if (Object.hasOwn(manifest.dependencies ?? {}, name)) continue
    const target = resolve(nodeModules, ...name.split('/'))
    assertInside(nodeModules, target)
    await rm(target, { recursive: true, force: true })
  }
  await rm(join(profileDir, PENDING_REMOVALS_FILE), { force: true })
}

export function createIOSPluginManager({ rpc, runtime, workspace, profileDir, installAnchor, safeMode = false, drainAgents }) {
  const sourceFile = join(profileDir, 'ios-plugin-sources.json')
  const importRoot = join(workspace, 'plugin-imports')
  const catalogCache = new Map()
  let profileMutationInProgress = false
  let sourceWrite = Promise.resolve()

  function mutateSources(operation) {
    const result = sourceWrite.then(operation)
    sourceWrite = result.catch(() => {})
    return result
  }

  async function embeddedPackages() {
    const manifest = JSON.parse(await readFile(installAnchor, 'utf8'))
    return new Set(Object.keys(manifest.dependencies ?? {}))
  }

  async function updatePendingRemoval(name, add) {
    const pending = await readPendingRemovals(profileDir)
    const next = add ? [...pending, name] : pending.filter((item) => item !== name)
    if (next.length) await writePendingRemovals(profileDir, next)
    else await rm(join(profileDir, PENDING_REMOVALS_FILE), { force: true })
  }

  async function mutateProfile(operation) {
    if (runtime.profileRestartRequired) throw new Error('请重新打开 DS Bot 后再修改插件')
    if (profileMutationInProgress) throw new Error('已有插件 profile 操作正在进行')
    profileMutationInProgress = true
    runtime.pluginMutationInProgress = true
    try {
      if (runtime.preparingTurn || runtime.activeTurns.size > 0) throw new Error('请等当前 Agent 轮次结束后再修改插件')
      await drainAgents()
      const active = [...runtime.activeAgents.values()]
      const disposalFailures = []
      for (const item of active) {
        try { await item.agent.whenIdle() } catch (error) { disposalFailures.push(error) }
      }
      for (const item of active) {
        try { await item.handle.dispose() } catch (error) { disposalFailures.push(error) }
      }
      runtime.activeAgents.clear()
      if (disposalFailures.length) throw new AggregateError(disposalFailures, '无法安全释放现有 DSH Agent')
      return await operation()
    } finally {
      runtime.pluginMutationInProgress = false
      profileMutationInProgress = false
    }
  }

  async function readSources() {
    try {
      const value = JSON.parse(await readFile(sourceFile, 'utf8'))
      if (!Array.isArray(value)) throw new Error('bad index source data')
      return value.filter((item) => item && typeof item.id === 'string' && typeof item.url === 'string')
    } catch (error) {
      if (error.code !== 'ENOENT') throw error
      await writeSources(DEFAULT_SOURCES)
      return structuredClone(DEFAULT_SOURCES)
    }
  }

  async function writeSources(sources) {
    await mkdir(profileDir, { recursive: true })
    const temp = `${sourceFile}.${randomUUID()}.tmp`
    await writeFile(temp, `${JSON.stringify(sources, null, 2)}\n`, { mode: 0o600 })
    await rename(temp, sourceFile)
    catalogCache.clear()
  }

  async function selectedSource() {
    const sources = await readSources()
    const enabled = sources.filter((source) => source.enabled === true)
    if (enabled.length !== 1) throw new Error('请先启用一个插件索引源')
    return enabled[0]
  }

  function catalogFallbackUrls(source) {
    if (source.id === 'dsh-market' && source.url.includes('cdn.jsdelivr.net/npm/dsh-plugin-catalog/index.json')) {
      return [
        source.url,
        'https://fastly.jsdelivr.net/npm/dsh-plugin-catalog/index.json',
        'https://unpkg.com/dsh-plugin-catalog/index.json',
        'https://api.dshfind.com/market/dsh-index.json',
      ]
    }
    return [source.url]
  }

  async function loadCatalog(source, force = false) {
    const cached = catalogCache.get(source.id)
    if (!force && cached && Date.now() - cached.at < 5 * 60_000) return cached.index
    const urls = catalogFallbackUrls(source)
    let lastError
    let buffer
    for (const candidateUrl of urls) {
      try {
        buffer = await fetchBuffer(candidateUrl, MAX_INDEX_BYTES, 25_000)
        break
      } catch (error) {
        lastError = error
      }
    }
    if (!buffer) throw lastError ?? new Error('无法拉取插件索引')
    let index
    try { index = JSON.parse(buffer.toString('utf8')) } catch { throw new Error('插件索引不是有效 JSON') }
    if (!index || index.format !== 1 || !Array.isArray(index.plugins)) throw new Error('只支持 DSH format 1 插件索引')
    if (index.plugins.length > 25_000) throw new RangeError('插件索引条目过多')
    index.plugins = index.plugins.filter((entry) => entry && typeof entry.name === 'string')
    catalogCache.set(source.id, { at: Date.now(), index })
    return index
  }

  function catalogEntry(entry, source) {
    const versions = Array.isArray(entry.versions) ? entry.versions : []
    const latest = latestVersion(versions.filter((item) => item?.source?.type === 'npm'))
      ?? latestVersion(versions.filter((item) => item?.source?.type === 'github'))
      ?? latestVersion(versions)
    const sourceType = latest?.source?.type ?? 'unknown'
    const supportedSource = sourceType === 'npm' || sourceType === 'github'
    return {
      name: entry.name,
      title: localizedTitle(entry),
      description: textOf(entry.description),
      version: latest?.version ?? '',
      homepage: typeof entry.homepage === 'string' ? entry.homepage : '',
      repositoryURL: typeof entry.repository?.url === 'string' ? entry.repository.url : '',
      category: typeof entry.metadata?.category === 'string' ? entry.metadata.category : '',
      sourceId: source.id,
      sourceName: source.name,
      installable: supportedSource && packageName(entry.name) && Boolean(latest?.version),
      installSource: sourceType,
    }
  }

  async function currentProfile() {
    const profile = loadProfileDirectory('dsh', profileDir, installAnchor)
    const skipped = profile.skippedBundles.filter(({ packageName: name }) => name !== PROFILE_BUNDLE)
    return { profile, skipped }
  }

  async function stageProfile(previous, next, bundles, added) {
    await writeRevision(profileDir, { previous, added })
    try {
      await writeManifest(profileDir, next, bundles)
      const { skipped } = await currentProfile()
      if (!safeMode && skipped.length) {
        throw new Error(skipped.map(({ packageName, reason }) => `${packageName}: ${reason}`).join('\n'))
      }
    } catch (error) {
      await settlePluginRevision(profileDir, true)
      throw error
    }
    runtime.profileRestartRequired = true
    return { restartReason: 'profile-change' }
  }

  async function installedPlugins() {
    const { dependencies } = readProfilePlugins({
      binName: 'dsh', profileDir, installAnchor,
    })
    const embedded = await embeddedPackages()
    const profilePkg = await readFile(join(profileDir, 'package.json'), 'utf8').then(JSON.parse).catch(() => ({}))
    const profileDeps = profilePkg.dependencies || {}
    return Promise.all(dependencies.filter((item) => item.bundle && !embedded.has(item.name) && packageName(item.name))
      .map(async (item) => {
        const enabled = !safeMode && runtime.profile.layers.some(({ packageName }) => packageName === item.name)
        const pkgDir = join(profileDir, 'node_modules', ...item.name.split('/'))
        const manifestPath = join(pkgDir, 'package.json')
        const manifest = await readFile(manifestPath, 'utf8').then(JSON.parse).catch(() => ({}))
        const description = typeof manifest.description === 'string' ? manifest.description : ''
        const depSpec = typeof profileDeps[item.name] === 'string' ? profileDeps[item.name] : ''
        const repoUrl = typeof manifest.repository === 'string'
          ? manifest.repository
          : (typeof manifest.repository?.url === 'string' ? manifest.repository.url : '')
        let sourceLabel = 'npm'
        if (depSpec.startsWith('file:')) {
          const ghMatch = repoUrl.match(/github\.com[/:]([^/]+\/[^/.]+)/i)
          sourceLabel = ghMatch ? `github:${ghMatch[1]}` : '本地导入'
        } else if (repoUrl.includes('github.com')) {
          const ghMatch = repoUrl.match(/github\.com[/:]([^/]+\/[^/.]+)/i)
          if (ghMatch) sourceLabel = `github:${ghMatch[1]}`
        }

        // Extract component submodules from manifest.exports or dsh.bundle.patch
        const components = []
        const seenComp = new Set()
        if (manifest.exports && typeof manifest.exports === 'object' && !Array.isArray(manifest.exports)) {
          for (const key of Object.keys(manifest.exports)) {
            if (key === './package.json' || key.endsWith('.json')) continue
            const compName = key === '.' ? item.name : `${item.name}/${key.replace(/^\.\//, '')}`
            if (seenComp.has(compName)) continue
            seenComp.add(compName)
            components.push({
              id: compName,
              name: compName,
              description: key === '.' ? description : `子模块 ${compName}`,
              active: enabled,
            })
          }
        }
        if (components.length === 0) {
          components.push({
            id: item.name,
            name: item.name,
            description,
            active: enabled,
          })
        }

        return {
          name: item.name,
          version: item.version,
          enabled,
          desiredEnabled: item.enabled,
          description,
          sourceLabel,
          components,
          compatibility: manifest.dsh?.client?.platform === 'web' ? 'web-ui' : (enabled ? 'verified' : 'unverified'),
        }
      }))

  }

  function validatePackageName(value) {
    if (!packageName(value) || DESKTOP_ONLY_BUNDLES.has(value)) {
      throw new Error('拒绝安装无效包名或桌面完整 bundle')
    }
  }

  async function inspectPackage(root, expectedName, expectedVersion) {
    const rootStat = await lstat(root)
    if (!rootStat.isDirectory() || rootStat.isSymbolicLink()) throw new Error('插件来源必须是普通目录')
    const manifestPath = join(root, 'package.json')
    let manifest
    try { manifest = JSON.parse(await readFile(manifestPath, 'utf8')) } catch { throw new Error('插件目录缺少有效 package.json') }
    validatePackageName(manifest.name)
    if (expectedName && manifest.name !== expectedName) throw new Error('下载包的名称与索引条目不一致')
    if (expectedVersion && manifest.version !== expectedVersion) throw new Error('下载包的版本与索引条目不一致')
    for (const [engine, version] of [['node', process.versions.node], ['dsh', '0.2.2-rc.5']]) {
      const range = manifest.engines?.[engine]
      if (range !== undefined && (typeof range !== 'string' || !semver.satisfies(version, range, { includePrerelease: true }))) {
        throw new Error(`插件要求 ${engine} ${String(range)}，本机为 ${version}`)
      }
    }
    const bundle = manifest.dsh?.bundle
    if (!bundle || typeof bundle.patch !== 'string' || !bundle.patch.trim()) throw new Error('这不是 DSH profile bundle：缺少 dsh.bundle.patch')
    if (bundle.platforms !== undefined) {
      const allowed = Array.isArray(bundle.platforms) && bundle.platforms.some((platform) => platform === 'ios')
      if (!allowed) throw new Error('该 bundle 的 dsh.bundle.platforms 不支持 iOS')
    }
    const patchPath = resolve(root, bundle.patch)
    assertInside(root, patchPath)
    const patchInfo = await lstat(patchPath).catch(() => undefined)
    if (!patchInfo?.isFile() || patchInfo.isSymbolicLink()) throw new Error('DSH bundle patch 文件缺失或不是普通文件')
    if (manifest.os && Array.isArray(manifest.os) && !manifest.os.some((os) => ['darwin', 'ios', 'any'].includes(os))) {
      throw new Error('NPM os 字段排除了 iOS')
    }
    if (manifest.cpu && Array.isArray(manifest.cpu) && !manifest.cpu.some((cpu) => ['arm64', 'aarch64', 'any'].includes(cpu))) {
      throw new Error('NPM cpu 字段不包含 iPhone arm64')
    }
    const nativeFiles = []
    const unsupportedImports = []
    let filesSeen = 0
    async function walk(directory) {
      for (const entry of await readdir(directory, { withFileTypes: true })) {
        filesSeen++
        if (filesSeen > MAX_PACKAGE_FILES) throw new RangeError('插件文件数超过安全上限')
        const filePath = join(directory, entry.name)
        const info = await lstat(filePath)
        if (info.isSymbolicLink() || (!info.isFile() && !info.isDirectory())) throw new Error('插件目录不能包含链接或特殊文件')
        const extension = extname(entry.name).toLowerCase()
        if (info.isFile() && ['.node', '.dylib', '.so', '.wasm'].includes(extension)) nativeFiles.push(relative(root, filePath))
        if (info.isFile() && ['.js', '.mjs', '.cjs'].includes(extension)) {
          if (info.size > 8 * 1024 * 1024) throw new RangeError('iOS 插件单个 JavaScript 文件不得超过 8 MiB')
          const source = await readFile(filePath, 'utf8')
          if (/(?:from\s*|import\s*\(?\s*|require\s*\(\s*)['"](?:node:)?(?:inspector|vm)(?:\/[^'"]*)?['"]/.test(source)) {
            unsupportedImports.push(relative(root, filePath))
          }
        }
        if (info.isDirectory()) await walk(filePath)
      }
    }
    await walk(root)
    if (nativeFiles.length) throw new Error(`iOS 不支持该包中的本机二进制：${nativeFiles.slice(0, 3).join(', ')}`)
    if (unsupportedImports.length) throw new Error(`iOS profile 不接纳 inspector 或 VM API：${unsupportedImports.slice(0, 3).join(', ')}`)
    return { manifest, patchPath }
  }

  async function assertDependenciesAvailable(manifest, stagedRoot = undefined) {
    const { profile } = await currentProfile()
    const resolution = await createRuntimeResolution({ installAnchor, profile })
    const versions = new Map(resolution.entries.map((entry) => [entry.name, entry.version]))
    for (const [name, range] of Object.entries(manifest.dependencies ?? {})) {
      const version = versions.get(name)
      if (version && semver.satisfies(version, range, { includePrerelease: true })) continue
      if (stagedRoot && packageName(name)) {
        const bundledPkg = resolve(stagedRoot, 'node_modules', ...name.split('/'), 'package.json')
        assertInside(stagedRoot, bundledPkg)
        const bundled = await readFile(bundledPkg, 'utf8').then(JSON.parse).catch(() => undefined)
        if (bundled?.name === name && typeof bundled.version === 'string' && semver.satisfies(bundled.version, range, { includePrerelease: true })) {
          continue
        }
      }
      throw new Error(`缺少 iOS runtime dependency ${name}@${range}；本安装器不会运行 npm/pnpm 脚本或下载未审核依赖`)
    }
    for (const [name, range] of Object.entries(manifest.peerDependencies ?? {})) {
      if (manifest.peerDependenciesMeta?.[name]?.optional) continue
      const version = versions.get(name)
      if (!version || !semver.satisfies(version, range, { includePrerelease: true })) {
        if (name.startsWith('@deepseek-ai/cordis') || name.startsWith('@deepseek-ai/dsh-')) {
          throw new Error(`插件与本机核心框架不兼容（DSH/Cordis 契约冲突）：要求 ${name}@${range}，本机为 ${version ?? '未安装'}`)
        }
        throw new Error(`插件 peer dependency 不兼容：${name}@${range}`)
      }
    }
    return new Set(versions.keys())
  }

  async function inspectDependencyPackage(root, expectedName, expectedVersion) {
    const manifestPath = join(root, 'package.json')
    let manifest
    try { manifest = JSON.parse(await readFile(manifestPath, 'utf8')) } catch { throw new Error('依赖包缺少有效 package.json') }
    validatePackageName(manifest.name)
    if (manifest.name !== expectedName || manifest.version !== expectedVersion) throw new Error('依赖包名称或版本与 registry 元数据不一致')
    const nativeFiles = []
    const unsupportedImports = []
    let filesSeen = 0
    async function walk(directory) {
      for (const entry of await readdir(directory, { withFileTypes: true })) {
        filesSeen++
        if (filesSeen > MAX_PACKAGE_FILES) throw new RangeError('依赖包文件数超过安全上限')
        const filePath = join(directory, entry.name)
        const info = await lstat(filePath)
        if (info.isSymbolicLink() || (!info.isFile() && !info.isDirectory())) throw new Error('依赖包不能包含链接或特殊文件')
        const extension = extname(entry.name).toLowerCase()
        if (info.isFile() && ['.node', '.dylib', '.so', '.wasm'].includes(extension)) nativeFiles.push(relative(root, filePath))
        if (info.isFile() && ['.js', '.mjs', '.cjs'].includes(extension)) {
          if (info.size > 8 * 1024 * 1024) throw new RangeError('依赖包单个 JavaScript 文件不得超过 8 MiB')
          const source = await readFile(filePath, 'utf8')
          if (/(?:from\s*|import\s*\(?\s*|require\s*\(\s*)['"](?:node:)?(?:child_process|worker_threads|cluster|inspector|vm)(?:\/[^'"]*)?['"]/.test(source)) {
            unsupportedImports.push(relative(root, filePath))
          }
        }
        if (info.isDirectory()) await walk(filePath)
      }
    }
    await walk(root)
    if (nativeFiles.length) throw new Error(`依赖包 ${expectedName} 含本机二进制：${nativeFiles.slice(0, 3).join(', ')}`)
    if (unsupportedImports.length) throw new Error(`依赖包 ${expectedName} 使用受限 Node API：${unsupportedImports.slice(0, 3).join(', ')}`)
    return manifest
  }

  async function resolvePureJsDependencies(pluginRoot) {
    const MAX_TRANSITIVE_DEPS = 24
    const MAX_DEPTH = 4
    const { profile } = await currentProfile()
    const resolution = await createRuntimeResolution({ installAnchor, profile })
    const embeddedVersions = new Map(resolution.entries.map((entry) => [entry.name, entry.version]))
    const rootManifest = JSON.parse(await readFile(join(pluginRoot, 'package.json'), 'utf8'))
    const queue = Object.entries(rootManifest.dependencies ?? {}).map(([name, range]) => ({ name, range, depth: 1 }))
    const installed = new Map()
    const pluginNodeModules = resolve(pluginRoot, 'node_modules')
    while (queue.length) {
      const { name, range, depth } = queue.shift()
      if (depth > MAX_DEPTH) throw new Error(`插件依赖层级超过安全上限（${MAX_DEPTH}）`)
      if (typeof range !== 'string' || !packageName(name)) throw new Error(`无效的插件依赖声明：${name}`)
      const embedded = embeddedVersions.get(name)
      if (embedded && semver.satisfies(embedded, range, { includePrerelease: true })) continue
      const existing = installed.get(name)
      if (existing) {
        if (semver.satisfies(existing, range, { includePrerelease: true })) continue
        throw new Error(`插件传递依赖版本冲突：${name}@${range} 与 ${existing}`)
      }
      if (installed.size >= MAX_TRANSITIVE_DEPS) throw new Error(`插件传递依赖数量超过上限（${MAX_TRANSITIVE_DEPS}）`)
      validatePackageName(name)
      const registryName = name.replace('/', '%2f')
      const metadataBuffer = await fetchBuffer(`https://registry.npmjs.org/${registryName}`, MAX_INDEX_BYTES)
      let metadata
      try { metadata = JSON.parse(metadataBuffer.toString('utf8')) } catch { throw new Error(`依赖 ${name} 的 registry 元数据无效`) }
      const availableVersions = Object.keys(metadata.versions ?? {})
      const chosen = semver.maxSatisfying(availableVersions, range, { includePrerelease: true })
      if (!chosen) throw new Error(`无法在 npm registry 解析插件依赖 ${name}@${range}`)
      const info = metadata.versions[chosen]
      if (!info || info.name !== name || typeof info.dist?.tarball !== 'string') throw new Error(`依赖 ${name}@${chosen} 缺少下载地址`)
      const tarball = httpsURL(info.dist.tarball)
      if (tarball.origin !== 'https://registry.npmjs.org') throw new Error(`依赖 ${name} 下载地址不属于 npm registry`)
      const bytes = await fetchBuffer(tarball.href, MAX_ARCHIVE_BYTES)
      await verifyIntegrity(bytes, info.dist.integrity)
      const dest = resolve(pluginNodeModules, ...name.split('/'))
      assertInside(pluginNodeModules, dest)
      await mkdir(dest, { recursive: true })
      await unpackNpmTarball(bytes, dest)
      const depManifest = await inspectDependencyPackage(dest, name, chosen)
      installed.set(name, chosen)
      for (const [subName, subRange] of Object.entries(depManifest.dependencies ?? {})) {
        queue.push({ name: subName, range: subRange, depth: depth + 1 })
      }
    }
  }

  async function packageItems(root) {
    const items = []
    async function walk(directory, depth = 0) {
      if (depth > 16) throw new RangeError('插件目录层级过深')
      for (const entry of await readdir(directory, { withFileTypes: true })) {
        const path = join(directory, entry.name)
        const info = await lstat(path)
        if (info.isSymbolicLink() || (!info.isFile() && !info.isDirectory())) throw new Error('插件目录不能包含链接或特殊文件')
        items.push({ path, directory: info.isDirectory(), bytes: info.size })
        if (info.isDirectory()) await walk(path, depth + 1)
      }
    }
    await walk(root)
    if (items.length > MAX_PACKAGE_FILES) throw new RangeError('插件文件数超过安全上限')
    return items
  }

  async function installDirectory(sourceDirectory, expectedName, expectedVersion) {
    if (safeMode) throw new Error('请先停用有问题的插件，再退出恢复模式')
    const staged = join(profileDir, `.ios-plugin-staging-${randomUUID()}`)
    const items = await packageItems(sourceDirectory)
    let totalBytes = 0
    for (const item of items) totalBytes += item.bytes
    if (totalBytes > MAX_UNPACKED_BYTES) throw new RangeError('插件目录超过 128 MiB')
    await mkdir(staged, { recursive: false })
    try {
      for (const item of items) {
        const rel = relative(sourceDirectory, item.path)
        const output = resolve(staged, rel)
        assertInside(staged, output)
        if (item.directory) await mkdir(output, { recursive: true })
        else {
          await mkdir(dirname(output), { recursive: true })
          await copyFile(item.path, output)
        }
      }
      const { manifest } = await inspectPackage(staged, expectedName, expectedVersion)
      if (manifest.name === 'dsh-purge-safe') await ensurePurgeSafeIOSCompatibility(staged, dirname(profileDir))
      if (DESKTOP_ONLY_BUNDLES.has(manifest.name)) throw new Error('这个完整桌面 bundle 不允许安装到 iOS profile')
      const available = await assertDependenciesAvailable(manifest, staged)
      if (available.has(manifest.name)) throw new Error('插件名称与已经内嵌的 DSH runtime 包冲突')
      const active = await installedPlugins()
      const alreadyInstalled = active.some((item) => item.name === manifest.name)
      const target = resolve(profileDir, 'node_modules', ...manifest.name.split('/'))
      assertInside(resolve(profileDir, 'node_modules'), target)
      await mkdir(dirname(target), { recursive: true })
      const backup = alreadyInstalled ? join(profileDir, `.ios-plugin-backup-${randomUUID()}`) : null
      if (backup) {
        try { await rename(target, backup) } catch (err) {
          if (err?.code !== 'ENOENT') throw err
        }
      }
      await rename(staged, target)
      const previous = readProfileManifest('dsh', profileDir)
      const existingBundles = previous.dsh?.profile?.bundles ?? [PROFILE_BUNDLE]
      const nextBundles = existingBundles.includes(manifest.name) ? existingBundles : [...existingBundles, manifest.name]
      const dependencies = { ...previous.dependencies, [manifest.name]: manifest.version }
      let composition
      try {
        composition = await stageProfile(previous, { ...previous, dependencies }, nextBundles, alreadyInstalled ? undefined : manifest.name)
      } catch (error) {
        await rm(target, { recursive: true, force: true })
        if (backup) await rename(backup, target).catch(() => {})
        throw error
      }
      if (backup) {
        // Keep the old version until the new runtime boots successfully (settled in settlePluginRevision).
        await writeRevision(profileDir, { previous, added: alreadyInstalled ? undefined : manifest.name, backup: { path: backup, target } })
      }
      return {
        name: manifest.name,
        version: manifest.version,
        enabled: true,
        upgraded: alreadyInstalled,
        restartRequired: Boolean(composition?.restartReason) || alreadyInstalled,
        ...(composition?.restartReason
          ? { restartReason: composition.restartReason }
          : (alreadyInstalled ? { restartReason: '已就地更新插件，请重启 DSH 引擎以加载新版本。' } : {})),
      }
    } finally {
      await rm(staged, { recursive: true, force: true })
    }
  }

  async function installFromNpm(name, version, sourceId) {
    validatePackageName(name)
    if (semver.valid(version) !== version) throw new Error('只能安装索引固定列出的具体版本')
    const sources = await readSources()
    const source = sources.find((item) => item.id === sourceId)
    if (!source || source.enabled !== true) throw new Error('插件索引源尚未启用')
    const index = await loadCatalog(source)
    const entry = index.plugins.find((item) => item.name === name)
    const releases = Array.isArray(entry?.versions) ? entry.versions : []
    const release = releases.find((item) => item?.version === version && (item.source?.type === 'npm' || item.source?.type === 'github'))
    if (!release) throw new Error('插件版本不在当前启用的索引源中')
    if (release.source?.type === 'github') {
      const repoSpec = release.source.repo || release.source.repository || release.source.url || entry?.repository?.url || ''
      const refSuffix = release.source.ref ? `#${release.source.ref}` : ''
      if (!repoSpec) throw new Error('GitHub 插件索引缺少仓库地址')
      return await installFromGithub(refSuffix && !String(repoSpec).includes('#') ? `${repoSpec}${refSuffix}` : String(repoSpec))
    }
    const registryName = name.replace('/', '%2f')
    const metadataBuffer = await fetchBuffer(`https://registry.npmjs.org/${registryName}`, MAX_INDEX_BYTES)
    let metadata
    try { metadata = JSON.parse(metadataBuffer.toString('utf8')) } catch { throw new Error('NPM registry 返回了无效 JSON') }
    const packageInfo = metadata.versions?.[version]
    if (!packageInfo || packageInfo.name !== name || packageInfo.version !== version || typeof packageInfo.dist?.tarball !== 'string') {
      throw new Error('NPM registry 没有返回索引指定的精确包版本')
    }
    const tarball = httpsURL(packageInfo.dist.tarball)
    if (tarball.origin !== 'https://registry.npmjs.org') throw new Error('包下载地址不属于已配置的 npm 仓库')
    rpc.notify?.('plugins.progress', { stage: 'download', detail: `正在从 npm 下载 ${name}@${version}…` })
    const bytes = await fetchBuffer(tarball.href, MAX_ARCHIVE_BYTES)
    await verifyIntegrity(bytes, packageInfo.dist.integrity)
    const staging = join(profileDir, `.ios-plugin-download-${randomUUID()}`)
    await mkdir(staging)
    try {
      rpc.notify?.('plugins.progress', { stage: 'unpack', detail: `正在解包并校验 ${name}…` })
      await unpackNpmTarball(bytes, staging)
      rpc.notify?.('plugins.progress', { stage: 'deps', detail: `正在解析纯 JS 依赖树…` })
      await resolvePureJsDependencies(staging)
      rpc.notify?.('plugins.progress', { stage: 'stage', detail: `正在写入 DSH Profile…` })
      return await installDirectory(staging, name, version)
    } finally {
      await rm(staging, { recursive: true, force: true })
    }
  }

  async function setPluginEnabled(name, enabled) {
    validatePackageName(name)
    if (safeMode && enabled) throw new Error('恢复模式下只能停用或卸载插件')
    if (typeof enabled !== 'boolean') throw new TypeError('enabled must be a boolean')
    if ((await embeddedPackages()).has(name)) throw new Error('DS Bot 内置的 DSH profile 插件不能单独停用')
    const before = readProfileManifest('dsh', profileDir)
    const inventory = readProfilePlugins({ binName: 'dsh', profileDir, installAnchor })
    if (!inventory.dependencies.some((item) => item.name === name && item.bundle)) throw new Error('找不到已安装的 DSH 插件 bundle')
    const existing = before.dsh?.profile?.bundles ?? [PROFILE_BUNDLE]
    const bundles = enabled
      ? (existing.includes(name) ? existing : [...existing, name])
      : existing.filter((item) => item !== name || item === PROFILE_BUNDLE)
    const composition = await stageProfile(before, before, bundles)
    return { name, enabled, restartRequired: Boolean(composition?.restartReason),
      ...(composition?.restartReason ? { restartReason: composition.restartReason } : {}) }
  }

  async function removePlugin(name) {
    validatePackageName(name)
    if ((await embeddedPackages()).has(name)) throw new Error('DS Bot 内置的 DSH profile 插件不能卸载')
    const before = readProfileManifest('dsh', profileDir)
    const dependencies = { ...before.dependencies }
    const inventory = readProfilePlugins({ binName: 'dsh', profileDir, installAnchor })
    if (!dependencies[name] || !inventory.dependencies.some((item) => item.name === name && item.bundle)) {
      throw new Error('找不到已安装的 DSH 插件 bundle')
    }
    for (const dependent of inventory.dependencies.filter((item) => item.name !== name && item.bundle)) {
      validatePackageName(dependent.name)
      const packagePath = resolve(profileDir, 'node_modules', ...dependent.name.split('/'), 'package.json')
      assertInside(resolve(profileDir, 'node_modules'), packagePath)
      const dependentManifest = JSON.parse(await readFile(packagePath, 'utf8'))
      if (Object.hasOwn(dependentManifest.dependencies ?? {}, name)
        || (Object.hasOwn(dependentManifest.peerDependencies ?? {}, name)
          && !dependentManifest.peerDependenciesMeta?.[name]?.optional)) {
        throw new Error('不能卸载 ' + name + '：已安装插件 ' + dependent.name + ' 依赖它')
      }
    }
    const bundles = (before.dsh?.profile?.bundles ?? []).filter((item) => item !== name)
    await updatePendingRemoval(name, true)
    let composition
    try {
      delete dependencies[name]
      composition = await stageProfile(before, { ...before, dependencies }, bundles)
    } catch (error) {
      await updatePendingRemoval(name, false)
      throw error
    }
    if (name === 'dsh-purge-safe') {
      await rm(join(workspace, 'dsh-purge-safe', 'writable-host'), { recursive: true, force: true }).catch(() => {})
    }
    return { removed: true, name, restartRequired: Boolean(composition?.restartReason),
      ...(composition?.restartReason ? { restartReason: composition.restartReason } : {}) }
  }

  rpc.handle('plugins.sources.list', async () => ({ sources: await readSources() }))
  rpc.handle('plugins.sources.add', ({ url: value }) => mutateSources(async () => {
    const url = httpsURL(String(value ?? '')).toString()
    const sources = await readSources()
    if (sources.some((source) => source.url === url)) throw new Error('这个插件索引源已经添加')
    const id = `custom-${createHash('sha256').update(url).digest('hex').slice(0, 10)}`
    sources.push({ id, name: new URL(url).hostname, url, enabled: false, builtIn: false })
    await writeSources(sources)
    return { sources }
  }))
  rpc.handle('plugins.sources.enable', ({ id, enabled }) => mutateSources(async () => {
    const sources = await readSources()
    if (!sources.some((source) => source.id === id)) throw new Error('找不到插件索引源')
    await writeSources(sources.map((source) => ({ ...source, enabled: source.id === id && enabled === true })))
    return { sources: await readSources() }
  }))
  rpc.handle('plugins.sources.remove', ({ id }) => mutateSources(async () => {
    const sources = await readSources()
    const source = sources.find((item) => item.id === id)
    if (!source || source.builtIn) throw new Error('内置索引源不能删除')
    await writeSources(sources.filter((item) => item.id !== id))
    return { sources: await readSources() }
  }))
  rpc.handle('plugins.catalog.search', async ({ query = '', offset = 0, limit = 40, refresh = false }) => {
    const source = await selectedSource()
    const index = await loadCatalog(source, refresh === true)
    const normalizedQuery = String(query).trim().toLocaleLowerCase()
    const entries = index.plugins.map((item) => catalogEntry(item, source))
      .filter((item) => !normalizedQuery || [item.name, item.title, item.description, item.category]
        .some((field) => typeof field === 'string' && field.toLocaleLowerCase().includes(normalizedQuery)))
    const start = Math.max(0, Number.isSafeInteger(offset) ? offset : 0)
    const count = Math.min(100, Math.max(1, Number.isSafeInteger(limit) ? limit : 40))
    return { source: source.name, total: entries.length, plugins: entries.slice(start, start + count) }
  })
  function parseGithubSpec(raw) {
    const trimmed = String(raw ?? '').trim()
    if (!trimmed) throw new Error('请输入 GitHub 仓库地址（如 https://github.com/owner/repo）')
    let owner = ''
    let repo = ''
    let ref = ''
    if (/^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+(?:[@#][A-Za-z0-9._/-]+)?$/.test(trimmed)) {
      const [slug, explicitRef = ''] = trimmed.split(/[@#]/, 2)
      ;[owner, repo] = slug.split('/', 2)
      ref = explicitRef
    } else {
      const url = httpsURL(trimmed)
      if (url.hostname !== 'github.com' && url.hostname !== 'www.github.com') {
        throw new Error('只支持 https://github.com/<owner>/<repo> 仓库地址')
      }
      const parts = url.pathname.replace(/\/+$/, '').split('/').filter(Boolean)
      if (parts.length < 2) throw new Error('无效的 GitHub 仓库地址，需要包含 owner/repo')
      owner = parts[0]
      repo = parts[1].replace(/\.git$/i, '')
      if (parts.length >= 4 && parts[2] === 'tree') ref = parts.slice(3).join('/')
      else if (parts.length >= 5 && parts[2] === 'releases' && parts[3] === 'tag') ref = parts.slice(4).join('/')
      else if (parts.length >= 4 && parts[2] === 'commit') ref = parts[3]
      else if (url.hash && url.hash.length > 1) ref = decodeURIComponent(url.hash.slice(1))
    }
    if (!/^[A-Za-z0-9_.-]{1,100}$/.test(owner) || !/^[A-Za-z0-9_.-]{1,100}$/.test(repo)) {
      throw new Error('GitHub 仓库名称包含非法字符')
    }
    if (ref && !/^[A-Za-z0-9._/-]{1,120}$/.test(ref)) throw new Error('GitHub 分支或标签名无效')
    return { owner, repo, ref }
  }

  async function installFromGithub(rawSpec) {
    const { owner, repo, ref } = parseGithubSpec(rawSpec)
    let targetRef = ref
    if (!targetRef) {
      try {
        const metaBuf = await fetchBuffer(`https://api.github.com/repos/${owner}/${repo}`, 2 * 1024 * 1024, 15_000)
        const meta = JSON.parse(metaBuf.toString('utf8'))
        if (typeof meta.default_branch === 'string' && meta.default_branch) {
          targetRef = meta.default_branch
        }
      } catch {
        // Bypass GitHub REST API anonymous rate limits (403/429) via codeload HEAD archive
        targetRef = 'HEAD'
      }
    }
    const tarballUrl = `https://codeload.github.com/${owner}/${repo}/tar.gz/${encodeURIComponent(targetRef || 'HEAD')}`
    rpc.notify?.('plugins.progress', { stage: 'download', detail: `正在下载 GitHub 源码包 ${owner}/${repo}…` })
    const bytes = await fetchBuffer(tarballUrl, MAX_ARCHIVE_BYTES, 45_000)
    const staging = join(profileDir, `.ios-plugin-github-${randomUUID()}`)
    await mkdir(staging)
    try {
      rpc.notify?.('plugins.progress', { stage: 'unpack', detail: `正在解包 ${owner}/${repo}…` })
      await unpackNpmTarball(bytes, staging, { stripSingleRoot: true })
      rpc.notify?.('plugins.progress', { stage: 'deps', detail: `正在解析纯 JS 依赖树…` })
      await resolvePureJsDependencies(staging)
      rpc.notify?.('plugins.progress', { stage: 'stage', detail: `正在校验并写入 DSH Profile…` })
      return await installDirectory(staging)
    } finally {
      await rm(staging, { recursive: true, force: true })
    }
  }

  async function auditInstalledPlugin(name) {
    validatePackageName(name)
    const nodeModules = resolve(profileDir, 'node_modules')
    const root = resolve(nodeModules, ...name.split('/'))
    assertInside(nodeModules, root)
    let manifest
    try { manifest = JSON.parse(await readFile(join(root, 'package.json'), 'utf8')) } catch {
      throw new Error(`找不到已安装插件 ${name}`)
    }
    let fileCount = 0
    let totalBytes = 0
    const findings = []
    let hasElevatedRisk = false
    async function scan(dir, depth = 0) {
      if (depth > 10) return
      for (const entry of await readdir(dir, { withFileTypes: true })) {
        if (entry.name === 'node_modules' && depth === 0) continue
        const full = join(dir, entry.name)
        const info = await lstat(full)
        if (info.isSymbolicLink()) {
          findings.push(`包含符号链接 (${relative(root, full)})`)
          hasElevatedRisk = true
          continue
        }
        if (info.isDirectory()) {
          await scan(full, depth + 1)
        } else if (info.isFile()) {
          fileCount += 1
          totalBytes += info.size
          const ext = extname(entry.name).toLowerCase()
          if (['.js', '.mjs', '.cjs', '.ts', '.mts'].includes(ext) && info.size <= 1024 * 1024) {
            const src = await readFile(full, 'utf8')
            const relFile = relative(root, full)
            if (/(?:from\s*|require\s*\(\s*)['"](?:node:)?child_process['"]/.test(src)) {
              findings.push(`子进程调用引用 (${relFile})`)
              hasElevatedRisk = true
            }
            if (/\beval\s*\(|new\s+Function\s*\(|constructor\s*\(\s*['"]return\s+process['"]/.test(src)) {
              findings.push(`动态代码求值 / 原型链构造 (${relFile})`)
              hasElevatedRisk = true
            }
            if (/(?:from\s*|require\s*\(\s*)['"](?:node:)?(?:vm|worker_threads|module)['"]|createRequire\s*\(/.test(src)) {
              findings.push(`VM / 线程 / 动态模块加载 (${relFile})`)
              hasElevatedRisk = true
            }
            if (/dsh-sessions\.sqlite|dsh-storage\.sqlite/.test(src)) {
              findings.push(`直接引用会话 SQLite 数据库 (${relFile})`)
              hasElevatedRisk = true
            }
            if (/['"]approval\/request['"]|['"]system-prompt['"]/.test(src)) {
              findings.push(`挂钩审批流或系统提示词 (${relFile})`)
              hasElevatedRisk = true
            }
            if (/\bprocess\.env\b/.test(src)) {
              findings.push(`读取进程环境变量 (${relFile})`)
            }
            if (/\bfetch\s*\(|https?\.request\s*\(|new\s+WebSocket\s*\(/.test(src)) {
              findings.push(`外部网络请求能力 (${relFile})`)
            }
          }
        }
      }
    }
    await scan(root)

    // #12213: Audit both engines.dsh and Cordis/DSH peerDependencies explicitly
    const peerIssues = []
    const peerDeps = manifest.peerDependencies && typeof manifest.peerDependencies === 'object' ? manifest.peerDependencies : {}
    for (const [peerName, range] of Object.entries(peerDeps)) {
      if (typeof range !== 'string' || !range.trim()) continue
      if (peerName === '@deepseek-ai/cordis') {
        if (!semver.satisfies('4.1.0', range, { includePrerelease: true })) {
          peerIssues.push(`${peerName} 要求 ${range}（宿主 4.1.0）`)
        }
      } else if (peerName.startsWith('@deepseek-ai/dsh-')) {
        if (!semver.satisfies('0.2.2-rc.5', range, { includePrerelease: true })) {
          peerIssues.push(`${peerName} 要求 ${range}（宿主 0.2.2-rc.5）`)
        }
      }
    }
    for (const issue of peerIssues) {
      findings.push(`依赖版本冲突：${issue}`)
      hasElevatedRisk = true
    }

    const uniqueFindings = [...new Set(findings)].slice(0, 14)
    const dshEngine = typeof manifest.engines?.dsh === 'string' ? manifest.engines.dsh : '未声明'
    const engineMatches = dshEngine === '未声明' || semver.satisfies('0.2.2-rc.5', dshEngine, { includePrerelease: true })
    const dshCompatible = engineMatches && peerIssues.length === 0
    return {
      name: manifest.name,
      version: manifest.version,
      fileCount,
      totalKB: Math.max(1, Math.round(totalBytes / 1024)),
      dshEngine,
      dshCompatible,
      peerIssues,
      patchEntry: manifest.dsh?.bundle?.patch ?? '缺失',
      findings: uniqueFindings,
      riskLevel: hasElevatedRisk
        ? 'elevated'
        : (uniqueFindings.length > 0 ? 'standard' : 'low'),
    }
  }

  const pluginConfigPath = join(profileDir, 'ios-plugin-configs.json')

  async function readPluginConfigs() {
    try {
      const parsed = JSON.parse(await readFile(pluginConfigPath, 'utf8'))
      return parsed && typeof parsed === 'object' && !Array.isArray(parsed) ? parsed : {}
    } catch (error) {
      if (error?.code === 'ENOENT') return {}
      throw error
    }
  }

  async function writePluginConfigs(configs) {
    const temp = `${pluginConfigPath}.${randomUUID()}.tmp`
    try {
      await writeFile(temp, `${JSON.stringify(configs, null, 2)}\n`, { mode: 0o600, flush: true })
      await rename(temp, pluginConfigPath)
    } finally {
      await rm(temp, { force: true })
    }
  }

  async function installLocalPath(resolved) {
    const info = await lstat(resolved)
    if (info.isFile()) {
      const lower = resolved.toLowerCase()
      if (!lower.endsWith('.tgz') && !lower.endsWith('.tar.gz')) {
        throw new Error('本地离线包仅支持文件夹或 .tgz / .tar.gz 压缩包')
      }
      rpc.notify?.('plugins.progress', { stage: 'unpack', detail: '正在解包本地 .tgz 插件包…' })
      const bytes = await readFile(resolved)
      if (bytes.byteLength > MAX_ARCHIVE_BYTES) throw new Error('本地插件压缩包超过 48 MB 限制')
      const staging = join(profileDir, `.ios-plugin-local-${randomUUID()}`)
      await mkdir(staging)
      try {
        await unpackNpmTarball(bytes, staging, { stripSingleRoot: true })
        rpc.notify?.('plugins.progress', { stage: 'deps', detail: '正在解析纯 JS 依赖树…' })
        await resolvePureJsDependencies(staging)
        rpc.notify?.('plugins.progress', { stage: 'stage', detail: '正在写入 DSH Profile…' })
        return await installDirectory(staging)
      } finally {
        await rm(staging, { recursive: true, force: true })
      }
    }
    rpc.notify?.('plugins.progress', { stage: 'stage', detail: '正在校验并导入本地插件目录…' })
    const localStaging = join(profileDir, `.ios-plugin-staging-${randomUUID()}`)
    await mkdir(localStaging)
    try {
      for (const item of await packageItems(resolved)) {
        const output = resolve(localStaging, relative(resolved, item.path))
        assertInside(localStaging, output)
        if (item.directory) await mkdir(output, { recursive: true })
        else { await mkdir(dirname(output), { recursive: true }); await copyFile(item.path, output) }
      }
      rpc.notify?.('plugins.progress', { stage: 'deps', detail: '正在解析纯 JS 依赖树…' })
      await resolvePureJsDependencies(localStaging)
      return await installDirectory(localStaging)
    } finally {
      await rm(localStaging, { recursive: true, force: true })
    }
  }

  rpc.handle('plugins.installed.list', async () => ({ plugins: await installedPlugins() }))
  rpc.handle('plugins.audit', async ({ name }) => auditInstalledPlugin(String(name ?? '')))
  rpc.handle('plugins.config.get', async ({ name }) => {
    const pkgName = String(name ?? '')
    validatePackageName(pkgName)
    const configs = await readPluginConfigs()
    const config = Object.hasOwn(configs, pkgName) && configs[pkgName] && typeof configs[pkgName] === 'object'
      ? configs[pkgName] : {}
    return { name: pkgName, config }
  })
  async function resolvePluginCordisEntryId(pkgName) {
    try {
      const pkgDir = resolve(profileDir, 'node_modules', ...pkgName.split('/'))
      assertInside(resolve(profileDir, 'node_modules'), pkgDir)
      const manifest = JSON.parse(await readFile(join(pkgDir, 'package.json'), 'utf8'))
      const patchRel = manifest?.dsh?.bundle?.patch
      if (typeof patchRel === 'string' && patchRel.trim()) {
        const patchAbs = resolve(pkgDir, patchRel)
        assertInside(pkgDir, patchAbs)
        const patchText = await readFile(patchAbs, 'utf8')
        const idMatch = patchText.match(/^\s*-?\s*id:\s*['"]?([A-Za-z0-9._/@:-]+)['"]?\s*$/m)
        if (idMatch?.[1] && /^[A-Za-z0-9._/@:-]{1,200}$/.test(idMatch[1])) return idMatch[1]
      }
    } catch { /* fallback to package name */ }
    return pkgName
  }

  rpc.handle('plugins.config.set', async ({ name, config }) => mutateProfile(async () => {
    const pkgName = String(name ?? '')
    validatePackageName(pkgName)
    if (!config || typeof config !== 'object' || Array.isArray(config)) {
      throw new Error('插件配置必须是 JSON 对象（例如 {}）')
    }
    const serialized = JSON.stringify(config)
    if (Buffer.byteLength(serialized, 'utf8') > 32 * 1024) throw new Error('插件配置不能超过 32 KB')
    const entryId = await resolvePluginCordisEntryId(pkgName)
    const configs = Object.assign(Object.create(null), await readPluginConfigs())
    configs[pkgName] = config
    if (entryId !== pkgName) configs[entryId] = config
    await mkdir(profileDir, { recursive: true })
    let previousConfig
    try {
      previousConfig = await readFile(pluginConfigPath)
    } catch (error) {
      if (error?.code !== 'ENOENT') throw error
    }
    const backupPath = join(profileDir, `.ios-plugin-config-backup-${randomUUID()}.json`)
    if (previousConfig) await writeFile(backupPath, previousConfig, { mode: 0o600, flag: 'wx', flush: true })
    try {
      await writeRevision(profileDir, {
        previous: readProfileManifest('dsh', profileDir),
        configBackup: { path: backupPath, target: pluginConfigPath, existed: Boolean(previousConfig) },
      })
      await writePluginConfigs(configs)
    } catch (error) {
      await settlePluginRevision(profileDir, true).catch(() => {})
      await rm(backupPath, { force: true }).catch(() => {})
      throw error
    }
    runtime.profileRestartRequired = true
    return { name: pkgName, entryId, saved: true, restartRequired: true }
  }))
  rpc.handle('plugins.disableAll', async () => mutateProfile(async () => {
    const before = readProfileManifest('dsh', profileDir)
    const embedded = await embeddedPackages()
    const existing = before.dsh?.profile?.bundles ?? [PROFILE_BUNDLE]
    const nextBundles = existing.filter((item) => item === PROFILE_BUNDLE || embedded.has(item))
    const disabledCount = existing.length - nextBundles.length
    const composition = await stageProfile(before, before, nextBundles)
    return { disabledCount, restartRequired: Boolean(composition?.restartReason || disabledCount > 0) }
  }))
  rpc.handle('plugins.install.npm', async (params) => mutateProfile(() =>
    installFromNpm(String(params.name ?? ''), String(params.version ?? ''), String(params.sourceId ?? ''))))
  rpc.handle('plugins.install.github', async ({ url }) => mutateProfile(() =>
    installFromGithub(String(url ?? ''))))
  rpc.handle('plugins.install.local', async ({ path }) => {
    const allowedRoot = await realpath(importRoot).catch(() => resolve(importRoot))
    const resolved = await realpath(resolve(String(path ?? ''))).catch(() => {
      throw new Error('本地插件目录或压缩包不存在或无法解析')
    })
    const rel = relative(allowedRoot, resolved)
    if (!rel || rel === '..' || rel.startsWith(`..${sep}`) || isAbsolute(rel)) {
      throw new Error('本地插件只能从应用内的导入暂存目录读取')
    }
    return mutateProfile(() => installLocalPath(resolved))
  })
  rpc.handle('plugins.enable', async ({ name, enabled }) =>
    mutateProfile(() => setPluginEnabled(String(name ?? ''), enabled === true)))
  rpc.handle('plugins.remove', async ({ name }) =>
    mutateProfile(() => removePlugin(String(name ?? ''))))
}

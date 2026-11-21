import { randomUUID, createHash } from 'node:crypto'
import { copyFile, lstat, mkdir, readFile, readdir, rename, rm, writeFile } from 'node:fs/promises'
import { dirname, extname, isAbsolute, join, relative, resolve, sep } from 'node:path'
import { gunzipSync } from 'node:zlib'
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
    url: 'https://cdn.jsdelivr.net/npm/dsh-plugin-catalog/index.json', enabled: false, builtIn: true,
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

function httpsURL(value) {
  let url
  try { url = new URL(value) } catch { throw new TypeError('需要完整的 HTTPS URL') }
  if (url.protocol !== 'https:' || !url.hostname || url.username || url.password) {
    throw new TypeError('插件索引与包下载只接受 HTTPS 地址')
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
  const tar = gunzipSync(compressed, { maxOutputLength: MAX_UNPACKED_BYTES })
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

  async function loadCatalog(source, force = false) {
    const cached = catalogCache.get(source.id)
    if (!force && cached && Date.now() - cached.at < 5 * 60_000) return cached.index
    const buffer = await fetchBuffer(source.url, MAX_INDEX_BYTES, 15_000)
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
    const latest = latestVersion(versions.filter((item) => item?.source?.type === 'npm')) ?? latestVersion(versions)
    const npmSource = latest?.source?.type === 'npm'
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
      installable: npmSource && packageName(entry.name) && Boolean(latest?.version),
      installSource: npmSource ? 'npm' : (latest?.source?.type ?? 'unknown'),
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
    return Promise.all(dependencies.filter((item) => item.bundle && !embedded.has(item.name) && packageName(item.name))
      .map(async (item) => {
        const enabled = !safeMode && runtime.profile.layers.some(({ packageName }) => packageName === item.name)
        const manifestPath = join(profileDir, 'node_modules', ...item.name.split('/'), 'package.json')
        const manifest = await readFile(manifestPath, 'utf8').then(JSON.parse).catch(() => ({}))
        return {
          name: item.name, version: item.version, enabled, desiredEnabled: item.enabled,
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
      if (DESKTOP_ONLY_BUNDLES.has(manifest.name)) throw new Error('这个完整桌面 bundle 不允许安装到 iOS profile')
      const available = await assertDependenciesAvailable(manifest, staged)
      if (available.has(manifest.name)) throw new Error('插件名称与已经内嵌的 DSH runtime 包冲突')
      const active = await installedPlugins()
      if (active.some((item) => item.name === manifest.name)) throw new Error(`${manifest.name} 已安装；请先卸载再重新安装此版本`)
      const target = resolve(profileDir, 'node_modules', ...manifest.name.split('/'))
      assertInside(resolve(profileDir, 'node_modules'), target)
      await mkdir(dirname(target), { recursive: true })
      await rename(staged, target)
      const previous = readProfileManifest('dsh', profileDir)
      const bundles = previous.dsh?.profile?.bundles ?? [PROFILE_BUNDLE]
      const dependencies = { ...previous.dependencies, [manifest.name]: manifest.version }
      let composition
      try {
        composition = await stageProfile(previous, { ...previous, dependencies }, [...bundles, manifest.name], manifest.name)
      } catch (error) {
        await rm(target, { recursive: true, force: true })
        throw error
      }
      return {
        name: manifest.name,
        version: manifest.version,
        enabled: true,
        restartRequired: Boolean(composition?.restartReason),
        ...(composition?.restartReason ? { restartReason: composition.restartReason } : {}),
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
    const release = releases.find((item) => item?.version === version && item.source?.type === 'npm')
    if (!release) throw new Error('插件版本不在当前启用的索引源中')
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
    const bytes = await fetchBuffer(tarball.href, MAX_ARCHIVE_BYTES)
    await verifyIntegrity(bytes, packageInfo.dist.integrity)
    const staging = join(profileDir, `.ios-plugin-download-${randomUUID()}`)
    await mkdir(staging)
    try {
      await unpackNpmTarball(bytes, staging)
      await resolvePureJsDependencies(staging)
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
      const metaBuf = await fetchBuffer(`https://api.github.com/repos/${owner}/${repo}`, 2 * 1024 * 1024, 15_000)
      let meta
      try { meta = JSON.parse(metaBuf.toString('utf8')) } catch { throw new Error('GitHub API 返回了无效数据') }
      targetRef = typeof meta.default_branch === 'string' && meta.default_branch ? meta.default_branch : 'main'
    }
    const tarballUrl = `https://codeload.github.com/${owner}/${repo}/tar.gz/${encodeURIComponent(targetRef)}`
    const bytes = await fetchBuffer(tarballUrl, MAX_ARCHIVE_BYTES, 45_000)
    const staging = join(profileDir, `.ios-plugin-github-${randomUUID()}`)
    await mkdir(staging)
    try {
      await unpackNpmTarball(bytes, staging, { stripSingleRoot: true })
      await resolvePureJsDependencies(staging)
      return await installDirectory(staging)
    } finally {
      await rm(staging, { recursive: true, force: true })
    }
  }

  rpc.handle('plugins.installed.list', async () => ({ plugins: await installedPlugins() }))
  rpc.handle('plugins.install.npm', async (params) => mutateProfile(() =>
    installFromNpm(String(params.name ?? ''), String(params.version ?? ''), String(params.sourceId ?? ''))))
  rpc.handle('plugins.install.github', async ({ url }) => mutateProfile(() =>
    installFromGithub(String(url ?? ''))))
  rpc.handle('plugins.install.local', async ({ path }) => {
    const resolved = resolve(String(path ?? ''))
    const allowed = resolve(importRoot) + sep
    if (!resolved.startsWith(allowed)) throw new Error('本地插件只能从应用内的导入暂存目录读取')
    return mutateProfile(() => installDirectory(resolved))
  })
  rpc.handle('plugins.enable', async ({ name, enabled }) =>
    mutateProfile(() => setPluginEnabled(String(name ?? ''), enabled === true)))
  rpc.handle('plugins.remove', async ({ name }) =>
    mutateProfile(() => removePlugin(String(name ?? ''))))
}

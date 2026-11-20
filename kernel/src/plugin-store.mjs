// Standalone DSH Plugin Store & Native-JS Plugin Installer for iOS.
// Supports 4 install channels:
//   1. Community Index Sources (dsh-market / dshfind / custom index.json)
//   2. npm package name (npmjs.org or China mirror npmmirror.com)
//   3. GitHub repository URL or owner/repo shorthand
//   4. Local folder copy-and-install (via iOS Files picker)

import { createHash } from 'node:crypto'
import { cpSync, existsSync, mkdirSync, readdirSync, readFileSync, rmSync, statSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { DESKTOP_DISABLED_MODULES } from './shims/disabled-stubs.mjs'
import { extractNpmTarballSafe } from './plugin-tar.mjs'

export const DEFAULT_REGISTRIES = Object.freeze({
  npmjs: 'https://registry.npmjs.org',
  npmmirror: 'https://registry.npmmirror.com',
})

const DISABLED_SET = new Set(DESKTOP_DISABLED_MODULES)
const FORBIDDEN_BINARY_EXTS = ['.node', '.dylib', '.so', '.dll', '.exe', '.framework']

/**
 * Parse a GitHub URL or `owner/repo` shorthand. Returns null for standard npm package names.
 * @param {string} input
 */
export function parseGitHubSpec(input) {
  const trimmed = String(input ?? '').trim()
  const urlMatch = /^https?:\/\/github\.com\/([A-Za-z0-9_.-]+)\/([A-Za-z0-9_.-]+?)(?:\.git)?(?:\/tree\/([^/\s]+))?\/?$/u.exec(trimmed)
  if (urlMatch) {
    return { owner: urlMatch[1], repo: urlMatch[2], ref: urlMatch[3] || 'HEAD' }
  }
  const ghMatch = /^github:([A-Za-z0-9_.-]+)\/([A-Za-z0-9_.-]+)(?:#([^/\s]+))?$/u.exec(trimmed)
  if (ghMatch) {
    return { owner: ghMatch[1], repo: ghMatch[2], ref: ghMatch[3] || 'HEAD' }
  }
  return null
}

/**
 * Verify npm `dist.integrity` (sha512-... / sha256-...) or fallback `dist.shasum` (sha1 hex).
 */
export function verifyTarballIntegrity(bytes, dist) {
  if (dist?.integrity && typeof dist.integrity === 'string') {
    const [algo, expectedB64] = dist.integrity.split('-')
    if (!algo || !expectedB64) throw new Error(`Malformed SRI integrity string: ${dist.integrity}`)
    const actualB64 = createHash(algo).update(bytes).digest('base64')
    if (actualB64 !== expectedB64) {
      const err = new Error(`Tarball ${algo} integrity mismatch`)
      err.code = 'INTEGRITY_MISMATCH'
      throw err
    }
    return { algorithm: algo, verified: true }
  }
  if (dist?.shasum) {
    const actualHex = createHash('sha1').update(bytes).digest('hex')
    if (actualHex !== dist.shasum) {
      const err = new Error('Tarball SHA-1 shasum mismatch')
      err.code = 'INTEGRITY_MISMATCH'
      throw err
    }
    return { algorithm: 'sha1', verified: true }
  }
  const err = new Error('Refusing to install tarball without integrity or shasum digest')
  err.code = 'INTEGRITY_MISSING'
  throw err
}

/**
 * Classify a DSH plugin manifest for iOS standalone compatibility before install.
 */
export function classifyPluginPackage(pkgManifest, { dshVersion, coreBundles }) {
  const name = pkgManifest?.name ?? ''
  if (coreBundles.has(name)) {
    return {
      compatible: false,
      status: 'core-builtin',
      reason: `Package "${name}" is already built into the pinned DSH ${dshVersion} core kernel and cannot be shadowed (#13730/#1305).`,
    }
  }
  if (DISABLED_SET.has(name)) {
    return {
      compatible: false,
      status: 'desktop-only',
      reason: `Desktop-only module "${name}" requires OS capabilities unavailable in the iOS sandbox.`,
    }
  }
  if (pkgManifest?.gypfile === true) {
    return {
      compatible: false,
      status: 'desktop-only',
      reason: `Plugin "${name}" requires native C/C++ node-gyp compilation, which is blocked by iOS.`,
    }
  }
  const allDeps = { ...(pkgManifest?.dependencies ?? {}), ...(pkgManifest?.optionalDependencies ?? {}) }
  const blockedDep = Object.keys(allDeps).find((dep) => DISABLED_SET.has(dep))
  if (blockedDep) {
    return {
      compatible: false,
      status: 'desktop-only',
      reason: `Plugin "${name}" depends on desktop-only native package "${blockedDep}".`,
    }
  }

  // Known upstream regression on DSH 0.2.2-rc.5 (Discussion #13792):
  // @deepseek-ai/dsh-experimental-session-search@0.2.1-alpha.2 breaks the workspace picker.
  if (name === '@deepseek-ai/dsh-experimental-session-search' && dshVersion === '0.2.2-rc.5') {
    const ver = String(pkgManifest?.version ?? '').trim()
    if (!ver || ver === '0.2.1-alpha.2' || ver.startsWith('0.2.1-')) {
      return {
        compatible: false,
        status: 'known-regression',
        reason: `Plugin "${name}@${ver || 'unknown'}" breaks the workspace picker on DSH 0.2.2-rc.5 (#13792).`,
      }
    }
  }

  // Verify `engines.dsh` declaration (exact or `||`-separated version list, e.g. "0.2.2-rc.2 || 0.2.2-rc.5")
  const enginesDsh = pkgManifest?.engines?.dsh
  if (typeof enginesDsh === 'string' && enginesDsh.trim()) {
    const branches = enginesDsh.split('||').map((s) => s.trim()).filter(Boolean)
    const allExact = branches.length > 0 && branches.every((b) => /^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$/u.test(b))
    if (allExact && !branches.includes(dshVersion)) {
      return {
        compatible: false,
        status: 'version-mismatch',
        reason: `Plugin "${name}" declares engines.dsh="${enginesDsh}", which excludes active kernel DSH ${dshVersion}.`,
      }
    }
  }

  const peers = pkgManifest?.peerDependencies ?? {}
  for (const [peerName, range] of Object.entries(peers)) {
    if (peerName.startsWith('@deepseek-ai/dsh') && typeof range === 'string') {
      const exactMatch = /^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$/u.test(range.trim())
      if (exactMatch && range.trim() !== dshVersion) {
        return {
          compatible: false,
          status: 'version-mismatch',
          reason: `Plugin "${name}" pins ${peerName}@${range}, incompatible with active kernel DSH ${dshVersion} (#13798).`,
        }
      }
    }
  }

  return { compatible: true, status: 'ios-ready' }
}

function scanDirectoryForNativeBinaries(dir) {
  const found = []
  for (const entry of readdirSync(dir)) {
    const full = join(dir, entry)
    const st = statSync(full)
    if (st.isDirectory()) {
      found.push(...scanDirectoryForNativeBinaries(full))
    } else if (FORBIDDEN_BINARY_EXTS.some((ext) => entry.toLowerCase().endsWith(ext))) {
      found.push(full)
    }
  }
  return found
}

/**
 * Manages DSH Plugin Store browsing, multi-channel installation (npm, GitHub, local folder),
 * enable/disable, and clean uninstall inside `<DSH_HOME>/user-plugins/`.
 */
export class DSHPluginStore {
  #pluginsRoot
  #registryFile
  #dshVersion
  #coreBundles
  #registryUrl
  #fetchImpl

  constructor({ dshHome, dshVersion, coreBundles, registryUrl = DEFAULT_REGISTRIES.npmmirror, fetchImpl }) {
    this.#pluginsRoot = join(dshHome, 'user-plugins')
    this.#registryFile = join(this.#pluginsRoot, 'registry.json')
    this.#dshVersion = dshVersion
    this.#coreBundles = new Set(coreBundles)
    this.#registryUrl = registryUrl.replace(/\/+$/u, '')
    this.#fetchImpl = fetchImpl
  }

  get registryUrl() {
    return this.#registryUrl
  }

  setRegistryUrl(url) {
    this.#registryUrl = String(url).replace(/\/+$/u, '')
  }

  async searchStore({ query = '', size = 20 } = {}) {
    const text = query.trim() ? `keywords:dsh-plugin ${query.trim()}` : 'keywords:dsh-plugin'
    const url = `${this.#registryUrl}/-/v1/search?text=${encodeURIComponent(text)}&size=${Math.min(Math.max(size, 1), 50)}`
    const res = await this.#fetchImpl(url, { method: 'GET' })
    if (!res.ok) throw new Error(`Plugin store search failed (HTTP ${res.status})`)
    const data = await res.json()
    const installed = new Map(this.listInstalled().map((p) => [p.name, p]))

    return (data.objects ?? []).map(({ package: pkg }) => {
      const check = classifyPluginPackage(pkg, {
        dshVersion: this.#dshVersion,
        coreBundles: this.#coreBundles,
      })
      const existing = installed.get(pkg.name)
      return {
        name: pkg.name,
        version: pkg.version,
        description: pkg.description ?? '',
        keywords: pkg.keywords ?? [],
        compatibility: check.status,
        compatible: check.compatible,
        reason: check.reason ?? null,
        installed: Boolean(existing),
        installedVersion: existing?.version ?? null,
        enabled: existing?.enabled ?? false,
      }
    })
  }

  /**
   * Install a native DSH plugin by npm package name OR GitHub URL (`https://github.com/owner/repo`).
   */
  async installPlugin({ name, version }) {
    const gh = parseGitHubSpec(name)
    if (gh) {
      return this.installFromGitHub(gh)
    }

    if (!name || typeof name !== 'string' || !/^(@[a-z0-9-~][a-z0-9-._~]*\/)?[a-z0-9-~][a-z0-9-._~]*$/u.test(name)) {
      throw new Error(`Invalid npm package name or GitHub URL: "${name}"`)
    }
    if (this.#coreBundles.has(name)) {
      const err = new Error(`Cannot install core kernel bundle "${name}" into user-plugins (anti-shadowing guard #13730/#1305).`)
      err.code = 'CORE_BUNDLE_SHADOW_BLOCKED'
      throw err
    }

    const metaUrl = `${this.#registryUrl}/${encodeURIComponent(name).replace('%40', '@')}`
    const metaRes = await this.#fetchImpl(metaUrl, { method: 'GET' })
    if (!metaRes.ok) throw new Error(`Failed to fetch plugin metadata for "${name}" (HTTP ${metaRes.status})`)
    const packument = await metaRes.json()

    let resolvedVersion = version
    if (!resolvedVersion) {
      if (name.startsWith('@deepseek-ai/dsh') && packument.versions?.[this.#dshVersion]) {
        resolvedVersion = this.#dshVersion
      } else {
        resolvedVersion = packument['dist-tags']?.latest
      }
    }

    const versionManifest = packument.versions?.[resolvedVersion]
    if (!versionManifest) {
      throw new Error(`Version "${resolvedVersion}" not found for plugin "${name}"`)
    }

    const compat = classifyPluginPackage(versionManifest, {
      dshVersion: this.#dshVersion,
      coreBundles: this.#coreBundles,
    })
    if (!compat.compatible) {
      const err = new Error(compat.reason || `Plugin "${name}" is incompatible with iOS standalone`)
      err.code = 'PLUGIN_INCOMPATIBLE'
      err.status = compat.status
      throw err
    }

    const tarballUrl = versionManifest.dist?.tarball
    if (!tarballUrl) throw new Error(`Missing dist.tarball URL for ${name}@${resolvedVersion}`)
    const tgzRes = await this.#fetchImpl(tarballUrl, { method: 'GET', responseEncoding: 'base64' })
    if (!tgzRes.ok) throw new Error(`Failed to download tarball for ${name}@${resolvedVersion} (HTTP ${tgzRes.status})`)

    const bytes = tgzRes.arrayBuffer
      ? Buffer.from(await tgzRes.arrayBuffer())
      : Buffer.from(await tgzRes.text(), 'base64')

    const integrity = verifyTarballIntegrity(bytes, versionManifest.dist)

    return this.#extractAndRegister({
      name,
      version: resolvedVersion,
      manifest: versionManifest,
      bytes,
      integrity: versionManifest.dist.integrity ?? versionManifest.dist.shasum,
      integrityAlgorithm: integrity.algorithm,
      sourceType: 'npm',
    })
  }

  /**
   * Install a DSH plugin directly from a GitHub repository tarball.
   */
  async installFromGitHub({ owner, repo, ref = 'HEAD' }) {
    const tarballUrl = `https://codeload.github.com/${owner}/${repo}/tar.gz/${encodeURIComponent(ref)}`
    const tgzRes = await this.#fetchImpl(tarballUrl, { method: 'GET', responseEncoding: 'base64' })
    if (!tgzRes.ok) throw new Error(`Failed to download GitHub archive ${owner}/${repo}@${ref} (HTTP ${tgzRes.status})`)
    const bytes = tgzRes.arrayBuffer
      ? Buffer.from(await tgzRes.arrayBuffer())
      : Buffer.from(await tgzRes.text(), 'base64')

    const sha256 = createHash('sha256').update(bytes).digest('hex')
    const stagingDir = join(this.#pluginsRoot, `.staging-gh-${Date.now()}`)
    mkdirSync(stagingDir, { recursive: true })
    try {
      extractNpmTarballSafe(bytes, stagingDir, { stripComponents: 1 })
      const pkgPath = join(stagingDir, 'package.json')
      if (!existsSync(pkgPath)) throw new Error(`GitHub repo ${owner}/${repo} is missing package.json`)
      const manifest = JSON.parse(readFileSync(pkgPath, 'utf8'))
      const name = manifest.name || repo
      const compat = classifyPluginPackage({ ...manifest, name }, {
        dshVersion: this.#dshVersion,
        coreBundles: this.#coreBundles,
      })
      if (!compat.compatible) {
        const err = new Error(compat.reason)
        err.code = 'PLUGIN_INCOMPATIBLE'
        throw err
      }
      return this.#extractAndRegister({
        name,
        version: manifest.version || `github-${ref}`,
        manifest,
        bytes,
        integrity: `sha256-${sha256}`,
        integrityAlgorithm: 'sha256',
        sourceType: 'github',
      })
    } finally {
      rmSync(stagingDir, { recursive: true, force: true })
    }
  }

  /**
   * Copy and install a plugin from a local folder selected via iOS Files picker ("从本地文件夹安装").
   * Copies into `<DSH_HOME>/user-plugins/` so the original user folder stays untouched.
   * @param {string} sourceFolder
   */
  installFromLocalFolder(sourceFolder) {
    const pkgPath = join(sourceFolder, 'package.json')
    if (!existsSync(pkgPath)) {
      throw new Error(`Selected folder does not contain a valid package.json: ${sourceFolder}`)
    }
    const manifest = JSON.parse(readFileSync(pkgPath, 'utf8'))
    const name = manifest.name
    if (!name) throw new Error('Local plugin package.json is missing "name".')

    const compat = classifyPluginPackage(manifest, {
      dshVersion: this.#dshVersion,
      coreBundles: this.#coreBundles,
    })
    if (!compat.compatible) {
      const err = new Error(compat.reason)
      err.code = 'PLUGIN_INCOMPATIBLE'
      throw err
    }

    const binaries = scanDirectoryForNativeBinaries(sourceFolder)
    if (binaries.length > 0) {
      const err = new Error(`Local plugin contains native binaries incompatible with iOS: ${binaries.join(', ')}`)
      err.code = 'IOS_NATIVE_BINARY_UNSUPPORTED'
      throw err
    }

    const safeDirName = name.replace(/\//gu, '__')
    const installDir = join(this.#pluginsRoot, safeDirName)
    mkdirSync(this.#pluginsRoot, { recursive: true })
    rmSync(installDir, { recursive: true, force: true })
    cpSync(sourceFolder, installDir, { recursive: true })

    const record = {
      name,
      version: manifest.version || '0.0.0-local',
      description: manifest.description ?? '',
      installDir,
      entry: manifest.main || manifest.exports?.['.'] || 'index.js',
      dshBundlePatch: manifest.dsh?.bundle?.patch ?? null,
      hasWebUI: Boolean(manifest.dsh?.client || manifest.exports?.['./client']),
      integrity: 'local-folder',
      integrityAlgorithm: 'local',
      sourceType: 'local-folder',
      enabled: true,
      installedAt: new Date().toISOString(),
      dshVersionAtInstall: this.#dshVersion,
    }

    const registry = this.#readRegistry()
    registry.plugins[name] = record
    this.#writeRegistry(registry)
    return record
  }

  listInstalled() {
    const registry = this.#readRegistry()
    return Object.values(registry.plugins)
  }

  setEnabled(name, enabled) {
    const registry = this.#readRegistry()
    const item = registry.plugins[name]
    if (!item) return { found: false }
    item.enabled = Boolean(enabled)
    this.#writeRegistry(registry)
    return { found: true, name, enabled: item.enabled }
  }

  uninstallPlugin(name) {
    const registry = this.#readRegistry()
    const item = registry.plugins[name]
    if (!item) return { found: false }
    if (item.installDir && existsSync(item.installDir)) {
      rmSync(item.installDir, { recursive: true, force: true })
    }
    delete registry.plugins[name]
    this.#writeRegistry(registry)
    return { found: true, removed: true, name }
  }

  #extractAndRegister({ name, version, manifest, bytes, integrity, integrityAlgorithm, sourceType }) {
    const safeDirName = name.replace(/\//gu, '__')
    const installDir = join(this.#pluginsRoot, safeDirName)
    const stagingDir = join(this.#pluginsRoot, `.staging-${safeDirName}-${Date.now()}`)
    mkdirSync(stagingDir, { recursive: true })

    try {
      const extracted = extractNpmTarballSafe(bytes, stagingDir, { stripComponents: 1 })
      rmSync(installDir, { recursive: true, force: true })
      mkdirSync(installDir, { recursive: true })
      extractNpmTarballSafe(bytes, installDir, { stripComponents: 1 })

      const record = {
        name,
        version,
        description: manifest.description ?? '',
        installDir,
        entry: manifest.main || manifest.exports?.['.'] || 'index.js',
        dshBundlePatch: manifest.dsh?.bundle?.patch ?? null,
        hasWebUI: Boolean(manifest.dsh?.client || manifest.exports?.['./client']),
        integrity,
        integrityAlgorithm,
        sourceType,
        fileCount: extracted.fileCount,
        enabled: true,
        installedAt: new Date().toISOString(),
        dshVersionAtInstall: this.#dshVersion,
      }

      const registry = this.#readRegistry()
      registry.plugins[name] = record
      this.#writeRegistry(registry)
      return record
    } finally {
      rmSync(stagingDir, { recursive: true, force: true })
    }
  }

  #readRegistry() {
    if (!existsSync(this.#registryFile)) return { schemaVersion: 1, plugins: {} }
    try {
      const parsed = JSON.parse(readFileSync(this.#registryFile, 'utf8'))
      return { schemaVersion: 1, plugins: parsed.plugins ?? {} }
    } catch {
      return { schemaVersion: 1, plugins: {} }
    }
  }

  #writeRegistry(registry) {
    mkdirSync(this.#pluginsRoot, { recursive: true })
    const tmp = `${this.#registryFile}.tmp`
    writeFileSync(tmp, `${JSON.stringify(registry, null, 2)}\n`, 'utf8')
    writeFileSync(this.#registryFile, readFileSync(tmp, 'utf8'), 'utf8')
    rmSync(tmp, { force: true })
  }
}

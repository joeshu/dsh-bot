import { mkdir, opendir, stat } from 'node:fs/promises'
import { realpathSync } from 'node:fs'
import { basename, dirname, isAbsolute, join, relative, resolve, sep } from 'node:path'
import { DirectoryPicker, DirectoryPickerError } from '@deepseek-ai/dsh-host-directory-picker'

function canonicalize(targetPath) {
  const abs = resolve(targetPath)
  try {
    return realpathSync(abs)
  } catch {
    const parent = dirname(abs)
    if (parent === abs) return abs
    try {
      return resolve(realpathSync(parent), abs.slice(parent.length + (parent.endsWith(sep) ? 0 : 1)))
    } catch {
      return abs
    }
  }
}

function sandboxCrumbs(sandboxRoot, target) {
  const crumbs = []
  let current = target
  for (;;) {
    const isRoot = current === sandboxRoot
    crumbs.unshift({
      name: isRoot ? 'workspace (files)' : basename(current),
      path: current,
      hidden: false,
    })
    if (isRoot) return crumbs
    const parent = dirname(current)
    if (parent === current) return crumbs
    current = parent
  }
}

/**
 * iOS-jailed browse directory picker for DSH Web UI.
 * Anchors `home` and all list/createDirectory calls inside `$DSH_HOME/files`
 * so any folder selected in the Web UI is guaranteed to satisfy `IosSandboxedFileSystem`.
 */
export default class IosSandboxedDirectoryPicker extends DirectoryPicker {
  constructor(ctx, config = {}) {
    super(ctx)
    this.config = config
    const home = resolve(process.env.DSH_HOME || process.cwd())
    this.sandboxRoot = canonicalize(join(home, 'files'))
    this.maxEntries = Number.isInteger(config?.maxEntries) && config.maxEntries > 0 ? config.maxEntries : 500
    this.browseCapability = {
      kind: 'browse',
      list: (path, signal) => this.list(path, signal),
      createDirectory: (path, name) => this.createDirectory(path, name),
    }
  }

  capability() {
    return this.browseCapability
  }

  resolveInSandbox(rawPath) {
    if (rawPath === undefined || rawPath === null || String(rawPath).trim() === '') {
      return this.sandboxRoot
    }
    const text = String(rawPath).trim()
    let candidate
    if (text === '/workspace' || text === '/workspace/') {
      candidate = this.sandboxRoot
    } else if (text.startsWith('/workspace/')) {
      candidate = resolve(this.sandboxRoot, text.slice('/workspace/'.length))
    } else {
      candidate = resolve(text)
    }
    const canonical = canonicalize(candidate)
    const rel = relative(this.sandboxRoot, canonical)
    if (rel === '..' || rel.startsWith(`..${sep}`) || isAbsolute(rel)) {
      // Clamp outside paths (e.g., stale desktop/container paths) cleanly back to sandboxRoot
      return this.sandboxRoot
    }
    return canonical
  }

  async list(path, signal) {
    signal?.throwIfAborted?.()
    await mkdir(this.sandboxRoot, { recursive: true })
    const target = this.resolveInSandbox(path)
    const entries = []
    let truncated = false
    try {
      const dir = await opendir(target)
      try {
        for await (const dirent of dir) {
          signal?.throwIfAborted?.()
          if (!dirent.isDirectory() && !dirent.isSymbolicLink()) continue
          const full = join(target, dirent.name)
          try {
            const info = await stat(full)
            if (!info.isDirectory()) continue
            const canonical = canonicalize(full)
            const rel = relative(this.sandboxRoot, canonical)
            if (rel === '..' || rel.startsWith(`..${sep}`) || isAbsolute(rel)) continue
            entries.push({
              name: dirent.name,
              path: canonical,
              hidden: dirent.name.startsWith('.'),
            })
          } catch {
            // Skip unreadable or broken symlinks
          }
        }
      } finally {
        await dir.close().catch(() => {})
      }
    } catch (error) {
      throw new DirectoryPickerError('directory-unreadable', target, `无法读取工作区目录 ${target}: ${error instanceof Error ? error.message : String(error)}`)
    }
    entries.sort((a, b) => a.name.localeCompare(b.name))
    if (entries.length > this.maxEntries) {
      entries.length = this.maxEntries
      truncated = true
    }
    return {
      path: target,
      home: this.sandboxRoot,
      crumbs: sandboxCrumbs(this.sandboxRoot, target),
      entries,
      truncated,
    }
  }

  async createDirectory(path, name) {
    await mkdir(this.sandboxRoot, { recursive: true })
    const parent = this.resolveInSandbox(path)
    const segment = String(name ?? '').trim()
    if (!segment || segment === '.' || segment === '..' || /[/\\]/.test(segment)) {
      throw new DirectoryPickerError('directory-create-failed', join(parent, segment), `文件夹名称无效："${segment}"`)
    }
    const target = join(parent, segment)
    const rel = relative(this.sandboxRoot, resolve(target))
    if (rel === '..' || rel.startsWith(`..${sep}`) || isAbsolute(rel)) {
      throw new DirectoryPickerError('directory-create-failed', target, '只能在 iOS 沙盒工作区 files/ 内创建目录')
    }
    try {
      await mkdir(target)
      return canonicalize(target)
    } catch (error) {
      if (error?.code === 'EEXIST') {
        throw new DirectoryPickerError('directory-exists', target, `目录已存在：${segment}`)
      }
      throw new DirectoryPickerError('directory-create-failed', target, `创建目录失败：${error instanceof Error ? error.message : String(error)}`)
    }
  }
}

import { realpathSync } from 'node:fs'
import { basename, dirname, isAbsolute, join, relative, resolve, sep } from 'node:path'
import { FsError } from '@deepseek-ai/dsh-fs'
import LocalFileSystem from '@deepseek-ai/dsh-fs-local'

function canonicalize(targetPath) {
  let current = resolve(targetPath)
  const suffix = []
  for (let depth = 0; depth < 64; depth++) {
    try {
      const real = realpathSync(current)
      return suffix.length ? resolve(real, ...suffix) : real
    } catch {
      const parent = dirname(current)
      if (parent === current) break
      suffix.unshift(basename(current))
      current = parent
    }
  }
  return resolve(targetPath)
}

export default class IosSandboxedFileSystem extends LocalFileSystem {
  constructor(ctx, config) {
    const home = resolve(process.env.DSH_HOME || config?.cwd || process.cwd())
    const sandboxRoot = join(home, 'files')
    super(ctx, { ...config, cwd: sandboxRoot })
    this.runtimeRoot = home
    this.sandboxRoot = canonicalize(sandboxRoot)
    if (ctx && typeof ctx.provide === 'function' && ctx.get?.('subprocess') === undefined) {
      ctx.provide('subprocess', {
        resolveExecutable: async () => { throw new Error('Subprocess spawning is disabled in the iOS sandbox') },
        spawn: () => { throw new Error('Subprocess spawning is disabled in the iOS sandbox') },
      })
    }
  }

  assertAllowed(candidatePath) {
    const canonical = canonicalize(candidatePath)
    const rel = relative(this.sandboxRoot, canonical)
    if (rel === '..' || rel.startsWith(`..${sep}`) || isAbsolute(rel)) {
      throw new FsError('Path escapes the iOS DSH workspace', 'FS_SANDBOX_DENIED')
    }
    return canonical
  }

  normalizeVirtualPath(candidate) {
    if (typeof candidate !== 'string') return candidate
    const trimmed = candidate.trim()
    if (trimmed === '/workspace' || trimmed === '/workspace/' || trimmed === 'workspace' || trimmed === 'workspace/') {
      return this.sandboxRoot
    }
    if (trimmed.startsWith('/workspace/')) {
      return join(this.sandboxRoot, trimmed.slice('/workspace/'.length))
    }
    if (trimmed === 'files' || trimmed === 'files/') {
      return this.sandboxRoot
    }
    if (trimmed.startsWith('files/')) {
      return join(this.sandboxRoot, trimmed.slice('files/'.length))
    }
    return candidate
  }

  cwdForSession(cwd) {
    if (typeof cwd !== 'string' || !cwd || resolve(cwd) === this.runtimeRoot) return this.sandboxRoot
    return this.normalizeVirtualPath(cwd)
  }

  async resolve(path, opts) {
    const normalized = this.normalizeVirtualPath(path)
    const result = await super.resolve(normalized, { ...opts, cwd: this.cwdForSession(opts?.cwd) })
    this.assertAllowed(String(result.targetKey))
    return result
  }

  processPath(target) {
    const path = super.processPath(this.normalizeVirtualPath(target))
    this.assertAllowed(path)
    return path
  }

  processPathFromHostPath(hostPath) {
    const path = super.processPathFromHostPath(this.normalizeVirtualPath(hostPath))
    if (path !== undefined) this.assertAllowed(path)
    return path
  }

  async lstat(path, opts, signal) {
    const normalized = this.normalizeVirtualPath(path)
    if (typeof normalized === 'string' && normalized.trim().length > 0) {
      const base = this.cwdForSession(opts?.cwd ?? this.config.cwd)
      this.assertAllowed(resolve(base, normalized))
    }
    return super.lstat(normalized, { ...opts, cwd: this.cwdForSession(opts?.cwd) }, signal)
  }
}

import { realpathSync } from 'node:fs'
import { dirname, isAbsolute, join, relative, resolve, sep } from 'node:path'
import { FsError } from '@deepseek-ai/dsh-fs'
import LocalFileSystem from '@deepseek-ai/dsh-fs-local'

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

export default class IosSandboxedFileSystem extends LocalFileSystem {
  constructor(ctx, config) {
    const home = resolve(process.env.DSH_HOME || config?.cwd || process.cwd())
    const sandboxRoot = join(home, 'files')
    super(ctx, { ...config, cwd: sandboxRoot })
    this.runtimeRoot = home
    this.sandboxRoot = canonicalize(sandboxRoot)
  }

  assertAllowed(candidatePath) {
    const canonical = canonicalize(candidatePath)
    const rel = relative(this.sandboxRoot, canonical)
    if (rel === '..' || rel.startsWith(`..${sep}`) || isAbsolute(rel)) {
      throw new FsError('Path escapes the iOS DSH workspace', 'FS_SANDBOX_DENIED')
    }
    return canonical
  }

  cwdForSession(cwd) {
    if (typeof cwd !== 'string' || !cwd || resolve(cwd) === this.runtimeRoot) return this.sandboxRoot
    return cwd
  }

  async resolve(path, opts) {
    const result = await super.resolve(path, { ...opts, cwd: this.cwdForSession(opts?.cwd) })
    this.assertAllowed(String(result.targetKey))
    return result
  }

  processPath(target) {
    const path = super.processPath(target)
    this.assertAllowed(path)
    return path
  }

  processPathFromHostPath(hostPath) {
    const path = super.processPathFromHostPath(hostPath)
    if (path !== undefined) this.assertAllowed(path)
    return path
  }

  async lstat(path, opts, signal) {
    if (typeof path === 'string' && path.trim().length > 0) {
      const base = this.cwdForSession(opts?.cwd ?? this.config.cwd)
      this.assertAllowed(resolve(base, path))
    }
    return super.lstat(path, { ...opts, cwd: this.cwdForSession(opts?.cwd) }, signal)
  }
}

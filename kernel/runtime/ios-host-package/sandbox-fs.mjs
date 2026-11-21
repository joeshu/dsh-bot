import { realpathSync } from 'node:fs'
import { dirname, isAbsolute, relative, resolve, sep } from 'node:path'
import { FsError } from '@deepseek-ai/dsh-fs'
import LocalFileSystem from '@deepseek-ai/dsh-fs-local'

const BLOCKED_ROOT_ENTRIES = new Set([
  'dsh-sessions.sqlite',
  'dsh-sessions.sqlite-wal',
  'dsh-sessions.sqlite-shm',
  'dsh-sessions.sqlite-journal',
  'dsh-storage.sqlite',
  'dsh-storage.sqlite-wal',
  'dsh-storage.sqlite-shm',
  'dsh-storage.sqlite-journal',
  'chats.json',
  'bots.json',
  'memory.json',
  'connectors.json',
  'usage.json',
  'groups.json',
  'profiles',
  'plugin-imports',
])

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
    super(ctx, config)
    this.sandboxRoot = canonicalize(process.env.DSH_HOME || this.config.cwd)
  }

  assertAllowed(candidatePath) {
    const canonical = canonicalize(candidatePath)
    const rel = relative(this.sandboxRoot, canonical)
    if (rel === '..' || rel.startsWith(`..${sep}`) || isAbsolute(rel)) {
      throw new FsError('Path escapes the iOS DSH workspace', 'FS_SANDBOX_DENIED')
    }
    if (rel) {
      const top = rel.split(sep)[0]
      if (BLOCKED_ROOT_ENTRIES.has(top)) {
        throw new FsError('Access to internal DS Bot storage is denied', 'FS_SANDBOX_DENIED')
      }
    }
    return canonical
  }

  async resolve(path, opts) {
    const result = await super.resolve(path, opts)
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
      const base = opts?.cwd ?? this.config.cwd
      this.assertAllowed(resolve(base, path))
    }
    return super.lstat(path, opts, signal)
  }
}

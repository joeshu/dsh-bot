// Pure-JS USTAR .tar.gz extractor with strict Zip-Slip, symlink, and native-binary (.node/.dylib/.so) guards.
// Runs inside the iOS BareKit worklet without spawning `tar` or `pnpm` child processes.

import { mkdirSync, writeFileSync } from 'node:fs'
import { dirname, isAbsolute, normalize, relative, resolve } from 'node:path'
import { gunzipSync } from 'node:zlib'

const BLOCK_SIZE = 512
const FORBIDDEN_BINARY_EXTS = ['.node', '.dylib', '.so', '.dll', '.exe', '.framework']

/**
 * Create a minimal USTAR tar buffer from a map of `{ relativePath: Buffer | string }`.
 * Used by tests and offline plugin packaging.
 * @param {Record<string, Buffer | string>} files
 * @returns {Buffer}
 */
export function createTarBuffer(files) {
  const chunks = []
  for (const [rawName, rawContent] of Object.entries(files)) {
    const content = Buffer.isBuffer(rawContent) ? rawContent : Buffer.from(String(rawContent), 'utf8')
    const header = Buffer.alloc(BLOCK_SIZE, 0)
    header.write(rawName.slice(0, 100), 0, 'utf8')
    header.write('0000644\0', 100, 'ascii')
    header.write('0000000\0', 108, 'ascii')
    header.write('0000000\0', 116, 'ascii')
    header.write(`${content.length.toString(8).padStart(11, '0')}\0`, 124, 'ascii')
    header.write(`${Math.floor(Date.now() / 1000).toString(8).padStart(11, '0')}\0`, 136, 'ascii')
    header.fill(0x20, 148, 156) // checksum placeholder
    header.write('0', 156, 'ascii') // regular file
    header.write('ustar\0', 257, 'ascii')
    header.write('00', 263, 'ascii')

    let sum = 0
    for (let i = 0; i < BLOCK_SIZE; i += 1) sum += header[i]
    header.write(`${sum.toString(8).padStart(6, '0')}\0 `, 148, 'ascii')

    chunks.push(header)
    if (content.length > 0) {
      chunks.push(content)
      const pad = (BLOCK_SIZE - (content.length % BLOCK_SIZE)) % BLOCK_SIZE
      if (pad > 0) chunks.push(Buffer.alloc(pad, 0))
    }
  }
  chunks.push(Buffer.alloc(BLOCK_SIZE * 2, 0)) // EOF blocks
  return Buffer.concat(chunks)
}

/**
 * Parse a gzipped npm tarball and inspect or extract entries safely into `destDir`.
 * Rejects path traversal (`..`), symlinks, and native binary addons incompatible with iOS.
 * @param {Buffer | Uint8Array} tgzBytes
 * @param {string} destDir
 * @param {{ stripComponents?: number, dryRun?: boolean }} [options]
 */
export const MAX_TAR_UNCOMPRESSED_BYTES = 64 * 1024 * 1024 // 64 MB Jetsam-safe cap
export const MAX_TAR_FILE_COUNT = 2000

export function extractNpmTarballSafe(
  tgzBytes,
  destDir,
  { stripComponents = 1, dryRun = false, maxUncompressedBytes = MAX_TAR_UNCOMPRESSED_BYTES, maxFiles = MAX_TAR_FILE_COUNT } = {},
) {
  let tar
  try {
    tar = gunzipSync(Buffer.isBuffer(tgzBytes) ? tgzBytes : Buffer.from(tgzBytes), { maxOutputLength: maxUncompressedBytes })
  } catch (err) {
    if (err?.code === 'ERR_BUFFER_TOO_LARGE' || /maxOutputLength/i.test(String(err?.message))) {
      const bombErr = new Error(`Tarball exceeds max uncompressed size limit (${maxUncompressedBytes} bytes).`)
      bombErr.code = 'TAR_SIZE_LIMIT_EXCEEDED'
      throw bombErr
    }
    throw err
  }
  const root = normalize(destDir)
  const extractedFiles = []
  const nativeBinariesFound = []

  let offset = 0
  while (offset + BLOCK_SIZE <= tar.length) {
    const header = tar.subarray(offset, offset + BLOCK_SIZE)
    // Two consecutive zero blocks mark end of archive
    if (header.every((b) => b === 0)) break

    const rawName = header.subarray(0, 100).toString('utf8').replace(/\0.*$/u, '')
    const prefix = header.subarray(345, 500).toString('utf8').replace(/\0.*$/u, '')
    const fullEntryName = prefix ? `${prefix}/${rawName}` : rawName
    const typeFlag = String.fromCharCode(header[156] || 0x30)
    const sizeOctal = header.subarray(124, 136).toString('ascii').replace(/\0.*$/u, '').trim()
    const size = sizeOctal ? parseInt(sizeOctal, 8) : 0
    if (!Number.isFinite(size) || size < 0 || offset + BLOCK_SIZE + size > tar.length) {
      const err = new Error(`Corrupt or truncated tarball entry size for: ${fullEntryName}`)
      err.code = 'TAR_CORRUPT_SIZE'
      throw err
    }

    offset += BLOCK_SIZE
    const content = tar.subarray(offset, offset + size)
    offset += Math.ceil(size / BLOCK_SIZE) * BLOCK_SIZE

    // Block symlinks and hardlinks (type '1' or '2') to prevent sandbox escape
    if (typeFlag === '1' || typeFlag === '2') {
      const err = new Error(`Tarball contains forbidden symlink/hardlink entry: ${fullEntryName}`)
      err.code = 'TAR_FORBIDDEN_LINK'
      throw err
    }

    if (typeFlag !== '0' && typeFlag !== '\0') continue // skip directories/pax headers

    const parts = fullEntryName.replace(/^\/+/u, '').split('/').filter(Boolean)
    if (parts.some((p) => p === '..')) {
      const err = new Error(`Tarball path traversal blocked: ${fullEntryName}`)
      err.code = 'TAR_PATH_TRAVERSAL'
      throw err
    }
    const stripped = parts.slice(stripComponents).join('/')
    if (!stripped) continue

    const lower = stripped.toLowerCase()
    if (FORBIDDEN_BINARY_EXTS.some((ext) => lower.endsWith(ext))) {
      nativeBinariesFound.push(stripped)
      continue
    }

    const outPath = resolve(root, stripped)
    const rel = relative(root, outPath)
    if (rel.startsWith('..') || isAbsolute(rel)) {
      const err = new Error(`Tarball target escapes destination: ${fullEntryName}`)
      err.code = 'TAR_PATH_TRAVERSAL'
      throw err
    }

    if (extractedFiles.length >= maxFiles) {
      const err = new Error(`Tarball exceeds max file count limit (${maxFiles}).`)
      err.code = 'TAR_FILE_LIMIT_EXCEEDED'
      throw err
    }
    extractedFiles.push({ path: stripped, bytes: content.length })
    if (!dryRun) {
      mkdirSync(dirname(outPath), { recursive: true })
      writeFileSync(outPath, content)
    }
  }

  if (nativeBinariesFound.length > 0) {
    const err = new Error(`Plugin contains native binaries incompatible with iOS sandbox: ${nativeBinariesFound.join(', ')}`)
    err.code = 'IOS_NATIVE_BINARY_UNSUPPORTED'
    err.binaries = nativeBinariesFound
    throw err
  }

  return { extractedFiles, fileCount: extractedFiles.length }
}

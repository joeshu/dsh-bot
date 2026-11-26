import { createHash, randomUUID } from 'node:crypto'
import { createReadStream } from 'node:fs'
import { mkdir, open, readFile, rename, rm, stat, unlink, writeFile } from 'node:fs/promises'
import { dirname, join, resolve } from 'node:path'
import {
  AttachmentError,
  AttachmentId,
  AttachmentStore,
  ImageVariantId,
} from '@deepseek-ai/dsh-attachment'
import { iosHost } from './index.mjs'

const DEFAULT_MAX_IMAGE_BYTES = 50 * 1024 * 1024
const DEFAULT_MAX_IMAGES_PER_MESSAGE = 20
const DEFAULT_MAX_MESSAGE_IMAGE_BYTES = 200 * 1024 * 1024
const DEFAULT_MAX_IMAGE_PIXELS = 64e6
const DEFAULT_MAX_IMAGE_DIMENSION = 65535
const DEFAULT_NORMALIZED_IMAGE_MAX_PIXELS = 2048 * 2048
const DEFAULT_NORMALIZED_IMAGE_MAX_DIMENSION = 8192
const DEFAULT_NORMALIZED_IMAGE_MAX_BYTES = 4 * 1024 * 1024
const SUPPORTED_MEDIA_TYPES = Object.freeze(['image/png', 'image/jpeg', 'image/webp', 'image/gif'])
const SHA256_ID_RE = /^sha256:([a-f0-9]{64})$/
const WINDOWS_DEVICE_NAME = /^(?:con|prn|aux|nul|com[1-9]|lpt[1-9])$/iu

function sha256Hex(bytes) {
  return createHash('sha256').update(bytes).digest('hex')
}

function fileLeafName(value) {
  if (value === undefined) return 'file'
  let clean = String(value)
    .slice(Math.max(String(value).lastIndexOf('/'), String(value).lastIndexOf('\\')) + 1)
    .replace(/[\u0000-\u001f\u007f]/g, '')
    .replace(/[<>:"|?*]/g, '_')
    .trim()
    .replace(/[. ]+$/u, '')
  const dot = clean.indexOf('.')
  const stem = (dot < 0 ? clean : clean.slice(0, dot)).replace(/[. ]+$/u, '')
  if (WINDOWS_DEVICE_NAME.test(stem)) clean = `_${clean}`
  clean = clean.slice(0, 200).replace(/[. ]+$/u, '')
  return clean === '' || clean === '.' || clean === '..' ? 'file' : clean
}

function extForMediaType(mediaType) {
  switch (mediaType) {
    case 'image/png': return 'png'
    case 'image/jpeg': return 'jpg'
    case 'image/webp': return 'webp'
    case 'image/gif': return 'gif'
    default: return 'bin'
  }
}

/**
 * Pure-JS image header probe for PNG, JPEG, GIF, and WebP.
 * Returns { mediaType, width, height, hasAlpha } or null when unrecognized.
 */
export function probeImagePureJS(inputBytes) {
  const buf = inputBytes instanceof Uint8Array ? Buffer.from(inputBytes.buffer, inputBytes.byteOffset, inputBytes.byteLength) : Buffer.from(inputBytes)
  if (buf.length < 12) return null

  // PNG: 89 50 4E 47 0D 0A 1A 0A + IHDR
  if (buf[0] === 0x89 && buf[1] === 0x50 && buf[2] === 0x4e && buf[3] === 0x47
    && buf[4] === 0x0d && buf[5] === 0x0a && buf[6] === 0x1a && buf[7] === 0x0a
    && buf.length >= 26 && buf.toString('ascii', 12, 16) === 'IHDR') {
    const width = buf.readUInt32BE(16)
    const height = buf.readUInt32BE(20)
    const colorType = buf[25]
    if (width > 0 && height > 0) {
      return { mediaType: 'image/png', width, height, hasAlpha: colorType === 4 || colorType === 6 }
    }
  }

  // GIF: GIF87a / GIF89a
  if (buf.length >= 10 && (buf.toString('ascii', 0, 6) === 'GIF87a' || buf.toString('ascii', 0, 6) === 'GIF89a')) {
    const width = buf.readUInt16LE(6)
    const height = buf.readUInt16LE(8)
    if (width > 0 && height > 0) {
      return { mediaType: 'image/gif', width, height, hasAlpha: true }
    }
  }

  // WebP: RIFF....WEBP
  if (buf.length >= 30 && buf.toString('ascii', 0, 4) === 'RIFF' && buf.toString('ascii', 8, 12) === 'WEBP') {
    const chunk = buf.toString('ascii', 12, 16)
    if (chunk === 'VP8 ' && buf.length >= 30) {
      const width = buf.readUInt16LE(26) & 0x3fff
      const height = buf.readUInt16LE(28) & 0x3fff
      if (width > 0 && height > 0) return { mediaType: 'image/webp', width, height, hasAlpha: false }
    } else if (chunk === 'VP8L' && buf.length >= 25 && buf[20] === 0x2f) {
      const bits = buf.readUInt32LE(21)
      const width = (bits & 0x3fff) + 1
      const height = ((bits >> 14) & 0x3fff) + 1
      const hasAlpha = ((bits >> 28) & 1) === 1
      if (width > 0 && height > 0) return { mediaType: 'image/webp', width, height, hasAlpha }
    } else if (chunk === 'VP8X' && buf.length >= 30) {
      const flags = buf[20]
      const width = 1 + (buf[24] | (buf[25] << 8) | (buf[26] << 16))
      const height = 1 + (buf[27] | (buf[28] << 8) | (buf[29] << 16))
      if (width > 0 && height > 0) return { mediaType: 'image/webp', width, height, hasAlpha: (flags & 0x10) !== 0 }
    }
  }

  // JPEG: FF D8
  if (buf[0] === 0xff && buf[1] === 0xd8) {
    let offset = 2
    while (offset + 4 <= buf.length) {
      while (offset < buf.length && buf[offset] !== 0xff) offset += 1
      while (offset < buf.length && buf[offset] === 0xff) offset += 1
      if (offset >= buf.length) break
      const marker = buf[offset++]
      if (marker === 0xd9 || marker === 0xda) break
      if (marker === 0x01 || (marker >= 0xd0 && marker <= 0xd8)) continue
      if (offset + 2 > buf.length) break
      const segLen = buf.readUInt16BE(offset)
      if (segLen < 2 || offset + segLen > buf.length) break
      const isSOF = (marker >= 0xc0 && marker <= 0xc3)
        || (marker >= 0xc5 && marker <= 0xc7)
        || (marker >= 0xc9 && marker <= 0xcb)
        || (marker >= 0xcd && marker <= 0xcf)
      if (isSOF && segLen >= 7) {
        const height = buf.readUInt16BE(offset + 3)
        const width = buf.readUInt16BE(offset + 5)
        if (width > 0 && height > 0) {
          return { mediaType: 'image/jpeg', width, height, hasAlpha: false }
        }
      }
      offset += segLen
    }
  }

  return null
}

async function atomicWriteBytes(targetPath, bytes) {
  await mkdir(dirname(targetPath), { recursive: true, mode: 0o700 })
  try {
    await stat(targetPath)
    return
  } catch { /* write below */ }
  const tmpPath = `${targetPath}.${randomUUID()}.tmp`
  try {
    await writeFile(tmpPath, bytes, { mode: 0o600, flag: 'wx' })
    await rename(tmpPath, targetPath)
  } catch (error) {
    await rm(tmpPath, { force: true }).catch(() => {})
    if (error?.code === 'EEXIST') return
    throw new AttachmentError('Unable to persist attachment.', 'ATTACHMENT_WRITE_FAILED', { cause: error })
  }
}

async function tryNativeImageProcess(bytes, options) {
  let host
  try { host = iosHost() } catch { return null }
  if (!host?.rpc || typeof host.rpc.request !== 'function') return null
  try {
    const res = await host.rpc.request('native.image.process', {
      base64: Buffer.from(bytes).toString('base64'),
      ...(options.maxWidth ? { maxWidth: options.maxWidth } : {}),
      ...(options.maxHeight ? { maxHeight: options.maxHeight } : {}),
      ...(options.maxBytes ? { maxBytes: options.maxBytes } : {}),
      ...(options.preserveAlpha !== undefined ? { preserveAlpha: options.preserveAlpha } : {}),
      ...(options.probeOnly ? { probeOnly: true } : {}),
    }, 30_000)
    if (!res || typeof res !== 'object') return null
    const width = Number(res.width)
    const height = Number(res.height)
    const mediaType = typeof res.mediaType === 'string' ? res.mediaType : undefined
    if (!Number.isSafeInteger(width) || width <= 0 || !Number.isSafeInteger(height) || height <= 0 || !mediaType) {
      return null
    }
    const outBytes = typeof res.base64 === 'string' && res.base64.length > 0
      ? new Uint8Array(Buffer.from(res.base64, 'base64'))
      : bytes
    return {
      data: outBytes,
      mediaType,
      width,
      height,
      hasAlpha: res.hasAlpha === true,
    }
  } catch {
    return null
  }
}

export class IOSAttachmentStore extends AttachmentStore {
  constructor(ctx, config = {}) {
    super(ctx)
    const dshHome = config?.dshHome || process.env.DSH_HOME || process.cwd()
    this.root = join(resolve(dshHome), 'attachments', 'v1')
    this.cacheRoot = join(resolve(dshHome), 'cache', 'attachments')
    this.imageLimits = Object.freeze({
      maxImageBytes: config?.maxImageBytes ?? DEFAULT_MAX_IMAGE_BYTES,
      maxImagesPerMessage: config?.maxImagesPerMessage ?? DEFAULT_MAX_IMAGES_PER_MESSAGE,
      maxMessageImageBytes: config?.maxMessageImageBytes ?? DEFAULT_MAX_MESSAGE_IMAGE_BYTES,
      maxImagePixels: config?.maxImagePixels ?? DEFAULT_MAX_IMAGE_PIXELS,
      maxImageDimension: config?.maxImageDimension ?? DEFAULT_MAX_IMAGE_DIMENSION,
      mediaTypes: SUPPORTED_MEDIA_TYPES,
    })
    this.normalizationPolicy = Object.freeze({
      maxPixels: config?.normalizedImageMaxPixels ?? DEFAULT_NORMALIZED_IMAGE_MAX_PIXELS,
      maxDimension: config?.normalizedImageMaxDimension ?? DEFAULT_NORMALIZED_IMAGE_MAX_DIMENSION,
      maxBytes: config?.normalizedImageMaxBytes ?? DEFAULT_NORMALIZED_IMAGE_MAX_BYTES,
    })
  }

  _imageObjectPath(sha256, mediaType) {
    return join(this.root, 'images', sha256.slice(0, 2), `${sha256}.${extForMediaType(mediaType)}`)
  }

  _fileObjectPath(sha256, leafName) {
    return join(this.root, 'files', sha256.slice(0, 2), sha256, leafName)
  }

  _ensureImageRef(ref) {
    const match = SHA256_ID_RE.exec(String(ref?.attachmentId ?? ''))
    if (!match?.[1] || !SUPPORTED_MEDIA_TYPES.includes(ref?.mediaType)
      || !Number.isSafeInteger(ref?.bytes) || ref.bytes <= 0
      || !Number.isSafeInteger(ref?.width) || ref.width <= 0
      || !Number.isSafeInteger(ref?.height) || ref.height <= 0) {
      throw new AttachmentError('Image attachment reference is invalid.', 'INVALID_ATTACHMENT_REF')
    }
    return match[1]
  }

  _ensureFileRef(ref) {
    const match = SHA256_ID_RE.exec(String(ref?.attachmentId ?? ''))
    if (!match?.[1] || typeof ref?.name !== 'string' || ref.name !== fileLeafName(ref.name)) {
      throw new AttachmentError('File attachment reference is invalid.', 'INVALID_ATTACHMENT_REF')
    }
    return match[1]
  }

  async _probe(bytes) {
    const pure = probeImagePureJS(bytes)
    if (pure) return pure
    const native = await tryNativeImageProcess(bytes, { probeOnly: true })
    if (native) return { mediaType: native.mediaType, width: native.width, height: native.height, hasAlpha: native.hasAlpha }
    throw new AttachmentError('Image data is invalid or unsupported.', 'INVALID_IMAGE')
  }

  async validateImage(input) {
    const data = input?.data instanceof Uint8Array ? input.data : new Uint8Array(input?.data ?? [])
    if (data.byteLength === 0) throw new AttachmentError('Image upload is empty.', 'INVALID_IMAGE')
    if (data.byteLength > this.imageLimits.maxImageBytes) {
      throw new AttachmentError('Image exceeds maximum allowed byte size.', 'IMAGE_TOO_LARGE')
    }
    if (!this.imageLimits.mediaTypes.includes(input?.mediaType)) {
      throw new AttachmentError(`Image type ${input?.mediaType} is not accepted by this deployment.`, 'UNSUPPORTED_IMAGE_TYPE')
    }
    const meta = await this._probe(data)
    if (meta.width * meta.height > this.imageLimits.maxImagePixels) {
      throw new AttachmentError('Image exceeds maximum pixel count.', 'IMAGE_TOO_MANY_PIXELS')
    }
    if (meta.width > this.imageLimits.maxImageDimension || meta.height > this.imageLimits.maxImageDimension) {
      throw new AttachmentError('Image dimension exceeds limit.', 'IMAGE_DIMENSION_TOO_LARGE')
    }
    return meta
  }

  async saveImage(input) {
    const raw = input?.data instanceof Uint8Array ? input.data : new Uint8Array(input?.data ?? [])
    const meta = await this.validateImage({ ...input, data: raw })
    let finalData = raw
    let finalMeta = meta
    const needsResize = meta.width * meta.height > this.normalizationPolicy.maxPixels
      || meta.width > this.normalizationPolicy.maxDimension
      || meta.height > this.normalizationPolicy.maxDimension
      || raw.byteLength > this.normalizationPolicy.maxBytes
    if (needsResize) {
      const scale = Math.min(
        1,
        Math.sqrt(this.normalizationPolicy.maxPixels / (meta.width * meta.height)),
        this.normalizationPolicy.maxDimension / Math.max(meta.width, meta.height),
      )
      const targetW = Math.max(1, Math.floor(meta.width * scale))
      const targetH = Math.max(1, Math.floor(meta.height * scale))
      const processed = await tryNativeImageProcess(raw, {
        maxWidth: targetW,
        maxHeight: targetH,
        maxBytes: this.normalizationPolicy.maxBytes,
        preserveAlpha: meta.hasAlpha,
      })
      if (processed) {
        finalData = processed.data
        finalMeta = {
          mediaType: SUPPORTED_MEDIA_TYPES.includes(processed.mediaType) ? processed.mediaType : 'image/jpeg',
          width: processed.width,
          height: processed.height,
          hasAlpha: processed.hasAlpha,
        }
      }
    }
    const sha256 = sha256Hex(finalData)
    const objectPath = this._imageObjectPath(sha256, finalMeta.mediaType)
    await atomicWriteBytes(objectPath, finalData)
    return {
      attachmentId: AttachmentId(`sha256:${sha256}`),
      mediaType: finalMeta.mediaType,
      bytes: finalData.byteLength,
      width: finalMeta.width,
      height: finalMeta.height,
      ...(input?.name !== undefined ? { name: fileLeafName(input.name) } : {}),
    }
  }

  async readImage(ref, signal) {
    signal?.throwIfAborted?.()
    const sha256 = this._ensureImageRef(ref)
    const objectPath = this._imageObjectPath(sha256, ref.mediaType)
    let data
    try {
      data = new Uint8Array(await readFile(objectPath, { signal }))
    } catch (error) {
      signal?.throwIfAborted?.()
      if (error?.code === 'ENOENT') throw new AttachmentError('Attachment object is missing.', 'ATTACHMENT_NOT_FOUND')
      throw new AttachmentError('Unable to read image attachment.', 'ATTACHMENT_READ_FAILED', { cause: error })
    }
    signal?.throwIfAborted?.()
    if (sha256Hex(data) !== sha256 || data.byteLength !== ref.bytes) {
      throw new AttachmentError('Stored attachment failed integrity verification.', 'ATTACHMENT_CORRUPT')
    }
    return { ref, data }
  }

  imageHostPath(ref) {
    const sha256 = this._ensureImageRef(ref)
    return this._imageObjectPath(sha256, ref.mediaType)
  }

  async readImageRequest(ref, target, signal) {
    signal?.throwIfAborted?.()
    this._ensureImageRef(ref)
    const stored = await this.readImage(ref, signal)
    const sourceMeta = probeImagePureJS(stored.data) ?? {
      mediaType: ref.mediaType,
      width: ref.width,
      height: ref.height,
      hasAlpha: ref.mediaType === 'image/png' || ref.mediaType === 'image/gif',
    }
    const variantHash = sha256Hex(Buffer.from(JSON.stringify({
      v: 'ios-imageio-v1',
      attachmentId: ref.attachmentId,
      width: target?.width ?? ref.width,
      height: target?.height ?? ref.height,
      maxBytes: target?.maxBytes ?? this.normalizationPolicy.maxBytes,
    })))
    const variantId = ImageVariantId(`sha256:${variantHash}`)
    const fitsTarget = (!target?.width || ref.width <= target.width)
      && (!target?.height || ref.height <= target.height)
      && (!target?.maxBytes || stored.data.byteLength <= target.maxBytes)
    if (fitsTarget) {
      return {
        variantId,
        attachment: ref,
        data: stored.data,
        mediaType: ref.mediaType,
        bytes: stored.data.byteLength,
        width: ref.width,
        height: ref.height,
        depth: 'uchar',
        space: 'srgb',
        hasAlpha: sourceMeta.hasAlpha,
      }
    }
    const processed = await tryNativeImageProcess(stored.data, {
      maxWidth: target?.width ?? ref.width,
      maxHeight: target?.height ?? ref.height,
      maxBytes: target?.maxBytes ?? this.normalizationPolicy.maxBytes,
      preserveAlpha: sourceMeta.hasAlpha,
    })
    const out = processed ?? {
      data: stored.data,
      mediaType: ref.mediaType,
      width: ref.width,
      height: ref.height,
      hasAlpha: sourceMeta.hasAlpha,
    }
    return {
      variantId,
      attachment: ref,
      data: out.data,
      mediaType: out.mediaType,
      bytes: out.data.byteLength,
      width: out.width,
      height: out.height,
      depth: 'uchar',
      space: 'srgb',
      hasAlpha: out.hasAlpha,
    }
  }

  async saveFile(input) {
    const data = input?.data instanceof Uint8Array ? input.data : new Uint8Array(input?.data ?? [])
    const name = fileLeafName(input?.name)
    const sha256 = sha256Hex(data)
    const targetPath = this._fileObjectPath(sha256, name)
    await atomicWriteBytes(targetPath, data)
    return {
      attachmentId: AttachmentId(`sha256:${sha256}`),
      name,
      bytes: data.byteLength,
    }
  }

  async saveFileStream(input) {
    const name = fileLeafName(input?.name)
    const signal = input?.signal
    const stagingDir = join(this.root, 'tmp')
    await mkdir(stagingDir, { recursive: true, mode: 0o700 })
    const tmpPath = join(stagingDir, randomUUID())
    const hash = createHash('sha256')
    let bytes = 0
    let fh
    try {
      fh = await open(tmpPath, 'wx', 0o600)
      for await (const chunk of input.data) {
        signal?.throwIfAborted?.()
        const buf = chunk instanceof Uint8Array ? chunk : Buffer.from(chunk)
        await fh.writeFile(buf)
        hash.update(buf)
        bytes += buf.byteLength
      }
      await fh.sync()
      await fh.close()
      fh = undefined
      const sha256 = hash.digest('hex')
      const targetPath = this._fileObjectPath(sha256, name)
      await mkdir(dirname(targetPath), { recursive: true, mode: 0o700 })
      try {
        await rename(tmpPath, targetPath)
      } catch (err) {
        await unlink(tmpPath).catch(() => {})
        if (err?.code !== 'EEXIST') throw err
      }
      return {
        attachmentId: AttachmentId(`sha256:${sha256}`),
        name,
        bytes,
      }
    } catch (error) {
      if (fh) await fh.close().catch(() => {})
      await unlink(tmpPath).catch(() => {})
      if (error instanceof AttachmentError || signal?.aborted) throw error
      throw new AttachmentError('Unable to persist file stream.', 'ATTACHMENT_WRITE_FAILED', { cause: error })
    }
  }

  async *readFileStream(ref, signal) {
    signal?.throwIfAborted?.()
    const sha256 = this._ensureFileRef(ref)
    const targetPath = this._fileObjectPath(sha256, ref.name)
    const hash = createHash('sha256')
    const stream = createReadStream(targetPath)
    try {
      for await (const chunk of stream) {
        signal?.throwIfAborted?.()
        const buf = chunk instanceof Uint8Array ? chunk : Buffer.from(chunk)
        hash.update(buf)
        yield buf
      }
    } catch (error) {
      signal?.throwIfAborted?.()
      if (error?.code === 'ENOENT') throw new AttachmentError('Attachment object is missing.', 'ATTACHMENT_NOT_FOUND')
      throw new AttachmentError('Unable to read file attachment.', 'ATTACHMENT_READ_FAILED', { cause: error })
    }
    if (hash.digest('hex') !== sha256) {
      throw new AttachmentError('Stored file attachment failed integrity verification.', 'ATTACHMENT_CORRUPT')
    }
  }

  fileHostPath(ref) {
    const sha256 = this._ensureFileRef(ref)
    return this._fileObjectPath(sha256, ref.name)
  }
}

export const name = 'dsbot-ios-attachments'
export function apply(ctx, config) {
  ctx.plugin(IOSAttachmentStore, config)
}
export default { name, apply }

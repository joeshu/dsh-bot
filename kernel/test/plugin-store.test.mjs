// Automated tests for DSH Plugin Store, pure-JS USTAR .tar.gz extractor,
// SRI SHA-512 integrity check, anti-shadowing (#13730/#1305), and native-binary gating.

import assert from 'node:assert/strict'
import { createHash } from 'node:crypto'
import { existsSync, mkdtempSync, readFileSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { test } from 'node:test'
import { gzipSync } from 'node:zlib'

import { classifyPluginPackage, DSHPluginStore, verifyTarballIntegrity } from '../src/plugin-store.mjs'
import { createTarBuffer, extractNpmTarballSafe } from '../src/plugin-tar.mjs'

function makeTgz(files) {
  return gzipSync(createTarBuffer(files))
}

test('classifyPluginPackage blocks core kernel shadowing (#13730/#1305), desktop natives, and exact-peer skew (#13798)', () => {
  const env = {
    dshVersion: '0.2.2-rc.5',
    coreBundles: new Set(['@deepseek-ai/dsh', '@deepseek-ai/dsh-base', '@deepseek-ai/dsh-session-query-sqlite']),
  }

  const shadow = classifyPluginPackage({ name: '@deepseek-ai/dsh-session-query-sqlite' }, env)
  assert.equal(shadow.compatible, false)
  assert.equal(shadow.status, 'core-builtin')

  const nativeGyp = classifyPluginPackage({ name: 'dsh-plugin-native-pty', gypfile: true }, env)
  assert.equal(nativeGyp.compatible, false)
  assert.equal(nativeGyp.status, 'desktop-only')

  const skew = classifyPluginPackage({
    name: '@deepseek-ai/dsh-hooks-claude-code',
    peerDependencies: { '@deepseek-ai/dsh-agent': '0.2.2-rc.3' },
  }, env)
  assert.equal(skew.compatible, false)
  assert.equal(skew.status, 'version-mismatch')

  const ok = classifyPluginPackage({
    name: '@deepseek-ai/dsh-plugin-weather',
    peerDependencies: { '@deepseek-ai/dsh-base': '0.2.2-rc.5' },
  }, env)
  assert.equal(ok.compatible, true)
  assert.equal(ok.status, 'ios-ready')
})

test('extractNpmTarballSafe blocks Zip-Slip path traversal and .node/.dylib native binaries', () => {
  const dir = mkdtempSync(join(tmpdir(), 'dsh-tar-test-'))
  try {
    const traversalTgz = makeTgz({ 'package/../../evil.js': 'console.log(1)' })
    assert.throws(
      () => extractNpmTarballSafe(traversalTgz, dir),
      (err) => err.code === 'TAR_PATH_TRAVERSAL',
    )

    const nativeTgz = makeTgz({
      'package/package.json': '{"name":"bad"}',
      'package/build/Release/binding.node': 'ELF',
    })
    assert.throws(
      () => extractNpmTarballSafe(nativeTgz, dir),
      (err) => err.code === 'IOS_NATIVE_BINARY_UNSUPPORTED',
    )
  } finally {
    rmSync(dir, { recursive: true, force: true })
  }
})

test('DSHPluginStore searches, verifies SHA-512, installs native JS plugin, toggles, and cleanly uninstalls', async () => {
  const dshHome = mkdtempSync(join(tmpdir(), 'dsh-store-home-'))
  try {
    const pluginTgz = makeTgz({
      'package/package.json': JSON.stringify({
        name: 'dsh-plugin-translator',
        version: '1.2.0',
        main: 'index.js',
        dsh: { bundle: { patch: './cordis.patch.yml' } },
      }),
      'package/index.js': 'export const name = "translator"; export function apply() {}',
      'package/cordis.patch.yml': '- insert:\n    - id: translator\n      name: dsh-plugin-translator\n',
    })
    const integrity = `sha512-${createHash('sha512').update(pluginTgz).digest('base64')}`

    // Verify integrity helper rejects tampering
    assert.equal(verifyTarballIntegrity(pluginTgz, { integrity }).verified, true)
    assert.throws(
      () => verifyTarballIntegrity(Buffer.from('tampered'), { integrity }),
      (err) => err.code === 'INTEGRITY_MISMATCH',
    )

    const mockFetch = async (url) => {
      if (url.includes('/-/v1/search')) {
        return {
          ok: true,
          status: 200,
          json: async () => ({
            objects: [
              { package: { name: 'dsh-plugin-translator', version: '1.2.0', description: 'Translate messages', keywords: ['dsh-plugin'] } },
              { package: { name: '@deepseek-ai/dsh-bash-local', version: '0.2.2-rc.5', description: 'Local shell', keywords: ['dsh-plugin'] } },
            ],
          }),
        }
      }
      if (url.endsWith('/dsh-plugin-translator')) {
        return {
          ok: true,
          status: 200,
          json: async () => ({
            name: 'dsh-plugin-translator',
            'dist-tags': { latest: '1.2.0' },
            versions: {
              '1.2.0': {
                name: 'dsh-plugin-translator',
                version: '1.2.0',
                description: 'Translate messages',
                main: 'index.js',
                dsh: { bundle: { patch: './cordis.patch.yml' } },
                dist: {
                  tarball: 'https://registry.npmjs.org/dsh-plugin-translator/-/dsh-plugin-translator-1.2.0.tgz',
                  integrity,
                },
              },
            },
          }),
        }
      }
      if (url.endsWith('.tgz')) {
        return {
          ok: true,
          status: 200,
          arrayBuffer: async () => pluginTgz.buffer.slice(pluginTgz.byteOffset, pluginTgz.byteOffset + pluginTgz.byteLength),
        }
      }
      return { ok: false, status: 404, json: async () => ({}) }
    }

    const store = new DSHPluginStore({
      dshHome,
      dshVersion: '0.2.2-rc.5',
      coreBundles: ['@deepseek-ai/dsh', '@deepseek-ai/dsh-base'],
      fetchImpl: mockFetch,
    })

    // 1. Search shows iOS-ready vs desktop-only badges accurately
    const results = await store.searchStore({ query: 'translator' })
    assert.equal(results.length, 2)
    assert.equal(results[0].compatible, true)
    assert.equal(results[1].compatible, false)
    assert.equal(results[1].compatibility, 'desktop-only')

    // 2. Install verified pure-JS DSH plugin
    const installed = await store.installPlugin({ name: 'dsh-plugin-translator' })
    assert.equal(installed.version, '1.2.0')
    assert.equal(installed.enabled, true)
    assert.equal(installed.dshBundlePatch, './cordis.patch.yml')
    assert.ok(existsSync(join(installed.installDir, 'index.js')))
    assert.match(readFileSync(join(installed.installDir, 'index.js'), 'utf8'), /translator/)

    // 3. Toggle disabled -> enabled
    assert.equal(store.setEnabled('dsh-plugin-translator', false).enabled, false)
    assert.equal(store.listInstalled()[0].enabled, false)

    // 4. Clean uninstall deletes files & registry entry (#13851)
    const removed = store.uninstallPlugin('dsh-plugin-translator')
    assert.equal(removed.removed, true)
    assert.equal(existsSync(installed.installDir), false)
    assert.equal(store.listInstalled().length, 0)
  } finally {
    rmSync(dshHome, { recursive: true, force: true })
  }
})

test('DSH 0.2.2-rc.5 #13792 & engines.dsh guard: blocks known regression & mismatched engines.dsh', () => {
  const ctx = { dshVersion: '0.2.2-rc.5', coreBundles: new Set(['@deepseek-ai/dsh']) }

  const reg = classifyPluginPackage(
    { name: '@deepseek-ai/dsh-experimental-session-search', version: '0.2.1-alpha.2' },
    ctx,
  )
  assert.equal(reg.compatible, false)
  assert.equal(reg.status, 'known-regression')

  const badEngine = classifyPluginPackage(
    { name: '@ash-qw/dsh-theme-prts', version: '4.2.0', engines: { dsh: '0.2.2-rc.2 || 0.2.2-rc.3' } },
    ctx,
  )
  assert.equal(badEngine.compatible, false)
  assert.equal(badEngine.status, 'version-mismatch')

  const okEngine = classifyPluginPackage(
    { name: '@ash-qw/dsh-theme-prts', version: '4.2.1', engines: { dsh: '0.2.2-rc.2 || 0.2.2-rc.3 || 0.2.2-rc.5' } },
    ctx,
  )
  assert.equal(okEngine.compatible, true)
  assert.equal(okEngine.status, 'ios-ready')
})

test('extractNpmTarballSafe enforces decompression size and file-count caps against tar bombs', () => {
  const tgz = gzipSync(createTarBuffer({
    'package/a.js': '1',
    'package/b.js': '2',
    'package/c.js': '3',
  }))
  assert.throws(
    () => extractNpmTarballSafe(tgz, '/tmp/tar-cap-test', { dryRun: true, maxFiles: 2 }),
    { code: 'TAR_FILE_LIMIT_EXCEEDED' },
  )
  assert.throws(
    () => extractNpmTarballSafe(tgz, '/tmp/tar-cap-test', { dryRun: true, maxUncompressedBytes: 512 }),
    { code: 'TAR_SIZE_LIMIT_EXCEEDED' },
  )
})

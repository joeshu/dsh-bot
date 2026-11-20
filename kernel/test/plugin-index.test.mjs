// Tests for community plugin index sources (dsh-market, dshfind, custom index.json),
// GitHub URL installation, local folder copy-install, and experimental plugin toggles.

import assert from 'node:assert/strict'
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { test } from 'node:test'
import { gzipSync } from 'node:zlib'

import { PluginIndexManager } from '../src/plugin-index.mjs'
import { DSHPluginStore, parseGitHubSpec } from '../src/plugin-store.mjs'
import { createTarBuffer } from '../src/plugin-tar.mjs'

test('PluginIndexManager manages mutually exclusive dsh-market, dshfind, and custom HTTPS index.json sources', async () => {
  const dshHome = mkdtempSync(join(tmpdir(), 'dsh-idx-home-'))
  try {
    const mockFetch = async (url) => {
      if (url.includes('dsh-market')) {
        return {
          ok: true,
          status: 200,
          json: async () => ({
            plugins: [
              { name: 'dsh-purge-safe', version: '1.0.3', description: 'DeepSeek Harness 破甲安全清理' },
              { name: 'dsh-plugin-whale-pet', version: '0.4.0', description: 'Whale Pet 伴侣插件' },
            ],
          }),
        }
      }
      return { ok: true, status: 200, json: async () => ({ plugins: [] }) }
    }

    const mgr = new PluginIndexManager({ dshHome, fetchImpl: mockFetch })

    // Default: both example sources present, none enabled
    const initial = mgr.listSources()
    assert.equal(initial.activeSourceId, null)
    assert.equal(initial.sources.length, 2)
    assert.equal(initial.sources.every((s) => s.enabled === false), true)

    // Enable dsh-market -> Discover loads catalog
    mgr.setActiveSource('dsh-market')
    const catalog = await mgr.fetchDiscoverCatalog()
    assert.equal(catalog.activeSource.id, 'dsh-market')
    assert.equal(catalog.items.length, 2)
    assert.equal(catalog.items[0].name, 'dsh-purge-safe')

    // Enabling dshfind replaces dsh-market (mutually exclusive)
    const switched = mgr.setActiveSource('dshfind')
    assert.equal(switched.activeSourceId, 'dshfind')
    assert.equal(switched.sources.find((s) => s.id === 'dsh-market').enabled, false)
    assert.equal(switched.sources.find((s) => s.id === 'dshfind').enabled, true)

    // Custom HTTPS index.json works; HTTP is rejected
    assert.throws(() => mgr.addCustomSource({ url: 'http://insecure.example.com/index.json' }))
    const added = mgr.addCustomSource({ url: 'https://plugins.example.com/index.json', name: 'My Index' })
    assert.equal(added.sources.length, 3)
    assert.ok(added.activeSourceId.startsWith('custom-'))

    // Experimental plugin toggle persists
    const exp = mgr.setExperimentalEnabled('dev-tools', true)
    assert.equal(exp.enabled, true)
    assert.equal(mgr.listExperimental().find((p) => p.id === 'dev-tools').enabled, true)
  } finally {
    rmSync(dshHome, { recursive: true, force: true })
  }
})

test('DSHPluginStore installs from GitHub URL and copies from local folder safely', async () => {
  const dshHome = mkdtempSync(join(tmpdir(), 'dsh-gh-local-'))
  const localSrc = mkdtempSync(join(tmpdir(), 'dsh-local-plugin-'))
  try {
    // 1. Parse GitHub URLs
    assert.deepEqual(parseGitHubSpec('https://github.com/example/dsh-plugin-whale-pet'), {
      owner: 'example',
      repo: 'dsh-plugin-whale-pet',
      ref: 'HEAD',
    })
    assert.equal(parseGitHubSpec('dsh-purge-safe'), null)

    // 2. GitHub tarball install
    const ghTgz = gzipSync(createTarBuffer({
      'dsh-plugin-whale-pet-main/package.json': JSON.stringify({
        name: 'dsh-plugin-whale-pet',
        version: '0.5.0',
        main: 'index.js',
        dsh: { client: { platform: 'web' } },
      }),
      'dsh-plugin-whale-pet-main/index.js': 'export const name = "whale-pet";',
    }))
    const store = new DSHPluginStore({
      dshHome,
      dshVersion: '0.2.2-rc.5',
      coreBundles: ['@deepseek-ai/dsh', '@deepseek-ai/dsh-base'],
      fetchImpl: async () => ({
        ok: true,
        status: 200,
        arrayBuffer: async () => ghTgz.buffer.slice(ghTgz.byteOffset, ghTgz.byteOffset + ghTgz.byteLength),
      }),
    })

    const ghInstalled = await store.installPlugin({ name: 'https://github.com/example/dsh-plugin-whale-pet' })
    assert.equal(ghInstalled.name, 'dsh-plugin-whale-pet')
    assert.equal(ghInstalled.sourceType, 'github')
    assert.equal(ghInstalled.hasWebUI, true)

    // 3. Local folder copy-install ("从本地文件夹安装")
    mkdirSync(localSrc, { recursive: true })
    writeFileSync(join(localSrc, 'package.json'), JSON.stringify({
      name: 'dsh-purge-safe',
      version: '1.0.0',
      description: 'DeepSeek Harness 破甲安全清理',
      main: 'index.js',
    }))
    writeFileSync(join(localSrc, 'index.js'), 'export const name = "purge-safe";')

    const localInstalled = store.installFromLocalFolder(localSrc)
    assert.equal(localInstalled.sourceType, 'local-folder')
    assert.ok(existsSync(join(localInstalled.installDir, 'index.js')))
    assert.match(readFileSync(join(localInstalled.installDir, 'index.js'), 'utf8'), /purge-safe/)
  } finally {
    rmSync(dshHome, { recursive: true, force: true })
    rmSync(localSrc, { recursive: true, force: true })
  }
})

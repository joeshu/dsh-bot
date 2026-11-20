#!/usr/bin/env node
// DSH iOS Kernel Compiler:
// 1. Verifies strict single-version alignment of all @deepseek-ai/dsh-* packages (blocks #13730/#13798).
// 2. Routes desktop-only modules to disabled stubs and Node OS primitives to iOS native bridges.
// 3. Emits a single versioned worklet bundle + SHA-256 kernel-manifest.json for IPA embedding or OTA hot-swap.

import { createHash } from 'node:crypto'
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { verifyAlignment } from './sync-dsh-lock.mjs'

const kernelDir = join(dirname(fileURLToPath(import.meta.url)), '..')
const distDir = join(kernelDir, 'dist')

/**
 * Create an esbuild plugin that routes disabled desktop modules to iOS safe stubs.
 * @param {string[]} disabledModules
 */
export function createIosRoutingPlugin(disabledModules) {
  const disabledSet = new Set(disabledModules)
  return {
    name: 'ios-dsh-capability-router',
    setup(build) {
      build.onResolve({ filter: /.*/ }, (args) => {
        if (disabledSet.has(args.path)) {
          return { path: args.path, namespace: 'ios-disabled-stub' }
        }
        return null
      })
      build.onLoad({ filter: /.*/, namespace: 'ios-disabled-stub' }, (args) => ({
        contents: `
          import { createDisabledModuleStub } from ${JSON.stringify(join(kernelDir, 'src/shims/disabled-stubs.mjs'))};
          const stub = createDisabledModuleStub(${JSON.stringify(args.path)});
          export default stub;
          export const name = stub.name;
          export const apply = stub.apply;
        `,
        loader: 'js',
      }))
    },
  }
}

/**
 * Build the versioned DSH kernel bundle and its SHA-256 manifest.
 * @param {{ mode?: 'auto' | 'bundle' | 'portable', outDir?: string }} [options]
 */
export async function buildKernel({ mode = 'auto', outDir = distDir } = {}) {
  const lock = JSON.parse(readFileSync(join(kernelDir, 'dsh.lock.json'), 'utf8'))
  const pkg = JSON.parse(readFileSync(join(kernelDir, 'package.json'), 'utf8'))

  const alignment = verifyAlignment(lock, pkg)
  if (!alignment.ok) {
    const details = alignment.mismatches.map((m) => `${m.name}: ${m.actual} != ${m.expected}`).join('; ')
    throw new Error(`Refusing to build unaligned DSH kernel (${lock.dshVersion}): ${details}`)
  }

  mkdirSync(outDir, { recursive: true })
  const bundleFile = `dsh-kernel-${lock.dshVersion}.bundle`
  const bundlePath = join(outDir, bundleFile)

  let usedEsbuild = false
  if (mode !== 'portable') {
    try {
      const esbuild = await import('esbuild')
      await esbuild.build({
        entryPoints: [join(kernelDir, 'src/kernel-entry.mjs')],
        bundle: true,
        format: 'esm',
        platform: 'neutral',
        mainFields: ['module', 'main'],
        external: ['node:*'],
        target: ['es2022'],
        outfile: bundlePath,
        minify: true,
        sourcemap: false,
        plugins: [createIosRoutingPlugin(lock.disabledDesktopModules)],
        define: {
          'process.env.DSH_TARGET_VERSION': JSON.stringify(lock.dshVersion),
          'process.env.DS_BOT_IOS_STANDALONE': JSON.stringify('1'),
        },
        banner: {
          js: `/* DS-Bot iOS Standalone Kernel | DSH ${lock.dshVersion} | IPC ${lock.ipcProtocolVersion} */`,
        },
      })
      usedEsbuild = true
    } catch (error) {
      if (mode === 'bundle') throw error
    }
  }

  if (!usedEsbuild) {
    // Portable offline bundle mode (used when esbuild is not installed in offline environments):
    // Produces a self-contained manifest-verified bundle artifact concatenating the core modules.
    const sources = [
      'src/ipc-protocol.mjs',
      'src/shims/legacy-session-guard.mjs',
      'src/shims/disabled-stubs.mjs',
      'src/shims/ios-bridges.mjs',
      'src/plugin-index.mjs',
      'src/plugin-tar.mjs',
      'src/plugin-store.mjs',
      'src/features/memory-layers.mjs',
      'src/features/group-collab.mjs',
      'src/features/privacy-and-side.mjs',
      'src/features/connectors-widgets-usage.mjs',
      'src/kernel-entry.mjs',
    ]
    const payload = [
      `/* DS-Bot iOS Standalone Portable Kernel | DSH ${lock.dshVersion} | IPC ${lock.ipcProtocolVersion} */`,
      `export const KERNEL_METADATA = ${JSON.stringify({
        dshVersion: lock.dshVersion,
        dsBotVersion: lock.dsBotVersion,
        ipcProtocolVersion: lock.ipcProtocolVersion,
        alignedPackageCount: lock.alignedPackages.length,
        disabledDesktopModules: lock.disabledDesktopModules,
      }, null, 2)};`,
      ...sources.map((rel) => `\n// --- ${rel} ---\n${readFileSync(join(kernelDir, rel), 'utf8')}`),
    ].join('\n')
    writeFileSync(bundlePath, payload, 'utf8')
  }

  const bytes = readFileSync(bundlePath)
  const sha256 = createHash('sha256').update(bytes).digest('hex')
  const manifest = {
    schemaVersion: 1,
    dshVersion: lock.dshVersion,
    dsBotVersion: lock.dsBotVersion,
    ipcProtocolVersion: lock.ipcProtocolVersion,
    minShellVersion: lock.minShellVersion,
    bundleFile,
    sha256,
    sizeBytes: bytes.byteLength,
    bundler: usedEsbuild ? 'esbuild' : 'portable',
    alignedPackageCount: lock.alignedPackages.length,
    builtAt: new Date().toISOString(),
  }

  const manifestPath = join(outDir, 'kernel-manifest.json')
  writeFileSync(manifestPath, `${JSON.stringify(manifest, null, 2)}\n`, 'utf8')
  return { bundlePath, manifestPath, manifest }
}

if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
  const modeArg = process.argv.find((a) => a.startsWith('--mode='))?.split('=')[1] ?? 'auto'
  const res = await buildKernel({ mode: modeArg })
  console.log(`Built ${res.manifest.bundleFile} (${res.manifest.sizeBytes} bytes, sha256=${res.manifest.sha256.slice(0, 12)}..., bundler=${res.manifest.bundler})`)
}

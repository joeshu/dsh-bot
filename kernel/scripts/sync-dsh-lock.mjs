#!/usr/bin/env node
// Single-command DSH version alignment tool.
// Prevents Discussion #13730 / #13798 version drift by syncing every @deepseek-ai/dsh-*
// package in kernel/dsh.lock.json and kernel/package.json to the exact same version.
//
// Usage:
//   node scripts/sync-dsh-lock.mjs 0.2.2-rc.6
//   node scripts/sync-dsh-lock.mjs --check

import { readFileSync, writeFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const kernelDir = join(dirname(fileURLToPath(import.meta.url)), '..')
const lockPath = join(kernelDir, 'dsh.lock.json')
const pkgPath = join(kernelDir, 'package.json')

const SEMVER_RE = /^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$/

export function verifyAlignment(lock, pkg) {
  const target = lock.dshVersion
  const mismatches = []
  for (const name of lock.alignedPackages) {
    const actual = pkg.dependencies?.[name]
    if (actual !== target) {
      mismatches.push({ name, expected: target, actual: actual ?? '(missing)' })
    }
  }
  for (const [name, actual] of Object.entries(pkg.overrides ?? {})) {
    if (name.startsWith('@deepseek-ai/dsh') && actual !== target) {
      mismatches.push({ name: `overrides.${name}`, expected: target, actual })
    }
  }
  return { ok: mismatches.length === 0, target, mismatches }
}

export function syncVersion(targetVersion) {
  if (!SEMVER_RE.test(targetVersion)) {
    throw new Error(`Invalid DSH semver version: "${targetVersion}"`)
  }
  const lock = JSON.parse(readFileSync(lockPath, 'utf8'))
  const pkg = JSON.parse(readFileSync(pkgPath, 'utf8'))

  lock.dshVersion = targetVersion
  pkg.dependencies ??= {}
  for (const name of lock.alignedPackages) {
    pkg.dependencies[name] = targetVersion
  }
  pkg.overrides ??= {}
  for (const key of Object.keys(pkg.overrides)) {
    if (key.startsWith('@deepseek-ai/dsh')) {
      pkg.overrides[key] = targetVersion
    }
  }

  writeFileSync(lockPath, `${JSON.stringify(lock, null, 2)}\n`, 'utf8')
  writeFileSync(pkgPath, `${JSON.stringify(pkg, null, 2)}\n`, 'utf8')
  return { targetVersion, alignedCount: lock.alignedPackages.length }
}

if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
  const arg = process.argv[2]
  if (!arg || arg === '--check') {
    const lock = JSON.parse(readFileSync(lockPath, 'utf8'))
    const pkg = JSON.parse(readFileSync(pkgPath, 'utf8'))
    const result = verifyAlignment(lock, pkg)
    if (!result.ok) {
      console.error(`DSH alignment check FAILED (target ${result.target}):`)
      for (const m of result.mismatches) {
        console.error(`  - ${m.name}: expected ${m.expected}, got ${m.actual}`)
      }
      process.exit(1)
    }
    console.log(`DSH alignment OK: ${lock.alignedPackages.length} packages locked at ${result.target}`)
  } else {
    const res = syncVersion(arg)
    console.log(`Synced ${res.alignedCount} DSH packages to ${res.targetVersion}`)
  }
}

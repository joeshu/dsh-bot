#!/usr/bin/env node
// Generates an AltStore / SideStore compatible `source.json` feed for the standalone unsigned IPA.
// Usage:
//   node scripts/generate-sidestore-source.mjs \
//     --repo owner/repo --tag v1.8.2 --ipa dist/DS-Bot-iOS-Standalone-v1.8.2-dsh0.2.2-rc.5-unsigned.ipa --out dist/source.json

import { readFileSync, statSync, writeFileSync } from 'node:fs'
import { basename, dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const rootDir = join(dirname(fileURLToPath(import.meta.url)), '..')
const lock = JSON.parse(readFileSync(join(rootDir, 'kernel/dsh.lock.json'), 'utf8'))
const pkg = JSON.parse(readFileSync(join(rootDir, 'kernel/package.json'), 'utf8'))

function parseArg(flag, fallback) {
  const idx = process.argv.indexOf(flag)
  return idx !== -1 && process.argv[idx + 1] ? process.argv[idx + 1] : fallback
}

export function buildSourceFeed({ repo, tag, ipaFilename, sizeBytes, dshVersion, appVersion, date }) {
  const downloadURL = `https://github.com/${repo}/releases/download/${tag}/${ipaFilename}`
  return {
    name: 'DS Bot iOS Standalone',
    identifier: 'io.github.dsbot.ios.standalone.source',
    subtitle: `Standalone iOS Agent powered by embedded DSH ${dshVersion}`,
    sourceURL: `https://github.com/${repo}/releases/latest/download/source.json`,
    apps: [
      {
        name: 'DS Bot',
        bundleIdentifier: 'io.github.dsbot.ios.standalone',
        developerName: 'DS Bot Standalone Contributors',
        subtitle: `Embedded DSH ${dshVersion} (No PC required)`,
        localizedDescription: `Standalone Apple iOS app with hot-swappable embedded DeepSeek Harness (${dshVersion}), native SQLite, Keychain Face ID vault, and Remote MCP support.`,
        tintColor: '#2563EB',
        versions: [
          {
            version: appVersion,
            date,
            localizedDescription: `Baseline DSH kernel ${dshVersion} with #13730/#13798 alignment lock and #13834 legacy session guard.`,
            downloadURL,
            size: sizeBytes,
            minOSVersion: '16.4',
          },
        ],
        appPermissions: {
          entitlements: [],
          privacy: {
            NSFaceIDUsageDescription: 'DS Bot uses Face ID to protect API keys and approve sensitive agent actions.',
            NSLocalNetworkUsageDescription: 'DS Bot connects to local MCP servers or self-hosted endpoints on your network.',
          },
        },
      },
    ],
  }
}

if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
  const repo = parseArg('--repo', 'joeshu/dsh-bot')
  const tag = parseArg('--tag', `v${pkg.version}`)
  const ipaPath = parseArg('--ipa', '')
  const outPath = parseArg('--out', join(rootDir, 'dist/source.json'))
  const sizeBytes = ipaPath ? statSync(ipaPath).size : 0
  const ipaFilename = ipaPath ? basename(ipaPath) : `DS-Bot-iOS-Standalone-v${pkg.version}-dsh${lock.dshVersion}-unsigned.ipa`

  const feed = buildSourceFeed({
    repo,
    tag,
    ipaFilename,
    sizeBytes,
    dshVersion: lock.dshVersion,
    appVersion: pkg.version,
    date: new Date().toISOString().slice(0, 10),
  })
  writeFileSync(outPath, `${JSON.stringify(feed, null, 2)}\n`, 'utf8')
  console.log(`Generated SideStore/AltStore source feed -> ${outPath}`)
}

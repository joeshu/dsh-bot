import test from 'node:test'
import assert from 'node:assert/strict'
import { existsSync, mkdtempSync, readFileSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'

const REPO_ROOT = fileURLToPath(new URL('../..', import.meta.url))
const readRepo = (rel) => readFileSync(join(REPO_ROOT, rel), 'utf8')
const HAS_RUNTIME_NODE_MODULES = existsSync(join(REPO_ROOT, 'kernel/runtime/node_modules/@deepseek-ai/dsh-attachment/lib/index.js'))

// Minimal valid 1x1 PNG (67 bytes)
const TINY_PNG = Buffer.from(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
  'base64',
)

// Minimal valid 1x1 GIF89a
const TINY_GIF = Buffer.from('R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7', 'base64')

test('session-arch (stage 2): probeImagePureJS & IOSAttachmentStore save/read/project images and files without sharp', async (t) => {
  if (!HAS_RUNTIME_NODE_MODULES) {
    t.skip('kernel/runtime/node_modules not installed in lightweight kernel-tests job')
    return
  }
  const { Context } = await import('../runtime/node_modules/@deepseek-ai/cordis/lib/index.js')
  const { IOSAttachmentStore, probeImagePureJS } = await import('../runtime/ios-host-package/ios-attachment-store.mjs')

  const pngMeta = probeImagePureJS(TINY_PNG)
  assert.deepEqual(pngMeta, { mediaType: 'image/png', width: 1, height: 1, hasAlpha: true })

  const gifMeta = probeImagePureJS(TINY_GIF)
  assert.deepEqual(gifMeta, { mediaType: 'image/gif', width: 1, height: 1, hasAlpha: true })

  assert.equal(probeImagePureJS(Buffer.from('not-an-image')), null)

  const dir = mkdtempSync(join(tmpdir(), 'dsbot-att-test-'))
  try {
    const ctx = new Context()
    const store = new IOSAttachmentStore(ctx, { dshHome: dir })

    const ref = await store.saveImage({ data: TINY_PNG, mediaType: 'image/png', name: 'sample.png' })
    assert.match(String(ref.attachmentId), /^sha256:[a-f0-9]{64}$/)
    assert.equal(ref.mediaType, 'image/png')
    assert.equal(ref.width, 1)
    assert.equal(ref.height, 1)
    assert.equal(ref.bytes, TINY_PNG.byteLength)

    const readBack = await store.readImage(ref)
    assert.deepEqual(Buffer.from(readBack.data), TINY_PNG)

    const projected = await store.readImageRequest(ref, { width: 1024, height: 1024, maxBytes: 1024 * 1024 })
    assert.equal(projected.width, 1)
    assert.equal(projected.height, 1)
    assert.equal(projected.mediaType, 'image/png')
    assert.match(String(projected.variantId), /^sha256:[a-f0-9]{64}$/)

    const fileRef = await store.saveFile({ data: Buffer.from('hello world'), name: 'notes.txt' })
    assert.equal(fileRef.name, 'notes.txt')
    assert.equal(fileRef.bytes, 11)
    const chunks = []
    for await (const c of store.readFileStream(fileRef)) chunks.push(c)
    assert.equal(Buffer.concat(chunks).toString('utf8'), 'hello world')
  } finally {
    rmSync(dir, { recursive: true, force: true })
  }
})

test('session-arch (stage 1): unified handle tracking, installModelSelection, bots.policy.sync, container CWD self-heal, zero-lock suspend & DEEPSEEK_SEARCH_API_KEY', () => {
  const entry = readRepo('kernel/runtime/dsh-ios-entry.mjs')
  const persistence = readRepo('kernel/runtime/sqlite-session-persistence.mjs')
  const approval = readRepo('kernel/runtime/ios-host-package/approval.mjs')
  const cordis = readRepo('kernel/runtime/ios-profile-package/cordis.patch.yml')

  // Unified AgentHandle coordinator & no destructive owner.close() hack
  assert.match(entry, /import\s+\{\s*installModelSelection\s*\}\s+from\s+'@deepseek-ai\/dsh-agent'/)
  assert.match(entry, /allAgentHandles:\s*new Map\(\)/)
  assert.match(entry, /async function releaseSessionAgent\(/)
  assert.doesNotMatch(entry, /owner\.close\?\.\(\)/)
  assert.match(entry, /rpc\.handle\('bots\.policy\.sync'/)
  assert.match(entry, /rpc\.notify\('session\.changed'/)

  // Zero-lock suspend & DEEPSEEK_SEARCH_API_KEY
  assert.match(cordis, /id:\s*session-query-sqlite[\s\S]*?journalMode:\s*truncate/)
  assert.match(entry, /sq\._db\.close\(\)/)
  assert.doesNotMatch(entry, /searchApiKeyEnv:\s*'DEEPSEEK_API_KEY'/)
  assert.match(entry, /searchApiKeyEnv:\s*'DEEPSEEK_SEARCH_API_KEY'/)

  // Container CWD migration & title backfill
  assert.match(persistence, /migrateContainerCwds\(\)/)
  assert.match(persistence, /backfillSessionTitles\(\)/)
  assert.match(persistence, /IOS_CONTAINER_FILES_RE/)

  // Web readOnly enforcement on ios:* sessions
  assert.match(approval, /runtime\.botPolicies\?\.get\(rootBotId\)/)
})

test('session-arch (stage 2-4): ImageIO store, safe truncateFromSeq, real /compact, questions global+prepend, subagent approval, child-thread search/jobs, lossless steer & telemetry', () => {
  const entry = readRepo('kernel/runtime/dsh-ios-entry.mjs')
  const persistence = readRepo('kernel/runtime/sqlite-session-persistence.mjs')
  const questions = readRepo('kernel/runtime/ios-host-package/questions.mjs')
  const privAccess = readRepo('kernel/runtime/ios-host-package/private-session-access.mjs')
  const cordis = readRepo('kernel/runtime/ios-profile-package/cordis.patch.yml')
  const compat = readRepo('kernel/runtime/ios-openai-compat-adapter.mjs')
  const hostSwift = readRepo('ios/Sources/Runtime/LocalAgentHost.swift')
  const chatSwift = readRepo('ios/Sources/UI/ChatView.swift')
  const modelsSwift = readRepo('ios/Sources/Runtime/AgentModels.swift')
  const searchSwift = readRepo('ios/Sources/UI/SessionSearchView.swift')
  const profileSwift = readRepo('ios/Sources/UI/BotProfileSheet.swift')
  const jobsSwift = readRepo('ios/Sources/UI/JobsManagerView.swift')

  // Stage 2: Attachment store, saveImage, /files 404, safe truncateFromSeq, Swift seq & delete confirmation
  assert.match(cordis, /name:\s*'@dsbot\/dsh-ios-host\/ios-attachment-store'/)
  assert.match(entry, /attachmentsSvc\.saveImage\(/)
  assert.doesNotMatch(entry, /attachmentsSvc\.storeImage\(/)
  assert.match(compat, /parsedUrl\.pathname\.endsWith\('\/files'\)/)
  assert.match(persistence, /inherited_event_count/)
  assert.match(persistence, /openCompactionSeq/)
  assert.match(privAccess, /ios\/session\/mutated/)
  assert.match(hostSwift, /native\.image\.process/)
  assert.match(hostSwift, /params\["assistantMessages"\]/)
  assert.match(chatSwift, /删除此处及后续对话…/)

  // Stage 3: Real slash commands, surface projection, questions global+prepend, subagent ask, search & jobs
  assert.match(entry, /rpc\.handle\('command\.execute'/)
  assert.match(entry, /rpc\.handle\('session\.ensureWebReady'/)
  assert.match(entry, /sourceKind === 'compaction'/)
  assert.match(entry, /approval\/policy', \{ policy: 'ask'/)
  assert.match(entry, /iosJobBelongsToOwner/)
  assert.match(questions, /\{\s*global:\s*true,\s*prepend:\s*true\s*\}/)
  assert.match(privAccess, /hasActiveNativeTurn/)
  assert.match(hostSwift, /func executeSlashCommand\(/)
  assert.match(hostSwift, /func ensureSessionWebReady\(/)
  assert.match(chatSwift, /runCompactCommand\(\)/)
  assert.doesNotMatch(chatSwift, /text:\s*"\/compact"/)
  assert.match(searchSwift, /targetMessageID:\s*targetMessageID/)
  assert.match(profileSwift, /effectiveSessionId/)
  assert.match(jobsSwift, /\$0\.agentPreset == "redteam"/)

  // Stage 4: Lossless steer, warm abort, non-empty pagination, telemetry formula, private lock hygiene
  assert.match(entry, /rpc\.handle\('chat\.steer'/)
  assert.match(entry, /minVisible = 15/)
  assert.match(hostSwift, /"chat\.steer"/)
  assert.match(modelsSwift, /let totalInput = inputTokens \+ cacheReadTokens/)
  assert.match(chatSwift, /host\.setDraftInput\("", for: thread\.sessionId, isPrivate: true\)/)
})

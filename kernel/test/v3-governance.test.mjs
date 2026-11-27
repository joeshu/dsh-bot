import test from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync, readdirSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { dirname, join } from 'node:path'

const __dirname = dirname(fileURLToPath(import.meta.url))
const runtimeDir = join(__dirname, '..', 'runtime')

// Mirror of flattenToolSchema contract in kernel/runtime/dsh-ios-entry.mjs
function flattenToolSchema(schema, defs = undefined, depth = 0) {
  if (!schema || typeof schema !== 'object' || Array.isArray(schema) || depth > 12) return schema
  const rootDefs = defs ?? schema.$defs ?? schema.definitions ?? {}
  if (typeof schema.$ref === 'string') {
    const key = schema.$ref.replace(/^#\/(\$defs|definitions)\//, '')
    if (Object.hasOwn(rootDefs, key)) {
      return flattenToolSchema(rootDefs[key], rootDefs, depth + 1)
    }
  }
  const out = {}
  for (const [k, v] of Object.entries(schema)) {
    if (k === '$defs' || k === 'definitions' || k === '$schema' || k === '$ref') continue
    if (k === 'const') {
      out.enum = [v]
      continue
    }
    if ((k === 'anyOf' || k === 'oneOf' || k === 'allOf') && Array.isArray(v)) {
      const nonNull = v.filter((item) => item && item.type !== 'null')
      if (nonNull.length === 1) {
        Object.assign(out, flattenToolSchema(nonNull[0], rootDefs, depth + 1))
        continue
      }
      out[k] = v.map((item) => flattenToolSchema(item, rootDefs, depth + 1))
      continue
    }
    if (k === 'properties' && v && typeof v === 'object' && !Array.isArray(v)) {
      const props = {}
      for (const [pk, pv] of Object.entries(v)) {
        props[pk] = flattenToolSchema(pv, rootDefs, depth + 1)
      }
      out.properties = props
      continue
    }
    if (k === 'items' && v && typeof v === 'object') {
      out.items = flattenToolSchema(v, rootDefs, depth + 1)
      continue
    }
    out[k] = v
  }
  return out
}

test('v3 governance: flattenToolSchema resolves $ref/$defs, converts const to enum, and unwraps nullable anyOf', () => {
  const input = {
    $schema: 'https://json-schema.org/draft/2020-12/schema',
    $defs: {
      Mode: { type: 'string', const: 'strict' },
    },
    type: 'object',
    properties: {
      mode: { $ref: '#/$defs/Mode' },
      note: { anyOf: [{ type: 'string' }, { type: 'null' }] },
    },
  }
  const flattened = flattenToolSchema(input)
  assert.equal(flattened.$defs, undefined)
  assert.equal(flattened.$schema, undefined)
  assert.deepEqual(flattened.properties.mode, { type: 'string', enum: ['strict'] })
  assert.deepEqual(flattened.properties.note, { type: 'string' })
})

test('v3 governance: dsh-ios-entry.mjs enforces Memory Freeze, empty-output normalization, WAL TRUNCATE, and runtime.health', () => {
  const source = readFileSync(join(runtimeDir, 'dsh-ios-entry.mjs'), 'utf8')
  assert.match(source, /frozenSystemPrompt/, 'Missing Memory Freeze Semantics in dsh-ios-entry.mjs')
  assert.match(source, /session\.refreshPersona/, 'Missing session.refreshPersona RPC')
  assert.match(source, /runtime\.health/, 'Missing runtime.health RPC')
  assert.match(source, /flush\(\{\s*truncate:\s*true\s*\}\)/, 'Missing WAL TRUNCATE flush on agent.suspend')
  assert.match(source, /export function flattenToolSchema/, 'Missing exported flattenToolSchema')
  assert.match(source, /模型返回空响应/, 'Missing empty-output normalization')
})

test('v3 governance: sqlite-session-persistence.mjs supports WAL TRUNCATE checkpoint mode and iOS memory pragmas', () => {
  const source = readFileSync(join(runtimeDir, 'sqlite-session-persistence.mjs'), 'utf8')
  assert.match(source, /PRAGMA wal_checkpoint\(\$\{safeMode\}\)/)
  assert.match(source, /options\?\.truncate \? 'TRUNCATE' : 'FULL'/)
  assert.match(source, /PRAGMA cache_size = -4000/)
  assert.match(source, /PRAGMA mmap_size = 0/)
})

test('v3 governance: ios-supervisor.mjs caps Worker V8 isolate via resourceLimits', () => {
  const source = readFileSync(join(runtimeDir, 'ios-supervisor.mjs'), 'utf8')
  assert.match(source, /worker-heap-mb/)
  assert.match(source, /resourceLimits:\s*\{[\s\S]*maxOldGenerationSizeMb/)
})

test('v3 governance: ios-plugin-manager.mjs enforces Cordis/DSH peer dependency gate (#12213)', () => {
  const source = readFileSync(join(runtimeDir, 'ios-plugin-manager.mjs'), 'utf8')
  assert.match(source, /@deepseek-ai\/cordis/)
  assert.match(source, /DSH\/Cordis 契约冲突/)
})

test('v3 governance: Web UI mounts sandbox-jailed directory picker host + client UI pair and pins default workspace to files/', () => {
  const patch = readFileSync(join(runtimeDir, 'ios-profile-package', 'cordis.patch.yml'), 'utf8')
  assert.match(patch, /@dsbot\/dsh-ios-host\/ios-directory-picker-browse/)
  assert.match(patch, /@deepseek-ai\/dsh-client-ui-directory-picker-browse/)
  assert.match(patch, /documentsDirectory:.*DSH_HOME \+ '\/files'/)
  const pickerSource = readFileSync(join(runtimeDir, 'ios-host-package', 'ios-directory-picker-browse.mjs'), 'utf8')
  assert.match(pickerSource, /sandboxRoot/)
  assert.match(pickerSource, /DirectoryPicker/)
})

test('v3 governance: sandbox-fs normalizes /workspace and files/ virtual paths and Web UI tools support fallback', () => {
  const fsSource = readFileSync(join(runtimeDir, 'ios-host-package', 'sandbox-fs.mjs'), 'utf8')
  assert.match(fsSource, /normalizeVirtualPath/)
  assert.match(fsSource, /\/workspace\//)
  const toolsSource = readFileSync(join(runtimeDir, 'ios-host-package', 'native-tools.mjs'), 'utf8')
  assert.match(toolsSource, /executeWebFallbackTool/)
  assert.match(toolsSource, /web_fetch blocked private or loopback address/)
  const pySource = readFileSync(join(runtimeDir, 'ios-host-package', 'ios-python-tool.mjs'), 'utf8')
  assert.match(pySource, /executeIOSPython\(/)
})

test('v3 governance: dsh-purge-safe enforces single-flight mount mutex, ESM cache-busting, and warm-boot stage stamp', () => {
  const entry = readFileSync(join(runtimeDir, 'dsh-ios-entry.mjs'), 'utf8')
  assert.match(entry, /redteamMountInFlight/)
  assert.match(entry, /\?rev=\$\{rev\}/)
  const pm = readFileSync(join(runtimeDir, 'ios-plugin-manager.mjs'), 'utf8')
  assert.match(pm, /\.ios-stage-stamp/)
})

test('v3 governance: ios-plugin-manager supports atomic in-place upgrade, GitHub rate-limit HEAD fallback, orphan cleanup, and plugins.audit', () => {
  const pm = readFileSync(join(runtimeDir, 'ios-plugin-manager.mjs'), 'utf8')
  assert.match(pm, /\.ios-plugin-backup-/)
  assert.match(pm, /targetRef = 'HEAD'/)
  assert.match(pm, /releases' && parts\[3\] === 'tag'/)
  assert.match(pm, /rpc\.handle\('plugins\.audit'/)
})

test('v3 governance: zero-lock SQLite close-on-suspend, --safe-mode supervisor flag, and webServerAlive health probe', () => {
  const sqliteSource = readFileSync(join(runtimeDir, 'sqlite-session-persistence.mjs'), 'utf8')
  assert.match(sqliteSource, /get db\(\)/)
  assert.match(sqliteSource, /closeDatabaseHandle\(\)/)
  assert.match(sqliteSource, /async suspendDatabase\(\)/)
  assert.match(sqliteSource, /resumeDatabase\(\)/)
  const supervisor = readFileSync(join(runtimeDir, 'ios-supervisor.mjs'), 'utf8')
  assert.match(supervisor, /args\.includes\('--safe-mode'\)/)
  const entry = readFileSync(join(runtimeDir, 'dsh-ios-entry.mjs'), 'utf8')
  assert.match(entry, /suspendDatabase/)
  assert.match(entry, /resumeDatabase/)
  assert.match(entry, /webServerAlive/)
})

test('v3 security: zero unsafe vm.runInNewContext in runtime and QuickJS RPC routing enabled', () => {
  const entry = readFileSync(join(runtimeDir, 'dsh-ios-entry.mjs'), 'utf8')
  const nativeTools = readFileSync(join(runtimeDir, 'ios-host-package', 'native-tools.mjs'), 'utf8')
  assert.doesNotMatch(entry, /vm\.runInNewContext\s*\(/)
  assert.doesNotMatch(nativeTools, /vm\.runInNewContext\s*\(/)
  assert.match(entry, /sandbox\.js_eval/)
  assert.match(nativeTools, /sandbox\.js_eval/)
  assert.match(entry, /codeGeneration:\s*\{\s*strings:\s*false,\s*wasm:\s*false\s*\}/)
  assert.match(entry, /redactDiagnosticSecrets/)
})

test('v3 security: web_fetch blocks IPv4/IPv6/mapped-IPv6/CGNAT/link-local SSRF, redirects, and unbounded bodies', async () => {
  const nativeToolsPath = join(runtimeDir, 'ios-host-package', 'native-tools.mjs')
  const nativeToolsSource = readFileSync(nativeToolsPath, 'utf8')
  assert.match(nativeToolsSource, /redirect:\s*'manual'/)
  assert.match(nativeToolsSource, /dnsLookup\(/)
  assert.match(nativeToolsSource, /body\?\.getReader\(\)/)
  assert.match(nativeToolsSource, /isPrivateOrReservedIP/)
  // Verify exact IP classification logic against edge cases
  const { isIP } = await import('node:net')
  const classifyBlock = nativeToolsSource.match(/function isPrivateOrReservedIPv4[\s\S]*?^}/m)?.[0]
  assert.ok(classifyBlock, 'isPrivateOrReservedIPv4 must exist')
  const fn = new Function(
    'isIP',
    nativeToolsSource.slice(
      nativeToolsSource.indexOf('function isPrivateOrReservedIPv4'),
      nativeToolsSource.indexOf('async function assertSafePublicHttpsUrl')
    ).replace('export function isPrivateOrReservedIP', 'function isPrivateOrReservedIP')
      + '\nreturn isPrivateOrReservedIP;'
  )(isIP)
  for (const blocked of [
    '127.0.0.1', '127.0.0.2', '10.0.0.1', '100.64.0.1', '169.254.169.254',
    '172.16.0.1', '192.168.1.1', '0.0.0.0', '::1', '::', 'fc00::1', 'fd12::1',
    'fe80::1', '::ffff:127.0.0.1', '::ffff:169.254.169.254', '::ffff:7f00:1',
  ]) {
    assert.equal(fn(blocked), true, `Expected ${blocked} to be blocked`)
  }
  for (const allowed of ['1.1.1.1', '8.8.8.8', '93.184.216.34', '2606:4700:4700::1111']) {
    assert.equal(fn(allowed), false, `Expected ${allowed} to be allowed`)
  }
})

test('v3 security: recursive symlink jail, terminal_exec 3-tier policy, plugin binary/SSRF/audit hardening, and WKDownloadDelegate', () => {
  for (const rel of [
    'ios-host-package/sandbox-fs.mjs',
    'ios-host-package/ios-directory-picker-browse.mjs',
    'ios-host-package/approval.mjs',
    'ios-host-package/native-tools.mjs',
    'dsh-ios-entry.mjs',
  ]) {
    const src = readFileSync(join(runtimeDir, rel), 'utf8')
    assert.match(src, /suffix\.unshift\(basename\(current\)\)/, `${rel} must recursively canonicalize nonexistent symlink ancestors`)
  }
  const entry = readFileSync(join(runtimeDir, 'dsh-ios-entry.mjs'), 'utf8')
  assert.match(entry, /if \(active\.permissionMode !== 'autoReview' && isMutating\)/)
  assert.match(entry, /else if \(isMutating && ctx\.approval\?\.request\)/)
  const pm = readFileSync(join(runtimeDir, 'ios-plugin-manager.mjs'), 'utf8')
  assert.match(pm, /isBlockedPluginHost/)
  assert.match(pm, /\['\.node', '\.dylib', '\.so', '\.dll', '\.exe'\]/)
  assert.match(pm, /peerIssues/)
  assert.match(pm, /await realpath\(importRoot\)/)
  const webView = readFileSync(join(runtimeDir, '..', '..', 'ios', 'Sources', 'UI', 'DSHWebUIView.swift'), 'utf8')
  assert.match(webView, /WKDownloadDelegate/)
  assert.match(webView, /decidePolicyFor navigationResponse/)
  assert.doesNotMatch(webView, /scheme == "about" \|\| scheme == "blob" \|\| scheme == "data"/)
})

test('v3 redteam: future-proof heuristic classifier, subagent/Web policy inheritance, Prompt Cache memoization, stale fork self-heal, and parallel staging', () => {
  const entry = readFileSync(join(runtimeDir, 'dsh-ios-entry.mjs'), 'utf8')
  assert.match(entry, /function redteamToolFlags\(name\)/)
  assert.match(entry, /function resolveRedteamPolicyForAgent\(agent\)/)
  assert.match(entry, /if \(policyKey === lastToolsPolicyKey\)/)
  assert.match(entry, /if \(redteamToolsFork && registeredRedteamToolNames\(\)\.length === 0\)/)
  assert.match(entry, /mountDurationMs:\s*redteamMountDurationMs/)

  // Execute redteamToolFlags directly on new hypothetical dsh-purge-safe tools
  const fnBlock = entry.slice(
    entry.indexOf('const REDTEAM_READ_TOOL_NAMES'),
    entry.indexOf('function redteamToolDenial')
  )
  const redteamToolFlags = new Function(`${fnBlock}\nreturn redteamToolFlags;`)()
  assert.deepEqual(redteamToolFlags('redteam_cve_search'), { known: true, read: true, write: false, sensitive: false })
  assert.deepEqual(redteamToolFlags('redteam_note_add'), { known: true, read: false, write: true, sensitive: false })
  assert.deepEqual(redteamToolFlags('redteam_poc_delete'), { known: true, read: false, write: true, sensitive: true })
  assert.deepEqual(redteamToolFlags('redteam_credential_list'), { known: true, read: false, write: false, sensitive: true })
  assert.equal(redteamToolFlags('not_redteam_tool').known, false)

  const pm = readFileSync(join(runtimeDir, 'ios-plugin-manager.mjs'), 'utf8')
  assert.match(pm, /coreFilePath\)\.href\}\?rev=\$\{coreRev\}/)
  assert.match(pm, /await Promise\.all\(copyList\.map/)
  assert.match(pm, /if \(name === 'dsh-purge-safe'\)/)
})

test('v3 web-access: private-session-access exposes typert.local RPCs (directoryPicker/workspace) and workspace bindings while blocking admin APIs and private sessions', async () => {
  const mod = await import(join(runtimeDir, 'ios-host-package', 'private-session-access.mjs'))
  const listeners = new Map()
  let registeredPolicy = null
  let invalidateCount = 0
  const browserPeer = { principal: { kind: 'owner' } }
  const localDescriptors = [
    { namespace: 'directoryPicker', method: 'list' },
    { namespace: 'directoryPicker', method: 'createDirectory' },
    { namespace: 'workspace', method: 'follow' },
    { namespace: 'workspace', method: 'create' },
    { namespace: 'session', method: 'list' },
    { namespace: 'pluginManager', method: 'install' },
    { namespace: 'plugins', method: 'enable' },
    { namespace: 'schedule', method: 'create' },
  ]
  const workspaces = [{ id: 'ws-default', path: '/workspace' }]
  const mockCtx = {
    logger: { error() {}, warn() {} },
    connection: { browserPeer },
    remoteAccess: {
      registerPolicy(kind, policy) {
        assert.equal(kind, 'ios-web')
        registeredPolicy = policy
        return () => {}
      },
      invalidate() { invalidateCount += 1 },
    },
    typert: {
      local: { list: () => localDescriptors, subscribe: () => () => {} },
      remotes: { list: () => [], subscribe: () => () => {} },
    },
    get(name) {
      if (name === 'sessionPersistence') {
        return {
          async list() {
            return [
              { header: { id: 'ios:public-bot' } },
              { header: { id: 'ios:secret-bot' } },
            ]
          },
          async open() { return { async read() { return { events: [] } }, async close() {} } },
        }
      }
      if (name === 'workspaceRegistry') return { list: () => workspaces }
      return undefined
    },
    on(event, fn) {
      if (!listeners.has(event)) listeners.set(event, [])
      listeners.get(event).push(fn)
    },
    inject(_deps, fn) { fn(mockCtx) },
    effect() {},
  }

  const prevEnv = process.env.DS_BOT_IOS_PRIVATE_BOT_IDS
  process.env.DS_BOT_IOS_PRIVATE_BOT_IDS = JSON.stringify(['secret-bot'])
  try {
    await mod.default.apply(mockCtx)
  } finally {
    if (prevEnv === undefined) delete process.env.DS_BOT_IOS_PRIVATE_BOT_IDS
    else process.env.DS_BOT_IOS_PRIVATE_BOT_IDS = prevEnv
  }

  assert.equal(browserPeer.principal.kind, 'ios-web')
  assert.ok(registeredPolicy, 'ios-web policy must be registered')
  const bindings = registeredPolicy.bindings({ kind: 'ios-web' })

  const globalBinding = bindings.find((b) => b.resource.kind === 'global')
  assert.ok(globalBinding, 'global binding must exist')
  assert.ok(globalBinding.role.actions.includes('directoryPicker/list'))
  assert.ok(globalBinding.role.actions.includes('directoryPicker/createDirectory'))
  assert.ok(globalBinding.role.actions.includes('workspace/follow'))
  assert.ok(globalBinding.role.actions.includes('workspace/create'))
  assert.ok(!globalBinding.role.actions.includes('pluginManager/install'))
  assert.ok(!globalBinding.role.actions.includes('plugins/enable'))
  assert.ok(!globalBinding.role.actions.includes('schedule/create'))

  const wsBinding = bindings.find((b) => b.resource.kind === 'workspace' && b.resource.id === 'ws-default')
  assert.ok(wsBinding, 'workspace resource binding must be emitted for ws-default')
  assert.ok(wsBinding.role.actions.includes('workspace/follow'))

  assert.ok(bindings.some((b) => b.resource.kind === 'session' && b.resource.id === 'ios:public-bot'))
  assert.ok(!bindings.some((b) => b.resource.kind === 'session' && b.resource.id === 'ios:secret-bot'))

  const before = invalidateCount
  for (const fn of listeners.get('domain/changed') ?? []) fn({ domain: 'workspace' })
  assert.ok(invalidateCount > before, 'workspace domain change must invalidate WEB_PRINCIPAL')
})

test('v3 browser: registers all 12 browser_* tools, enforces private-bot & readOnly gates, and wires iOS WKWebView controller', async () => {
  const nativeToolsSrc = readFileSync(join(runtimeDir, 'ios-host-package/native-tools.mjs'), 'utf8')
  const entrySrc = readFileSync(join(runtimeDir, 'dsh-ios-entry.mjs'), 'utf8')
  const swiftControllerSrc = readFileSync(join(__dirname, '..', '..', 'ios/Sources/Bridge/AgentBrowserController.swift'), 'utf8')

  const expectedTools = [
    'browser_open', 'browser_snapshot', 'browser_click', 'browser_type',
    'browser_select', 'browser_press_key', 'browser_scroll', 'browser_screenshot',
    'browser_back', 'browser_wait', 'browser_eval', 'browser_handoff',
  ]
  for (const toolName of expectedTools) {
    assert.ok(nativeToolsSrc.includes(`name: '${toolName}'`), `native-tools.mjs must register ${toolName}`)
    assert.ok(entrySrc.includes(`'${toolName}'`), `dsh-ios-entry.mjs allowlist must include ${toolName}`)
  }
  assert.match(swiftControllerSrc, /WKUIDelegate/, 'AgentBrowserController must implement WKUIDelegate')
  assert.match(swiftControllerSrc, /WKDownloadDelegate/, 'AgentBrowserController must implement WKDownloadDelegate')
  assert.match(swiftControllerSrc, /isHumanControlling/, 'AgentBrowserController must support human takeover lock')
  assert.match(swiftControllerSrc, /__dsbotCollectRoots/, 'AgentBrowserController must pierce open Shadow DOM')
  assert.match(swiftControllerSrc, /acquireActionSlot/, 'AgentBrowserController must serialize concurrent browser actions')
  assert.match(swiftControllerSrc, /captchaDetected/, 'AgentBrowserController must detect verification gates for handoff')
})

test('v3 web-ui: DSHWebUIView provides immersive floating capsule, sidebar return bridge, theme sync, and visualViewport keyboard handling', async () => {
  const webUISrc = readFileSync(join(__dirname, '..', '..', 'ios/Sources/UI/DSHWebUIView.swift'), 'utf8')
  assert.match(webUISrc, /\.toolbar\(\.hidden,\s*for:\s*\.navigationBar\)/, 'DSHWebUIView must hide redundant native navigation bar')
  assert.match(webUISrc, /floatingCapsule/, 'DSHWebUIView must render floating top-right capsule')
  assert.match(webUISrc, /dsbotNative/, 'DSHWebUIView must wire dsbotNative WKScriptMessageHandler')
  assert.match(webUISrc, /dsbot-return-pill/, 'DSHWebUIView must inject sidebar return-to-DS-Bot pill')
  assert.match(webUISrc, /visualViewport/, 'DSHWebUIView must sync visualViewport height for iOS keyboard')
  assert.match(webUISrc, /themeChanged/, 'DSHWebUIView must sync Web UI theme color to native top bar')
})

test('v3 roadmap: canonical ipc-protocol, main-CI kernel-tests gate, multi-thread private isolation, real reasoningEffort & per-Bot disabledTools', async () => {
  const repoRoot = join(__dirname, '..', '..')
  const runtimeProtocol = readFileSync(join(runtimeDir, 'ipc-protocol.mjs'), 'utf8')
  const prepareScript = readFileSync(join(repoRoot, 'scripts/prepare-dsh-runtime.py'), 'utf8')
  const ciWorkflow = readFileSync(join(repoRoot, '.github/workflows/ios-ipa-build.yml'), 'utf8')
  const entrySrc = readFileSync(join(runtimeDir, 'dsh-ios-entry.mjs'), 'utf8')
  const privateAccessSrc = readFileSync(join(runtimeDir, 'ios-host-package/private-session-access.mjs'), 'utf8')

  assert.ok(!runtimeProtocol.includes('../src/ipc-protocol.mjs'), 'kernel/runtime/ipc-protocol.mjs must be canonical, not a re-export')
  assert.ok(prepareScript.includes('ROOT / "kernel" / "runtime" / "ipc-protocol.mjs"'), 'prepare-dsh-runtime.py must package kernel/runtime/ipc-protocol.mjs')
  assert.match(ciWorkflow, /kernel-tests:/, 'ios-ipa-build.yml must include kernel-tests job')
  assert.match(ciWorkflow, /needs:\s*\[kernel-tests,/, 'candidate job must depend on kernel-tests')
  assert.match(privateAccessSrc, /hasPrivateRootPrefix/, 'private-session-access.mjs must isolate multi-thread ios:<botId>:<threadId> children')
  assert.match(entrySrc, /reasoningEffort:\s*reasoningEnabled\s*\?\s*dshReasoningEffort\s*:\s*'off'/, 'dsh-ios-entry.mjs must map reasoningEffort to DSH-supported values (low/high/max/off)')
  assert.match(entrySrc, /normalizedDisabledTools/, 'dsh-ios-entry.mjs must enforce per-Bot disabledTools denylist')
})

test('v3 ui-refactor: SessionAddress, unifiedPendingInbox, idempotent approvals, private snapshot shield, and unifiedNavigationV2 flag', () => {
  const repoRoot = join(__dirname, '..', '..')
  const routingSrc = readFileSync(join(repoRoot, 'ios/Sources/Runtime/SessionAddressAndRouting.swift'), 'utf8')
  const hostSrc = readFileSync(join(repoRoot, 'ios/Sources/Runtime/LocalAgentHost.swift'), 'utf8')
  const chatSrc = readFileSync(join(repoRoot, 'ios/Sources/UI/ChatView.swift'), 'utf8')
  const inboxSrc = readFileSync(join(repoRoot, 'ios/Sources/UI/SessionInboxView.swift'), 'utf8')
  const settingsSrc = readFileSync(join(repoRoot, 'ios/Sources/UI/AgentSettingsView.swift'), 'utf8')

  assert.match(routingSrc, /public struct SessionAddress/, 'SessionAddress must be defined')
  assert.match(routingSrc, /public struct PendingInboxItem/, 'PendingInboxItem must be defined')
  assert.match(routingSrc, /public enum AppRoute/, 'AppRoute must be defined')
  assert.match(routingSrc, /public enum AppActionCatalog/, 'AppActionCatalog must be defined')
  assert.match(hostSrc, /public func resolveAddress\(/, 'LocalAgentHost must validate SessionAddress')
  assert.match(hostSrc, /public var unifiedPendingInbox:/, 'LocalAgentHost must expose unifiedPendingInbox')
  assert.match(hostSrc, /inFlightRequestIDs/, 'LocalAgentHost must guard against duplicate approval/question taps')
  assert.match(hostSrc, /unifiedNavigationV2/, 'LocalAgentHost must expose unifiedNavigationV2 feature flag')
  assert.match(chatSrc, /private var activeSessionId:/, 'ChatView must bind thread operations to activeSessionId')
  assert.match(chatSrc, /isPrivateSnapshotShielded/, 'ChatView must shield private conversations on background/inactive')
  assert.match(chatSrc, /showPrivateExportConfirm/, 'ChatView must confirm cross-space export for private sessions')
  assert.match(chatSrc, /BotThreadsSheet\(/, 'ChatView must wire BotThreadsSheet for multi-thread switching')
  assert.match(inboxSrc, /host\.unifiedPendingInbox/, 'SessionInboxView must consume unifiedPendingInbox')
  assert.match(settingsSrc, /\$host\.unifiedNavigationV2/, 'Settings must expose unifiedNavigationV2 rollback toggle')
})

test('v3 web-workspace: private-session-access collects typertGateway.collectSrcClaims(), excludes desktop launchers, and cordis.patch.yml activates cleanly with Settings & session-title', () => {
  const privateAccessSrc = readFileSync(join(runtimeDir, 'ios-host-package/private-session-access.mjs'), 'utf8')
  const entrySrc = readFileSync(join(runtimeDir, 'dsh-ios-entry.mjs'), 'utf8')
  const patchSrc = readFileSync(join(runtimeDir, 'ios-profile-package/cordis.patch.yml'), 'utf8')

  assert.match(privateAccessSrc, /collectSrcClaims\(/, 'private-session-access.mjs must collect live @Remote endpoints from typertGateway.collectSrcClaims()')
  assert.match(privateAccessSrc, /ctx\.on\('internal\/service'/, 'private-session-access.mjs must invalidate remoteAccess policy when Cordis services mount')
  assert.match(privateAccessSrc, /settings\\\/openSettingsDocument/, 'private-session-access.mjs must exclude desktop-only settings/openSettingsDocument')
  assert.match(privateAccessSrc, /session\\\/openWorkspacePath/, 'private-session-access.mjs must exclude desktop-only session/openWorkspacePath')
  assert.match(entrySrc, /wsRegistry\.list\(\)\.length === 0 && typeof wsRegistry\.create === 'function'/, 'dsh-ios-entry.mjs must fall back to wsRegistry.create(WORKSPACE_FILES) when initializeDefault no-ops')
  assert.match(patchSrc, /fallbackMaxWords:\s*\d+/, 'cordis.patch.yml must configure dsh-session-title required options')
  assert.doesNotMatch(patchSrc, /@deepseek-ai\/dsh-agent-tool-presentation/, 'cordis.patch.yml must not mount deprecated duplicate agent-tool-presentation')
  assert.match(patchSrc, /@deepseek-ai\/dsh-config-editor/, 'cordis.patch.yml must mount dsh-config-editor for Web UI Settings')
  assert.match(patchSrc, /@deepseek-ai\/dsh-settings/, 'cordis.patch.yml must mount dsh-settings for Web UI Settings')
  assert.match(entrySrc, /iosPureJsWorkspaceFileSearch/, 'dsh-ios-entry.mjs must patch workspaceFiles.search with pure-JS sandboxed search (no ripgrep subprocess on iOS)')
  const webUISrc = readFileSync(join(__dirname, '..', '..', 'ios/Sources/UI/DSHWebUIView.swift'), 'utf8')
  const hostSrc = readFileSync(join(__dirname, '..', '..', 'ios/Sources/Runtime/LocalAgentHost.swift'), 'utf8')
  assert.match(webUISrc, /window\.__DSH_FILE_UPLOAD__/, 'DSHWebUIView must hook __DSH_FILE_UPLOAD__ to main-thread fetch for iOS WKWebView uploads')
  assert.match(hostSrc, /supportedImportContentTypes/, 'LocalAgentHost must expose comprehensive supportedImportContentTypes for iOS fileImporter')
  assert.match(hostSrc, /cachedModelsKey/, 'LocalAgentHost must cache discovered models per endpoint URL')
  assert.match(hostSrc, /favoriteModelsKey/, 'LocalAgentHost must persist favorite pinned models')
  assert.match(hostSrc, /syncProviderModelCatalogToDSH/, 'LocalAgentHost must sync custom endpoint model catalog to DSH Web UI')
  assert.match(hostSrc, /applyModelToAllBots/, 'LocalAgentHost must support applying selected model to all Bots')
  assert.match(entrySrc, /ensureRedteamPresetRegistered/, 'dsh-ios-entry.mjs must register redteam preset on ctx.agentPresets so Web UI shows 红队模式')
  assert.match(entrySrc, /rpc\.handle\('models\.catalog\.sync'/, 'dsh-ios-entry.mjs must handle models.catalog.sync to expose custom endpoint models in Web UI')
  const engineSrc = readFileSync(join(__dirname, '..', '..', 'ios/Sources/Runtime/LocalAgentEngine.swift'), 'utf8')
  assert.match(engineSrc, /parseModelIdentifiers/, 'LocalAgentEngine must parse OpenAI/Anthropic/Ollama model list responses')
  assert.match(engineSrc, /v1\/models/, 'LocalAgentEngine must retry v1/models when baseURL omits /v1')
  const dsSrc = readFileSync(join(__dirname, '..', '..', 'ios/Sources/UI/DesignSystem.swift'), 'utf8')
  assert.match(dsSrc, /public struct ModelPickerSheet/, 'DesignSystem must provide searchable ModelPickerSheet with favorites and refresh')
})

test('v3 custom-endpoint: HTTP /v1 OpenAI-only fallback translates Anthropic /messages to /chat/completions with dual auth and SSE streaming', async () => {
  const http = await import('node:http')
  const { installCustomEndpointCompatFetch } = await import(join(runtimeDir, 'ios-openai-compat-adapter.mjs'))

  const seenPaths = []
  let seenAuth = ''
  const server = http.createServer((req, res) => {
    seenPaths.push(req.url)
    seenAuth = req.headers.authorization || ''
    if (req.url === '/v1/messages') {
      res.writeHead(404, { 'content-type': 'application/json' })
      res.end(JSON.stringify({ error: { message: 'Not Found' } }))
      return
    }
    if (req.url === '/v1/chat/completions') {
      let body = ''
      req.on('data', (chunk) => { body += chunk })
      req.on('end', () => {
        const parsed = JSON.parse(body)
        assert.equal(parsed.model, 'custom-gpt')
        assert.equal(parsed.messages[0].role, 'system')
        assert.equal(parsed.messages[1].role, 'user')
        res.writeHead(200, { 'content-type': 'text/event-stream; charset=utf-8' })
        res.write(`data: ${JSON.stringify({ model: 'custom-gpt', choices: [{ delta: { reasoning_content: 'think-1' } }] })}\n\n`)
        res.write(`data: ${JSON.stringify({ model: 'custom-gpt', choices: [{ delta: { content: 'hello-oai' } }] })}\n\n`)
        res.write(`data: ${JSON.stringify({ model: 'custom-gpt', choices: [{ delta: { tool_calls: [{ index: 0, id: 'call_1', function: { name: 'ping', arguments: '{"ok":true}' } }] }, finish_reason: 'tool_calls' }], usage: { prompt_tokens: 12, completion_tokens: 7 } })}\n\n`)
        res.write('data: [DONE]\n\n')
        res.end()
      })
      return
    }
    res.writeHead(404)
    res.end()
  })

  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve))
  const { port } = server.address()
  const base = `http://127.0.0.1:${port}/v1`
  const origFetch = globalThis.fetch
  const prevFlag = globalThis.__DSBOT_COMPAT_FETCH_INSTALLED__
  globalThis.__DSBOT_COMPAT_FETCH_INSTALLED__ = false

  try {
    installCustomEndpointCompatFetch({
      getProviderBaseURL: () => base,
      isOfficialBase: () => false,
    })

    const reqBody = JSON.stringify({
      model: 'custom-gpt',
      system: 'be concise',
      messages: [{ role: 'user', content: [{ type: 'text', text: 'hi' }] }],
      stream: true,
    })

    const r1 = await globalThis.fetch(`${base}/messages`, {
      method: 'POST',
      headers: { 'content-type': 'application/json', 'x-api-key': 'test-key-123' },
      body: reqBody,
    })
    assert.equal(r1.status, 200)
    const sse1 = await r1.text()
    assert.equal(seenAuth, 'Bearer test-key-123')
    assert.deepEqual(seenPaths, ['/v1/messages', '/v1/chat/completions'])
    assert.match(sse1, /event: message_start/)
    assert.match(sse1, /"type":"thinking_delta","thinking":"think-1"/)
    assert.match(sse1, /"type":"text_delta","text":"hello-oai"/)
    assert.match(sse1, /"type":"tool_use","id":"call_1","name":"ping"/)
    assert.match(sse1, /"stop_reason":"tool_use"/)
    assert.match(sse1, /event: message_stop/)

    // Second request must hit /v1/chat/completions directly without retrying /v1/messages
    seenPaths.length = 0
    const r2 = await globalThis.fetch(`${base}/messages`, {
      method: 'POST',
      headers: { 'content-type': 'application/json', 'x-api-key': 'test-key-123' },
      body: reqBody,
    })
    assert.equal(r2.status, 200)
    await r2.text()
    assert.deepEqual(seenPaths, ['/v1/chat/completions'])
  } finally {
    globalThis.fetch = origFetch
    globalThis.__DSBOT_COMPAT_FETCH_INSTALLED__ = prevFlag
    await new Promise((resolve) => server.close(resolve))
  }
})

test('v3 custom-endpoint: ensureAnthropicStreamComplete synthesizes missing content_block_stop, message_delta, and message_stop', async () => {
  const { ensureAnthropicStreamComplete } = await import(join(runtimeDir, 'ios-openai-compat-adapter.mjs'))
  const truncated = [
    'event: message_start\ndata: {"type":"message_start","message":{"id":"m1","role":"assistant","content":[]}}\n\n',
    'event: content_block_start\ndata: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}\n\n',
    'event: content_block_delta\ndata: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"hi"}}\n\n',
  ].join('')
  const rawResp = new Response(truncated, {
    status: 200,
    headers: { 'content-type': 'text/event-stream; charset=utf-8' },
  })
  const repaired = ensureAnthropicStreamComplete(rawResp)
  const text = await repaired.text()
  assert.match(text, /"type":"text_delta","text":"hi"/)
  assert.match(text, /"type":"content_block_stop","index":0/)
  assert.match(text, /"type":"message_delta"/)
  assert.match(text, /"type":"message_stop"/)
})

test('v3 full-audit (v2.4.0): multi-thread session keys, writable configEditor sandbox override, per-Bot endpoint binding, and multimodal image blocks', () => {
  const repoRoot = join(__dirname, '..', '..')
  const entrySrc = readFileSync(join(runtimeDir, 'dsh-ios-entry.mjs'), 'utf8')
  const hostSrc = readFileSync(join(repoRoot, 'ios/Sources/Runtime/LocalAgentHost.swift'), 'utf8')
  const modelsSrc = readFileSync(join(repoRoot, 'ios/Sources/Runtime/AgentModels.swift'), 'utf8')
  const patchSrc = readFileSync(join(runtimeDir, 'ios-profile-package/cordis.patch.yml'), 'utf8')

  assert.match(entrySrc, /function isValidSessionKey\(value\)/, 'dsh-ios-entry.mjs must support botId:threadId multi-thread session keys')
  assert.match(entrySrc, /function isPrivateBotOrThread\(sessionKey\)/, 'dsh-ios-entry.mjs must enforce root-bot privacy on child threads')
  assert.match(entrySrc, /function inferCustomModelCapabilities\(id\)/, 'dsh-ios-entry.mjs must infer custom model vision/maxTokens capabilities')
  assert.match(entrySrc, /web-config-overrides\.json/, 'dsh-ios-entry.mjs must redirect Web UI configEditor edits to writable sandbox JSON')
  assert.match(entrySrc, /params\.imagePaths/, 'dsh-ios-entry.mjs must attach native multimodal image blocks in startTurn')
  assert.match(patchSrc, /id:\s*agent-preset-redteam/, 'cordis.patch.yml must declare agent-preset-redteam')
  assert.match(modelsSrc, /public var providerProfileId: String\?/, 'BotProfile must support optional per-Bot providerProfileId')
  assert.match(hostSrc, /public func effectiveApiBaseURL\(for bot: BotProfile\?\)/, 'LocalAgentHost must resolve per-Bot endpoint URL')
})

test('v3 master-refactor (v2.5.0): 3-Tab unified IA, zero .fileImporter, chats.json safety, AuthKind.none, web.sessions.list, non-busy-wait SQLite, and multi-session concurrency', () => {
  const repoRoot = join(__dirname, '..', '..')
  const standaloneSrc = readFileSync(join(repoRoot, 'ios/Sources/UI/StandaloneViews.swift'), 'utf8')
  const unifiedSrc = readFileSync(join(repoRoot, 'ios/Sources/UI/UnifiedConversationsTabView.swift'), 'utf8')
  const settingsSrc = readFileSync(join(repoRoot, 'ios/Sources/UI/AgentSettingsView.swift'), 'utf8')
  const connectorSrc = readFileSync(join(repoRoot, 'ios/Sources/UI/ConnectorMarketplaceView.swift'), 'utf8')
  const hostSrc = readFileSync(join(repoRoot, 'ios/Sources/Runtime/LocalAgentHost.swift'), 'utf8')
  const entrySrc = readFileSync(join(runtimeDir, 'dsh-ios-entry.mjs'), 'utf8')
  const sqliteSrc = readFileSync(join(runtimeDir, 'sqlite-session-persistence.mjs'), 'utf8')

  // 1. 3-Tab IA + GlobalBotPulseBar child-thread resolution + AgentBrowserSheet hero entry
  assert.match(standaloneSrc, /case conversations/, 'MainTabView must use 3-Tab conversations case')
  assert.doesNotMatch(standaloneSrc, /case agents\b/, 'MainTabView must not have redundant agents tab')
  assert.match(standaloneSrc, /host\.resolveAddress\(sid\)/, 'GlobalBotPulseBar must resolve child-thread addresses')
  assert.match(standaloneSrc, /AgentBrowserSheet\(workspace: host\.workspace\)/, 'ToolsHubTabView must provide direct AgentBrowserSheet entry')
  assert.match(unifiedSrc, /public struct UnifiedConversationsTabView/, 'UnifiedConversationsTabView must exist')
  assert.match(unifiedSrc, /case webSessions = "Web"/, 'UnifiedConversationsTabView must surface standalone Web sessions')

  // 2. Settings deduplication + Editable ProviderProfile
  assert.match(settingsSrc, /private struct EditProviderProfileSheet/, 'ModelServiceSettingsView must allow editing ProviderProfiles')
  assert.match(settingsSrc, /BackendDevToolsInspectorView\(host: host\)/, 'RuntimeDiagnosticsAndBackupView must host BackendDevToolsInspectorView')
  assert.doesNotMatch(settingsSrc, /ExperimentalFeaturesView\(host: host\)/, 'SettingsAndExploreTabView must not link to retired ExperimentalFeaturesView')

  // 3. Critical data safety & compiler warning fixes
  assert.match(connectorSrc, /ConnectorCatalogItem\.AuthKind\.none/, 'ConnectorMarketplaceView must qualify AuthKind.none')
  assert.match(
    hostSrc,
    /legacyMessagesBySession = messagesBySession[\s\S]{0,120}restoreInterruptedStreamingDraftIfNeeded\(\)/,
    'loadPersistedWorkspace must initialize legacyMessagesBySession before restoring interrupted draft'
  )
  assert.match(hostSrc, /private func persistWorkspace\(immediate: Bool = false\)/, 'persistWorkspace must support debounced and immediate flushes')
  assert.match(hostSrc, /private var activeTurnsBySession: \[String: ActiveTurnContext\]/, 'LocalAgentHost must support concurrent multi-session turns')
  assert.match(hostSrc, /public func orderedAvailableModels\(for endpointURL: String\? = nil\)/, 'LocalAgentHost must expose per-endpoint orderedAvailableModels')

  // 4. Kernel web.sessions.list & non-busy-wait SQLite drainLive
  assert.match(entrySrc, /rpc\.handle\('web\.sessions\.list'/, 'dsh-ios-entry.mjs must expose web.sessions.list')
  assert.doesNotMatch(sqliteSrc, /while \(this\.draining\) await new Promise/, 'sqlite-session-persistence.mjs must not busy-wait spin with setTimeout(0)')
  assert.match(sqliteSrc, /this\.drainPromise/, 'sqlite-session-persistence.mjs must use single-flight drainPromise')

  // 5. Zero remaining SwiftUI .fileImporter( across ios/Sources/UI/
  const uiDir = join(repoRoot, 'ios/Sources/UI')
  for (const name of readdirSync(uiDir)) {
    if (!name.endsWith('.swift')) continue
    const content = readFileSync(join(uiDir, name), 'utf8')
    assert.doesNotMatch(content, /\.fileImporter\s*\(/, `${name} must use NativeDocumentPicker instead of .fileImporter`)
  }
})

test('v3 sandbox: every dsh-agent-instructions preset in cordis.patch.yml pins projectRootMarkers to .dsbot-ios-workspace-root', () => {
  const patchSrc = readFileSync(join(runtimeDir, 'ios-profile-package/cordis.patch.yml'), 'utf8')
  const blocks = patchSrc.split(/- id: agent-instructions\b/).slice(1)
  assert.ok(blocks.length >= 5, `expected at least 5 agent-instructions preset blocks, got ${blocks.length}`)
  for (let i = 0; i < blocks.length; i++) {
    const nextEntryIdx = blocks[i].indexOf('\n          - id:')
    const block = nextEntryIdx >= 0 ? blocks[i].slice(0, nextEntryIdx) : blocks[i]
    assert.match(
      block,
      /projectRootMarkers:\s*\n\s*-\s*\.dsbot-ios-workspace-root\b/,
      `agent-instructions block #${i + 1} in cordis.patch.yml must declare projectRootMarkers: [.dsbot-ios-workspace-root] to prevent walking above $DSH_HOME/files`
    )
  }
})

test('v3 web-workbench: sandboxPolicy root, onboarding bypass, public-session waterfall bridge, exact Fetch routes, canonical WORKSPACE_FILES, skills/ unification, and deep-link auth fix', () => {
  const repoRoot = join(__dirname, '..', '..')
  const patchSrc = readFileSync(join(runtimeDir, 'ios-profile-package/cordis.patch.yml'), 'utf8')
  const entrySrc = readFileSync(join(runtimeDir, 'dsh-ios-entry.mjs'), 'utf8')
  const privateAccessSrc = readFileSync(join(runtimeDir, 'ios-host-package/private-session-access.mjs'), 'utf8')
  const webUISrc = readFileSync(join(repoRoot, 'ios/Sources/UI/DSHWebUIView.swift'), 'utf8')
  const skillsViewSrc = readFileSync(join(repoRoot, 'ios/Sources/UI/WorkspaceFilesAndSkillsView.swift'), 'utf8')
  const chatSkillsSrc = readFileSync(join(repoRoot, 'ios/Sources/UI/ChatSessionTrajectoryAndPlugins.swift'), 'utf8')

  // 1. cordis.patch.yml workspace & Web UI defaults
  assert.match(patchSrc, /id:\s*sandbox-policy[\s\S]{0,160}workspaceRoot:\s*!!js process\.env\.DSH_HOME \+ '\/files'/, 'sandbox-policy must pin workspaceRoot to $DSH_HOME/files')
  assert.match(patchSrc, /id:\s*ui-settings-general[\s\S]{0,120}welcomeNoticeVersion:\s*'2026-09-28\.1'/, 'ui-settings-general must pre-acknowledge welcomeNoticeVersion for embedded iOS Web UI')
  assert.match(patchSrc, /id:\s*ui-settings-models[\s\S]{0,120}credentialOnboarding:\s*false/, 'ui-settings-models must disable browser credential onboarding modal on iOS')
  const redteamBlock = patchSrc.split(/- id: agent-preset-redteam\b/)[1]?.split(/\n    - id: typert\b/)[0] ?? ''
  assert.match(redteamBlock, /@deepseek-ai\/dsh-skill-filesystem/, 'agent-preset-redteam must mount dsh-skill-filesystem')
  assert.match(redteamBlock, /@deepseek-ai\/dsh-tool-skill/, 'agent-preset-redteam must mount dsh-tool-skill')
  assert.match(redteamBlock, /@deepseek-ai\/dsh-plan-mode/, 'agent-preset-redteam must mount dsh-plan-mode')
  assert.match(redteamBlock, /@deepseek-ai\/dsh-tool-jobs/, 'agent-preset-redteam must mount dsh-tool-jobs')

  // 2. private-session-access.mjs exact Fetch routes & waterfall bridge for Web approvals/questions
  assert.match(privateAccessSrc, /'\/api\/changes\.summary'/, 'private-session-access.mjs must allow /api/changes.summary for public sessions')
  assert.match(privateAccessSrc, /'\/api\/changes\.diff'/, 'private-session-access.mjs must allow /api/changes.diff for public sessions')
  assert.match(privateAccessSrc, /'\/api\/file'/, 'private-session-access.mjs must allow /api/file (jailed by IosSandboxedFileSystem)')
  assert.match(privateAccessSrc, /'\/api\/present\.host'/, 'private-session-access.mjs must allow /api/present.host')
  assert.match(privateAccessSrc, /installGatewayWaterfallBridge/, 'private-session-access.mjs must bridge public-session waterfall events for Web UI approvals & questions')
  assert.match(privateAccessSrc, /isPublicWaterfallAgentId/, 'waterfall bridge must refuse private sessions')

  // 3. dsh-ios-entry.mjs canonical WORKSPACE_FILES, DSH_AGENTS_HOME, defaultCwd, initializeDefault, and skills sync
  assert.match(entrySrc, /WORKSPACE_FILES = realpathSync\(WORKSPACE_FILES\)/, 'dsh-ios-entry.mjs must canonicalize WORKSPACE_FILES for /var -> /private/var alignment')
  assert.match(entrySrc, /process\.env\.DSH_AGENTS_HOME = WORKSPACE_FILES/, 'dsh-ios-entry.mjs must anchor DSH_AGENTS_HOME inside WORKSPACE_FILES')
  assert.match(entrySrc, /sessionController\.commands\.defaultCwd = WORKSPACE_FILES/, 'dsh-ios-entry.mjs must anchor unscoped Web sessions to WORKSPACE_FILES')
  assert.match(entrySrc, /wsController\.initializeDefault = async function iosInitializeDefaultWorkspace/, 'dsh-ios-entry.mjs must pin workspaceController.initializeDefault to WORKSPACE_FILES')
  assert.match(entrySrc, /syncLegacySkillsToWorkspaceFiles/, 'dsh-ios-entry.mjs must migrate legacy skills into files/skills')

  // 4. DSHWebUIView.swift deep-link auth fix (no /session/<id>?token=... 401)
  assert.doesNotMatch(webUISrc, /comps\.path\s*=\s*"\/session\//, 'DSHWebUIView must never rewrite /?token=... path to /session/<id> (causes HTTP 401)')
  assert.match(webUISrc, /dsh\.sessions\.current/, 'DSHWebUIView must seed dsh.sessions.current in localStorage for initialSessionId deep-linking')

  // 5. Swift Skills views anchored in files/skills
  assert.match(skillsViewSrc, /\.appendingPathComponent\("files", isDirectory: true\)\s*\.appendingPathComponent\("skills", isDirectory: true\)/, 'SkillsManagerView must store skills in files/skills')
  assert.match(chatSkillsSrc, /\.appendingPathComponent\("files", isDirectory: true\)\s*\.appendingPathComponent\("skills", isDirectory: true\)/, 'UserSkillsSheetView must store skills in files/skills')
})


test('v3 governance: phase 3/4 hardening (abortable python, bounded gunzip, cached statements, quote-aware terminal, light git status)', () => {
  const py = readFileSync(join(runtimeDir, 'ios-host-package', 'python-execution.mjs'), 'utf8')
  assert.match(py, /signal\?\.addEventListener\?\.\('abort'/)
  const pm = readFileSync(join(runtimeDir, 'ios-plugin-manager.mjs'), 'utf8')
  assert.match(pm, /createGunzip/)
  assert.doesNotMatch(pm, /gunzipSync/)
  assert.match(pm, /child_process\|worker_threads\|cluster\|inspector\|vm/)
  const sqlite = readFileSync(join(runtimeDir, 'sqlite-session-persistence.mjs'), 'utf8')
  assert.match(sqlite, /stmt\(sql\)/)
  assert.doesNotMatch(sqlite, /owner\.db\.prepare\(/)
  const entry = readFileSync(join(runtimeDir, 'dsh-ios-entry.mjs'), 'utf8')
  assert.match(entry, /splitTerminalSegments/)
  const terminalPolicy = readFileSync(join(runtimeDir, 'ios-host-package', 'virtual-terminal-policy.mjs'), 'utf8')
  assert.match(terminalPolicy, /function splitTerminalSegments/)
  assert.match(entry, /Avoid reading every file into memory/)
})

test('v3 governance: plugin upgrade keeps backup until boot settles; local dirs resolve pure-JS deps', () => {
  const pm = readFileSync(join(runtimeDir, 'ios-plugin-manager.mjs'), 'utf8')
  assert.match(pm, /backup: \{ path: backup, target \}/)
  assert.match(pm, /revision\.backup/)
  assert.match(pm, /localStaging/)
})

test('v3 governance: phase 3/4 full closure (SQLite attachment index, GitHub catalog, Cordis config ID, Web usage, Swift perf/pricing/outline)', () => {
  const sqlite = readFileSync(join(runtimeDir, 'sqlite-session-persistence.mjs'), 'utf8')
  assert.match(sqlite, /CREATE TABLE IF NOT EXISTS session_attachments/)
  assert.match(sqlite, /listAttachmentIds\(\)/)
  assert.match(sqlite, /backfillSessionAttachments\(\)/)

  const priv = readFileSync(join(runtimeDir, 'ios-host-package', 'private-session-access.mjs'), 'utf8')
  assert.match(priv, /persistence\.listAttachmentIds/)

  const pm = readFileSync(join(runtimeDir, 'ios-plugin-manager.mjs'), 'utf8')
  assert.match(pm, /resolvePluginCordisEntryId/)
  assert.match(pm, /sourceType === 'npm' \|\| sourceType === 'github'/)

  const entry = readFileSync(join(runtimeDir, 'dsh-ios-entry.mjs'), 'utf8')
  assert.match(entry, /uncachedInputTokens/)
  assert.match(entry, /web-workbench/)

  const repoRoot = join(__dirname, '..', '..')
  const transport = readFileSync(join(repoRoot, 'ios/Sources/Runtime/NodeRuntimeTransport.swift'), 'utf8')
  assert.match(transport, /--max-old-space-size=128/)
  const ipc = readFileSync(join(repoRoot, 'ios/Sources/Runtime/IPCChannel.swift'), 'utf8')
  assert.match(ipc, /private var readOffset = 0/)
  const cost = readFileSync(join(repoRoot, 'ios/Sources/Runtime/CostAndBudgetGovernor.swift'), 'utf8')
  assert.match(cost, /deepseek-v4-pro/)
  assert.match(cost, /estimateTotalCost/)
  const features = readFileSync(join(repoRoot, 'ios/Sources/UI/DSBotFeaturesViews.swift'), 'utf8')
  assert.match(features, /var fenceChar: Character\? = nil/)
})

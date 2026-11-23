import test from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
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
  assert.match(entrySrc, /reasoningEffort:\s*reasoningEnabled\s*\?\s*requestedEffort\s*:\s*'off'/, 'dsh-ios-entry.mjs must pass real reasoningEffort to DSH agentOptions')
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

test('v3 web-workspace: private-session-access collects typertGateway.collectSrcClaims() and dsh-ios-entry registers default files/ workspace even with existing sessions', () => {
  const privateAccessSrc = readFileSync(join(runtimeDir, 'ios-host-package/private-session-access.mjs'), 'utf8')
  const entrySrc = readFileSync(join(runtimeDir, 'dsh-ios-entry.mjs'), 'utf8')

  assert.match(privateAccessSrc, /collectSrcClaims\(/, 'private-session-access.mjs must collect live @Remote endpoints from typertGateway.collectSrcClaims()')
  assert.match(privateAccessSrc, /ctx\.on\('internal\/service'/, 'private-session-access.mjs must invalidate remoteAccess policy when Cordis services mount')
  assert.match(entrySrc, /wsRegistry\.list\(\)\.length === 0 && typeof wsRegistry\.create === 'function'/, 'dsh-ios-entry.mjs must fall back to wsRegistry.create(WORKSPACE_FILES) when initializeDefault no-ops')
})


import test from 'node:test'
import assert from 'node:assert/strict'
import { existsSync, mkdtempSync, readFileSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import {
  isMutatingVirtualTerminalCommand,
  parseEchoRedirection,
  splitTerminalSegments,
} from '../runtime/ios-host-package/virtual-terminal-policy.mjs'
import { configureIOSHost } from '../runtime/ios-host-package/index.mjs'
import { IOSGuestPTYSubprocess } from '../runtime/ios-host-package/ios-subprocess.mjs'

const repoRoot = join(dirname(fileURLToPath(import.meta.url)), '../..')
const runtimeFile = (name) => readFileSync(join(repoRoot, 'kernel/runtime', name), 'utf8')
const HAS_RUNTIME_SESSION_MODULES = existsSync(join(repoRoot, 'kernel/runtime/node_modules/@deepseek-ai/dsh-session-persistence/lib/index.js'))

test('virtual terminal write policy recognizes supported writes and leaves isolated evaluators read-only', () => {
  for (const command of ['mkdir notes', 'touch notes/a.txt', 'cp a b', 'mv a b', 'rm a', 'export FLAG=1', 'git commit -m done', 'git snapshot save']) {
    assert.equal(isMutatingVirtualTerminalCommand(command), true, command)
  }
  for (const command of ['pwd', 'ls', 'cat notes/a.txt', 'node -e "1 + 1"', 'python -c "print(1)"', 'echo "rm -rf /"', 'echo ">" hello']) {
    assert.equal(isMutatingVirtualTerminalCommand(command), false, command)
  }
  assert.equal(isMutatingVirtualTerminalCommand('echo hello > notes/a.txt'), true)
  assert.equal(isMutatingVirtualTerminalCommand('echo hello >> notes/a.txt'), true)
  assert.equal(isMutatingVirtualTerminalCommand('echo hello; rm notes/a.txt'), true)
})

test('virtual terminal parser preserves quoted separators and parses only unquoted echo redirection', () => {
  assert.deepEqual(splitTerminalSegments('echo "a;b && c"; pwd && ls'), ['echo "a;b && c"', 'pwd', 'ls'])
  assert.equal(parseEchoRedirection('echo ">" hello'), undefined)
  assert.deepEqual(parseEchoRedirection('echo "hello world" > "notes file.txt"'), {
    content: 'hello world', path: 'notes file.txt', append: false,
  })
  assert.deepEqual(parseEchoRedirection('echo more >> notes.txt'), {
    content: 'more', path: 'notes.txt', append: true,
  })
  assert.throws(() => parseEchoRedirection('echo x > a b'), /需要一个目标文件名/)
})

test('runtime hardening fails closed without native QuickJS and blocks unsupported Node tests', () => {
  const entry = runtimeFile('dsh-ios-entry.mjs')
  const nativeTools = runtimeFile('ios-host-package/native-tools.mjs')
  const nodeCaseStart = entry.indexOf("case 'node':")
  const pythonCaseStart = entry.indexOf("case 'python':", nodeCaseStart)
  const virtualJavaScript = entry.slice(nodeCaseStart, pythonCaseStart)
  assert.match(entry, /node --test is disabled/)
  assert.match(entry, /Native QuickJS bridge is unavailable; JavaScript execution failed closed/)
  assert.match(nativeTools, /Native QuickJS bridge is unavailable; JavaScript execution failed closed/)
  assert.doesNotMatch(nativeTools, /node:vm|vm\.createContext|vm\.runInContext/)
  assert.doesNotMatch(virtualJavaScript, /vm\.createContext|sandboxCtx\.__emit/)
})

test('iOS runtime staging includes the imported virtual terminal policy module', () => {
  const staging = readFileSync(join(repoRoot, 'scripts/prepare-dsh-runtime.py'), 'utf8')
  assert.match(staging, /"ios-host-package\/virtual-terminal-policy\.mjs": SOURCE \/ "ios-host-package" \/ "virtual-terminal-policy\.mjs"/)
})

test('iOS Web PTYs use the ARM64 guest bridge and do not expose host subprocesses', () => {
  const provider = runtimeFile('ios-host-package/ios-subprocess.mjs')
  const profile = runtimeFile('ios-profile-package/cordis.patch.yml')
  const host = readFileSync(join(repoRoot, 'ios/Sources/Runtime/LocalAgentHost.swift'), 'utf8')
  assert.match(provider, /extends SubprocessRuntime/)
  assert.match(provider, /native\.web_terminal\.open/)
  assert.match(provider, /native\.web_terminal\.write/)
  assert.doesNotMatch(provider, /node:child_process|spawnSync|execSync/)
  assert.match(profile, /name: '@dsbot\/dsh-ios-host\/ios-subprocess'/)
  assert.match(host, /ARM64GuestPTYWebTerminal\.shared\.open/)
  assert.match(host, /native\.web_terminal\.close/)
  assert.match(host, /authorizedWebTerminalSessionID/)
  assert.match(host, /native\.web_terminal\.cancel_open/)
  assert.match(readFileSync(join(repoRoot, 'kernel/runtime/dsh-ios-entry.mjs'), 'utf8'), /'ios-subprocess'/)
  assert.match(runtimeFile('dsh-ios-entry.mjs'), /web_terminal\.resolve_owner/)
  assert.match(host, /web_terminal\.resolve_owner/)
})

test('iOS subprocess provider restricts execution to a guest shell and forwards PTY controls', async () => {
  const provider = Object.create(IOSGuestPTYSubprocess.prototype)
  assert.equal(await provider.resolveExecutable('/bin/sh'), '/bin/sh')
  assert.equal(await provider.resolveExecutable('ash'), '/bin/ash')
  assert.deepEqual(await provider.terminalEnvironment(), { platform: 'posix', defaultShell: '/bin/sh' })
  assert.throws(() => provider.spawn({}), (error) => error.code === 'SUBPROCESS_PTY_UNAVAILABLE')
  await assert.rejects(
    provider.spawnTerminal({ argv: ['/bin/bash'], rows: 24, cols: 80, env: { DSH_SESSION_ID: 'session-abc' } }),
    (error) => error.code === 'SUBPROCESS_PTY_UNAVAILABLE',
  )

  const requestLog = []
  let releaseRead
  const sessionId = '4c8982f4-975f-4a52-88dd-24b8895f67af'
  configureIOSHost({
    workspace: '/tmp/dsbot-provider-contract',
    runtime: {},
    rpc: {
      async request(method, params) {
        requestLog.push({ method, params })
        if (method === 'native.web_terminal.open') return { sessionId }
        if (method === 'native.web_terminal.read') return new Promise((resolve) => { releaseRead = resolve })
        return { accepted: true }
      },
    },
  })
  const terminal = await provider.spawnTerminal({
    argv: ['/bin/sh', '-i'], rows: 24, cols: 80,
    env: { DSH_SESSION_ID: 'session-public-1' },
  })
  await terminal.signalForeground('SIGINT')
  await terminal.signalForeground('SIGTSTP')
  await terminal.signalForeground('SIGHUP')
  assert.deepEqual(requestLog.filter(({ method }) => method === 'native.web_terminal.write').map(({ params }) => params.text), ['\u0003', '\u001a'])
  assert.equal(requestLog.filter(({ method }) => method === 'native.web_terminal.close').length, 1)
  assert.equal((await terminal.done).signal, 'SIGHUP')
  releaseRead?.({ output: '', done: true, exitCode: 0 })
})

test('session listing uses indexed scopes, bounded pagination, and excludes private web roots', () => {
  const persistence = runtimeFile('sqlite-session-persistence.mjs')
  const entry = runtimeFile('dsh-ios-entry.mjs')
  assert.match(persistence, /session_activity_order_idx ON sessions\(COALESCE\(last_activity_at, created_at\) DESC, id ASC\)/)
  assert.match(persistence, /scope === 'web-root'/)
  assert.match(persistence, /excludeRootIds/)
  assert.match(persistence, /options\.before !== undefined/)
  assert.match(persistence, /LIMIT \?/)
  assert.match(entry, /scope: 'web-root',[\s\S]*?limit: 80,[\s\S]*?excludeRootIds: \[\.\.\.runtime\.privateBotIds\]/)
})

test('SQLite session listing filters private roots and uses stable activity pagination', async (t) => {
  if (!HAS_RUNTIME_SESSION_MODULES) {
    t.skip('kernel/runtime/node_modules not installed in lightweight kernel-tests job')
    return
  }
  const dir = mkdtempSync(join(tmpdir(), 'dsbot-session-list-'))
  const databasePath = join(dir, 'sessions.sqlite')
  process.argv.push(`--database=${databasePath}`)
  let persistence
  try {
    const { SQLiteSessionPersistence } = await import('../runtime/sqlite-session-persistence.mjs')
    persistence = Object.create(SQLiteSessionPersistence.prototype)
    persistence._db = null
    persistence._stmts = new Map()
    persistence._stmtDb = null
    persistence.openDatabase({ runMigrations: true })
    const insert = persistence.db.prepare(`INSERT INTO sessions
      (id, header_json, inherited_event_count, next_seq, revision, created_at, last_activity_at, last_message_preview)
      VALUES (?, ?, 0, ?, 0, ?, ?, '')`)
    const rows = [
      { id: 'web-a', seq: 1, created: 10, activity: 500 },
      { id: 'web-c', seq: 1, created: 11, activity: 500 },
      { id: 'web-b', seq: 1, created: 12, activity: 700 },
      { id: 'secret', seq: 1, created: 13, activity: 900 },
      { id: 'secret:child', seq: 1, created: 14, activity: 850 },
      { id: 'ios:standard', seq: 1, created: 15, activity: 950 },
      { id: 'web-subagent', seq: 1, created: 16, activity: 800, origin: 'subagent' },
      { id: 'web-child', seq: 1, created: 17, activity: 750, parentSession: 'web-root' },
      { id: 'web-empty', seq: 0, created: 18, activity: null },
    ]
    for (const row of rows) {
      const header = { id: row.id, createdAt: row.created, parentSession: row.parentSession, origin: row.origin }
      insert.run(row.id, JSON.stringify(header), row.seq, row.created, row.activity)
    }

    const visible = await persistence.list({ scope: 'web-root', orderBy: 'activity', limit: 10, excludeRootIds: ['secret'] })
    assert.deepEqual(visible.map((row) => row.header.id), ['web-b', 'web-a', 'web-c'])
    const nextPage = await persistence.list({
      scope: 'web-root', orderBy: 'activity', limit: 10, excludeRootIds: ['secret'],
      before: { activityAt: 500, id: 'web-a' },
    })
    assert.deepEqual(nextPage.map((row) => row.header.id), ['web-c'])
    const ios = await persistence.list({ scope: 'ios', orderBy: 'activity' })
    assert.deepEqual(ios.map((row) => row.header.id), ['ios:standard'])
    const plan = persistence.db.prepare(`EXPLAIN QUERY PLAN SELECT id FROM sessions
      ORDER BY COALESCE(last_activity_at, created_at) DESC, id ASC LIMIT 2`).all()
    assert.ok(plan.some((row) => String(row.detail).includes('session_activity_order_idx')), JSON.stringify(plan))
  } finally {
    persistence?.closeDatabaseHandle()
    rmSync(dir, { recursive: true, force: true })
  }
})

test('plugin config writes are bounded, atomic, private, and recoverable', () => {
  const manager = runtimeFile('ios-plugin-manager.mjs')
  assert.match(manager, /Buffer\.byteLength\(serialized, 'utf8'\)/)
  assert.match(manager, /await rename\(temp, pluginConfigPath\)/)
  assert.match(manager, /mode: 0o600, flush: true/)
  assert.match(manager, /configBackup: \{ path: backupPath, target: pluginConfigPath, existed: Boolean\(previousConfig\) \}/)
  assert.match(manager, /if \(configBackup\.existed === true\)[\s\S]*?await rename\(backupPath, targetPath\)/)
  assert.match(manager, /Object\.hasOwn\(configs, pkgName\)/)
})

test('supervisor clears crash-loop count only after a stable ready period', () => {
  const supervisor = runtimeFile('ios-supervisor.mjs')
  assert.match(supervisor, /const stableReadyWindowMs = 60_000/)
  assert.match(supervisor, /setTimeout\(\(\) => \{\s*if \(thread === worker && ready\) unexpectedCrashCount = 0/)
  assert.match(supervisor, /clearTimeout\(stableReadyTimer\)/)
})

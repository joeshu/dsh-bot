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

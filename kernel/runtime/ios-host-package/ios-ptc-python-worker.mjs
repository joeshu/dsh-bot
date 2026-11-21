import { parentPort, workerData } from 'node:worker_threads'
import { join } from 'node:path'
import { pathToFileURL } from 'node:url'

const MAX_OUTPUT_CHARACTERS = 32_000
const MAX_WASM_MEMORY_PAGES = 4_096
const pending = new Map()
let nextBindingId = 0
let outputLength = 0
let outputTruncated = false

function appendOutput(value) {
  const text = String(value ?? '')
  const remaining = MAX_OUTPUT_CHARACTERS - outputLength
  const emitted = text.slice(0, Math.max(0, remaining))
  outputLength += emitted.length
  if (text.length > remaining) outputTruncated = true
  if (emitted) parentPort.postMessage({ type: 'stdout', text: emitted })
}

const callHost = (global, name, argsJSON) => {
  if (!parentPort || !workerData.bindings.some((binding) => binding.global === global && binding.names.includes(name))) {
    return safeThenable(Promise.reject(`Tool binding ${global}.${name} is not available.`))
  }
  if (typeof argsJSON !== 'string' || argsJSON.length > 262_144) {
    return safeThenable(Promise.reject('Tool arguments must be JSON under the 256 KiB limit.'))
  }
  const id = ++nextBindingId
  const pendingCall = new Promise((resolve, reject) => {
    pending.set(id, { resolve, reject })
    try { parentPort.postMessage({ type: 'binding.call', id, global, name, argsJSON }) } catch (error) {
      pending.delete(id)
      reject(error instanceof Error ? error.message : String(error))
    }
  })
  return safeThenable(pendingCall)
}

function safeThenable(promise) {
  // Python sees a thenable that can only deliver the JSON string or a plain
  // rejection message. Hiding both prototypes prevents the guest from walking
  // through a host Promise/Function constructor to the Node Worker globals.
  const then = (resolve, reject) => { void Promise.prototype.then.call(promise, resolve, reject) }
  Object.setPrototypeOf(then, null)
  Object.setPrototypeOf(promise, null)
  Object.defineProperty(promise, 'then', { value: then })
  return Object.freeze(promise)
}

Object.setPrototypeOf(callHost, null)
Object.freeze(callHost)

parentPort?.on('message', (message) => {
  if (!Number.isSafeInteger(message?.id)) return
  const call = pending.get(message.id)
  if (!call) return
  pending.delete(message.id)
  if (message.type === 'binding.result') call.resolve(message.valueJSON)
  else call.reject(String(message.message ?? 'Tool call failed.'))
})

function pythonBootstrap() {
  return String.raw`
import asyncio
import json as __dsh_json
import math as __dsh_math
import textwrap as __dsh_textwrap
from js import __dsh_host_call__

class ToolCallError(Exception):
    def __init__(self, toolName, message):
        super().__init__(message)
        self.toolName = toolName

def __dsh_make_error_type(name, member):
    def initialize(self, member_name, message):
        Exception.__init__(self, message)
        setattr(self, member, member_name)
    return type(name, (Exception,), {"__init__": initialize})

class __DshNamespace:
    def __init__(self, namespace, names, error_type=None):
        self._namespace = namespace
        self._names = frozenset(names)
        self._error_type = error_type
    def __getattribute__(self, name):
        if not name.startswith("__"):
            names = object.__getattribute__(self, "_names")
            if name in names:
                return object.__getattribute__(self, "__getitem__")(name)
        return object.__getattribute__(self, name)
    def __getattr__(self, name):
        return self[name]
    def __getitem__(self, name):
        names = object.__getattribute__(self, "_names")
        namespace = object.__getattribute__(self, "_namespace")
        error_type = object.__getattribute__(self, "_error_type")
        if name not in names:
            raise AttributeError(f"Tool {name!r} is not available in this run.")
        async def invoke(args=None):
            try:
                value_json = await __dsh_host_call__(namespace, name, __dsh_json.dumps(args, ensure_ascii=False, allow_nan=False, separators=(",", ":")))
                return __dsh_json.loads(value_json)
            except Exception as error:
                if error_type is None or isinstance(error, error_type):
                    raise
                raise error_type(name, str(error)) from error
        return invoke

for __dsh_binding in __dsh_json.loads(__dsh_binding_specs_json__):
    __dsh_namespace = __dsh_binding["global"]
    __dsh_error_spec = __dsh_binding.get("errorClass")
    __dsh_error_type = None
    if __dsh_error_spec is not None:
        __dsh_error_type = __dsh_make_error_type(__dsh_error_spec["name"], __dsh_error_spec["memberNameProperty"])
        globals()[__dsh_error_spec["name"]] = __dsh_error_type
    globals()[__dsh_namespace] = __DshNamespace(__dsh_namespace, __dsh_binding["names"], __dsh_error_type)
`
}

function isJsonValue(value, depth = 0) {
  if (depth > 100) return false
  if (value === null || typeof value === 'string' || typeof value === 'boolean') return true
  if (typeof value === 'number') return Number.isFinite(value)
  if (Array.isArray(value)) return value.every((item) => isJsonValue(item, depth + 1))
  if (!value || typeof value !== 'object' || (Object.getPrototypeOf(value) !== Object.prototype && Object.getPrototypeOf(value) !== null)) return false
  return Object.keys(value).every((key) => isJsonValue(value[key], depth + 1))
}

function jsonValidationSource() {
  return String.raw`
def __dsh_validate_json(value, depth=0, ancestors=None):
    if ancestors is None:
        ancestors = set()
    if depth > 100:
        raise TypeError("return value exceeds the supported JSON depth")
    if value is None or type(value) in (str, bool):
        return
    if type(value) is int:
        if abs(value) > 9007199254740991:
            raise TypeError("return value contains an integer outside the exact JSON number range")
        return
    if type(value) is float:
        if not __dsh_math.isfinite(value):
            raise TypeError("return value contains a non-finite number")
        return
    if type(value) not in (list, dict):
        raise TypeError(f"return value contains unsupported {type(value).__name__}")
    identity = id(value)
    if identity in ancestors:
        raise TypeError("return value contains a cycle")
    ancestors.add(identity)
    if type(value) is list:
        for item in value:
            __dsh_validate_json(item, depth + 1, ancestors)
    else:
        for key, item in value.items():
            if type(key) is not str:
                raise TypeError("return value object keys must be strings")
            __dsh_validate_json(item, depth + 1, ancestors)
    ancestors.remove(identity)
`
}

function indentProgram(program) {
  const lines = program.replaceAll('\r\n', '\n').replaceAll('\r', '\n').split('\n')
  return lines.map((line) => line ? `    ${line}` : '').join('\n')
}

try {
  if (!parentPort || typeof workerData?.program !== 'string' || typeof workerData?.runtimeDirectory !== 'string') {
    throw new Error('Invalid local PTC Python worker request.')
  }
  const runtimeDirectory = workerData.runtimeDirectory
  const jsglobals = Object.create(null)
  jsglobals.__dsh_host_call__ = callHost
  const memory = new WebAssembly.Memory({ initial: 512, maximum: MAX_WASM_MEMORY_PAGES })
  const { loadPyodide } = await import(pathToFileURL(join(runtimeDirectory, 'pyodide.mjs')).href)
  const pyodide = await loadPyodide({
    indexURL: `${runtimeDirectory}/`,
    packageBaseUrl: `${runtimeDirectory}/full/`,
    lockFileURL: join(runtimeDirectory, 'pyodide-lock.json'),
    fullStdLib: true,
    jsglobals,
    wasmMemory: memory,
    stdin: () => null,
    stdout: appendOutput,
    stderr: appendOutput,
  })
  await pyodide.loadPackage('numpy')
  pyodide.setStdout({ batched: appendOutput })
  pyodide.setStderr({ batched: appendOutput })
  Object.freeze(jsglobals)
  pyodide.globals.set('__dsh_binding_specs_json__', JSON.stringify(workerData.bindings))
  pyodide.globals.set('__dsh_program__', workerData.program)
  pyodide.runPython(pythonBootstrap())
  pyodide.runPython(jsonValidationSource())

  const body = indentProgram(workerData.program)
  const wrapper = `import textwrap as __dsh_wrap\n__dsh_source = __dsh_wrap.dedent(__dsh_program__)\nif not __dsh_source.strip():\n    raise ValueError("program body is empty")\nexec("async def __dsh_main__():\\n" + "\\n".join("    " + line if line else "" for line in __dsh_source.splitlines()) + "\\n", globals(), globals())\nawait __dsh_main__()`
  // `body` is intentionally computed in JS to reject an empty source before Pyodide starts compiling it.
  if (!body.trim()) throw new Error('PTC Python program body is empty.')
  let result
  try {
    result = await pyodide.runPythonAsync(wrapper)
    if (result === undefined) {
      parentPort.postMessage({ type: 'completed', hasValue: false, outputTruncated })
    } else {
      pyodide.globals.set('__dsh_result__', result)
      const json = pyodide.runPython('__dsh_validate_json(__dsh_result__)\n__dsh_json.dumps(__dsh_result__, ensure_ascii=False, allow_nan=False, separators=(",", ":"))')
      const value = JSON.parse(String(json))
      if (!isJsonValue(value)) throw new Error('PTC Python result is not lossless JSON.')
      parentPort.postMessage({ type: 'completed', hasValue: true, value, outputTruncated })
    }
  } catch (error) {
    const detail = error instanceof Error ? error.stack || error.message : String(error)
    if (outputLength < MAX_OUTPUT_CHARACTERS) appendOutput(`${outputLength ? '\n' : ''}${detail}`)
    parentPort.postMessage({ type: 'completed', error: { kind: 'exception', message: detail.slice(0, 4_000) }, outputTruncated })
  } finally {
    result?.destroy?.()
  }
} catch (error) {
  const detail = error instanceof Error ? error.stack || error.message : String(error)
  if (outputLength < MAX_OUTPUT_CHARACTERS) appendOutput(`${outputLength ? '\n' : ''}${detail}`)
  parentPort?.postMessage({ type: 'completed', error: { kind: 'protocol', message: detail.slice(0, 4_000) }, outputTruncated })
}

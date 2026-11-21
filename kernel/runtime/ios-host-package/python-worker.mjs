import { parentPort, workerData } from 'node:worker_threads'
import { join } from 'node:path'
import { pathToFileURL } from 'node:url'

const MAX_OUTPUT_CHARACTERS = 32_000
const MAX_WASM_MEMORY_PAGES = 4_096 // 256 MiB (64 KiB pages)
let output = ''
let truncated = false

function safePrefix(text, length) {
  let prefix = text.slice(0, Math.max(0, length))
  if (!prefix) return prefix
  const last = prefix.charCodeAt(prefix.length - 1)
  if (last >= 0xD800 && last <= 0xDBFF && prefix.length < text.length) prefix = prefix.slice(0, -1)
  return prefix
}

function appendOutput(message) {
  const text = String(message ?? '')
  const remaining = MAX_OUTPUT_CHARACTERS - output.length
  if (remaining > 0) output += safePrefix(text, remaining)
  if (text.length > remaining) truncated = true
}

function finish(error) {
  const suffix = '\n[输出已截断至 32,000 字符]'
  const finalOutput = truncated
    ? safePrefix(output, Math.max(0, MAX_OUTPUT_CHARACTERS - suffix.length)) + suffix
    : safePrefix(output, MAX_OUTPUT_CHARACTERS)
  parentPort?.postMessage({ type: 'completed', output: finalOutput, ...(error ? { error } : {}) })
}

try {
  if (!parentPort || typeof workerData?.code !== 'string' || typeof workerData?.runtimeDirectory !== 'string') {
    throw new Error('Invalid local Python worker request.')
  }

  // The runtime assets and NumPy wheel are embedded in the app. No package
  // install or network fetch is allowed at execution time.
  const runtimeDirectory = workerData.runtimeDirectory
  const { loadPyodide } = await import(pathToFileURL(join(runtimeDirectory, 'pyodide.mjs')).href)
  const pythonGlobals = Object.create(null)
  const memory = new WebAssembly.Memory({ initial: 512, maximum: MAX_WASM_MEMORY_PAGES })
  const pyodide = await loadPyodide({
    indexURL: `${runtimeDirectory}/`,
    packageBaseUrl: `${runtimeDirectory}/full/`,
    lockFileURL: join(runtimeDirectory, 'pyodide-lock.json'),
    fullStdLib: true,
    jsglobals: pythonGlobals,
    wasmMemory: memory,
    stdin: () => null,
    stdout: appendOutput,
    stderr: appendOutput,
  })
  await pyodide.loadPackage('numpy')
  pyodide.setStdout({ batched: appendOutput })
  pyodide.setStderr({ batched: appendOutput })

  // Pyodide uses this empty object for Python's `js` module. Node globals stay
  // in the worker host and are never added to that object.
  Object.freeze(pythonGlobals)

  const result = await pyodide.runPythonAsync(workerData.code)
  if (result !== undefined && result !== null) {
    let display = ''
    try { display = String(result) } finally { result?.destroy?.() }
    if (output && !output.endsWith('\n')) appendOutput('\n')
    appendOutput(display)
  }
  finish()
} catch (error) {
  const detail = error instanceof Error ? error.stack || error.message : String(error)
  if (output && !output.endsWith('\n')) appendOutput('\n')
  appendOutput(detail)
  finish({ kind: 'exception', message: detail.slice(0, 4_000) })
}

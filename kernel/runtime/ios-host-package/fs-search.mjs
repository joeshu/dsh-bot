import { defineTool } from '@deepseek-ai/dsh-tools'
import { relative, sep } from 'node:path'

const IGNORED_DIRECTORIES = new Set(['.git', '.svn', '.hg', '.jj', 'node_modules', '.DS_Store'])
const MAX_VISITED_ENTRIES = 10_000
const MAX_RESULTS = 100
const MAX_GREP_FILES = 500
const MAX_FILE_BYTES = 262_144
const MAX_GREP_MATCHES = 250
const MAX_MATCH_LINE_CHARS = 2_000

function hasUnsafeRegexFeatures(pattern) {
  let inCharacterClass = false
  let unboundedQuantifiers = 0
  for (let index = 0; index < pattern.length; index++) {
    const char = pattern[index]
    if (char === '\\') {
      const escaped = pattern[index + 1]
      if (escaped && /[1-9]/.test(escaped)) return true
      index++
      continue
    }
    if (char === '[') inCharacterClass = true
    else if (char === ']') inCharacterClass = false
    if (inCharacterClass) continue
    // Keep the mobile matcher bounded: grouping can create exponential
    // backtracking, and three or more unbounded repetitions can create large
    // polynomial blowups even without groups.
    if (char === '(' || char === ')') return true
    if (char === '*' || char === '+') unboundedQuantifiers++
    else if (char === '{') {
      const quantifier = /^\{\d*,\}/.exec(pattern.slice(index))
      if (quantifier) unboundedQuantifiers++
    }
    if (unboundedQuantifiers > 2) return true
  }
  return false
}

function globExpression(pattern) {
  let expression = '^'
  for (let index = 0; index < pattern.length; index++) {
    const char = pattern[index]
    if (char === '*' && pattern[index + 1] === '*') {
      index++
      if (pattern[index + 1] === '/') {
        index++
        expression += '(?:.*/)?'
      } else expression += '.*'
    } else if (char === '*') expression += '[^/]*'
    else if (char === '?') expression += '[^/]'
    else if (char === '{') expression += '(?:'
    else if (char === '}') expression += ')'
    else if (char === ',') expression += '|'
    else if (char === '[') expression += '['
    else if (char === ']' || char === '-') expression += char
    else expression += /[\\^$.*+?()[\]{}|]/.test(char) ? `\\${char}` : char
  }
  return new RegExp(`${expression}$`)
}

async function searchRoot(ctx, exec, requestedPath) {
  if (typeof requestedPath === 'string' && !requestedPath.trim()) throw new Error('path must be a non-empty directory when given')
  const cwd = await ctx.workingDirectory.ensure(exec.agent, exec.signal)
  const root = await ctx.fs.resolve(requestedPath || '.', { cwd, signal: exec.signal })
  const info = await ctx.fs.stat(root, exec.signal)
  if (!info || info.type !== 'directory') throw new Error(`Search path is not a directory: ${root.displayPath}`)
  const cwdTarget = await ctx.fs.resolve('.', { cwd, signal: exec.signal })
  return { root, cwdTarget }
}

async function* walk(ctx, root, exec, limits = {}) {
  const maxVisited = limits.maxVisited ?? MAX_VISITED_ENTRIES
  const stack = [root]
  let visited = 0
  while (stack.length && visited < maxVisited) {
    exec.signal?.throwIfAborted()
    const directory = stack.pop()
    const entries = await ctx.fs.listDir(directory, exec.signal)
    for (const entry of entries) {
      if (++visited > maxVisited) return
      if (entry.type === 'directory') {
        if (!IGNORED_DIRECTORIES.has(entry.name)) stack.push(entry.target)
      } else if (entry.type === 'file' && entry.name !== '.DS_Store') {
        yield entry
      }
    }
  }
}

function relativePath(ctx, cwd, target) {
  const value = ctx.fs.processPath(target)
  const base = ctx.fs.processPath(cwd)
  const path = relative(base, value).split(sep).join('/')
  return path || '.'
}

function apply(ctx) {
  const glob = defineTool({
    name: 'glob',
    description: 'Find workspace files by glob pattern. Supports *, **, ?, and {a,b} alternatives. Hidden files are included; VCS metadata and node_modules are skipped.',
    parameters: {
      pattern: { type: 'string', required: true, description: 'Glob pattern relative to path or the current workspace.' },
      path: { type: 'string', description: 'Optional workspace directory to search.' },
    },
    timeoutMs: 30_000,
    async execute(args, exec) {
      const pattern = typeof args.pattern === 'string' ? args.pattern.trim().replaceAll('\\', '/') : ''
      if (!pattern || pattern.length > 512 || pattern.split('/').includes('..')) throw new Error('pattern must be a safe non-empty glob of at most 512 characters')
      const expression = globExpression(pattern)
      const { root, cwdTarget } = await searchRoot(ctx, exec, args.path)
      const rootPath = relativePath(ctx, cwdTarget, root)
      const results = []
      for await (const entry of walk(ctx, root, exec)) {
        const path = relativePath(ctx, cwdTarget, entry.target)
        if (expression.test(relativePath(ctx, root, entry.target))) results.push(path)
        if (results.length >= MAX_RESULTS) break
      }
      return { output: results.length ? results.join('\n') + (results.length === MAX_RESULTS ? '\n(results capped at 100; narrow the pattern or path)' : '') : `No files matched ${pattern} under ${rootPath}` }
    },
  })

  const grep = defineTool({
    name: 'grep',
    description: 'Search UTF-8 workspace files with a bounded regular expression. Grouping, lookarounds, backreferences, and more than two unbounded repetitions are unsupported. Results are capped; use path or include to narrow large searches.',
    parameters: {
      pattern: { type: 'string', required: true, description: 'JavaScript-compatible regular expression.' },
      path: { type: 'string', description: 'Optional workspace directory to search.' },
      include: { type: 'string', description: 'Optional file glob, for example **/*.{ts,swift}.' },
    },
    timeoutMs: 45_000,
    async execute(args, exec) {
      const pattern = typeof args.pattern === 'string' ? args.pattern : ''
      if (!pattern || pattern.length > 180 || /[\x00-\x1f\x7f]/.test(pattern) || hasUnsafeRegexFeatures(pattern)) {
        throw new Error('pattern must be a safe regular expression of at most 180 characters')
      }
      const expression = new RegExp(pattern)
      const include = args.include ? globExpression(String(args.include).replaceAll('\\', '/')) : undefined
      const { root, cwdTarget } = await searchRoot(ctx, exec, args.path)
      const matches = []
      let inspected = 0
      for await (const entry of walk(ctx, root, exec)) {
        if (inspected++ >= MAX_GREP_FILES) break
        const path = relativePath(ctx, cwdTarget, entry.target)
        if (include && !include.test(relativePath(ctx, root, entry.target))) continue
        const info = await ctx.fs.stat(entry.target, exec.signal)
        if (!info || info.type !== 'file' || (info.size ?? 0) > MAX_FILE_BYTES) continue
        let content
        try { content = await ctx.fs.readText(entry.target, exec.signal) } catch { continue }
        const lines = content.split(/\r?\n/)
        for (let index = 0; index < lines.length; index++) {
          exec.signal?.throwIfAborted()
          expression.lastIndex = 0
          const line = lines[index].slice(0, MAX_MATCH_LINE_CHARS)
          if (!expression.test(line)) continue
          matches.push(`${path}:${index + 1}: ${line}`)
          if (matches.length >= MAX_GREP_MATCHES) break
        }
        if (matches.length >= MAX_GREP_MATCHES) break
      }
      return { output: matches.length ? matches.join('\n') + (matches.length === MAX_GREP_MATCHES ? '\n(matches capped at 250; narrow the search)' : '') : `No matches for ${pattern}` }
    },
  })
  const removeGlob = ctx.tools.register(glob)
  const removeGrep = ctx.tools.register(grep)
  ctx.effect(() => () => { removeGrep(); removeGlob() }, 'dsbot-ios.fs-search')
}

export default { name: 'dsbot-ios-fs-search', inject: ['tools', 'fs', 'workingDirectory'], apply }

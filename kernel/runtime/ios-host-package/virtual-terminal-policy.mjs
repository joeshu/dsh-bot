/** Quote-aware parser for the small, non-shell virtual terminal. */
export function splitTerminalSegments(line) {
  const segments = []
  let current = ''
  let quote = ''
  const text = String(line)
  for (let i = 0; i < text.length; i += 1) {
    const ch = text[i]
    if (quote) {
      current += ch
      if (ch === '\\' && quote === '"' && i + 1 < text.length) current += text[++i]
      else if (ch === quote) quote = ''
      continue
    }
    if (ch === '"' || ch === "'") { quote = ch; current += ch; continue }
    if (ch === ';' || (ch === '&' && text[i + 1] === '&')) {
      if (ch === '&') i += 1
      if (current.trim()) segments.push(current.trim())
      current = ''
      continue
    }
    current += ch
  }
  if (current.trim()) segments.push(current.trim())
  return segments
}

export function tokenizeShellWords(input) {
  const tokens = []
  let current = ''
  let quote = null
  const text = String(input)
  for (let i = 0; i < text.length; i += 1) {
    const ch = text[i]
    if (quote) {
      if (ch === quote) quote = null
      else if (ch === '\\' && quote === '"' && i + 1 < text.length) current += text[++i]
      else current += ch
    } else if (ch === '"' || ch === "'") {
      quote = ch
    } else if (/\s/.test(ch)) {
      if (current) { tokens.push(current); current = '' }
    } else {
      current += ch
    }
  }
  if (current) tokens.push(current)
  return tokens
}

/** Parse the one supported redirection form without treating quoted `>` as an operator. */
export function parseEchoRedirection(line) {
  const text = String(line).trim()
  if (!/^echo(?:\s|$)/i.test(text)) return undefined
  let quote = ''
  for (let i = 4; i < text.length; i += 1) {
    const ch = text[i]
    if (quote) {
      if (ch === '\\' && quote === '"' && i + 1 < text.length) { i += 1; continue }
      if (ch === quote) quote = ''
      continue
    }
    if (ch === '"' || ch === "'") { quote = ch; continue }
    if (ch !== '>') continue
    const append = text[i + 1] === '>'
    const operatorLength = append ? 2 : 1
    const content = text.slice(4, i).trim()
    const targetText = text.slice(i + operatorLength).trim()
    const targets = tokenizeShellWords(targetText)
    if (targets.length !== 1) throw new Error('echo: 重定向需要一个目标文件名')
    return { content: tokenizeShellWords(content).join(' '), path: targets[0], append }
  }
  return undefined
}

const MUTATING_COMMANDS = new Set(['mkdir', 'touch', 'cp', 'mv', 'rm', 'export'])

export function isMutatingVirtualTerminalCommand(line) {
  return splitTerminalSegments(line).some((segment) => {
    const [command = '', ...args] = tokenizeShellWords(segment)
    if (MUTATING_COMMANDS.has(command.toLowerCase())) return true
    if (command.toLowerCase() === 'echo') return Boolean(parseEchoRedirection(segment))
    if (command.toLowerCase() === 'git') return ['commit', 'snapshot'].includes(String(args[0] ?? '').toLowerCase())
    return false
  })
}

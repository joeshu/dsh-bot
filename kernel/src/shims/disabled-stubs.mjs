// Compile-time & runtime stubs for desktop-only DSH / OS modules that cannot run
// inside the iOS sandbox (no fork/exec, no PTY, no Chromium, no LibreOffice).
// Every stub returns a structured, diagnosable error instead of crashing the worklet.

export class IOSCapabilityUnavailableError extends Error {
  constructor(moduleName, operation = 'invoke') {
    super(`iOS standalone sandbox does not support desktop module "${moduleName}" (${operation}). Use Remote MCP or iOS native tools instead.`)
    this.name = 'IOSCapabilityUnavailableError'
    this.code = 'IOS_CAPABILITY_UNAVAILABLE'
    this.moduleName = moduleName
    this.operation = operation
  }
}

/**
 * Create a safe Proxy stub for any disabled desktop module.
 * Allows Cordis / DSH plugin loaders to inspect metadata without throwing at import time,
 * while throwing IOSCapabilityUnavailableError if an unsupported runtime operation is invoked.
 * @param {string} moduleName
 */
export function createDisabledModuleStub(moduleName) {
  const unavailable = (op) => {
    throw new IOSCapabilityUnavailableError(moduleName, op)
  }

  const base = {
    __iosDisabledStub: true,
    moduleName,
    name: `ios-disabled:${moduleName}`,
    apply() {
      return { disabled: true, reason: 'IOS_CAPABILITY_UNAVAILABLE', moduleName }
    },
    spawn: () => unavailable('spawn'),
    launch: () => unavailable('launch'),
  }

  return new Proxy(base, {
    get(target, prop) {
      if (prop in target) return target[prop]
      if (prop === '__esModule') return true
      if (prop === 'default') return target
      if (typeof prop === 'symbol') return undefined
      return () => unavailable(String(prop))
    },
  })
}

export const DESKTOP_DISABLED_MODULES = Object.freeze([
  '@deepseek-ai/dsh-web-app',
  '@deepseek-ai/dsh-bash-local',
  '@deepseek-ai/dsh-computer-use',
  '@deepseek-ai/dsh-cua',
  '@deepseek-ai/dsh-experimental-cua-macos',
  '@deepseek-ai/dsh-experimental-computer-use-cua-driver-native',
  '@deepseek-ai/dsh-skill-office',
  '@deepseek-ai/dsh-tool-workspace-dependencies',
  '@deepseek-ai/libreoffice-kit',
  '@trycua/cua-driver',
  'playwright-core',
  'node-pty',
  'sharp',
  'koffi',
  'pnpm',
])

let claimed = false

/** A process-wide single slot for the memory-heavy offline Python interpreter. */
export function claimIOSPythonWorker() {
  if (claimed) return undefined
  claimed = true
  let released = false
  return () => {
    if (released) return
    released = true
    claimed = false
  }
}

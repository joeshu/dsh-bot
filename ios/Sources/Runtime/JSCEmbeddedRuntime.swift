import Foundation
import JavaScriptCore

public struct JSExecutionResult: Equatable {
    public let value: String
    public let logs: [String]
    public let error: String?

    public var ok: Bool { error == nil }
}

/// On-device sandboxed JavaScript execution runtime powered by Apple's built-in `JavaScriptCore`.
/// - Zero extra binary size, zero JIT/entitlement conflicts (100% SideStore / LiveContainer / TrollStore safe)
/// - Runs pure-JS DSH plugin handlers and the `js_eval` agent tool safely inside an isolated `JSVirtualMachine`
public final class JSCEmbeddedRuntime: @unchecked Sendable {
    private let queue = DispatchQueue(label: "io.github.dsbot.jsc.runtime")
    private let lock = NSLock()
    private var runaway = 0
    private static let maxRunaway = 2
    private static let maxOutputBytes = 262_144

    public init() {}

    /// Execute a JavaScript expression or pure-JS plugin snippet inside a fresh isolated `JSContext` with timeout isolation.
    /// JavaScriptCore's public API cannot terminate a running script, so a timed-out worker may keep spinning;
    /// the number of such workers is capped and further runs are refused until they finish.
    public func evaluate(script: String, globals: [String: Any] = [:], timeoutSeconds: TimeInterval = 8.0) -> JSExecutionResult {
        guard script.utf8.count <= 262_144 else {
            return JSExecutionResult(value: "", logs: [], error: "Script exceeds 256 KB safety limit.")
        }
        lock.lock()
        let blocked = runaway >= Self.maxRunaway
        lock.unlock()
        if blocked {
            return JSExecutionResult(value: "", logs: [], error: "Too many unfinished JavaScript runs; restart the app to recover.")
        }

        let sem = DispatchSemaphore(value: 0)
        var outcome: JSExecutionResult?
        var timedOut = false
        let worker = DispatchQueue(label: "io.github.dsbot.jsc.eval.\(UUID().uuidString.prefix(6))", qos: .userInitiated)
        worker.async { [self] in
            let result = Self.runIsolated(script: script, globals: globals)
            lock.lock()
            if timedOut {
                runaway -= 1
            } else {
                outcome = result
            }
            lock.unlock()
            sem.signal()
        }
        if sem.wait(timeout: .now() + max(0.5, timeoutSeconds)) == .timedOut {
            lock.lock()
            if outcome == nil {
                timedOut = true
                runaway += 1
            }
            lock.unlock()
            if timedOut {
                return JSExecutionResult(value: "", logs: [], error: "JavaScript execution timed out after \(Int(timeoutSeconds))s.")
            }
        }
        lock.lock()
        let final = outcome
        lock.unlock()
        guard var res = final else {
            return JSExecutionResult(value: "", logs: [], error: "JavaScript execution returned no result.")
        }
        if res.value.utf8.count > Self.maxOutputBytes {
            res = JSExecutionResult(value: String(res.value.prefix(Self.maxOutputBytes)), logs: res.logs, error: res.error)
        }
        return res
    }

    private static func runIsolated(script: String, globals: [String: Any]) -> JSExecutionResult {
            guard let vm = JSVirtualMachine(), let ctx = JSContext(virtualMachine: vm) else {
                return JSExecutionResult(value: "", logs: [], error: "Failed to initialize JavaScriptCore VM")
            }

            var capturedLogs: [String] = []
            var capturedError: String?

            ctx.exceptionHandler = { _, exception in
                capturedError = exception?.toString() ?? "Unknown JavaScript exception"
            }

            // Inject safe `console.log` / `console.warn` / `console.error`
            let logFn: @convention(block) (String) -> Void = { msg in
                if capturedLogs.count < 200 {
                    capturedLogs.append(msg)
                }
            }
            ctx.setObject(logFn, forKeyedSubscript: "__ios_log" as NSString)
            ctx.evaluateScript("""
                var console = {
                    log: function() { __ios_log(Array.prototype.slice.call(arguments).map(String).join(' ')); },
                    warn: function() { __ios_log('[WARN] ' + Array.prototype.slice.call(arguments).map(String).join(' ')); },
                    error: function() { __ios_log('[ERROR] ' + Array.prototype.slice.call(arguments).map(String).join(' ')); }
                };
            """)

            for (key, val) in globals {
                ctx.setObject(val, forKeyedSubscript: key as NSString)
            }

            let rawValue = ctx.evaluateScript(script)
            if let err = capturedError {
                return JSExecutionResult(value: "", logs: capturedLogs, error: err)
            }
            let rendered: String
            if let v = rawValue, !v.isUndefined && !v.isNull {
                if v.isObject,
                   let jsonStr = ctx.evaluateScript("JSON.stringify")?.call(withArguments: [v])?.toString(),
                   jsonStr != "undefined" {
                    rendered = jsonStr
                } else {
                    rendered = v.toString() ?? ""
                }
            } else {
                rendered = ""
            }
            return JSExecutionResult(value: rendered, logs: capturedLogs, error: nil)
    }

    /// Execute an installed pure-JS DSH plugin file (`index.js`) and return its exported metadata/result.
    public func runInstalledPlugin(at fileURL: URL, inputJSON: String = "{}") -> JSExecutionResult {
        guard let source = try? String(contentsOf: fileURL, encoding: .utf8) else {
            return JSExecutionResult(value: "", logs: [], error: "Plugin entry not readable: \(fileURL.lastPathComponent)")
        }
        let wrapped = """
        (function(input) {
            var module = { exports: {} };
            var exports = module.exports;
            \(source)
            if (typeof module.exports === 'function') return module.exports(input);
            if (module.exports && typeof module.exports.run === 'function') return module.exports.run(input);
            return { loaded: true, name: module.exports && module.exports.name ? module.exports.name : 'plugin' };
        })(\(inputJSON));
        """
        return evaluate(script: wrapped)
    }
}

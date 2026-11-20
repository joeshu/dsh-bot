import Foundation
import SQLite3

private let SQLITE_TRANSIENT_DESTRUCTOR = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public enum SQLiteBridgeError: Error, LocalizedError {
    case sandboxViolation(String)
    case openFailed(String)
    case execFailed(String)
    case notOpen(String)

    public var errorDescription: String? {
        switch self {
        case .sandboxViolation(let path): return "SQLite path outside App Sandbox: \(path)"
        case .openFailed(let msg): return "SQLite open failed: \(msg)"
        case .execFailed(let msg): return "SQLite exec failed: \(msg)"
        case .notOpen(let path): return "SQLite database not open: \(path)"
        }
    }
}

/// Thread-safe native iOS `libsqlite3` bridge backing `@deepseek-ai/dsh-session-query-sqlite`.
/// Enforces App Sandbox path containment and parameterized bindings to prevent SQL injection.
public final class SQLiteBridge: @unchecked Sendable {
    private let queue = DispatchQueue(label: "io.github.dsbot.sqlite.bridge")
    private let allowedRoot: String
    private var handles: [String: OpaquePointer] = [:]

    public init(allowedRoot: URL? = nil) {
        if let root = allowedRoot {
            self.allowedRoot = root.standardizedFileURL.path
        } else {
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            self.allowedRoot = docs.appendingPathComponent("dsh-home", isDirectory: true).standardizedFileURL.path
        }
    }

    deinit {
        for (_, db) in handles {
            sqlite3_close(db)
        }
    }

    private func validatedPath(_ rawPath: String) throws -> String {
        if rawPath == ":memory:" { return rawPath }
        let standardized = URL(fileURLWithPath: rawPath).standardizedFileURL.path
        guard standardized == allowedRoot || standardized.hasPrefix(allowedRoot + "/") else {
            throw SQLiteBridgeError.sandboxViolation(rawPath)
        }
        return standardized
    }

    public func open(path: String) throws -> [String: Any] {
        let safePath = try validatedPath(path)
        return try queue.sync {
            if handles[safePath] != nil {
                return ["ok": true, "path": safePath]
            }
            if safePath != ":memory:" {
                let dir = URL(fileURLWithPath: safePath).deletingLastPathComponent()
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            }
            var db: OpaquePointer?
            let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
            guard sqlite3_open_v2(safePath, &db, flags, nil) == SQLITE_OK, let handle = db else {
                let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
                if let db { sqlite3_close(db) }
                throw SQLiteBridgeError.openFailed(msg)
            }
            sqlite3_busy_timeout(handle, 5000)
            sqlite3_exec(handle, "PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA foreign_keys=ON; PRAGMA busy_timeout=5000;", nil, nil, nil)
            handles[safePath] = handle
            return ["ok": true, "path": safePath]
        }
    }

    public func exec(path: String, sql: String) throws -> [String: Any] {
        let safePath = try validatedPath(path)
        return try queue.sync {
            guard let db = handles[safePath] else { throw SQLiteBridgeError.notOpen(safePath) }
            var errPtr: UnsafeMutablePointer<CChar>?
            let rc = sqlite3_exec(db, sql, nil, nil, &errPtr)
            if rc != SQLITE_OK {
                let msg = errPtr.map { String(cString: $0) } ?? "SQLite error \(rc)"
                sqlite3_free(errPtr)
                throw SQLiteBridgeError.execFailed(msg)
            }
            return ["ok": true, "changes": Int(sqlite3_changes(db))]
        }
    }

    public func run(path: String, sql: String, params: [Any] = []) throws -> [String: Any] {
        let safePath = try validatedPath(path)
        return try queue.sync {
            guard let db = handles[safePath] else { throw SQLiteBridgeError.notOpen(safePath) }
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let statement = stmt else {
                throw SQLiteBridgeError.execFailed(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(statement) }
            try bind(params: params, to: statement, db: db)
            let step = sqlite3_step(statement)
            guard step == SQLITE_DONE || step == SQLITE_ROW else {
                throw SQLiteBridgeError.execFailed(String(cString: sqlite3_errmsg(db)))
            }
            return [
                "ok": true,
                "changes": Int(sqlite3_changes(db)),
                "lastInsertRowid": Int(sqlite3_last_insert_rowid(db))
            ]
        }
    }

    public func query(path: String, sql: String, params: [Any] = []) throws -> [String: Any] {
        let safePath = try validatedPath(path)
        return try queue.sync {
            guard let db = handles[safePath] else { throw SQLiteBridgeError.notOpen(safePath) }
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let statement = stmt else {
                throw SQLiteBridgeError.execFailed(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(statement) }
            try bind(params: params, to: statement, db: db)

            let colCount = sqlite3_column_count(statement)
            var rows: [[String: Any]] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                var row: [String: Any] = [:]
                for i in 0..<colCount {
                    let name = String(cString: sqlite3_column_name(statement, i))
                    switch sqlite3_column_type(statement, i) {
                    case SQLITE_INTEGER:
                        row[name] = Int(sqlite3_column_int64(statement, i))
                    case SQLITE_FLOAT:
                        row[name] = sqlite3_column_double(statement, i)
                    case SQLITE_TEXT:
                        if let cStr = sqlite3_column_text(statement, i) {
                            row[name] = String(cString: cStr)
                        }
                    default:
                        row[name] = NSNull()
                    }
                }
                rows.append(row)
            }
            return ["rows": rows]
        }
    }

    public func close(path: String) throws -> [String: Any] {
        let safePath = try validatedPath(path)
        return queue.sync {
            if let db = handles.removeValue(forKey: safePath) {
                sqlite3_close(db)
            }
            return ["ok": true]
        }
    }

    private func bind(params: [Any], to stmt: OpaquePointer, db: OpaquePointer) throws {
        for (idx, value) in params.enumerated() {
            let col = Int32(idx + 1)
            let rc: Int32
            switch value {
            case is NSNull:
                rc = sqlite3_bind_null(stmt, col)
            case let b as Bool:
                rc = sqlite3_bind_int64(stmt, col, b ? 1 : 0)
            case let i as Int:
                rc = sqlite3_bind_int64(stmt, col, Int64(i))
            case let i64 as Int64:
                rc = sqlite3_bind_int64(stmt, col, i64)
            case let d as Double:
                rc = sqlite3_bind_double(stmt, col, d)
            case let s as String:
                rc = sqlite3_bind_text(stmt, col, s, -1, SQLITE_TRANSIENT_DESTRUCTOR)
            default:
                let s = String(describing: value)
                rc = sqlite3_bind_text(stmt, col, s, -1, SQLITE_TRANSIENT_DESTRUCTOR)
            }
            guard rc == SQLITE_OK else {
                throw SQLiteBridgeError.execFailed(String(cString: sqlite3_errmsg(db)))
            }
        }
    }
}

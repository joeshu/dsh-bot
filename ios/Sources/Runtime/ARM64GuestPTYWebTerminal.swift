import Foundation

/// Owns the interactive terminal opened from the app's Web/Workbench terminal UI.
/// The random token returned to the UI is mapped to a host-created PTY owner;
/// callers cannot choose or infer the guest's numeric session ID.
public actor ARM64GuestPTYWebTerminal {
    public static let shared = ARM64GuestPTYWebTerminal()

    private struct Session {
        let owner: ARM64GuestPTYOwner
        var reader: Task<Void, Never>?
        var output = Data()
        var outputWasTruncated = false
        var exitCode: Int32?
        var error: String?
        var readWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    }

    private let runtime: any LinuxPTYRuntime
    private let maxSessions = 4
    private let maxBufferedOutputBytes = 256 * 1024
    private let maxReadBytes = 32 * 1024
    private let maxPendingReadsPerSession = 8
    private var openingTasks: [String: Task<String, Error>] = [:]
    private var requestSessions: [String: String] = [:]
    private var sessions: [String: Session] = [:]

    public init(runtime: any LinuxPTYRuntime = LinuxPTYRuntimeRegistry.shared) {
        self.runtime = runtime
    }

    public func open(
        ownerSessionID: String = "main",
        requestID: String? = nil,
        rows: UInt16 = 24,
        columns: UInt16 = 80
    ) async throws -> String {
        guard rows >= 2, rows <= 300, columns >= 2, columns <= 500 else {
            throw ARM64GuestPTYProtocolError.invalidDimensions
        }
        guard sessions.count < maxSessions else {
            throw ARM64GuestPTYProtocolError.sessionLimitReached
        }
        if let requestID {
            guard UUID(uuidString: requestID) != nil, requestSessions[requestID] == nil else {
                throw ARM64GuestPTYProtocolError.invalidOwner
            }
        }
        let id = UUID().uuidString.lowercased()
        guard let owner = ARM64GuestPTYOwner(kind: .web, sessionID: ownerSessionID, terminalID: id) else {
            throw ARM64GuestPTYProtocolError.invalidOwner
        }
        sessions[id] = Session(owner: owner)
        if let requestID { requestSessions[requestID] = id }
        let task = Task { try await self.startSession(id: id, owner: owner, rows: rows, columns: columns) }
        openingTasks[id] = task
        do {
            let result = try await task.value
            openingTasks.removeValue(forKey: id)
            return result
        } catch {
            sessions.removeValue(forKey: id)
            openingTasks.removeValue(forKey: id)
            if let requestID, requestSessions[requestID] == id { requestSessions.removeValue(forKey: requestID) }
            throw error
        }
    }

    public func cancelOpen(requestID: String) async {
        guard let sessionID = requestSessions[requestID] else { return }
        await close(sessionID: sessionID)
    }

    public func write(_ text: String, sessionID: String) async throws {
        guard let session = authorizedSession(sessionID), session.exitCode == nil, session.error == nil else {
            throw ARM64GuestPTYProtocolError.sessionNotOpen
        }
        let input = Data(text.utf8)
        guard !input.isEmpty, input.count <= ARM64GuestPTYCodec.maxPayloadBytes else {
            throw ARM64GuestPTYProtocolError.frameTooLarge(input.count)
        }
        try await runtime.sendInput(input, owner: session.owner)
    }

    public func resize(rows: UInt16, columns: UInt16, sessionID: String) async throws {
        guard rows >= 2, rows <= 300, columns >= 2, columns <= 500 else {
            throw ARM64GuestPTYProtocolError.invalidDimensions
        }
        guard let session = authorizedSession(sessionID), session.exitCode == nil, session.error == nil else {
            throw ARM64GuestPTYProtocolError.sessionNotOpen
        }
        try await runtime.resize(owner: session.owner, rows: rows, columns: columns)
    }

    public func read(sessionID: String) async throws -> [String: Any] {
        guard let initial = authorizedSession(sessionID) else {
            throw ARM64GuestPTYProtocolError.ownerNotAuthorized
        }
        if initial.output.isEmpty, initial.exitCode == nil, initial.error == nil {
            guard initial.readWaiters.count < maxPendingReadsPerSession else {
                throw ARM64GuestPTYProtocolError.outputBackpressure
            }
            await withCheckedContinuation { continuation in
                guard var current = sessions[sessionID], current.output.isEmpty,
                      current.exitCode == nil, current.error == nil else {
                    continuation.resume()
                    return
                }
                let waiterID = UUID()
                current.readWaiters[waiterID] = continuation
                sessions[sessionID] = current
                Task { [weak self] in
                    do { try await Task.sleep(nanoseconds: 5_000_000_000) } catch { return }
                    await self?.wakeReader(for: sessionID, waiterID: waiterID)
                }
            }
        }
        guard var session = authorizedSession(sessionID) else {
            throw ARM64GuestPTYProtocolError.ownerNotAuthorized
        }
        let count = min(maxReadBytes, session.output.count)
        let output = count > 0 ? session.output.prefix(count) : Data()
        if count > 0 { session.output.removeFirst(count) }
        var result: [String: Any] = [
            "output": Data(output).base64EncodedString(),
            "truncated": session.outputWasTruncated,
            "done": session.exitCode != nil || session.error != nil,
            "error": session.error ?? "",
        ]
        if let exitCode = session.exitCode { result["exitCode"] = Int(exitCode) }
        session.outputWasTruncated = false
        sessions[sessionID] = session
        return result
    }

    public func close(sessionID: String) async {
        guard let session = sessions.removeValue(forKey: sessionID) else { return }
        requestSessions = requestSessions.filter { $0.value != sessionID }
        openingTasks.removeValue(forKey: sessionID)?.cancel()
        session.reader?.cancel()
        session.readWaiters.values.forEach { $0.resume() }
        await runtime.closePTY(owner: session.owner)
    }

    public func closeAll() async {
        for task in openingTasks.values { task.cancel() }
        openingTasks.removeAll()
        let ids = Array(sessions.keys)
        for id in ids { await close(sessionID: id) }
    }

    private func startSession(
        id: String,
        owner: ARM64GuestPTYOwner,
        rows: UInt16,
        columns: UInt16
    ) async throws -> String {
        try Task.checkCancellation()
        guard sessions[id] != nil else { throw CancellationError() }
        do {
            try Task.checkCancellation()
            guard sessions[id] != nil else { throw CancellationError() }
            let stream = try await runtime.openPTY(owner: owner, rows: rows, columns: columns, timeoutSeconds: 120)
            guard var session = sessions[id] else {
                await runtime.closePTY(owner: owner)
                throw CancellationError()
            }
            session.reader = Task { [weak self] in
                do {
                    for try await event in stream {
                        await self?.receive(event, for: id)
                    }
                } catch {
                    await self?.receive(error: error, for: id)
                }
            }
            sessions[id] = session
            return id
        } catch {
            throw error
        }
    }

    private func authorizedSession(_ id: String) -> Session? {
        guard id.utf8.count == 36, sessions[id] != nil else { return nil }
        return sessions[id]
    }

    private func receive(_ event: ARM64GuestPTYEvent, for id: String) {
        guard var session = sessions[id] else { return }
        switch event {
        case .output(let bytes):
            session.output.append(bytes)
            if session.output.count > maxBufferedOutputBytes {
                let excess = session.output.count - maxBufferedOutputBytes
                session.output.removeFirst(excess)
                session.outputWasTruncated = true
            }
        case .exited(let status):
            session.exitCode = status
        }
        let waiters = Array(session.readWaiters.values)
        session.readWaiters.removeAll()
        sessions[id] = session
        waiters.forEach { $0.resume() }
    }

    private func receive(error: Error, for id: String) {
        guard var session = sessions[id] else { return }
        session.error = String(error.localizedDescription.prefix(512))
        let waiters = Array(session.readWaiters.values)
        session.readWaiters.removeAll()
        sessions[id] = session
        waiters.forEach { $0.resume() }
    }

    private func wakeReader(for id: String, waiterID: UUID) {
        guard var session = sessions[id], let waiter = session.readWaiters.removeValue(forKey: waiterID) else { return }
        sessions[id] = session
        waiter.resume()
    }
}

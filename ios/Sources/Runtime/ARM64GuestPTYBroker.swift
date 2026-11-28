import Foundation

public enum ARM64GuestPTYEvent: Sendable, Equatable {
    case output(Data)
    case exited(Int32)
}

/// Byte transport connected to the guest's PL011 UART. Implementations must serialize writes.
public protocol ARM64GuestSerialTransport: AnyObject, Sendable {
    func setReceiveHandler(_ handler: (@Sendable (Data) -> Void)?)
    func setCloseHandler(_ handler: (@Sendable () -> Void)?)
    func send(_ bytes: Data) throws
    func close()
}

/// Authenticates each shell operation by its host-owned Bot/Web/native identity, then
/// multiplexes DSBP frames over one private serial connection to the guest.
public actor ARM64GuestPTYBroker {
    private enum SessionState: Equatable {
        case opening
        case open
        case closing
    }

    private struct SessionRecord {
        let owner: ARM64GuestPTYOwner
        let sessionID: UInt32
        let stream: AsyncThrowingStream<ARM64GuestPTYEvent, Error>
        let streamContinuation: AsyncThrowingStream<ARM64GuestPTYEvent, Error>.Continuation
        var state: SessionState
        var openContinuation: CheckedContinuation<AsyncThrowingStream<ARM64GuestPTYEvent, Error>, Error>?
        var closeContinuation: CheckedContinuation<Int32?, Error>?
        var watchdog: Task<Void, Never>?
#if DEBUG
        var lastProgress: String? = nil
#endif
    }

    private static let maxSessions = 4
    private static let closeTimeoutSeconds: UInt64 = 5
    private let transport: ARM64GuestSerialTransport
    private let directory: ARM64GuestPTYSessionDirectory
    private var decoder = ARM64GuestPTYDecoder()
    private var receiveContinuation: AsyncStream<Data>.Continuation?
    private var receiveTask: Task<Void, Never>?
    private var sessions: [UInt32: SessionRecord] = [:]
    private var started = false
    private var isClosed = false
    private var guestReady = false
    private var readyChallenge: Data?
    private var readyContinuation: CheckedContinuation<Void, Error>?
    private var readyWatchdog: Task<Void, Never>?

    public init(
        transport: ARM64GuestSerialTransport,
        directory: ARM64GuestPTYSessionDirectory = ARM64GuestPTYSessionDirectory()
    ) {
        self.transport = transport
        self.directory = directory
    }

    public func start() {
        guard !started, !isClosed else { return }
        started = true
        let incoming = AsyncStream<Data>.makeStream(bufferingPolicy: .bufferingOldest(128))
        receiveContinuation = incoming.continuation
        receiveTask = Task { [weak self] in
            for await bytes in incoming.stream {
                guard let self else { return }
                await self.receive(bytes)
            }
        }
        transport.setReceiveHandler { [weak self] bytes in
            guard let self else { return }
            switch incoming.continuation.yield(bytes) {
            case .enqueued:
                break
            case .dropped:
                Task { await self.receiveOverflow() }
            case .terminated:
                break
            @unknown default:
                Task { await self.receiveOverflow() }
            }
        }
        transport.setCloseHandler { [weak self] in
            Task { await self?.transportDidClose() }
        }
    }

    public func waitUntilReady(timeoutSeconds: UInt64 = 30) async throws {
        if guestReady { return }
        guard started, !isClosed else { throw ARM64GuestPTYProtocolError.transportClosed }
        guard readyContinuation == nil else { throw ARM64GuestPTYProtocolError.guestNotReady }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let challenge = Data(UUID().uuidString.utf8)
            readyChallenge = challenge
            readyContinuation = continuation
            readyWatchdog = Task { [weak self] in
                do {
                    try await Task.sleep(nanoseconds: min(max(1, timeoutSeconds), 300) * 1_000_000_000)
                } catch {
                    return
                }
                await self?.failReadiness(ARM64GuestPTYProtocolError.timeout("agent startup"))
            }
            do {
                try transmit(ARM64GuestPTYFrame(type: .ping, sessionID: 0, payload: challenge))
            } catch {
                readyWatchdog?.cancel()
                readyWatchdog = nil
                readyChallenge = nil
                readyContinuation = nil
                continuation.resume(throwing: error)
            }
        }
    }

    public func open(
        owner: ARM64GuestPTYOwner,
        rows: UInt16 = 24,
        columns: UInt16 = 80,
        timeoutSeconds: UInt64 = 15
    ) async throws -> AsyncThrowingStream<ARM64GuestPTYEvent, Error> {
        guard guestReady, !isClosed else { throw ARM64GuestPTYProtocolError.guestNotReady }
        guard rows >= 2, rows <= 300, columns >= 2, columns <= 500 else {
            throw ARM64GuestPTYProtocolError.invalidDimensions
        }
        guard sessions.count < Self.maxSessions else {
            throw ARM64GuestPTYProtocolError.sessionLimitReached
        }
        let sessionID = try await directory.sessionID(for: owner)
        guard sessions[sessionID] == nil else { throw ARM64GuestPTYProtocolError.sessionNotOpen }
        do {
            try Task.checkCancellation()
        } catch {
            await directory.revoke(owner: owner)
            throw error
        }
        guard sessions.count < Self.maxSessions else {
            await directory.revoke(owner: owner)
            throw ARM64GuestPTYProtocolError.sessionLimitReached
        }

        var payload = Data()
        payload.append(UInt8(rows >> 8))
        payload.append(UInt8(rows & 0xff))
        payload.append(UInt8(columns >> 8))
        payload.append(UInt8(columns & 0xff))

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<AsyncThrowingStream<ARM64GuestPTYEvent, Error>, Error>) in
                guard !Task.isCancelled else {
                    Task { [directory] in await directory.revoke(owner: owner) }
                    continuation.resume(throwing: CancellationError())
                    return
                }
                var streamContinuation: AsyncThrowingStream<ARM64GuestPTYEvent, Error>.Continuation!
                let stream = AsyncThrowingStream<ARM64GuestPTYEvent, Error>(bufferingPolicy: .bufferingOldest(64)) {
                    streamContinuation = $0
                }
                streamContinuation.onTermination = { [weak self] termination in
                    guard case .cancelled = termination else { return }
                    Task { await self?.cancelSession(for: owner) }
                }
                var record = SessionRecord(
                    owner: owner,
                    sessionID: sessionID,
                    stream: stream,
                    streamContinuation: streamContinuation,
                    state: .opening,
                    openContinuation: continuation,
                    closeContinuation: nil,
                    watchdog: nil
                )
                record.watchdog = Task { [weak self] in
                    do {
                        try await Task.sleep(nanoseconds: min(max(1, timeoutSeconds), 120) * 1_000_000_000)
                    } catch {
                        return
                    }
                    await self?.expireSession(sessionID, state: .opening, operation: "shell startup")
                }
                sessions[sessionID] = record
                do {
                    try transmit(ARM64GuestPTYFrame(type: .create, sessionID: sessionID, payload: payload))
                } catch {
                    Task { [directory] in await directory.revoke(owner: owner) }
                    record.watchdog?.cancel()
                    record.streamContinuation.finish(throwing: error)
                    continuation.resume(throwing: error)
                    sessions.removeValue(forKey: sessionID)
                }
            }
        } onCancel: {
            Task { [weak self] in await self?.cancelSession(for: owner) }
        }
    }

    public func sendInput(_ data: Data, from owner: ARM64GuestPTYOwner) async throws {
        guard data.count <= ARM64GuestPTYCodec.maxPayloadBytes else {
            throw ARM64GuestPTYProtocolError.frameTooLarge(data.count)
        }
        let record = try await authorizedSession(for: owner)
        guard record.state == .open else { throw ARM64GuestPTYProtocolError.sessionNotOpen }
        try transmit(ARM64GuestPTYFrame(type: .input, sessionID: record.sessionID, payload: data))
    }

    public func resize(owner: ARM64GuestPTYOwner, rows: UInt16, columns: UInt16) async throws {
        guard rows >= 2, rows <= 300, columns >= 2, columns <= 500 else {
            throw ARM64GuestPTYProtocolError.invalidDimensions
        }
        let record = try await authorizedSession(for: owner)
        guard record.state == .open else { throw ARM64GuestPTYProtocolError.sessionNotOpen }
        var payload = Data()
        payload.append(UInt8(rows >> 8))
        payload.append(UInt8(rows & 0xff))
        payload.append(UInt8(columns >> 8))
        payload.append(UInt8(columns & 0xff))
        try transmit(ARM64GuestPTYFrame(type: .resize, sessionID: record.sessionID, payload: payload))
    }

    @discardableResult
    public func close(owner: ARM64GuestPTYOwner) async throws -> Int32? {
        guard let sessionID = await directory.existingSessionID(for: owner),
              let existing = sessions[sessionID], existing.owner == owner else {
            throw ARM64GuestPTYProtocolError.ownerNotAuthorized
        }
        guard existing.state == .open else { throw ARM64GuestPTYProtocolError.sessionNotOpen }

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int32?, Error>) in
            guard var record = sessions[sessionID], record.owner == owner, record.state == .open else {
                continuation.resume(throwing: ARM64GuestPTYProtocolError.ownerNotAuthorized)
                return
            }
            record.state = .closing
            record.closeContinuation = continuation
            record.watchdog = Task { [weak self] in
                do {
                    try await Task.sleep(nanoseconds: Self.closeTimeoutSeconds * 1_000_000_000)
                } catch {
                    return
                }
                await self?.expireSession(sessionID, state: .closing, operation: "shell close")
            }
            sessions[sessionID] = record
            do {
                try transmit(ARM64GuestPTYFrame(type: .close, sessionID: sessionID))
            } catch {
                Task { [directory] in await directory.revoke(owner: owner) }
                record.watchdog?.cancel()
                record.streamContinuation.finish(throwing: error)
                continuation.resume(throwing: error)
                sessions.removeValue(forKey: sessionID)
            }
        }
    }

    public func stop() async {
        await terminate(with: ARM64GuestPTYProtocolError.transportClosed)
    }

    public func activeSessionCount() -> Int { sessions.count }

    private func authorizedSession(for owner: ARM64GuestPTYOwner) async throws -> SessionRecord {
        guard let sessionID = await directory.existingSessionID(for: owner),
              let record = sessions[sessionID], record.owner == owner,
              await directory.authorize(guestSessionID: sessionID, for: owner) else {
            throw ARM64GuestPTYProtocolError.ownerNotAuthorized
        }
        return record
    }

    private func receive(_ bytes: Data) async {
        guard !isClosed else { return }
        do {
            for frame in try decoder.push(bytes) {
                await handle(frame)
            }
        } catch {
            await terminate(with: error)
        }
    }

    private func receiveOverflow() async {
        await terminate(with: ARM64GuestPTYProtocolError.outputBackpressure)
    }

    private func handle(_ frame: ARM64GuestPTYFrame) async {
        if frame.sessionID == 0 {
            switch frame.type {
            case .ready:
                markGuestReady()
            case .pong where frame.payload == readyChallenge:
                markGuestReady()
            case .error:
                failReadiness(ARM64GuestPTYProtocolError.guestNotReady)
            default:
                break
            }
            return
        }

        guard var record = sessions[frame.sessionID] else { return }
        switch frame.type {
        case .ready:
            guard record.state == .opening else { return }
            record.state = .open
            record.watchdog?.cancel()
            record.watchdog = nil
            let continuation = record.openContinuation
            record.openContinuation = nil
            sessions[frame.sessionID] = record
            continuation?.resume(returning: record.stream)
        case .output:
            switch record.streamContinuation.yield(.output(frame.payload)) {
            case .enqueued:
                break
            case .dropped:
                await requestSessionClose(frame.sessionID, error: ARM64GuestPTYProtocolError.outputBackpressure)
            case .terminated:
                await requestSessionClose(frame.sessionID, error: CancellationError())
            @unknown default:
                await finishSession(frame.sessionID, error: ARM64GuestPTYProtocolError.invalidFrame)
            }
        case .exit:
            guard frame.payload.count == 4 else {
                await finishSession(frame.sessionID, error: ARM64GuestPTYProtocolError.invalidFrame)
                return
            }
            let exitStatus = Int32(bitPattern: Self.readUInt32(frame.payload))
            _ = record.streamContinuation.yield(.exited(exitStatus))
            await finishSession(frame.sessionID, exitStatus: exitStatus)
        case .error:
            let message = String(data: frame.payload, encoding: .utf8) ?? "Guest PTY agent error."
            let error = ARM64GuestPTYProtocolError.guestRejected(message)
            if record.state == .closing {
                await finishSession(frame.sessionID, error: error)
            } else {
                await requestSessionClose(frame.sessionID, error: error)
            }
        case .progress:
#if DEBUG
            guard record.state == .opening,
                  frame.payload.count <= 32,
                  let stage = String(data: frame.payload, encoding: .utf8),
                  stage.utf8.allSatisfy({ ($0 >= 0x61 && $0 <= 0x7a) || $0 == 0x2d }) else { return }
            record.lastProgress = stage
            sessions[frame.sessionID] = record
            print("DSBOT_GUEST_PTY_STAGE \(stage)")
#endif
            return
        default:
            break
        }
    }

    private func markGuestReady() {
        guestReady = true
        readyWatchdog?.cancel()
        readyWatchdog = nil
        readyChallenge = nil
        let continuation = readyContinuation
        readyContinuation = nil
        continuation?.resume()
    }

    private func failReadiness(_ error: Error) {
        readyWatchdog?.cancel()
        readyWatchdog = nil
        readyChallenge = nil
        let continuation = readyContinuation
        readyContinuation = nil
        continuation?.resume(throwing: error)
    }

    private func expireSession(_ sessionID: UInt32, state expectedState: SessionState, operation: String) async {
        guard sessions[sessionID]?.state == expectedState else { return }
        if expectedState == .opening {
#if DEBUG
            if let stage = sessions[sessionID]?.lastProgress {
                print("DSBOT_GUEST_PTY_TIMEOUT last-stage=\(stage)")
            } else {
                print("DSBOT_GUEST_PTY_TIMEOUT no-guest-stage")
            }
#endif
            await requestSessionClose(sessionID, error: ARM64GuestPTYProtocolError.timeout(operation))
        } else {
            await finishSession(sessionID, error: ARM64GuestPTYProtocolError.timeout(operation))
        }
    }

    private func cancelSession(for owner: ARM64GuestPTYOwner) async {
        guard let sessionID = await directory.existingSessionID(for: owner),
              let record = sessions[sessionID], record.owner == owner else { return }
        guard record.state != .closing else { return }
        await requestSessionClose(sessionID, error: CancellationError())
    }

    /// Close the guest PTY while keeping its slot reserved until EXIT or a bounded
    /// cleanup timeout. Dropping the host record immediately can overbook the guest
    /// while it is still terminating descendants under the session UID.
    private func requestSessionClose(_ sessionID: UInt32, error: Error) async {
        guard var record = sessions[sessionID] else { return }
        guard record.state != .closing else { return }

        record.state = .closing
        record.watchdog?.cancel()
        record.watchdog = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: Self.closeTimeoutSeconds * 1_000_000_000)
            } catch {
                return
            }
            await self?.expireSession(sessionID, state: .closing, operation: "shell cleanup")
        }
        let openContinuation = record.openContinuation
        record.openContinuation = nil
        let closeContinuation = record.closeContinuation
        record.closeContinuation = nil
        sessions[sessionID] = record

        record.streamContinuation.finish(throwing: error)
        openContinuation?.resume(throwing: error)
        closeContinuation?.resume(throwing: error)

        do {
            try transmit(ARM64GuestPTYFrame(type: .close, sessionID: sessionID))
        } catch {
            await finishSession(sessionID, error: error)
        }
    }

    private func finishSession(_ sessionID: UInt32, error: Error? = nil, exitStatus: Int32? = nil) async {
        guard let record = sessions.removeValue(forKey: sessionID) else { return }
        record.watchdog?.cancel()
        record.streamContinuation.finish(throwing: error)
        if let continuation = record.openContinuation {
            continuation.resume(throwing: error ?? ARM64GuestPTYProtocolError.sessionNotOpen)
        }
        if let continuation = record.closeContinuation {
            if let error { continuation.resume(throwing: error) }
            else { continuation.resume(returning: exitStatus) }
        }
        await directory.revoke(owner: record.owner)
    }

    private func terminate(with error: Error) async {
        guard !isClosed else { return }
        isClosed = true
        receiveContinuation?.finish()
        receiveContinuation = nil
        receiveTask?.cancel()
        receiveTask = nil
        guestReady = false
        failReadiness(error)
        transport.setReceiveHandler(nil)
        transport.setCloseHandler(nil)
        transport.close()
        for sessionID in Array(sessions.keys) {
            await finishSession(sessionID, error: error)
        }
    }

    private func transportDidClose() async {
        await terminate(with: ARM64GuestPTYProtocolError.transportClosed)
    }

    private func transmit(_ frame: ARM64GuestPTYFrame) throws {
        guard !isClosed else { throw ARM64GuestPTYProtocolError.transportClosed }
        try transport.send(ARM64GuestPTYCodec.encode(frame))
    }

    private static func readUInt32(_ data: Data) -> UInt32 {
        data.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }
}

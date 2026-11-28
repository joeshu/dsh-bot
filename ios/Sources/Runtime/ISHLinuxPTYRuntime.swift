#if DSBOT_ISH_RUNTIME_ENABLED
import Foundation

extension ISHKernelBridge: @unchecked Sendable {}

/// Coalesces the character-sized writes produced by a pasted shell command
/// into bounded output frames before they reach AsyncThrowingStream.
private final class ISHPTYOutputBuffer: @unchecked Sendable {
    private static let maxPendingBytes = 256 * 1024
    private static let maxChunkBytes = 8 * 1024

    private let lock = NSLock()
    private let queue = DispatchQueue(label: "io.github.dsbot.ish-pty-output", qos: .userInitiated)
    private let continuation: AsyncThrowingStream<ARM64GuestPTYEvent, Error>.Continuation
    private let onBackpressure: @Sendable () -> Void
    private var pending = Data()
    private var flushScheduled = false
    private var closed = false
    private var backpressureReported = false

    init(
        continuation: AsyncThrowingStream<ARM64GuestPTYEvent, Error>.Continuation,
        onBackpressure: @escaping @Sendable () -> Void
    ) {
        self.continuation = continuation
        self.onBackpressure = onBackpressure
    }

    func append(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        guard !closed else { lock.unlock(); return }
        guard data.count <= Self.maxPendingBytes - pending.count else {
            lock.unlock()
            failBackpressure()
            return
        }
        pending.append(data)
        let shouldScheduleFlush = !flushScheduled
        flushScheduled = true
        lock.unlock()

        if shouldScheduleFlush {
            queue.asyncAfter(deadline: .now() + .milliseconds(2)) { [weak self] in
                self?.flushOneChunk()
            }
        }
    }

    func finish(status: Int32? = nil, error: Error? = nil) {
        lock.lock()
        guard !closed else { lock.unlock(); return }
        closed = true
        lock.unlock()

        queue.async { [self] in
            while let chunk = takeChunk() {
                guard yieldOutput(chunk) else { return }
            }
            if let status {
                switch continuation.yield(.exited(status)) {
                case .enqueued:
                    break
                case .dropped:
                    failBackpressure()
                    return
                case .terminated:
                    return
                @unknown default:
                    failBackpressure()
                    return
                }
            }
            if let error {
                continuation.finish(throwing: error)
            } else {
                continuation.finish()
            }
        }
    }

    private func flushOneChunk() {
        guard let chunk = takeChunk() else { return }
        guard yieldOutput(chunk) else { return }
        lock.lock()
        let hasPending = !pending.isEmpty
        if !hasPending { flushScheduled = false }
        lock.unlock()
        if hasPending {
            queue.asyncAfter(deadline: .now() + .milliseconds(2)) { [weak self] in
                self?.flushOneChunk()
            }
        }
    }

    private func takeChunk() -> Data? {
        lock.lock()
        defer { lock.unlock() }
        guard !pending.isEmpty else {
            flushScheduled = false
            return nil
        }
        let count = min(pending.count, Self.maxChunkBytes)
        let chunk = Data(pending.prefix(count))
        pending.removeFirst(count)
        return chunk
    }

    private func yieldOutput(_ data: Data) -> Bool {
        switch continuation.yield(.output(data)) {
        case .enqueued:
            return true
        case .dropped:
            failBackpressure()
            return false
        case .terminated:
            lock.lock()
            closed = true
            pending.removeAll(keepingCapacity: false)
            flushScheduled = false
            lock.unlock()
            return false
        @unknown default:
            failBackpressure()
            return false
        }
    }

    private func failBackpressure() {
        lock.lock()
        let shouldNotify = !backpressureReported
        backpressureReported = true
        closed = true
        pending.removeAll(keepingCapacity: false)
        flushScheduled = false
        lock.unlock()
        continuation.finish(throwing: ARM64GuestPTYProtocolError.outputBackpressure)
        if shouldNotify { onBackpressure() }
    }
}

/// iSH host actor behind the same DSH Bot and Web PTY contract used by QEMU.
/// The rootfs is installed once and mounted for the app lifetime; each owner
/// receives a host-generated PTY lease and cannot supply a host path.
public actor ISHLinuxPTYRuntime: LinuxPTYRuntime {
    public static let shared = ISHLinuxPTYRuntime()

    private struct Lease {
        let id: String
        let outputBuffer: ISHPTYOutputBuffer
    }

    private let bridge = ISHKernelBridge.shared()
    private var leases: [ARM64GuestPTYOwner: Lease] = [:]
    private var openingOwners: Set<ARM64GuestPTYOwner> = []
    private var installedRootfsURL: URL?
    private var booted = false
    private var bootTask: Task<Void, Error>?
    private var stopInProgress = false

    public init() {}

    public func validateBundledResources() async throws {
        installedRootfsURL = try await ISHRootfsStore.shared.installIfNeeded()
    }

    public func openPTY(
        owner: ARM64GuestPTYOwner,
        rows: UInt16 = 24,
        columns: UInt16 = 80,
        timeoutSeconds: UInt64 = 120
    ) async throws -> AsyncThrowingStream<ARM64GuestPTYEvent, Error> {
        guard !stopInProgress else { throw ARM64GuestPTYProtocolError.guestNotReady }
        guard rows >= 2, rows <= 300, columns >= 2, columns <= 500 else {
            throw ARM64GuestPTYProtocolError.invalidDimensions
        }
        guard leases[owner] == nil, openingOwners.insert(owner).inserted else {
            throw ARM64GuestPTYProtocolError.sessionNotOpen
        }
        defer { openingOwners.remove(owner) }
        try Task.checkCancellation()
        try await ensureBooted(timeoutSeconds: timeoutSeconds)
        try Task.checkCancellation()
        guard !stopInProgress else { throw ARM64GuestPTYProtocolError.guestNotReady }

        let sessionID = UUID().uuidString.lowercased()
        let pair = AsyncThrowingStream<ARM64GuestPTYEvent, Error>.makeStream(
            // 256 KiB of pending bytes are emitted as at most 32 chunks;
            // reserve one additional event for the exit status even when
            // the consumer is briefly suspended during process teardown.
            bufferingPolicy: .bufferingOldest(64)
        )
        let continuation = pair.continuation
        let outputBuffer = ISHPTYOutputBuffer(continuation: continuation) { [weak self] in
            Task { await self?.closePTY(owner: owner) }
        }
        continuation.onTermination = { [weak self] termination in
            guard case .cancelled = termination else { return }
            Task { await self?.closePTY(owner: owner) }
        }

        if let error = bridge.openSession(
            id: sessionID,
            rows: UInt(rows),
            columns: UInt(columns),
            outputHandler: { data in
                outputBuffer.append(data)
            },
            exitHandler: { [weak self] status in
                outputBuffer.finish(status: status)
                Task { await self?.reapCompleted(owner: owner, sessionID: sessionID) }
            }
        ) {
            outputBuffer.finish(error: error)
            throw error
        }
        do {
            try Task.checkCancellation()
        } catch {
            let bridge = self.bridge
            _ = await withCheckedContinuation { (closeContinuation: CheckedContinuation<Bool, Never>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    closeContinuation.resume(returning: bridge.close(id: sessionID))
                }
            }
            outputBuffer.finish(error: error)
            throw error
        }

        leases[owner] = Lease(id: sessionID, outputBuffer: outputBuffer)
        return pair.stream
    }

    public func sendInput(_ data: Data, owner: ARM64GuestPTYOwner) async throws {
        guard let lease = leases[owner] else { throw ARM64GuestPTYProtocolError.sessionNotOpen }
        guard data.count <= ARM64GuestPTYCodec.maxPayloadBytes else {
            throw ARM64GuestPTYProtocolError.frameTooLarge(data.count)
        }
        let bridge = self.bridge
        let error = await withCheckedContinuation { (continuation: CheckedContinuation<Error?, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: bridge.writeInput(data, sessionID: lease.id))
            }
        }
        if let error { throw error }
    }

    public func resize(owner: ARM64GuestPTYOwner, rows: UInt16, columns: UInt16) async throws {
        guard let lease = leases[owner] else { throw ARM64GuestPTYProtocolError.sessionNotOpen }
        guard rows >= 2, rows <= 300, columns >= 2, columns <= 500 else {
            throw ARM64GuestPTYProtocolError.invalidDimensions
        }
        guard bridge.resize(id: lease.id, rows: UInt(rows), columns: UInt(columns)) else {
            throw ARM64GuestPTYProtocolError.sessionNotOpen
        }
    }

    public func closePTY(owner: ARM64GuestPTYOwner) async {
        guard let lease = leases[owner] else { return }
        let bridge = self.bridge
        let closed = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: bridge.close(id: lease.id))
            }
        }
        if closed, leases[owner]?.id == lease.id {
            leases.removeValue(forKey: owner)
            lease.outputBuffer.finish()
        }
    }

    public func stop() async {
        guard !stopInProgress else { return }
        stopInProgress = true
        defer { stopInProgress = false }
        let owners = Array(leases.keys)
        for owner in owners { await closePTY(owner: owner) }
        bridge.closeAllSessions()
    }

    private func reapCompleted(owner: ARM64GuestPTYOwner, sessionID: String) async {
        guard let lease = leases[owner], lease.id == sessionID else { return }
        let bridge = self.bridge
        let closed = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: bridge.close(id: sessionID))
            }
        }
        guard closed, leases[owner]?.id == sessionID else { return }
        leases.removeValue(forKey: owner)
        lease.outputBuffer.finish()
    }

    private func ensureBooted(timeoutSeconds: UInt64) async throws {
        guard !booted else { return }
        let task: Task<Void, Error>
        if let bootTask {
            task = bootTask
        } else {
            task = Task { [weak self] in
                guard let self else { throw CancellationError() }
                try await self.bootEngine(timeoutSeconds: timeoutSeconds)
            }
            bootTask = task
        }
        do {
            try await task.value
            booted = true
            bootTask = nil
        } catch {
            bootTask = nil
            throw error
        }
    }

    private func bootEngine(timeoutSeconds: UInt64) async throws {
        let root: URL
        if let installedRootfsURL {
            root = installedRootfsURL
        } else {
            root = try await ISHRootfsStore.shared.installIfNeeded()
            installedRootfsURL = root
        }
        // Expose only user project files. The DSH home directory also holds
        // SQLite state and runtime metadata that a shell must never see.
        let workspace = LocalAgentTransport.defaultWorkspace
            .appendingPathComponent("files", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try Self.validateWorkspaceContainsNoSymbolicLinks(workspace)
        let bridge = self.bridge
        let error = await withCheckedContinuation { (continuation: CheckedContinuation<Error?, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: bridge.boot(
                    rootPath: root.path,
                    workspacePath: workspace.path,
                    timeoutSeconds: TimeInterval(timeoutSeconds)
                ))
            }
        }
        if let error { throw error }
    }

    private static func validateWorkspaceContainsNoSymbolicLinks(_ workspace: URL) throws {
        let fileManager = FileManager.default
        let attributes = try fileManager.attributesOfItem(atPath: workspace.path)
        guard (attributes[.type] as? FileAttributeType) == .typeDirectory else {
            throw ARM64GuestPTYProtocolError.guestRejected("The DSH project root is not a directory.")
        }
        var pending = [workspace]
        while let entry = pending.popLast() {
            let values = try entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else {
                throw ARM64GuestPTYProtocolError.guestRejected(
                    "The DSH project contains a symbolic link; remove it before opening the iSH terminal."
                )
            }
            if values.isDirectory == true {
                pending.append(contentsOf: try fileManager.contentsOfDirectory(
                    at: entry,
                    includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                    options: []
                ))
            }
        }
    }
}
#endif

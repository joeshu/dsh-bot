import Foundation

/// Backend-neutral operations used by DSH tools and both terminal surfaces.
/// An iSH implementation can replace the QEMU adapter without changing RPC
/// or DSH's subprocess compatibility layer.
public protocol LinuxPTYRuntime: Sendable {
    func validateBundledResources() async throws
    func openPTY(
        owner: ARM64GuestPTYOwner,
        rows: UInt16,
        columns: UInt16,
        timeoutSeconds: UInt64
    ) async throws -> AsyncThrowingStream<ARM64GuestPTYEvent, Error>
    func sendInput(_ data: Data, owner: ARM64GuestPTYOwner) async throws
    func resize(owner: ARM64GuestPTYOwner, rows: UInt16, columns: UInt16) async throws
    func closePTY(owner: ARM64GuestPTYOwner) async
    func stop() async
}

/// Single selection point for process and terminal callers. Keep QEMU selected
/// until the iSH bridge passes the same runtime contract and acceptance gates.
public enum LinuxPTYRuntimeRegistry {
#if DSBOT_ISH_RUNTIME_ENABLED
    public static let shared: any LinuxPTYRuntime = ISHLinuxPTYRuntime.shared
#else
    public static let shared: any LinuxPTYRuntime = QEMULinuxPTYRuntime.shared
#endif
}

/// Adapts the existing authenticated QEMU serial broker to the common PTY
/// contract. The broker remains responsible for owner/session authentication;
/// this layer owns the runtime lease for each open PTY.
public actor QEMULinuxPTYRuntime: LinuxPTYRuntime {
    public static let shared = QEMULinuxPTYRuntime()

    private let runtime: ARM64GuestQEMURuntime
    private var brokersByOwner: [ARM64GuestPTYOwner: ARM64GuestPTYBroker] = [:]

    public init(runtime: ARM64GuestQEMURuntime = .shared) {
        self.runtime = runtime
    }

    public func validateBundledResources() async throws {
        try await runtime.validateBundledResources()
    }

    public func openPTY(
        owner: ARM64GuestPTYOwner,
        rows: UInt16 = 24,
        columns: UInt16 = 80,
        timeoutSeconds: UInt64 = 120
    ) async throws -> AsyncThrowingStream<ARM64GuestPTYEvent, Error> {
        let broker = try await runtime.acquirePTYLease()
        do {
            let stream = try await broker.open(
                owner: owner,
                rows: rows,
                columns: columns,
                timeoutSeconds: timeoutSeconds
            )
            brokersByOwner[owner] = broker
            return stream
        } catch {
            await runtime.releasePTYLease()
            throw error
        }
    }

    public func sendInput(_ data: Data, owner: ARM64GuestPTYOwner) async throws {
        guard let broker = brokersByOwner[owner] else {
            throw ARM64GuestPTYProtocolError.sessionNotOpen
        }
        try await broker.sendInput(data, from: owner)
    }

    public func resize(owner: ARM64GuestPTYOwner, rows: UInt16, columns: UInt16) async throws {
        guard let broker = brokersByOwner[owner] else {
            throw ARM64GuestPTYProtocolError.sessionNotOpen
        }
        try await broker.resize(owner: owner, rows: rows, columns: columns)
    }

    public func closePTY(owner: ARM64GuestPTYOwner) async {
        guard let broker = brokersByOwner.removeValue(forKey: owner) else { return }
        try? await broker.close(owner: owner)
        await runtime.releasePTYLease()
    }

    public func stop() async {
        let opened = brokersByOwner
        brokersByOwner.removeAll()
        for (owner, broker) in opened {
            try? await broker.close(owner: owner)
        }
        await runtime.stop()
    }
}

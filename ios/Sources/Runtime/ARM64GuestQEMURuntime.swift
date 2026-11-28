import Darwin
import Foundation

public enum ARM64GuestQEMURuntimeError: Error, LocalizedError {
    case guestRuntimeNotBundled
    case qemuFrameworkNotBundled
    case qemuLoadFailed(String)
    case qemuEntryPointMissing(String)
    case qemuInitFailed(Int32)
    case qemuInitTimedOut
    case socketPathTooLong
    case socketConnectionTimedOut(String)
    case qemuExited

    public var errorDescription: String? {
        switch self {
        case .guestRuntimeNotBundled:
            return "ARM64 Linux guest image is not included in this app build."
        case .qemuFrameworkNotBundled:
            return "The ARM64 iOS TCI/QEMU framework is not included in this app build."
        case .qemuLoadFailed(let message):
            return "Could not load the ARM64 iOS QEMU runtime: \(message)"
        case .qemuEntryPointMissing(let name):
            return "The ARM64 iOS QEMU runtime is missing \(name)."
        case .qemuInitFailed(let status):
            return "QEMU initialization failed with status \(status)."
        case .qemuInitTimedOut:
            return "QEMU did not finish initialization before the startup deadline."
        case .socketPathTooLong:
            return "The private QEMU Unix socket path exceeds the platform limit."
        case .socketConnectionTimedOut(let name):
            return "QEMU did not open its private \(name) Unix socket before the startup deadline."
        case .qemuExited:
            return "The ARM64 guest runtime exited. Start the terminal again to launch a fresh guest."
        }
    }
}

/// Owns one in-process QEMU TCI instance and the authenticated serial broker.
/// QEMU is launched lazily and stays alive for this app process; no guest process,
/// TCP port or network-backed serial endpoint is created by the host.
public actor ARM64GuestQEMURuntime {
    public static let shared = ARM64GuestQEMURuntime()

    private typealias QEMUInit = @convention(c) (
        Int32,
        UnsafePointer<UnsafePointer<CChar>?>?,
        UnsafePointer<UnsafePointer<CChar>?>?
    ) -> Int32
    private typealias QEMUMainLoop = @convention(c) () -> Void
    private typealias QEMUCleanup = @convention(c) () -> Void

    private struct QEMUFunctions: @unchecked Sendable {
        let initialize: QEMUInit
        let mainLoop: QEMUMainLoop
        let cleanup: QEMUCleanup
    }

    private final class ThreadState: @unchecked Sendable {
        private let lock = NSLock()
        private var initializationStatus: Int32?
        private var exited = false

        func didInitialize(_ status: Int32) {
            lock.lock()
            initializationStatus = status
            lock.unlock()
        }

        func didExit() {
            lock.lock()
            exited = true
            lock.unlock()
        }

        func result() -> (initializationStatus: Int32?, exited: Bool) {
            lock.lock()
            defer { lock.unlock() }
            return (initializationStatus, exited)
        }
    }

    private var startupTask: Task<ARM64GuestPTYBroker, Error>?
    private var startupGeneration: UUID?
    private var qemuTask: Task<Void, Never>?
    private var shutdownTask: Task<Void, Never>?
    private var idleShutdownTask: Task<Void, Never>?
    private var idleShutdownGeneration: UUID?
    private var ptyLeaseCount = 0
    private var qemuHandle: UnsafeMutableRawPointer?
    private var qemuFunctions: QEMUFunctions?
    private var threadState: ThreadState?
    private var serialTransport: ARM64GuestUnixSocketTransport?
    private var ptyBroker: ARM64GuestPTYBroker?
    private var qmpFileDescriptor: Int32?
    private var socketDirectoryURL: URL?
    private var hasLaunchedQEMU = false
    private let bundle: Bundle

    public init(bundle: Bundle = .main) { self.bundle = bundle }

    public func start() async throws -> ARM64GuestPTYBroker {
        while let shutdownTask { await shutdownTask.value }
        if let ptyBroker {
            try await ptyBroker.waitUntilReady(timeoutSeconds: 1)
            return ptyBroker
        }
        if let startupTask, let generation = startupGeneration {
            return try await awaitStartup(startupTask, generation: generation)
        }
        guard !hasLaunchedQEMU else { throw ARM64GuestQEMURuntimeError.qemuExited }

        let generation = UUID()
        let task = Task { try await self.createRuntime() }
        startupTask = task
        startupGeneration = generation
        return try await awaitStartup(task, generation: generation)
    }

    private func awaitStartup(
        _ task: Task<ARM64GuestPTYBroker, Error>,
        generation: UUID
    ) async throws -> ARM64GuestPTYBroker {
        let broker: ARM64GuestPTYBroker
        do {
            broker = try await task.value
        } catch {
            if startupGeneration == generation {
                await stop()
            }
            throw error
        }
        if startupGeneration != generation {
            // Another waiter may have committed the same shared startup first.
            // Only an explicit stop/exit invalidates the result in that case.
            guard ptyBroker === broker else {
                await broker.stop()
                throw CancellationError()
            }
        } else {
            ptyBroker = broker
            startupTask = nil
            startupGeneration = nil
        }
        // Cancellation belongs to the waiter. The shared guest remains available
        // for other owners that joined the same startup operation.
        if Task.isCancelled { throw CancellationError() }
        return broker
    }

    public func brokerIfStarted() -> ARM64GuestPTYBroker? { ptyBroker }

    /// Keep the shared guest alive while a caller has an active or opening PTY.
    public func acquirePTYLease() async throws -> ARM64GuestPTYBroker {
        while let shutdownTask { await shutdownTask.value }
        idleShutdownTask?.cancel()
        idleShutdownTask = nil
        idleShutdownGeneration = nil
        ptyLeaseCount += 1
        do {
            return try await start()
        } catch {
            ptyLeaseCount = max(0, ptyLeaseCount - 1)
            if ptyLeaseCount == 0 { scheduleIdleShutdown() }
            throw error
        }
    }

    public func releasePTYLease() {
        guard ptyLeaseCount > 0 else { return }
        ptyLeaseCount -= 1
        if ptyLeaseCount == 0 { scheduleIdleShutdown() }
    }

    public func validateBundledResources() throws {
        let guestDirectory = bundle.bundleURL.appendingPathComponent("DSBotGuestRuntime", isDirectory: true)
        let kernel = guestDirectory.appendingPathComponent("vmlinuz-virt")
        let initramfs = guestDirectory.appendingPathComponent("rootfs.cpio.gz")
        guard FileManager.default.fileExists(atPath: kernel.path),
              FileManager.default.fileExists(atPath: initramfs.path) else {
            throw ARM64GuestQEMURuntimeError.guestRuntimeNotBundled
        }
        let qemuBinary = bundle.bundleURL
            .appendingPathComponent("Frameworks", isDirectory: true)
            .appendingPathComponent("qemu-aarch64-softmmu.framework", isDirectory: true)
            .appendingPathComponent("qemu-aarch64-softmmu")
        guard FileManager.default.fileExists(atPath: qemuBinary.path) else {
            throw ARM64GuestQEMURuntimeError.qemuFrameworkNotBundled
        }
    }

    public func stop() async {
        if let shutdownTask {
            await shutdownTask.value
            return
        }
        let task = Task { await self.performStop() }
        shutdownTask = task
        await task.value
    }

    private func performStop() async {
        defer { shutdownTask = nil }
        idleShutdownTask?.cancel()
        idleShutdownTask = nil
        idleShutdownGeneration = nil
        ptyLeaseCount = 0
        let pendingStartup = startupTask
        pendingStartup?.cancel()
        startupTask = nil
        startupGeneration = nil
        if let ptyBroker {
            self.ptyBroker = nil
            await ptyBroker.stop()
        }
        serialTransport?.close()
        serialTransport = nil

        if let qemuTask, let threadState {
            let initializationDeadline = Date().addingTimeInterval(5)
            while threadState.result().initializationStatus == nil,
                  !threadState.result().exited,
                  Date() < initializationDeadline {
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            let state = threadState.result()
            if state.initializationStatus == 0 && !state.exited,
               let qmpFileDescriptor {
                try? await Task.detached(priority: .utility) {
                    try Self.requestQEMUQuit(fileDescriptor: qmpFileDescriptor)
                }.value
            }
            let exitDeadline = Date().addingTimeInterval(8)
            while !threadState.result().exited, Date() < exitDeadline {
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            guard threadState.result().exited else {
                // Never wait indefinitely for a wedged emulator. Keep its
                // framework loaded and the instance marked unusable; unloading
                // QEMU while its main loop is live would leave invalid code.
                print("DSBOT_QEMU_SHUTDOWN_TIMEOUT emulator remains loaded until app exit")
                return
            }
            await qemuTask.value
            return
        }
        qemuTask = nil
        threadState = nil
        qemuFunctions = nil
        if let qmpFileDescriptor {
            _ = Darwin.close(qmpFileDescriptor)
            self.qmpFileDescriptor = nil
        }
        removeSocketDirectory()
        if let qemuHandle {
            dlclose(qemuHandle)
            self.qemuHandle = nil
        }
    }

    private func scheduleIdleShutdown() {
        guard ptyLeaseCount == 0, ptyBroker != nil, shutdownTask == nil else { return }
        idleShutdownTask?.cancel()
        let generation = UUID()
        idleShutdownGeneration = generation
        idleShutdownTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 30_000_000_000) } catch { return }
            await self?.stopIfIdle(generation: generation)
        }
    }

    private func stopIfIdle(generation: UUID) async {
        guard idleShutdownGeneration == generation, ptyLeaseCount == 0 else { return }
        idleShutdownTask = nil
        idleShutdownGeneration = nil
        await stop()
    }

    private func createRuntime() async throws -> ARM64GuestPTYBroker {
        try Task.checkCancellation()
        try validateBundledResources()
        let guestDirectory = bundle.bundleURL.appendingPathComponent("DSBotGuestRuntime", isDirectory: true)
        let kernel = guestDirectory.appendingPathComponent("vmlinuz-virt")
        let initramfs = guestDirectory.appendingPathComponent("rootfs.cpio.gz")

        let qemuFramework = bundle.bundleURL
            .appendingPathComponent("Frameworks", isDirectory: true)
            .appendingPathComponent("qemu-aarch64-softmmu.framework", isDirectory: true)
        let qemuBinary = qemuFramework.appendingPathComponent("qemu-aarch64-softmmu")
        guard FileManager.default.fileExists(atPath: qemuBinary.path) else {
            throw ARM64GuestQEMURuntimeError.qemuFrameworkNotBundled
        }
        guard let handle = dlopen(qemuBinary.path, RTLD_NOW | RTLD_LOCAL) else {
            let message = dlerror().map { String(cString: $0) } ?? "unknown dynamic loader error"
            throw ARM64GuestQEMURuntimeError.qemuLoadFailed(message)
        }
        qemuHandle = handle

        func symbol<T>(_ name: String, as type: T.Type) throws -> T {
            guard let address = dlsym(handle, name) else {
                throw ARM64GuestQEMURuntimeError.qemuEntryPointMissing(name)
            }
            return unsafeBitCast(address, to: type)
        }
        let qemu = QEMUFunctions(
            initialize: try symbol("qemu_init", as: QEMUInit.self),
            mainLoop: try symbol("qemu_main_loop", as: QEMUMainLoop.self),
            cleanup: try symbol("qemu_cleanup", as: QEMUCleanup.self)
        )
        qemuFunctions = qemu
        try Task.checkCancellation()

        let socketDirectory = try Self.makePrivateSocketDirectory()
        socketDirectoryURL = socketDirectory
        let serialSocketPath = socketDirectory.appendingPathComponent("s", isDirectory: false).path
        let qmpSocketPath = socketDirectory.appendingPathComponent("q", isDirectory: false).path
        guard Self.isValidUnixSocketPath(serialSocketPath), Self.isValidUnixSocketPath(qmpSocketPath) else {
            throw ARM64GuestQEMURuntimeError.socketPathTooLong
        }

        // TCI is single-threaded; one guest CPU avoids software-emulation
        // scheduling overhead for this shell-focused workload.
        let arguments = [
            "dsbot-qemu",
            "-machine", "virt,gic-version=2",
            "-cpu", "max",
            "-m", "384M",
            "-smp", "1",
            "-accel", "tcg,thread=single",
            "-kernel", kernel.path,
            "-initrd", initramfs.path,
            "-append", "earlycon=pl011,mmio32,0x09000000 console=ttyAMA0,115200 loglevel=4 rdinit=/init panic=0",
            "-display", "none",
            "-monitor", "none",
            "-serial", "unix:\(serialSocketPath),server=on,wait=off",
            "-qmp", "unix:\(qmpSocketPath),server=on,wait=off",
            "-nic", "none",
            "-no-user-config",
            "-no-shutdown",
        ]
        let state = ThreadState()
        threadState = state
        hasLaunchedQEMU = true
        qemuTask = Task.detached(priority: .userInitiated) { [weak self] in
            let argvStrings = arguments.map { strdup($0)! }
            let environment = ["HOME=\(NSTemporaryDirectory())", "PATH=/usr/bin:/bin", "TMPDIR=\(NSTemporaryDirectory())"]
            let envStrings = environment.map { strdup($0)! }
            defer {
                argvStrings.forEach { free($0) }
                envStrings.forEach { free($0) }
            }
            let argv: [UnsafePointer<CChar>?] = argvStrings.map { UnsafePointer($0) } + [nil]
            let envp: [UnsafePointer<CChar>?] = envStrings.map { UnsafePointer($0) } + [nil]
            let status = argv.withUnsafeBufferPointer { argvBuffer in
                envp.withUnsafeBufferPointer { envBuffer in
                    qemu.initialize(Int32(argvStrings.count), argvBuffer.baseAddress, envBuffer.baseAddress)
                }
            }
            state.didInitialize(status)
            if status == 0 { qemu.mainLoop() }
            qemu.cleanup()
            state.didExit()
            await self?.qemuDidExit()
        }

        let initializationDeadline = Date().addingTimeInterval(10)
        while threadState?.result().initializationStatus == nil,
              threadState?.result().exited == false,
              Date() < initializationDeadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        guard let initialization = threadState?.result() else {
            throw ARM64GuestQEMURuntimeError.qemuExited
        }
        guard let status = initialization.initializationStatus else {
            throw ARM64GuestQEMURuntimeError.qemuInitTimedOut
        }
        guard status == 0 else {
            throw ARM64GuestQEMURuntimeError.qemuInitFailed(status)
        }
        let qmpDescriptor = try await Self.connectUnixSocket(at: qmpSocketPath, label: "QMP")
        qmpFileDescriptor = qmpDescriptor
        let serialDescriptor = try await Self.connectUnixSocket(at: serialSocketPath, label: "serial")
        let transport = ARM64GuestUnixSocketTransport(fileDescriptor: serialDescriptor)
        serialTransport = transport

        let broker = ARM64GuestPTYBroker(transport: transport)
        await broker.start()
        try await broker.waitUntilReady(timeoutSeconds: 120)
        return broker
    }

    private func qemuDidExit() async {
        if let ptyBroker {
            await ptyBroker.stop()
            self.ptyBroker = nil
        }
        serialTransport?.close()
        serialTransport = nil
        if let qmpFileDescriptor {
            _ = Darwin.close(qmpFileDescriptor)
            self.qmpFileDescriptor = nil
        }
        removeSocketDirectory()
        qemuTask = nil
        startupTask = nil
        startupGeneration = nil
        hasLaunchedQEMU = false
        threadState = nil
        qemuFunctions = nil
        if let qemuHandle {
            dlclose(qemuHandle)
            self.qemuHandle = nil
        }
    }

    private static func makePrivateSocketDirectory() throws -> URL {
#if targetEnvironment(simulator)
        let parent = URL(fileURLWithPath: "/tmp", isDirectory: true)
#else
        let parent = FileManager.default.temporaryDirectory
#endif
        let token = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12)).lowercased()
        let directory = parent.appendingPathComponent("q\(token)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        return directory
    }

    private static func isValidUnixSocketPath(_ path: String) -> Bool {
        let address = sockaddr_un()
        return path.utf8.count < MemoryLayout.size(ofValue: address.sun_path)
    }

    private static func connectUnixSocket(at path: String, label: String) async throws -> Int32 {
        let deadline = Date().addingTimeInterval(5)
        var lastError = ENOENT
        let pathBytes = Array(path.utf8) + [0]

        while Date() < deadline {
            let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
            guard descriptor >= 0 else { throw posixError(errno) }
            var noSignal: Int32 = 1
            _ = setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))

            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            let copied = withUnsafeMutableBytes(of: &address.sun_path) { destination in
                guard pathBytes.count <= destination.count else { return false }
                for (index, byte) in pathBytes.enumerated() {
                    destination[index] = byte
                }
                return true
            }
            guard copied else {
                _ = Darwin.close(descriptor)
                throw ARM64GuestQEMURuntimeError.socketPathTooLong
            }

            let socketLength = socklen_t(
                MemoryLayout<UInt8>.size + MemoryLayout<sa_family_t>.size + path.utf8.count
            )
            address.sun_len = UInt8(socketLength)
            let result = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(descriptor, $0, socketLength)
                }
            }
            if result == 0 { return descriptor }
            lastError = errno
            _ = Darwin.close(descriptor)
            guard lastError == ENOENT || lastError == ECONNREFUSED || lastError == EINTR else {
                throw posixError(lastError)
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        throw ARM64GuestQEMURuntimeError.socketConnectionTimedOut(label)
    }

    private func removeSocketDirectory() {
        guard let socketDirectoryURL else { return }
        try? FileManager.default.removeItem(at: socketDirectoryURL)
        self.socketDirectoryURL = nil
    }

    private static func requestQEMUQuit(fileDescriptor descriptor: Int32) throws {
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        _ = setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        _ = setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        _ = try readLine(from: descriptor) // QMP greeting
        try writeAll(descriptor, Data("{\"execute\":\"qmp_capabilities\",\"id\":1}\r\n".utf8))
        _ = try readLine(from: descriptor)
        try writeAll(descriptor, Data("{\"execute\":\"quit\",\"id\":2}\r\n".utf8))
    }

    private static func readLine(from descriptor: Int32) throws -> Data {
        var output = Data()
        var byte: UInt8 = 0
        while output.count < 8192 {
            let count = Darwin.recv(descriptor, &byte, 1, 0)
            if count == 1 {
                output.append(byte)
                if byte == 0x0a { return output }
            } else if count < 0 && errno == EINTR {
                continue
            } else {
                throw posixError(count < 0 ? errno : ECONNRESET)
            }
        }
        throw posixError(EMSGSIZE)
    }

    private static func writeAll(_ descriptor: Int32, _ data: Data) throws {
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.send(descriptor, base.advanced(by: offset), bytes.count - offset, 0)
                if count > 0 { offset += count }
                else if count < 0 && errno == EINTR { continue }
                else { throw posixError(count < 0 ? errno : EPIPE) }
            }
        }
    }

    private static func posixError(_ code: Int32) -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
    }
}

/// Serial socket adapter for QEMU's private Unix-domain PL011 chardev.
public final class ARM64GuestUnixSocketTransport: ARM64GuestSerialTransport, @unchecked Sendable {
    private let stateLock = NSLock()
    private let sendLock = NSLock()
    private var fileDescriptor: Int32
    private var receiveHandler: (@Sendable (Data) -> Void)?
    private var closeHandler: (@Sendable () -> Void)?
    private var bufferedData: [Data] = []
    private var bufferedBytes = 0
    private var isClosed = false
    private let readQueue = DispatchQueue(label: "io.github.dsbot.guest-serial.read", qos: .userInitiated)

    fileprivate init(fileDescriptor: Int32) {
        self.fileDescriptor = fileDescriptor
        var noSignal: Int32 = 1
        _ = setsockopt(fileDescriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        readQueue.async { [weak self] in self?.readLoop() }
    }

    public func setReceiveHandler(_ handler: (@Sendable (Data) -> Void)?) {
        stateLock.lock()
        receiveHandler = handler
        let pending = handler == nil ? [] : bufferedData
        if handler != nil {
            bufferedData.removeAll(keepingCapacity: false)
            bufferedBytes = 0
        }
        stateLock.unlock()
        pending.forEach { handler?($0) }
    }

    public func setCloseHandler(_ handler: (@Sendable () -> Void)?) {
        stateLock.lock()
        closeHandler = handler
        let alreadyClosed = isClosed
        stateLock.unlock()
        if alreadyClosed { handler?() }
    }

    public func send(_ bytes: Data) throws {
        sendLock.lock()
        defer { sendLock.unlock() }
        stateLock.lock()
        let descriptor = fileDescriptor
        let available = !isClosed && descriptor >= 0
        stateLock.unlock()
        guard available else { throw ARM64GuestPTYProtocolError.transportClosed }

        do {
            try bytes.withUnsafeBytes { buffer in
                guard let base = buffer.baseAddress else { return }
                var offset = 0
                while offset < buffer.count {
                    let count = Darwin.send(descriptor, base.advanced(by: offset), buffer.count - offset, 0)
                    if count > 0 { offset += count }
                    else if count < 0 && errno == EINTR { continue }
                    else { throw POSIXError(POSIXErrorCode(rawValue: count < 0 ? errno : EPIPE) ?? .EIO) }
                }
            }
        } catch {
            close()
            throw error
        }
    }

    public func close() {
        stateLock.lock()
        guard !isClosed else { stateLock.unlock(); return }
        isClosed = true
        let descriptor = fileDescriptor
        fileDescriptor = -1
        let handler = closeHandler
        stateLock.unlock()
        if descriptor >= 0 {
            _ = Darwin.shutdown(descriptor, Int32(SHUT_RDWR))
            _ = Darwin.close(descriptor)
        }
        handler?()
    }

    private func readLoop() {
        var buffer = [UInt8](repeating: 0, count: 32 * 1024)
        while true {
            stateLock.lock()
            let descriptor = fileDescriptor
            let available = !isClosed && descriptor >= 0
            stateLock.unlock()
            guard available else { return }
            let count = buffer.withUnsafeMutableBufferPointer { bytes -> Int in
                guard let base = bytes.baseAddress else { return 0 }
                return Darwin.recv(descriptor, base, bytes.count, 0)
            }
            if count > 0 {
                let data = Data(buffer.prefix(count))
                stateLock.lock()
                let handler = receiveHandler
                if handler == nil && !isClosed && bufferedBytes <= 1_048_576 - data.count {
                    bufferedData.append(data)
                    bufferedBytes += data.count
                }
                let overflow = handler == nil && bufferedBytes > 1_048_576 - data.count
                stateLock.unlock()
                if let handler { handler(data) }
                if overflow { close(); return }
            } else if count < 0 && errno == EINTR {
                continue
            } else {
                close()
                return
            }
        }
    }
}

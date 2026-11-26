import Darwin
import Foundation

/// Owns the single embedded Node process and a private AF_UNIX duplex socket.
/// Node runs on a dedicated worker thread; no localhost port or child process is used.
public final class NodeRuntimeTransport: IPCByteTransport, @unchecked Sendable {
    public static let defaultWorkspace = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("dsh-home", isDirectory: true)

    private let stateLock = NSLock()
    private var hostFD: Int32
    private var nodeFD: Int32
    private let arguments: [String]
    private var receiveHandler: ((Data) -> Void)?
    private var closeHandler: (() -> Void)?
    private var bufferedData: [Data] = []
    private var closed = false
    private var launched = false

    public static func prepare(
        apiBaseURL: String,
        workspace: URL = defaultWorkspace,
        privateSessionIDs: [String] = [],
        safeMode: Bool = false
    ) throws -> NodeRuntimeTransport {
        try NodeRuntimeTransport(apiBaseURL: apiBaseURL, workspace: workspace, privateSessionIDs: privateSessionIDs, safeMode: safeMode)
    }

    private init(apiBaseURL: String, workspace: URL, privateSessionIDs: [String], safeMode: Bool) throws {
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        Self.applyIOSStorageProtection(to: workspace)
        guard let runtimeDirectory = Bundle.main.resourceURL?.appendingPathComponent("DSHRuntime", isDirectory: true) else {
            throw IPCFrameError.remoteError(code: -32000, message: "Embedded DSH runtime resources are missing.")
        }
        let entry = runtimeDirectory.appendingPathComponent("ios-supervisor.mjs")
        let database = workspace.appendingPathComponent("dsh-sessions.sqlite")
        guard FileManager.default.fileExists(atPath: entry.path) else {
            throw IPCFrameError.remoteError(code: -32000, message: "Embedded DSH entry point is missing.")
        }

        var pair = [Int32](repeating: -1, count: 2)
        let socketStatus = pair.withUnsafeMutableBufferPointer { buffer -> Int32 in
            guard let descriptors = buffer.baseAddress else { return -1 }
            return socketpair(AF_UNIX, SOCK_STREAM, 0, descriptors)
        }
        guard socketStatus == 0 else {
            throw IPCFrameError.remoteError(code: Int(errno), message: "Could not create the private Node IPC socket.")
        }
        hostFD = pair[0]
        nodeFD = pair[1]
        var noSignal: Int32 = 1
        _ = setsockopt(hostFD, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        _ = setsockopt(nodeFD, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))

        let idsData = try JSONSerialization.data(withJSONObject: privateSessionIDs)
        let privateIdsToken = idsData.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let oldSpaceMB = MemoryGovernor.recommendedNodeOldSpaceMB()
        var args = [
            "node", "--no-warnings", "--expose-internals", "--max-old-space-size=\(oldSpaceMB)", entry.path,
            "--ipc-fd=\(nodeFD)",
            "--workspace=\(workspace.path)",
            "--database=\(database.path)",
            "--api-base=\(apiBaseURL)",
            "--private-session-ids=\(privateIdsToken)",
            "--worker-heap-mb=\(oldSpaceMB)",
        ]
        if safeMode {
            args.append("--safe-mode")
        }
        arguments = args
    }

    /// Apply iOS CompleteUntilFirstUserAuthentication protection to the workspace/SQLite
    /// directory and exclude rebuildable runtime caches from iCloud backup.
    private static func applyIOSStorageProtection(to workspace: URL) {
        let fm = FileManager.default
        try? fm.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: workspace.path
        )
        for cacheFolder in [".cache", "tmp", "node_modules"] {
            var dirURL = workspace.appendingPathComponent(cacheFolder, isDirectory: true)
            if fm.fileExists(atPath: dirURL.path) {
                var resourceValues = URLResourceValues()
                resourceValues.isExcludedFromBackup = true
                try? dirURL.setResourceValues(resourceValues)
            }
        }
    }

    /// Start Node after IPC handlers are installed so the runtime's ready handshake cannot race registration.
    public func launch() {
        stateLock.lock()
        guard !closed, !launched, nodeFD >= 0 else { stateLock.unlock(); return }
        launched = true
        nodeFD = -1 // net.Socket takes ownership after the Node script starts.
        let nodeArguments = arguments
        stateLock.unlock()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var cArguments: [UnsafeMutablePointer<CChar>?] = nodeArguments.map { strdup($0) }
            cArguments.append(nil) // node_start follows the C argv[argc] == NULL contract.
            defer {
                cArguments.compactMap { $0 }.forEach { free($0) }
            }
            let status = cArguments.withUnsafeMutableBufferPointer { buffer -> Int32 in
                guard let base = buffer.baseAddress else { return -1 }
                return node_start(Int32(nodeArguments.count), base)
            }
            self?.processExited(status)
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in self?.readLoop() }
    }

    public func setReceiveHandler(_ handler: @escaping (Data) -> Void) {
        stateLock.lock()
        let pending = bufferedData
        bufferedData.removeAll(keepingCapacity: false)
        receiveHandler = handler
        stateLock.unlock()
        pending.forEach(handler)
    }

    public func setCloseHandler(_ handler: @escaping () -> Void) {
        stateLock.lock()
        closeHandler = handler
        let alreadyClosed = closed
        stateLock.unlock()
        if alreadyClosed { handler() }
    }

    private let writeQueue = DispatchQueue(label: "io.github.dsbot.node.write", qos: .userInitiated)
    private var readLoopRunning = false

    public func write(_ data: Data) {
        writeQueue.async { [weak self] in
            guard let self else { return }
            self.stateLock.lock()
            let descriptor = self.hostFD
            let isAvailable = !self.closed && descriptor >= 0
            self.stateLock.unlock()
            guard isAvailable else { return }
            data.withUnsafeBytes { bytes in
                guard let base = bytes.baseAddress else { return }
                var offset = 0
                while offset < bytes.count {
                    let written = Darwin.write(descriptor, base.advanced(by: offset), bytes.count - offset)
                    if written > 0 { offset += written; continue }
                    if written < 0 && errno == EINTR { continue }
                    self.close()
                    return
                }
            }
        }
    }

    public func close() {
        stateLock.lock()
        guard !closed else { stateLock.unlock(); return }
        closed = true
        let descriptor = hostFD
        let unusedNodeDescriptor = nodeFD
        let deferCloseToReader = readLoopRunning
        if !deferCloseToReader {
            hostFD = -1
        }
        nodeFD = -1
        let callback = closeHandler
        stateLock.unlock()
        if descriptor >= 0 {
            _ = shutdown(descriptor, Int32(SHUT_RDWR))
            if !deferCloseToReader {
                writeQueue.async {
                    _ = Darwin.close(descriptor)
                }
            }
        }
        if unusedNodeDescriptor >= 0 { _ = Darwin.close(unusedNodeDescriptor) }
        callback?()
    }

    private func readLoop() {
        stateLock.lock()
        readLoopRunning = true
        stateLock.unlock()
        defer {
            stateLock.lock()
            readLoopRunning = false
            let descriptor = closed ? hostFD : -1
            if closed { hostFD = -1 }
            stateLock.unlock()
            if descriptor >= 0 {
                writeQueue.async {
                    _ = Darwin.close(descriptor)
                }
            }
        }
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            stateLock.lock()
            let descriptor = hostFD
            let isAvailable = !closed && descriptor >= 0
            stateLock.unlock()
            guard isAvailable else { return }
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, bytes.count)
            }
            if count > 0 {
                let chunk = Data(buffer.prefix(count))
                stateLock.lock()
                let handler = receiveHandler
                if handler == nil { bufferedData.append(chunk) }
                stateLock.unlock()
                handler?(chunk)
                continue
            }
            if count < 0 && errno == EINTR { continue }
            close()
            return
        }
    }

    private func processExited(_ status: Int32) {
        stateLock.lock()
        let shouldClose = !closed
        stateLock.unlock()
        if shouldClose {
            close()
            NSLog("DSH Node runtime exited with status %d", status)
        }
    }
}

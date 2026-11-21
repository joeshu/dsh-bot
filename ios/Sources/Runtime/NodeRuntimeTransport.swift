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

    public static func prepare(apiBaseURL: String, workspace: URL = defaultWorkspace, privateSessionIDs: [String] = []) throws -> NodeRuntimeTransport {
        try NodeRuntimeTransport(apiBaseURL: apiBaseURL, workspace: workspace, privateSessionIDs: privateSessionIDs)
    }

    private init(apiBaseURL: String, workspace: URL, privateSessionIDs: [String]) throws {
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
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
        arguments = [
            "node", "--no-warnings", "--expose-internals", entry.path,
            "--ipc-fd=\(nodeFD)",
            "--workspace=\(workspace.path)",
            "--database=\(database.path)",
            "--api-base=\(apiBaseURL)",
            "--private-session-ids=\(privateIdsToken)",
        ]
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

    public func write(_ data: Data) {
        stateLock.lock()
        let descriptor = hostFD
        let isAvailable = !closed && descriptor >= 0
        stateLock.unlock()
        guard isAvailable else { return }
        data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(descriptor, base.advanced(by: offset), bytes.count - offset)
                if written > 0 { offset += written; continue }
                if written < 0 && errno == EINTR { continue }
                close()
                return
            }
        }
    }

    public func close() {
        stateLock.lock()
        guard !closed else { stateLock.unlock(); return }
        closed = true
        let descriptor = hostFD
        let unusedNodeDescriptor = nodeFD
        hostFD = -1
        nodeFD = -1
        let callback = closeHandler
        stateLock.unlock()
        if descriptor >= 0 {
            _ = shutdown(descriptor, Int32(SHUT_RDWR))
            _ = Darwin.close(descriptor)
        }
        if unusedNodeDescriptor >= 0 { _ = Darwin.close(unusedNodeDescriptor) }
        callback?()
    }

    private func readLoop() {
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

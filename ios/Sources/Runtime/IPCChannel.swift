import Foundation

/// Length-prefixed JSON-RPC 2.0 frame codec matching `kernel/src/ipc-protocol.mjs`.
/// Wire format: [4-byte big-endian UInt32 payload length][UTF-8 JSON payload].
public enum IPCFrameError: Error, LocalizedError {
    case frameTooLarge(Int)
    case invalidFrameLength(Int)
    case invalidJSON
    case remoteError(code: Int, message: String)
    case timeout(method: String)
    case channelClosed

    public var errorDescription: String? {
        switch self {
        case .frameTooLarge(let size): return "IPC frame exceeds max size: \(size)"
        case .invalidFrameLength(let len): return "Invalid IPC frame length: \(len)"
        case .invalidJSON: return "Invalid UTF-8 JSON in IPC frame"
        case .remoteError(let code, let msg): return "IPC error (\(code)): \(msg)"
        case .timeout(let method): return "IPC request timed out: \(method)"
        case .channelClosed: return "IPC channel closed"
        }
    }
}

public struct IPCFrameCodec {
    public static let protocolVersion = "1.0.0"
    public static let maxFrameBytes = 16 * 1024 * 1024

    public static func encode(_ object: [String: Any]) throws -> Data {
        let payload = try JSONSerialization.data(withJSONObject: object, options: [])
        guard payload.count <= maxFrameBytes else {
            throw IPCFrameError.frameTooLarge(payload.count)
        }
        var lengthBE = UInt32(payload.count).bigEndian
        var frame = Data(bytes: &lengthBE, count: 4)
        frame.append(payload)
        return frame
    }
}

public final class IPCFrameDecoder {
    private var buffer = Data()
    private var readOffset = 0

    public init() {}

    public var pendingBytes: Int { buffer.count - readOffset }

    public func push(_ chunk: Data) throws -> [[String: Any]] {
        if !chunk.isEmpty {
            buffer.append(chunk)
        }
        var messages: [[String: Any]] = []

        while buffer.count - readOffset >= 4 {
            let headerStart = buffer.startIndex + readOffset
            let length = buffer[headerStart..<(headerStart + 4)].withUnsafeBytes { raw -> Int in
                let val = raw.loadUnaligned(as: UInt32.self)
                return Int(UInt32(bigEndian: val))
            }
            guard length > 0 && length <= IPCFrameCodec.maxFrameBytes else {
                buffer.removeAll()
                readOffset = 0
                throw IPCFrameError.invalidFrameLength(length)
            }
            guard buffer.count - readOffset >= 4 + length else { break }

            let payloadStart = headerStart + 4
            let payload = buffer.subdata(in: payloadStart..<(payloadStart + length))
            readOffset += 4 + length

            guard let obj = try JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
                throw IPCFrameError.invalidJSON
            }
            messages.append(obj)
        }

        if readOffset > 0 {
            if readOffset >= buffer.count {
                buffer.removeAll(keepingCapacity: true)
                readOffset = 0
            } else if readOffset >= 4096 && readOffset * 2 >= buffer.count {
                buffer.removeSubrange(buffer.startIndex..<(buffer.startIndex + readOffset))
                readOffset = 0
            }
        }

        return messages
    }
}

/// Transport abstraction for the native agent and its tests.
public protocol IPCByteTransport: AnyObject {
    func write(_ data: Data)
    func setReceiveHandler(_ handler: @escaping (Data) -> Void)
    func setCloseHandler(_ handler: @escaping () -> Void)
    func close()
}

public extension IPCByteTransport {
    func setCloseHandler(_ handler: @escaping () -> Void) {}
}

/// Async/await JSON-RPC 2.0 endpoint for the app and native agent.
public actor IPCChannel {
    private let transport: IPCByteTransport
    private let decoder = IPCFrameDecoder()
    private var nextId = 1
    private var pending: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private var deadlines: [Int: Task<Void, Never>] = [:]
    private var requestHandlers: [String: ([String: Any]) async throws -> [String: Any]] = [:]
    private var notificationHandlers: [UUID: (String, [String: Any]) -> Void] = [:]
    private var closeHandlers: [UUID: () -> Void] = [:]
    private var isClosed = false
    private let inboundContinuation: AsyncStream<Data>.Continuation

    public init(transport: IPCByteTransport) {
        self.transport = transport
        var capturedCont: AsyncStream<Data>.Continuation?
        let stream = AsyncStream<Data> { cont in
            capturedCont = cont
        }
        let cont = capturedCont!
        self.inboundContinuation = cont
        transport.setReceiveHandler { data in
            cont.yield(data)
        }
        transport.setCloseHandler { [weak self] in
            Task { await self?.transportDidClose() }
        }
        Task { [weak self] in
            for await chunk in stream {
                guard let self else { break }
                await self.handleIncomingData(chunk)
            }
        }
    }

    public func registerHandler(method: String, handler: @escaping ([String: Any]) async throws -> [String: Any]) {
        requestHandlers[method] = handler
    }

    @discardableResult
    public func onNotification(_ handler: @escaping (String, [String: Any]) -> Void) -> UUID {
        let id = UUID()
        notificationHandlers[id] = handler
        return id
    }

    public func removeNotificationHandler(_ id: UUID) {
        notificationHandlers.removeValue(forKey: id)
    }

    @discardableResult
    public func onClose(_ handler: @escaping () -> Void) -> UUID {
        let id = UUID()
        if isClosed { handler() }
        else { closeHandlers[id] = handler }
        return id
    }

    public func request(_ method: String, params: [String: Any] = [:], timeoutSeconds: UInt64 = 15) async throws -> [String: Any] {
        guard !isClosed else { throw IPCFrameError.channelClosed }
        let id = nextId
        nextId += 1
        let frame = try IPCFrameCodec.encode(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                pending[id] = continuation
                deadlines[id] = Task { [weak self] in
                    do { try await Task.sleep(nanoseconds: min(timeoutSeconds, 300) * 1_000_000_000) } catch { return }
                    await self?.cancelRequest(id, error: IPCFrameError.timeout(method: method))
                }
                transport.write(frame)
            }
        } onCancel: {
            Task { await self.cancelRequest(id, error: CancellationError()) }
        }
    }

    private func cancelRequest(_ id: Int, error: Error) {
        deadlines.removeValue(forKey: id)?.cancel()
        pending.removeValue(forKey: id)?.resume(throwing: error)
    }

    public func notify(_ method: String, params: [String: Any] = [:]) throws {
        guard !isClosed else { return }
        let frame = try IPCFrameCodec.encode([
            "jsonrpc": "2.0",
            "method": method,
            "params": params
        ])
        transport.write(frame)
    }

    public func close() {
        guard !isClosed else { return }
        isClosed = true
        inboundContinuation.finish()
        transport.close()
        for (_, cont) in pending {
            cont.resume(throwing: IPCFrameError.channelClosed)
        }
        pending.removeAll()
        for deadline in deadlines.values { deadline.cancel() }
        deadlines.removeAll()
        notifyCloseHandlers()
    }

    private func transportDidClose() {
        guard !isClosed else { return }
        isClosed = true
        inboundContinuation.finish()
        for (_, continuation) in pending {
            continuation.resume(throwing: IPCFrameError.channelClosed)
        }
        pending.removeAll()
        for deadline in deadlines.values { deadline.cancel() }
        deadlines.removeAll()
        notifyCloseHandlers()
    }

    private func notifyCloseHandlers() {
        let handlers = Array(closeHandlers.values)
        closeHandlers.removeAll()
        handlers.forEach { $0() }
    }

    private func handleIncomingData(_ data: Data) async {
        do {
            let messages = try decoder.push(data)
            for msg in messages {
                // Deliver responses & notifications inline in strict FIFO order;
                // only inbound RPC requests run concurrently so bridge calls cannot deadlock streaming.
                if msg["id"] != nil && msg["method"] != nil {
                    Task { await self.dispatch(msg) }
                } else {
                    await dispatch(msg)
                }
            }
        } catch {
            close()
        }
    }

    private func dispatch(_ msg: [String: Any]) async {
        // Response to outbound request
        if let id = msg["id"] as? Int, msg["method"] == nil {
            guard let cont = pending.removeValue(forKey: id) else { return }
            deadlines.removeValue(forKey: id)?.cancel()
            if let errObj = msg["error"] as? [String: Any] {
                let code = errObj["code"] as? Int ?? -32000
                let message = errObj["message"] as? String ?? "Unknown IPC error"
                cont.resume(throwing: IPCFrameError.remoteError(code: code, message: message))
            } else {
                let result = msg["result"] as? [String: Any] ?? [:]
                cont.resume(returning: result)
            }
            return
        }

        // Inbound notification
        if msg["id"] == nil, let method = msg["method"] as? String {
            let params = msg["params"] as? [String: Any] ?? [:]
            for (_, handler) in notificationHandlers {
                handler(method, params)
            }
            return
        }

        // Inbound request from the transport.
        if let id = msg["id"] as? Int, let method = msg["method"] as? String {
            let params = msg["params"] as? [String: Any] ?? [:]
            guard let handler = requestHandlers[method] else {
                let reply = try? IPCFrameCodec.encode([
                    "jsonrpc": "2.0",
                    "id": id,
                    "error": ["code": -32601, "message": "Method not found: \(method)"]
                ])
                if let reply { transport.write(reply) }
                return
            }
            do {
                let result = try await handler(params)
                let reply = try IPCFrameCodec.encode([
                    "jsonrpc": "2.0",
                    "id": id,
                    "result": result
                ])
                transport.write(reply)
            } catch {
                let reply = try? IPCFrameCodec.encode([
                    "jsonrpc": "2.0",
                    "id": id,
                    "error": ["code": -32000, "message": error.localizedDescription]
                ])
                if let reply { transport.write(reply) }
            }
        }
    }
}

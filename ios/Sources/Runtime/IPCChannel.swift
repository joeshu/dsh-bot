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

    public init() {}

    public var pendingBytes: Int { buffer.count }

    public func push(_ chunk: Data) throws -> [[String: Any]] {
        buffer.append(chunk)
        var messages: [[String: Any]] = []

        while buffer.count >= 4 {
            let length = buffer.prefix(4).withUnsafeBytes { raw -> Int in
                let val = raw.load(as: UInt32.self)
                return Int(UInt32(bigEndian: val))
            }
            guard length > 0 && length <= IPCFrameCodec.maxFrameBytes else {
                buffer.removeAll()
                throw IPCFrameError.invalidFrameLength(length)
            }
            guard buffer.count >= 4 + length else { break }

            let payload = buffer.subdata(in: 4..<(4 + length))
            buffer.removeSubrange(0..<(4 + length))

            guard let obj = try JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
                throw IPCFrameError.invalidJSON
            }
            messages.append(obj)
        }

        return messages
    }
}

/// Transport abstraction implemented by BareKit (`Bare.IPC`) in production and loopback in XCTest.
public protocol IPCByteTransport: AnyObject {
    func write(_ data: Data)
    func setReceiveHandler(_ handler: @escaping (Data) -> Void)
    func close()
}

/// Async/await JSON-RPC 2.0 client/server endpoint for SwiftUI Shell <-> DSH Kernel.
public actor IPCChannel {
    private let transport: IPCByteTransport
    private let decoder = IPCFrameDecoder()
    private var nextId = 1
    private var pending: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private var requestHandlers: [String: ([String: Any]) async throws -> [String: Any]] = [:]
    private var notificationHandlers: [UUID: (String, [String: Any]) -> Void] = [:]
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

    public func request(_ method: String, params: [String: Any] = [:]) async throws -> [String: Any] {
        guard !isClosed else { throw IPCFrameError.channelClosed }
        let id = nextId
        nextId += 1
        let frame = try IPCFrameCodec.encode([
            "jsonrpc": "2.0",
            "id": id,
            "method": method,
            "params": params
        ])
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            transport.write(frame)
        }
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

        // Inbound request from DSH Kernel (e.g., bridge.sqlite.*, bridge.net.*, bridge.keychain.*)
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

import Foundation

public enum NetworkBridgeError: Error, LocalizedError {
    case invalidURL(String)

    public var errorDescription: String? {
        switch self {
        case .invalidURL(let raw): return "Invalid URL: \(raw)"
        }
    }
}

/// Native iOS `URLSession` HTTP + real async SSE streaming bridge backing DSH LLM & Remote MCP calls.
/// Bypasses undici/WASM requirements in `--jitless` environments and respects iOS VPN/proxy settings.
public actor NetworkBridge {
    private let session: URLSession
    private var activeStreams: [String: Task<Void, Never>] = [:]

    public init(configuration: URLSessionConfiguration = .default) {
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForRequest = 60
        self.session = URLSession(configuration: configuration)
    }

    public func request(params: [String: Any]) async throws -> [String: Any] {
        let req = try buildURLRequest(from: params)
        let (data, response) = try await session.data(for: req)
        let http = response as? HTTPURLResponse
        var respHeaders: [String: String] = [:]
        if let fields = http?.allHeaderFields {
            for (k, v) in fields {
                respHeaders[String(describing: k).lowercased()] = String(describing: v)
            }
        }
        return [
            "status": http?.statusCode ?? 0,
            "headers": respHeaders,
            "body": (params["responseEncoding"] as? String == "base64")
                ? data.base64EncodedString()
                : (String(data: data, encoding: .utf8) ?? "")
        ]
    }

    /// Starts an asynchronous SSE stream using `URLSession.bytes(for:)` and emits
    /// `bridge.net.sseChunk` / `bridge.net.sseEnd` / `bridge.net.sseError` notifications over `IPCChannel`.
    public func sseStart(params: [String: Any], channel: IPCChannel) throws -> [String: Any] {
        let req = try buildURLRequest(from: params)
        let streamId = "sse_\(UUID().uuidString.prefix(8))"
        let session = self.session

        let task = Task { [weak self] in
            defer {
                Task { await self?.removeStream(streamId) }
            }
            do {
                let (bytes, response) = try await session.bytes(for: req)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 200
                if !(200..<300).contains(status) {
                    var errBody = ""
                    for try await errLine in bytes.lines {
                        errBody += errLine
                        if errBody.count >= 600 { break }
                    }
                    if !Task.isCancelled {
                        try? await channel.notify("bridge.net.sseError", params: [
                            "streamId": streamId,
                            "status": status,
                            "message": "HTTP \(status): \(errBody.prefix(240))"
                        ])
                    }
                    return
                }
                for try await line in bytes.lines {
                    if Task.isCancelled { break }
                    try? await channel.notify("bridge.net.sseChunk", params: [
                        "streamId": streamId,
                        "data": line + "\n"
                    ])
                }
                if !Task.isCancelled {
                    try? await channel.notify("bridge.net.sseEnd", params: [
                        "streamId": streamId,
                        "status": status
                    ])
                }
            } catch {
                if !Task.isCancelled {
                    try? await channel.notify("bridge.net.sseError", params: [
                        "streamId": streamId,
                        "message": error.localizedDescription
                    ])
                }
            }
        }

        activeStreams[streamId] = task
        return ["streamId": streamId]
    }

    public func sseCancel(streamId: String) -> [String: Any] {
        if let task = activeStreams.removeValue(forKey: streamId) {
            task.cancel()
            return ["ok": true, "cancelled": true]
        }
        return ["ok": true, "cancelled": false]
    }

    public func cancelAllStreams() {
        for (_, task) in activeStreams {
            task.cancel()
        }
        activeStreams.removeAll()
    }

    private func removeStream(_ streamId: String) {
        activeStreams.removeValue(forKey: streamId)
    }

    private func buildURLRequest(from params: [String: Any]) throws -> URLRequest {
        let rawURL = params["url"] as? String ?? ""
        guard let url = URL(string: rawURL) else {
            throw NetworkBridgeError.invalidURL(rawURL)
        }
        var req = URLRequest(url: url)
        req.httpMethod = (params["method"] as? String ?? "GET").uppercased()
        if let headers = params["headers"] as? [String: String] {
            for (k, v) in headers {
                req.setValue(v, forHTTPHeaderField: k)
            }
        }
        if let body = params["body"] as? String {
            req.httpBody = body.data(using: .utf8)
        }
        return req
    }
}

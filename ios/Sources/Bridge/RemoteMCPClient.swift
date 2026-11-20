import Foundation

public struct MCPToolDescriptor: Identifiable, Equatable {
    public let id: String
    public let name: String
    public let description: String
}

enum RemoteMCPError: Error, LocalizedError {
    case http(Int)
    case invalidResponse
    case unsupportedVersion
    case toolError

    var errorDescription: String? {
        switch self {
        case .http(let status): return "MCP 服务返回 HTTP \(status)。"
        case .invalidResponse: return "MCP 服务返回了无效响应。"
        case .unsupportedVersion: return "连接器不支持 MCP 2025-03-26 Streamable HTTP。"
        case .toolError: return "MCP 工具报告执行失败。"
        }
    }
}

public actor RemoteMCPClient {
    private static let protocolVersion = "2025-03-26"
    private let session: URLSession
    private let keychain: KeychainBridge
    private var connections: [String: String] = [:]
    private var handshakes: [String: Task<String, Error>] = [:]

    public init(keychain: KeychainBridge = KeychainBridge(), session: URLSession? = nil) {
        self.session = session ?? isolatedHTTPSession(timeout: 30)
        self.keychain = keychain
    }

    static func endpointURL(_ raw: String) throws -> URL {
        guard let url = try ModelProvider.httpsComponents(raw.trimmingCharacters(in: .whitespacesAndNewlines)).url else {
            throw ModelProviderError.invalidAddress
        }
        return url
    }

    public func listTools(endpoint: String, keychainAccount: String? = nil) async throws -> [MCPToolDescriptor] {
        let result = try await request(endpoint: endpoint, keychainAccount: keychainAccount, method: "tools/list", params: [:])
        guard let tools = result["tools"] as? [[String: Any]] else { throw RemoteMCPError.invalidResponse }
        return tools.compactMap { tool in
            guard let name = tool["name"] as? String, !name.isEmpty else { return nil }
            return MCPToolDescriptor(id: name, name: name, description: tool["description"] as? String ?? "")
        }
    }

    public func callTool(endpoint: String, name: String, arguments: [String: Any], keychainAccount: String? = nil) async throws -> String {
        let result = try await request(endpoint: endpoint, keychainAccount: keychainAccount,
                                       method: "tools/call", params: ["name": name, "arguments": arguments])
        if result["isError"] as? Bool == true { throw RemoteMCPError.toolError }
        if let content = result["content"] as? [[String: Any]] {
            let texts = content.compactMap { $0["text"] as? String }
            if !texts.isEmpty { return texts.joined(separator: "\n") }
        }
        return String(decoding: try JSONSerialization.data(withJSONObject: result), as: UTF8.self)
    }

    private func request(endpoint: String, keychainAccount: String?, method: String, params: [String: Any]) async throws -> [String: Any] {
        let url = try Self.endpointURL(endpoint)
        var token: String?
        if let keychainAccount {
            token = try await keychain.getSecret(account: keychainAccount, requireBiometrics: false)["value"] as? String
        }
        let connection = "\(keychainAccount ?? "")|\(url.absoluteString)"
        let sessionID = try await connect(url: url, token: token, connection: connection)
        try Task.checkCancellation()
        do {
            return try await send(url, token: token, sessionID: sessionID, method: method, params: params).result
        } catch RemoteMCPError.http(404) {
            connections.removeValue(forKey: connection)
            throw RemoteMCPError.http(404)
        }
    }

    private func connect(url: URL, token: String?, connection: String) async throws -> String {
        if let current = connections[connection] { return current }
        if let pending = handshakes[connection] { return try await pending.value }

        let task = Task {
            let initialization = try await send(url, token: token, sessionID: "", method: "initialize", params: [
                "protocolVersion": Self.protocolVersion,
                "capabilities": [:],
                "clientInfo": ["name": "DS Bot iOS", "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1"]
            ])
            guard initialization.result["protocolVersion"] as? String == Self.protocolVersion else {
                throw RemoteMCPError.unsupportedVersion
            }
            let sessionID = initialization.sessionID ?? ""
            _ = try await send(url, token: token, sessionID: sessionID, method: "notifications/initialized", params: [:], notification: true)
            return sessionID
        }
        handshakes[connection] = task
        defer { handshakes.removeValue(forKey: connection) }
        let sessionID = try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
        connections[connection] = sessionID
        return sessionID
    }

    private func send(_ url: URL, token: String?, sessionID: String, method: String,
                      params: [String: Any], notification: Bool = false) async throws -> (result: [String: Any], sessionID: String?) {
        let id = UUID().uuidString
        var payload: [String: Any] = ["jsonrpc": "2.0", "method": method, "params": params]
        if !notification { payload["id"] = id }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        if method != "initialize" { request.setValue(Self.protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version") }
        if !sessionID.isEmpty { request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id") }
        if let token, !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        guard let http = response as? HTTPURLResponse else { throw RemoteMCPError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw RemoteMCPError.http(http.statusCode) }
        let responseSessionID = http.value(forHTTPHeaderField: "Mcp-Session-Id")
        if notification {
            guard http.statusCode == 202 else { throw RemoteMCPError.invalidResponse }
            return ([:], responseSessionID)
        }

        if http.mimeType == "text/event-stream" {
            var events = ServerSentEvents()
            for try await byte in bytes {
                try Task.checkCancellation()
                guard let event = try events.append(byte: byte) else { continue }
                if let result = try decode(Data(event.utf8), id: id) { return (result, responseSessionID) }
            }
        } else if http.mimeType == "application/json" {
            var data = Data()
            for try await byte in bytes {
                try Task.checkCancellation()
                guard data.count < 1_500_000 else { throw ModelProviderError.responseTooLarge }
                data.append(byte)
            }
            if let result = try decode(data, id: id) { return (result, responseSessionID) }
        }
        throw RemoteMCPError.invalidResponse
    }

    private func decode(_ data: Data, id: String) throws -> [String: Any]? {
        guard let message = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              message["jsonrpc"] as? String == "2.0" else { throw RemoteMCPError.invalidResponse }
        guard message["id"] as? String == id else { return nil }
        if message["error"] != nil { throw RemoteMCPError.toolError }
        guard let result = message["result"] as? [String: Any] else { throw RemoteMCPError.invalidResponse }
        return result
    }
}

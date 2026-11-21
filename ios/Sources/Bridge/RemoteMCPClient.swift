import Foundation

public struct MCPToolDescriptor: Identifiable, Equatable {
    public let id: String
    public let name: String
    public let description: String
    public let inputSchemaJSON: String

    public init(id: String, name: String, description: String, inputSchemaJSON: String = "{}") {
        self.id = id
        self.name = name
        self.description = description
        self.inputSchemaJSON = inputSchemaJSON
    }
}

enum RemoteMCPError: Error, LocalizedError {
    case http(Int)
    case invalidResponse
    case unsupportedVersion(String)
    case toolError(String)

    var errorDescription: String? {
        switch self {
        case .http(let status): return "MCP 服务返回 HTTP \(status)。"
        case .invalidResponse: return "MCP 服务返回了无效响应。"
        case .unsupportedVersion(let ver): return "连接器返回不支持的 MCP 协议版本（\(ver)）。"
        case .toolError(let detail): return detail.isEmpty ? "MCP 工具报告执行失败。" : "MCP 工具执行失败：\(detail)"
        }
    }
}

public actor RemoteMCPClient {
    private static let defaultProtocolVersion = "2025-03-26"

    private struct SessionState {
        let sessionID: String
        let protocolVersion: String
    }

    private let session: URLSession
    private let keychain: KeychainBridge
    private var connections: [String: SessionState] = [:]
    private var handshakes: [String: Task<SessionState, Error>] = [:]

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
            var schemaStr = "{}"
            if let schema = tool["inputSchema"],
               let data = try? JSONSerialization.data(withJSONObject: schema, options: [.sortedKeys]) {
                schemaStr = String(decoding: data, as: UTF8.self)
            }
            return MCPToolDescriptor(
                id: name,
                name: name,
                description: tool["description"] as? String ?? "",
                inputSchemaJSON: schemaStr
            )
        }
    }

    public func callTool(endpoint: String, name: String, arguments: [String: Any], keychainAccount: String? = nil) async throws -> String {
        let result = try await request(endpoint: endpoint, keychainAccount: keychainAccount,
                                       method: "tools/call", params: ["name": name, "arguments": arguments])
        if result["isError"] as? Bool == true {
            let texts = (result["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }
            throw RemoteMCPError.toolError(texts.joined(separator: "\n"))
        }
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
        let state = try await connect(url: url, token: token, connection: connection)
        try Task.checkCancellation()
        do {
            return try await send(url, token: token, sessionID: state.sessionID, protocolVersion: state.protocolVersion, method: method, params: params).result
        } catch RemoteMCPError.http(404) {
            // Streamable HTTP spec: 404 indicates expired session — re-initialize once and retry.
            connections.removeValue(forKey: connection)
            let refreshed = try await connect(url: url, token: token, connection: connection)
            try Task.checkCancellation()
            return try await send(url, token: token, sessionID: refreshed.sessionID, protocolVersion: refreshed.protocolVersion, method: method, params: params).result
        }
    }

    private func connect(url: URL, token: String?, connection: String) async throws -> SessionState {
        if let current = connections[connection] { return current }
        if let pending = handshakes[connection] { return try await pending.value }

        let task = Task {
            let initialization = try await send(
                url,
                token: token,
                sessionID: "",
                protocolVersion: Self.defaultProtocolVersion,
                method: "initialize",
                params: [
                    "protocolVersion": Self.defaultProtocolVersion,
                    "capabilities": [:],
                    "clientInfo": ["name": "DS Bot iOS", "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "2.0"]
                ]
            )
            let negotiated = (initialization.result["protocolVersion"] as? String ?? Self.defaultProtocolVersion).trimmingCharacters(in: .whitespacesAndNewlines)
            guard negotiated.hasPrefix("2024-") || negotiated.hasPrefix("2025-") || negotiated.hasPrefix("2026-") else {
                throw RemoteMCPError.unsupportedVersion(negotiated)
            }
            let sessionID = initialization.sessionID ?? ""
            _ = try? await send(url, token: token, sessionID: sessionID, protocolVersion: negotiated, method: "notifications/initialized", params: [:], notification: true)
            return SessionState(sessionID: sessionID, protocolVersion: negotiated)
        }
        handshakes[connection] = task
        defer { handshakes.removeValue(forKey: connection) }
        let state = try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
        connections[connection] = state
        return state
    }

    private func send(_ url: URL, token: String?, sessionID: String, protocolVersion: String, method: String,
                      params: [String: Any], notification: Bool = false) async throws -> (result: [String: Any], sessionID: String?) {
        let id = UUID().uuidString
        var payload: [String: Any] = ["jsonrpc": "2.0", "method": method, "params": params]
        if !notification { payload["id"] = id }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        if method != "initialize" { request.setValue(protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version") }
        if !sessionID.isEmpty { request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id") }
        if let token, !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        guard let http = response as? HTTPURLResponse else { throw RemoteMCPError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw RemoteMCPError.http(http.statusCode) }
        let responseSessionID = http.value(forHTTPHeaderField: "Mcp-Session-Id")
        if notification {
            return ([:], responseSessionID)
        }

        let mime = (http.mimeType ?? "").lowercased()
        if mime.contains("text/event-stream") {
            var events = ServerSentEvents()
            for try await byte in bytes {
                try Task.checkCancellation()
                guard let event = try events.append(byte: byte) else { continue }
                if let result = try decode(Data(event.utf8), id: id) { return (result, responseSessionID) }
            }
        } else if mime.contains("application/json") || mime.isEmpty {
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
        if let err = message["error"] as? [String: Any] {
            let msg = err["message"] as? String ?? ""
            throw RemoteMCPError.toolError(msg)
        }
        guard let result = message["result"] as? [String: Any] else { throw RemoteMCPError.invalidResponse }
        return result
    }
}

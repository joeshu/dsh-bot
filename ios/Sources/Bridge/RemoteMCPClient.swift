import Foundation

public struct MCPToolDescriptor: Identifiable, Equatable {
    public let id: String
    public let name: String
    public let description: String
}

public enum RemoteMCPError: Error, LocalizedError {
    case invalidEndpoint(String)
    case httpError(Int)
    case rpcError(String)

    public var errorDescription: String? {
        switch self {
        case .invalidEndpoint(let raw): return "Invalid MCP endpoint URL: \(raw)"
        case .httpError(let code): return "MCP server returned HTTP \(code)"
        case .rpcError(let msg): return "MCP RPC error: \(msg)"
        }
    }
}

/// Real Model Context Protocol (MCP) Streamable HTTP JSON-RPC 2.0 client for standalone iOS.
/// Supports `initialize`, `tools/list`, and `tools/call` with optional Bearer token loaded from iOS Keychain.
public actor RemoteMCPClient {
    private let session: URLSession
    private let keychain: KeychainBridge
    private var sessionIds: [String: String] = [:] // endpoint -> Mcp-Session-Id

    public init(keychain: KeychainBridge = KeychainBridge()) {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 45
        self.session = URLSession(configuration: cfg)
        self.keychain = keychain
    }

    public func listTools(endpoint: String, keychainAccount: String? = nil) async throws -> [MCPToolDescriptor] {
        _ = try? await sendRPC(
            endpoint: endpoint,
            method: "initialize",
            params: [
                "protocolVersion": "2025-03-26",
                "capabilities": [:],
                "clientInfo": ["name": "DSBot-iOS-Standalone", "version": "1.2.0"]
            ],
            keychainAccount: keychainAccount
        )

        let result = try await sendRPC(endpoint: endpoint, method: "tools/list", params: [:], keychainAccount: keychainAccount)
        let rawTools = result["tools"] as? [[String: Any]] ?? []
        return rawTools.compactMap { dict in
            guard let name = dict["name"] as? String else { return nil }
            return MCPToolDescriptor(
                id: name,
                name: name,
                description: dict["description"] as? String ?? ""
            )
        }
    }

    public func callTool(endpoint: String, name: String, arguments: [String: Any], keychainAccount: String? = nil) async throws -> String {
        let result = try await sendRPC(
            endpoint: endpoint,
            method: "tools/call",
            params: ["name": name, "arguments": arguments],
            keychainAccount: keychainAccount
        )
        if let content = result["content"] as? [[String: Any]] {
            let texts = content.compactMap { $0["text"] as? String }
            if !texts.isEmpty { return texts.joined(separator: "\n") }
        }
        if let data = try? JSONSerialization.data(withJSONObject: result),
           let str = String(data: data, encoding: .utf8) {
            return str
        }
        return ""
    }

    private func sendRPC(endpoint: String, method: String, params: [String: Any], keychainAccount: String?) async throws -> [String: Any] {
        guard let url = URL(string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme == "https" || url.scheme == "http" else {
            throw RemoteMCPError.invalidEndpoint(endpoint)
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        if let sid = sessionIds[endpoint] {
            req.setValue(sid, forHTTPHeaderField: "Mcp-Session-Id")
        }
        if let account = keychainAccount,
           let secretObj = try? await keychain.getSecret(account: account, requireBiometrics: false),
           let token = secretObj["value"] as? String, !token.isEmpty {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let payload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": Int.random(in: 1...999_999),
            "method": method,
            "params": params
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await session.data(for: req)
        if let http = response as? HTTPURLResponse {
            if let sid = http.value(forHTTPHeaderField: "Mcp-Session-Id"), !sid.isEmpty {
                sessionIds[endpoint] = sid
            }
            guard (200..<300).contains(http.statusCode) else {
                throw RemoteMCPError.httpError(http.statusCode)
            }
        }

        // Handle either direct JSON or `data: {...}` SSE-wrapped MCP response
        let rawText = String(data: data, encoding: .utf8) ?? ""
        let jsonData: Data
        if rawText.contains("data: ") {
            let line = rawText.split(separator: "\n")
                .reversed()
                .compactMap { l -> String? in
                    guard l.hasPrefix("data: ") else { return nil }
                    let body = String(l.dropFirst(6)).trimmingCharacters(in: .whitespaces)
                    return body.hasPrefix("{") ? body : nil
                }.first ?? "{}"
            jsonData = Data(line.utf8)
        } else {
            jsonData = data
        }

        guard let obj = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            return [:]
        }
        if let err = obj["error"] as? [String: Any] {
            throw RemoteMCPError.rpcError(err["message"] as? String ?? "Unknown MCP error")
        }
        return obj["result"] as? [String: Any] ?? [:]
    }
}

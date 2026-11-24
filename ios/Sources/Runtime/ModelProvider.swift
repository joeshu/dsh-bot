import Foundation

enum ModelProviderError: Error, LocalizedError {
    case invalidAddress
    case missingKey
    case missingModel
    case invalidResponse
    case http(Int)
    case interrupted
    case invalidToolCall
    case toolLimit
    case responseTooLarge

    var errorDescription: String? {
        switch self {
        case .invalidAddress: return "请输入有效的 HTTP 或 HTTPS 服务地址。"
        case .missingKey: return "请在设置中为当前服务地址保存 API Key。"
        case .missingModel: return "请为当前服务输入模型 ID。"
        case .invalidResponse: return "模型服务返回了无效响应。"
        case .http(let code): return "模型服务返回 HTTP \(code)。"
        case .interrupted: return "流式回复中断，可以重试。"
        case .invalidToolCall: return "模型返回的工具调用不完整。"
        case .toolLimit: return "已达到本回合的工具调用上限。"
        case .responseTooLarge: return "响应超过大小限制。"
        }
    }
}

struct ModelProvider {
    static let defaultAddress = "https://api.deepseek.com"
    static let defaultModel = "deepseek-flash"
    // Local selection, translated to an API model and thinking flag for DeepSeek.
    static let thinkingModel = "deepseek-flash-thinking"

    let baseURL: URL
    let isDeepSeek: Bool

    init(_ raw: String) throws {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var parts = try Self.endpointComponents(trimmed.isEmpty ? Self.defaultAddress : trimmed)
        guard parts.query == nil else { throw ModelProviderError.invalidAddress }
        while parts.percentEncodedPath.last == "/" {
            parts.percentEncodedPath.removeLast()
        }
        isDeepSeek = parts.scheme == "https" && parts.host == "api.deepseek.com" && parts.port == nil
            && ["", "/v1"].contains(parts.percentEncodedPath)
        if isDeepSeek { parts.path = "" }
        guard let url = parts.url else { throw ModelProviderError.invalidAddress }
        baseURL = url
    }

    static func endpointComponents(_ raw: String) throws -> URLComponents {
        guard var parts = URLComponents(string: raw),
              let scheme = parts.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              let host = parts.host?.lowercased(), !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.fragment == nil else {
            throw ModelProviderError.invalidAddress
        }
        parts.scheme = scheme
        parts.host = host
        if (scheme == "https" && parts.port == 443) || (scheme == "http" && parts.port == 80) {
            parts.port = nil
        }
        return parts
    }

    static func httpsComponents(_ raw: String) throws -> URLComponents {
        guard var parts = URLComponents(string: raw),
              parts.scheme?.lowercased() == "https",
              let host = parts.host?.lowercased(), !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.fragment == nil else {
            throw ModelProviderError.invalidAddress
        }
        parts.scheme = "https"
        parts.host = host
        if parts.port == 443 { parts.port = nil }
        return parts
    }

    func endpoint(_ path: String) -> URL {
        path.split(separator: "/").reduce(baseURL) { $0.appendingPathComponent(String($1)) }
    }

    func selection(_ id: String) -> String {
        guard isDeepSeek else { return id }
        switch id {
        case "", "deepseek-chat": return Self.defaultModel
        case "deepseek-reasoner": return Self.thinkingModel
        default: return id
        }
    }

    func historyProfile(model: String, tools: Bool) -> String {
        "\(baseURL.absoluteString)|\(selection(model))|\(tools)"
    }

    func modelFields(_ selection: String) throws -> [String: Any] {
        let id = self.selection(selection).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { throw ModelProviderError.missingModel }
        guard isDeepSeek else { return ["model": id] }
        let thinking = id == Self.thinkingModel || id == "deepseek-v4-pro"
        return [
            "model": id == Self.thinkingModel ? Self.defaultModel : id,
            "thinking": ["type": thinking ? "enabled" : "disabled"]
        ]
    }
}

struct ProviderMessage: Codable, Equatable {
    struct ToolCall: Codable, Equatable {
        struct Function: Codable, Equatable {
            var name = ""
            var arguments = ""
        }

        var id = ""
        var type = "function"
        var function = Function()
    }

    let role: String
    var content: String?
    var reasoning_content: String?
    var tool_calls: [ToolCall]?
    var tool_call_id: String?

    var payload: [String: Any] {
        var result: [String: Any] = ["role": role, "content": content.map { $0 as Any } ?? NSNull()]
        if let reasoning_content { result["reasoning_content"] = reasoning_content }
        if let tool_calls {
            result["tool_calls"] = tool_calls.map {
                ["id": $0.id, "type": $0.type,
                 "function": ["name": $0.function.name, "arguments": $0.function.arguments]]
            }
        }
        if let tool_call_id { result["tool_call_id"] = tool_call_id }
        return result
    }
}

struct ServerSentEvents {
    private var lines: [String] = []
    private var bytes = 0
    private var lineBytes: [UInt8] = []
    private var skipLineFeed = false
    private var firstLine = true

    mutating func append(byte: UInt8) throws -> String? {
        defer { skipLineFeed = byte == 13 }
        if byte == 10 && skipLineFeed { return nil }
        if byte == 10 || byte == 13 {
            var line = String(decoding: lineBytes, as: UTF8.self)
            lineBytes.removeAll(keepingCapacity: true)
            if firstLine && line.first == "\u{FEFF}" { line.removeFirst() }
            firstLine = false
            return try append(line)
        }
        guard lineBytes.count < 1_500_000 else { throw ModelProviderError.responseTooLarge }
        lineBytes.append(byte)
        return nil
    }

    mutating func append(_ line: String) throws -> String? {
        if line.isEmpty { return finish() }
        guard line == "data" || line.hasPrefix("data:") else { return nil }
        var value = line == "data" ? "" : String(line.dropFirst(5))
        if value.first == " " { value.removeFirst() }
        bytes += value.utf8.count + 1
        guard bytes <= 1_500_000 else { throw ModelProviderError.responseTooLarge }
        lines.append(value)
        return nil
    }

    mutating func finish() -> String? {
        guard !lines.isEmpty else { return nil }
        let result = lines.joined(separator: "\n")
        lines.removeAll(keepingCapacity: true)
        bytes = 0
        return result
    }
}

struct CompletionRound {
    private(set) var content = ""
    private(set) var reasoning = ""
    private(set) var finishReason: String?
    private(set) var done = false
    private var callsByIndex: [Int: ProviderMessage.ToolCall] = [:]

    var toolCalls: [ProviderMessage.ToolCall] {
        callsByIndex.keys.sorted().compactMap { callsByIndex[$0] }
    }

    mutating func consume(_ event: String) throws -> (content: String, reasoning: String, usage: [String: Any]?) {
        if event.trimmingCharacters(in: .whitespacesAndNewlines) == "[DONE]" {
            done = true
            return ("", "", nil)
        }
        guard let json = try? JSONSerialization.jsonObject(with: Data(event.utf8)) as? [String: Any],
              json["error"] == nil else { throw ModelProviderError.invalidResponse }
        let choice = (json["choices"] as? [[String: Any]])?.first
        finishReason = choice?["finish_reason"] as? String ?? finishReason
        let delta = choice?["delta"] as? [String: Any]
        let text = delta?["content"] as? String ?? ""
        let thought = delta?["reasoning_content"] as? String ?? ""
        content += text
        reasoning += thought
        guard content.utf8.count + reasoning.utf8.count <= 1_500_000 else {
            throw ModelProviderError.responseTooLarge
        }
        for part in (delta?["tool_calls"] as? [[String: Any]]) ?? [] {
            guard let index = part["index"] as? Int, (0..<12).contains(index) else {
                throw ModelProviderError.invalidToolCall
            }
            var call = callsByIndex[index] ?? ProviderMessage.ToolCall()
            if let id = part["id"] as? String { call.id = id }
            if let function = part["function"] as? [String: Any] {
                call.function.name += function["name"] as? String ?? ""
                call.function.arguments += function["arguments"] as? String ?? ""
            }
            guard call.function.arguments.utf8.count <= 65_536 else { throw ModelProviderError.invalidToolCall }
            callsByIndex[index] = call
        }
        return (text, thought, json["usage"] as? [String: Any])
    }
}

#if !os(Linux)
final class NoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

final class SafeHTTPSRedirects: NSObject, URLSessionTaskDelegate {
    private let maxHops = 5
    private var hopCounts: [Int: Int] = [:]
    private let lock = NSLock()

    static func isPrivateOrLoopbackHost(_ rawHost: String) -> Bool {
        let host = rawHost.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if host.isEmpty || host == "localhost" || host.hasSuffix(".local") || host.hasSuffix(".internal") {
            return true
        }
        if host == "::1" || host == "::" || host.hasPrefix("fe80:") || host.hasPrefix("fc") || host.hasPrefix("fd") {
            return true
        }
        let parts = host.split(separator: ".").compactMap { Int($0) }
        if parts.count == 4 && parts.allSatisfy({ (0...255).contains($0) }) {
            let (a, b) = (parts[0], parts[1])
            if a == 10 || a == 127 || a == 0 { return true }
            if a == 169 && b == 254 { return true }
            if a == 172 && (16...31).contains(b) { return true }
            if a == 192 && b == 168 { return true }
            if a == 100 && (64...127).contains(b) { return true }
        }
        return false
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        lock.lock()
        let nextHop = (hopCounts[task.taskIdentifier] ?? 0) + 1
        hopCounts[task.taskIdentifier] = nextHop
        lock.unlock()
        guard nextHop <= maxHops,
              let url = request.url,
              url.scheme?.lowercased() == "https",
              url.user == nil, url.password == nil,
              let host = url.host,
              !Self.isPrivateOrLoopbackHost(host) else {
            completionHandler(nil)
            return
        }
        var sanitized = request
        sanitized.setValue(nil, forHTTPHeaderField: "Authorization")
        sanitized.setValue(nil, forHTTPHeaderField: "Cookie")
        completionHandler(sanitized)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        hopCounts.removeValue(forKey: task.taskIdentifier)
        lock.unlock()
    }
}

func isolatedHTTPSession(timeout: TimeInterval) -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpShouldSetCookies = false
    configuration.urlCredentialStorage = nil
    configuration.timeoutIntervalForRequest = timeout
    configuration.timeoutIntervalForResource = timeout * 2
    return URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
}

func isolatedWebFetchSession(timeout: TimeInterval) -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpShouldSetCookies = false
    configuration.urlCredentialStorage = nil
    configuration.timeoutIntervalForRequest = timeout
    configuration.timeoutIntervalForResource = timeout * 2
    return URLSession(configuration: configuration, delegate: SafeHTTPSRedirects(), delegateQueue: nil)
}
#endif

import Combine
import Foundation

public enum LocalAgentState: Equatable {
    case idle
    case starting
    case ready
    case failed(String)
}

public struct PendingApproval: Identifiable, Equatable {
    public let id: String
    public let sessionId: String
    public let turnId: String
    public let tool: String
    public let summary: String
}

public struct ChatMessageItem: Identifiable, Codable, Equatable {
    public let id: String
    public let sessionId: String
    public let role: String // "user" | "assistant"
    public let content: String
    public let reasoning: String
    public let timestamp: Date
    var transcript: [ProviderMessage]?
    var providerProfile: String?
    var incomplete: Bool?

    public init(id: String = UUID().uuidString, sessionId: String, role: String, content: String, reasoning: String = "", timestamp: Date = Date()) {
        self.id = id
        self.sessionId = sessionId
        self.role = role
        self.content = content
        self.reasoning = reasoning
        self.timestamp = timestamp
    }
}

public struct BotProfile: Identifiable, Codable, Equatable {
    public let id: String
    public var name: String
    public var roleLabel: String
    public var model: String
    public var systemPrompt: String
    public var isMain: Bool
    public var isPrivate: Bool
    public var isGroup: Bool
    public var section: String

    enum CodingKeys: String, CodingKey {
        case id, name, roleLabel, model, systemPrompt, isMain, isPrivate, isGroup, section
    }

    public init(id: String, name: String, roleLabel: String, model: String = "deepseek-flash", systemPrompt: String = "", isMain: Bool = false, isPrivate: Bool = false, isGroup: Bool = false, section: String = "默认团队") {
        self.id = id
        self.name = name
        self.roleLabel = roleLabel
        self.model = model
        self.systemPrompt = systemPrompt
        self.isMain = isMain
        self.isPrivate = isPrivate
        self.isGroup = isGroup
        self.section = section
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        roleLabel = try c.decode(String.self, forKey: .roleLabel)
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? ModelProvider.defaultModel
        systemPrompt = try c.decodeIfPresent(String.self, forKey: .systemPrompt) ?? ""
        isMain = try c.decodeIfPresent(Bool.self, forKey: .isMain) ?? false
        isPrivate = try c.decodeIfPresent(Bool.self, forKey: .isPrivate) ?? false
        isGroup = try c.decodeIfPresent(Bool.self, forKey: .isGroup) ?? false
        section = try c.decodeIfPresent(String.self, forKey: .section) ?? "默认团队"
    }
}

@MainActor
public final class LocalAgentHost: ObservableObject {
    private static let defaultBots: [BotProfile] = [
        BotProfile(id: "main", name: "Chief", roleLabel: "Main Bot · 团队总管", model: ModelProvider.thinkingModel, isMain: true, section: "核心团队"),
        BotProfile(id: "coder", name: "Architect", roleLabel: "架构与代码审查", model: ModelProvider.thinkingModel, section: "核心团队"),
        BotProfile(id: "team_group", name: "核心研发群", roleLabel: "群聊 · 目标与待办", model: ModelProvider.defaultModel, isGroup: true, section: "协作群聊"),
        BotProfile(id: "private_vault", name: "私密助理", roleLabel: "私密会话 · 设备解锁", model: ModelProvider.defaultModel, isPrivate: true, section: "私密空间")
    ]

    @Published public private(set) var state: LocalAgentState = .idle
    @Published public private(set) var workspaceError: String?
    @Published public private(set) var models: [String] = []
    @Published public var customTools = UserDefaults.standard.bool(forKey: "dsbot.customTools") {
        didSet { UserDefaults.standard.set(customTools, forKey: "dsbot.customTools") }
    }

    public let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    public let buildNumber = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
    @Published public var bots: [BotProfile] = []
    @Published public private(set) var messagesBySession: [String: [ChatMessageItem]] = [:]
    @Published public private(set) var streamingSessionId: String?
    @Published public private(set) var streamingReasoning: String = ""
    @Published public private(set) var streamingContent: String = ""
    @Published public private(set) var isStreaming: Bool = false
    @Published public private(set) var streamFirstTokenMs: Int?
    @Published public private(set) var lastStreamError: String?
    @Published public private(set) var lastErrorSessionId: String?
    @Published public private(set) var pendingApprovals: [PendingApproval] = []
    @Published public private(set) var activeTurnId: String?
    @Published public var useBubbleLayout: Bool = (UserDefaults.standard.object(forKey: "dsbot.useBubbleLayout") as? Bool) ?? true {
        didSet { UserDefaults.standard.set(useBubbleLayout, forKey: "dsbot.useBubbleLayout") }
    }
    @Published public var apiBaseURL: String = UserDefaults.standard.string(forKey: "dsbot.apiBaseURL") ?? ModelProvider.defaultAddress {
        didSet {
            UserDefaults.standard.set(apiBaseURL, forKey: "dsbot.apiBaseURL")
            models = []
        }
    }

    var usesOfficialModels: Bool { (try? ModelProvider(apiBaseURL).isDeepSeek) == true }

    func modelSelection(_ id: String) -> String { (try? ModelProvider(apiBaseURL).selection(id)) ?? id }

    func saveAPIKey(_ key: String) throws {
        try KeychainBridge().saveModelKey(key, provider: ModelProvider(apiBaseURL))
    }

    func refreshModels() async throws -> (latency: Int, count: Int) {
        guard let channel else { throw IPCFrameError.channelClosed }
        let address = apiBaseURL
        let result = try await channel.request("models.test", params: ["apiBaseURL": address], timeoutSeconds: 95)
        let ids = result["models"] as? [String] ?? []
        if apiBaseURL == address { models = ids }
        return (result["latencyMs"] as? Int ?? 0, ids.count)
    }

    private var channel: IPCChannel?
    private let migrateOfficialKey: Bool
    private let workspace: URL
    private let persistQueue = DispatchQueue(label: "io.github.dsbot.workspace.persist", qos: .utility)
    private var workspaceReadable = true
    private var uiNotifContinuation: AsyncStream<(String, [String: Any])>.Continuation?
    private var pendingReasoningBuffer = ""
    private var pendingContentBuffer = ""
    private var flushScheduled = false
    private var streamStartedAt: Date?
    private var sentCancellation = false

    public init() {
        workspace = LocalAgentTransport.defaultWorkspace
        let defaults = UserDefaults.standard
        let migrationKey = "dsbot.canMigrateOfficialKey"
        if let eligible = defaults.object(forKey: migrationKey) as? Bool {
            migrateOfficialKey = eligible
        } else {
            let old = defaults.string(forKey: "dsbot.apiBaseURL") ?? ""
            let eligible = (try? ModelProvider(old).isDeepSeek) == true
            defaults.set(eligible, forKey: migrationKey)
            migrateOfficialKey = eligible
        }
    }

    public func messages(for sessionId: String) -> [ChatMessageItem] {
        messagesBySession[sessionId] ?? []
    }

    public func addBot(name: String, roleLabel: String, model: String, systemPrompt: String = "", isPrivate: Bool, isGroup: Bool) {
        let id = (isGroup ? "grp_" : "bot_") + String(UUID().uuidString.prefix(6)).lowercased()
        let section = isPrivate ? "私密空间" : (isGroup ? "协作群聊" : "核心团队")
        bots.append(BotProfile(id: id, name: name, roleLabel: roleLabel, model: model, systemPrompt: systemPrompt, isPrivate: isPrivate, isGroup: isGroup, section: section))
        persistWorkspace()
    }

    public func sendMessage(sessionId: String, text: String, model: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isStreaming, state == .ready, let channel else { return }
        lastErrorSessionId = sessionId
        guard trimmed.utf8.count <= 262_144 else {
            lastStreamError = "消息超过 256 KB。"
            return
        }
        guard let provider = try? ModelProvider(apiBaseURL) else {
            lastStreamError = ModelProviderError.invalidAddress.localizedDescription
            return
        }
        let turnId = UUID().uuidString
        messagesBySession[sessionId, default: []].append(ChatMessageItem(sessionId: sessionId, role: "user", content: trimmed))
        persistWorkspace()
        activeTurnId = turnId
        streamingSessionId = sessionId
        sentCancellation = false
        streamingReasoning = ""
        streamingContent = ""
        streamStartedAt = Date()
        streamFirstTokenMs = nil
        lastStreamError = nil
        isStreaming = true
        DSHaptics.impact(.light)

        let bot = bots.first(where: { $0.id == sessionId })
        let tools = provider.isDeepSeek || customTools
        let history = Self.providerHistory(messages(for: sessionId), provider: provider, model: model, tools: tools)
        do {
            _ = try await channel.request("chat.send", params: [
                "sessionId": sessionId, "turnId": turnId, "model": model, "apiBaseURL": apiBaseURL,
                "systemPrompt": bot?.systemPrompt ?? "", "isGroup": bot?.isGroup ?? false,
                "customTools": customTools, "history": history
            ])
        } catch {
            guard activeTurnId == turnId else { return }
            lastStreamError = error.localizedDescription
            finishTurn()
        }
    }

    static func providerHistory(_ history: [ChatMessageItem], provider: ModelProvider, model: String, tools: Bool) -> [[String: Any]] {
        let profile = provider.historyProfile(model: model, tools: tools)
        var pendingUser: ChatMessageItem?
        var turns: [[ProviderMessage]] = []
        for message in history {
            if message.role == "user" {
                pendingUser = message
            } else if let user = pendingUser {
                pendingUser = nil
                guard message.incomplete != true else { continue }
                let supplied = message.providerProfile == profile ? message.transcript : nil
                let assistant: [ProviderMessage]
                if tools {
                    guard let supplied else { continue }
                    assistant = supplied
                } else {
                    assistant = [ProviderMessage(role: "assistant", content: message.content)]
                }
                turns.append([ProviderMessage(role: "user", content: user.content)] + assistant)
            }
        }
        var payload = turns.suffix(8).flatMap { $0 }.map(\.payload)
        if let pendingUser { payload.append(ProviderMessage(role: "user", content: pendingUser.content).payload) }
        // Drop whole old turns if necessary to keep the IPC request within its frame size.
        var retained = Array(turns.suffix(8))
        while retained.count > 0, let bytes = try? JSONSerialization.data(withJSONObject: payload), bytes.count > 10_000_000 {
            retained.removeFirst()
            payload = retained.flatMap { $0 }.map(\.payload)
            if let pendingUser { payload.append(ProviderMessage(role: "user", content: pendingUser.content).payload) }
        }
        return payload
    }

    public func clearSession(_ sessionId: String) {
        messagesBySession[sessionId] = []
        lastStreamError = nil
        persistWorkspace()
    }

    public func updateBot(id: String, name: String, roleLabel: String, model: String, systemPrompt: String = "") {
        guard let idx = bots.firstIndex(where: { $0.id == id }) else { return }
        bots[idx].name = name
        bots[idx].roleLabel = roleLabel
        bots[idx].model = model
        bots[idx].systemPrompt = systemPrompt
        persistWorkspace()
        DSHaptics.notify(.success)
    }

    public func regenerateLastReply(sessionId: String, model: String) async {
        guard !isStreaming, state == .ready else { return }
        var list = messagesBySession[sessionId] ?? []
        if list.last?.role == "assistant" {
            list.removeLast()
        }
        guard let lastUser = list.last(where: { $0.role == "user" }) else { return }
        if list.last?.id == lastUser.id {
            list.removeLast()
        }
        messagesBySession[sessionId] = list
        persistWorkspace()
        await sendMessage(sessionId: sessionId, text: lastUser.content, model: model)
    }

    public func exportSessionMarkdown(sessionId: String, botName: String) -> String {
        let formatter = ISO8601DateFormatter()
        var lines: [String] = [
            "# DS Bot 会话导出：\(botName)",
            "",
            "- 导出时间：\(formatter.string(from: Date()))",
            "- 应用版本：\(appVersion)",
            ""
        ]
        for msg in messages(for: sessionId) {
            let speaker = msg.role == "user" ? "用户" : botName
            lines.append("## \(speaker) (\(formatter.string(from: msg.timestamp)))")
            lines.append("")
            if !msg.reasoning.isEmpty {
                lines.append("<details><summary>深度思考过程</summary>")
                lines.append("")
                lines.append(msg.reasoning)
                lines.append("")
                lines.append("</details>")
                lines.append("")
            }
            lines.append(msg.content)
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    public func deleteBot(id: String) {
        guard let target = bots.first(where: { $0.id == id }), !target.isMain else { return }
        bots.removeAll { $0.id == id }
        messagesBySession.removeValue(forKey: id)
        persistWorkspace()
        DSHaptics.impact(.medium)
    }

    public func boot() async {
        guard state != .starting, state != .ready else { return }
        state = .starting
        workspaceError = nil
        do {
            try loadPersistedWorkspace()
            let rpc = IPCChannel(transport: LocalAgentTransport(root: workspace, migrateOfficialKey: migrateOfficialKey))
            channel = rpc
            await registerUINotifications(on: rpc)
            let readiness = try await rpc.request("agent.info", timeoutSeconds: 5)
            guard readiness["engine"] as? String == "swift" else { throw IPCFrameError.invalidJSON }
            state = .ready
        } catch {
            uiNotifContinuation?.finish()
            if let channel { await channel.close() }
            self.channel = nil
            state = .failed(error.localizedDescription)
        }
    }

    public func suspendForBackground() async {
        guard let channel else { return }
        if activeTurnId != nil { sentCancellation = true }
        _ = try? await channel.request("agent.suspend")
    }

    public func resumeFromBackground() async {
        _ = try? await channel?.request("agent.resume")
    }

    public func abortActiveTurn() async {
        guard let turnId = activeTurnId, !sentCancellation else { return }
        sentCancellation = true
        pendingApprovals.removeAll { $0.turnId == turnId }
        do {
            let response = try await channel?.request("chat.abort", params: ["turnId": turnId])
            if response?["aborted"] as? Bool != true, activeTurnId == turnId { finishTurn() }
        } catch {
            if activeTurnId == turnId {
                lastStreamError = error.localizedDescription
                finishTurn()
            }
        }
    }

    public func respondToApproval(id: String, approved: Bool) async {
        guard let approval = pendingApprovals.first(where: { $0.id == id }),
              approval.turnId == activeTurnId, !sentCancellation else { return }
        pendingApprovals.removeAll { $0.id == id }
        _ = try? await channel?.request("approval.respond", params: [
            "approvalId": id, "turnId": approval.turnId, "sessionId": approval.sessionId, "approved": approved
        ])
    }

    public func rpc() -> IPCChannel? { state == .ready ? channel : nil }

    private func loadPersistedWorkspace() throws {
        do {
            try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
            func load<T: Decodable>(_ name: String, fallback: T) throws -> T {
                let file = workspace.appendingPathComponent(name)
                guard FileManager.default.fileExists(atPath: file.path) else { return fallback }
                return try JSONDecoder().decode(T.self, from: Data(contentsOf: file))
            }
            bots = try load("bots.json", fallback: Self.defaultBots)
            if bots.isEmpty { bots = Self.defaultBots }
            messagesBySession = try load("chats.json", fallback: [:])
            workspaceReadable = true
        } catch {
            workspaceReadable = false
            throw IPCFrameError.remoteError(code: -32000, message: "无法读取本机工作区。原有文件已保留。")
        }
    }

    private func persistWorkspace() {
        guard workspaceReadable else { return }
        let botsSnapshot = bots
        let chatsSnapshot = messagesBySession
        let root = workspace
        persistQueue.async { [weak self] in
            do {
                try JSONEncoder().encode(botsSnapshot).write(to: root.appendingPathComponent("bots.json"), options: .atomic)
                try JSONEncoder().encode(chatsSnapshot).write(to: root.appendingPathComponent("chats.json"), options: .atomic)
                Task { @MainActor in self?.workspaceError = nil }
            } catch {
                Task { @MainActor in self?.workspaceError = "保存本机工作区失败。请检查存储空间后重试。" }
            }
        }
    }

    private func flushPendingStreamBuffers() {
        flushScheduled = false
        if !pendingReasoningBuffer.isEmpty {
            streamingReasoning += pendingReasoningBuffer
            pendingReasoningBuffer = ""
        }
        if !pendingContentBuffer.isEmpty {
            streamingContent += pendingContentBuffer
            pendingContentBuffer = ""
        }
    }

    private func scheduleStreamFlushIfNeeded() {
        guard !flushScheduled else { return }
        flushScheduled = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 33_000_000) // ~30 FPS coalescing
            self?.flushPendingStreamBuffers()
        }
    }

    private func finishTurn(_ params: [String: Any] = [:]) {
        flushPendingStreamBuffers()
        if let sessionId = streamingSessionId, !streamingContent.isEmpty || !streamingReasoning.isEmpty {
            var item = ChatMessageItem(sessionId: sessionId, role: "assistant", content: streamingContent, reasoning: streamingReasoning)
            item.incomplete = params["status"] as? String != "completed"
            if let transcript = params["transcript"],
               let bytes = try? JSONSerialization.data(withJSONObject: transcript) {
                item.transcript = try? JSONDecoder().decode([ProviderMessage].self, from: bytes)
                item.providerProfile = params["profile"] as? String
            }
            messagesBySession[sessionId, default: []].append(item)
            persistWorkspace()
        }
        streamingReasoning = ""
        streamingContent = ""
        streamingSessionId = nil
        pendingApprovals.removeAll()
        isStreaming = false
        activeTurnId = nil
    }

    private func registerUINotifications(on rpc: IPCChannel) async {
        uiNotifContinuation?.finish()
        let (stream, continuation) = AsyncStream<(String, [String: Any])>.makeStream()
        uiNotifContinuation = continuation
        _ = await rpc.onNotification { method, params in
            continuation.yield((method, params))
        }
        Task { @MainActor [weak self] in
            for await (method, params) in stream {
                guard let self else { break }
                if method == "approval.closed" {
                    self.pendingApprovals.removeAll { $0.id == params["approvalId"] as? String }
                    continue
                }
                guard let turnId = params["turnId"] as? String, self.activeTurnId == turnId,
                      let sessionId = params["sessionId"] as? String, sessionId == self.streamingSessionId else { continue }
                switch method {
                case "chat.delta":
                    guard !self.sentCancellation else { continue }
                    if self.streamFirstTokenMs == nil, let start = self.streamStartedAt {
                        self.streamFirstTokenMs = max(1, Int(Date().timeIntervalSince(start) * 1_000))
                    }
                    self.pendingReasoningBuffer += params["reasoning"] as? String ?? ""
                    self.pendingContentBuffer += params["content"] as? String ?? ""
                    self.scheduleStreamFlushIfNeeded()
                case "chat.done":
                    self.lastStreamError = params["error"] as? String
                    self.finishTurn(params)
                case "approval.request":
                    guard !self.sentCancellation, let id = params["approvalId"] as? String,
                          let tool = params["tool"] as? String, let summary = params["summary"] as? String else { continue }
                    self.pendingApprovals.append(PendingApproval(id: id, sessionId: sessionId, turnId: turnId, tool: tool, summary: summary))
                default: break
                }
            }
        }
    }
}

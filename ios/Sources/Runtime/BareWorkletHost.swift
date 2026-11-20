import Foundation

public enum WorkletBootState: Equatable {
    case idle
    case booting(version: String)
    case ready(version: String, isBaseline: Bool)
    case rolledBack(from: String, to: String, reason: String)
    case failed(String)
}

public struct PendingApproval: Identifiable, Equatable {
    public let id: String
    public let sessionId: String
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

    public init(id: String, name: String, roleLabel: String, model: String = "deepseek-chat", systemPrompt: String = "", isMain: Bool = false, isPrivate: Bool = false, isGroup: Bool = false, section: String = "默认团队") {
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
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? "deepseek-chat"
        systemPrompt = try c.decodeIfPresent(String.self, forKey: .systemPrompt) ?? ""
        isMain = try c.decodeIfPresent(Bool.self, forKey: .isMain) ?? false
        isPrivate = try c.decodeIfPresent(Bool.self, forKey: .isPrivate) ?? false
        isGroup = try c.decodeIfPresent(Bool.self, forKey: .isGroup) ?? false
        section = try c.decodeIfPresent(String.self, forKey: .section) ?? "默认团队"
    }
}

private actor BootSignalWaiter {
    private var continuation: CheckedContinuation<Void, Error>?
    private var settled = false
    private var result: Result<Void, Error>?

    func awaitSignal() async throws {
        if let existing = result {
            try existing.get()
            return
        }
        try await withCheckedThrowingContinuation { cont in
            if let existing = result {
                cont.resume(with: existing)
            } else {
                self.continuation = cont
            }
        }
    }

    func resolve() {
        guard !settled else { return }
        settled = true
        result = .success(())
        continuation?.resume(returning: ())
        continuation = nil
    }

    func reject(_ error: Error) {
        guard !settled else { return }
        settled = true
        result = .failure(error)
        continuation?.resume(throwing: error)
        continuation = nil
    }
}

/// Manages the BareKit / LocalAgent worklet running DSH 0.2.2-rc.5 with 5-second watchdog auto-rollback,
/// disk-persisted multi-session chat history & Bot roster, streaming reasoning/content, and native iOS bridges.
@MainActor
public final class BareWorkletHost: ObservableObject {
    private static let defaultBots: [BotProfile] = [
        BotProfile(id: "main", name: "Chief", roleLabel: "Main Bot · 团队总管", model: "deepseek-reasoner", isMain: true, section: "核心团队"),
        BotProfile(id: "coder", name: "Architect", roleLabel: "架构与代码审查", model: "deepseek-reasoner", section: "核心团队"),
        BotProfile(id: "team_group", name: "核心研发群", roleLabel: "群聊 · 管理员控费", model: "deepseek-chat", isGroup: true, section: "协作群聊"),
        BotProfile(id: "private_vault", name: "私密助理", roleLabel: "隐私 Bot · Face ID 隔离", model: "deepseek-chat", isPrivate: true, section: "私密空间")
    ]

    @Published public private(set) var state: WorkletBootState = .idle
    @Published public private(set) var activeVersion: String = KernelManager.baselineVersion
    @Published public var bots: [BotProfile] = []
    @Published public private(set) var messagesBySession: [String: [ChatMessageItem]] = [:]
    @Published public private(set) var streamingSessionId: String?
    @Published public private(set) var streamingReasoning: String = ""
    @Published public private(set) var streamingContent: String = ""
    @Published public private(set) var isStreaming: Bool = false
    @Published public private(set) var streamFirstTokenMs: Int?
    @Published public private(set) var lastStreamError: String?
    @Published public private(set) var pendingApprovals: [PendingApproval] = []
    @Published public private(set) var activeTurnId: String?
    @Published public var useBubbleLayout: Bool = (UserDefaults.standard.object(forKey: "dsbot.useBubbleLayout") as? Bool) ?? true {
        didSet { UserDefaults.standard.set(useBubbleLayout, forKey: "dsbot.useBubbleLayout") }
    }
    @Published public var apiBaseURL: String = UserDefaults.standard.string(forKey: "dsbot.apiBaseURL") ?? "https://api.deepseek.com" {
        didSet { UserDefaults.standard.set(apiBaseURL, forKey: "dsbot.apiBaseURL") }
    }

    public let kernelManager: KernelManager
    private let watchdogTimeoutSeconds: TimeInterval
    private var channel: IPCChannel?
    private let sqliteBridge: SQLiteBridge
    private let networkBridge: NetworkBridge
    private let keychainBridge: KeychainBridge
    private let dshHomeURL: URL
    private let persistQueue = DispatchQueue(label: "io.github.dsbot.workspace.persist", qos: .utility)
    private var cancelledTurnIds: Set<String> = []
    private var uiNotifContinuation: AsyncStream<(String, [String: Any])>.Continuation?
    private var pendingReasoningBuffer: String = ""
    private var pendingContentBuffer: String = ""
    private var flushScheduled: Bool = false
    private var streamStartedAt: Date?

    public init(
        kernelManager: KernelManager = KernelManager(),
        watchdogTimeoutSeconds: TimeInterval = 5.0
    ) {
        self.kernelManager = kernelManager
        self.watchdogTimeoutSeconds = watchdogTimeoutSeconds
        self.sqliteBridge = SQLiteBridge()
        self.networkBridge = NetworkBridge()
        self.keychainBridge = KeychainBridge()
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        self.dshHomeURL = docs.appendingPathComponent("dsh-home", isDirectory: true)
        try? FileManager.default.createDirectory(at: dshHomeURL, withIntermediateDirectories: true)
        loadPersistedWorkspace()
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
        guard !trimmed.isEmpty else { return }
        if isStreaming {
            await abortActiveTurn()
        }
        let turnId = "turn_\(UUID().uuidString.prefix(8))"
        messagesBySession[sessionId, default: []].append(
            ChatMessageItem(sessionId: sessionId, role: "user", content: trimmed)
        )
        persistWorkspace()
        activeTurnId = turnId
        streamingSessionId = sessionId
        pendingReasoningBuffer = ""
        pendingContentBuffer = ""
        flushScheduled = false
        streamingReasoning = ""
        streamingContent = ""
        streamStartedAt = Date()
        streamFirstTokenMs = nil
        lastStreamError = nil
        isStreaming = true
        DSHaptics.impact(.light)

        let historyPayload: [[String: String]] = messages(for: sessionId).suffix(16).map {
            ["role": $0.role, "content": $0.content]
        }

        let customPrompt = bots.first(where: { $0.id == sessionId })?.systemPrompt ?? ""
        if let rpc = channel {
            _ = try? await rpc.request("chat.send", params: [
                "sessionId": sessionId,
                "turnId": turnId,
                "text": trimmed,
                "model": model,
                "apiBaseURL": apiBaseURL,
                "systemPrompt": customPrompt,
                "history": historyPayload
            ])
        } else {
            isStreaming = false
            activeTurnId = nil
            streamingSessionId = nil
        }
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
        guard !isStreaming else { return }
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
            "- 内核版本：DSH \(activeVersion)",
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

    public func boot(transportFactory: (URL) throws -> IPCByteTransport) async {
        await shutdown()
        do {
            let resolved = try kernelManager.resolveActiveKernel()
            state = .booting(version: resolved.manifest.dshVersion)

            do {
                try await startAndAwaitReady(bundleURL: resolved.bundleURL, manifest: resolved.manifest, transportFactory: transportFactory)
                activeVersion = resolved.manifest.dshVersion
                state = .ready(version: resolved.manifest.dshVersion, isBaseline: resolved.isBaseline)
            } catch {
                await teardownChannel()
                if !resolved.isBaseline {
                    let faultyVersion = resolved.manifest.dshVersion
                    kernelManager.rollbackFromFaultyKernel(version: faultyVersion)
                    let fallback = try kernelManager.resolveActiveKernel()
                    try await startAndAwaitReady(bundleURL: fallback.bundleURL, manifest: fallback.manifest, transportFactory: transportFactory)
                    activeVersion = fallback.manifest.dshVersion
                    state = .rolledBack(from: faultyVersion, to: fallback.manifest.dshVersion, reason: error.localizedDescription)
                    DSHaptics.notify(.warning)
                } else {
                    state = .failed(error.localizedDescription)
                    DSHaptics.notify(.error)
                }
            }
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    public func suspendForBackground() async {
        if isStreaming {
            if let tid = activeTurnId { cancelledTurnIds.insert(tid) }
            commitActiveStreamIfNeeded()
            isStreaming = false
            activeTurnId = nil
        }
        persistWorkspace()
        _ = try? await channel?.request("kernel.suspend")
    }

    public func resumeFromBackground() async {
        _ = try? await channel?.request("kernel.resume")
    }

    public func abortActiveTurn() async {
        let turnId = activeTurnId
        if let turnId {
            cancelledTurnIds.insert(turnId)
            _ = try? await channel?.request("chat.abort", params: ["turnId": turnId])
        }
        commitActiveStreamIfNeeded()
        isStreaming = false
        activeTurnId = nil
        streamingSessionId = nil
        DSHaptics.impact(.medium)
    }

    public func respondToApproval(id: String, approved: Bool) async {
        pendingApprovals.removeAll { $0.id == id }
        _ = try? await channel?.request("approval.respond", params: ["approvalId": id, "approved": approved])
        DSHaptics.notify(approved ? .success : .warning)
    }

    public func shutdown() async {
        persistWorkspace()
        if let ch = channel {
            _ = try? await ch.request("kernel.shutdown")
        }
        await teardownChannel()
        state = .idle
    }

    public func rpc() -> IPCChannel? { channel }

    private func loadPersistedWorkspace() {
        let botsURL = dshHomeURL.appendingPathComponent("bots.json")
        if let data = try? Data(contentsOf: botsURL),
           let decoded = try? JSONDecoder().decode([BotProfile].self, from: data),
           !decoded.isEmpty {
            bots = decoded
        } else {
            bots = Self.defaultBots
        }
        let chatsURL = dshHomeURL.appendingPathComponent("chats.json")
        if let data = try? Data(contentsOf: chatsURL),
           let decoded = try? JSONDecoder().decode([String: [ChatMessageItem]].self, from: data) {
            messagesBySession = decoded
        }
    }

    private func persistWorkspace() {
        let botsSnapshot = bots
        let chatsSnapshot = messagesBySession
        let root = dshHomeURL
        persistQueue.async {
            if let botsData = try? JSONEncoder().encode(botsSnapshot) {
                try? botsData.write(to: root.appendingPathComponent("bots.json"), options: .atomic)
            }
            if let chatsData = try? JSONEncoder().encode(chatsSnapshot) {
                try? chatsData.write(to: root.appendingPathComponent("chats.json"), options: .atomic)
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

    private func commitActiveStreamIfNeeded() {
        flushPendingStreamBuffers()
        guard let sid = streamingSessionId,
              (!streamingContent.isEmpty || !streamingReasoning.isEmpty) else { return }
        messagesBySession[sid, default: []].append(
            ChatMessageItem(sessionId: sid, role: "assistant", content: streamingContent, reasoning: streamingReasoning)
        )
        persistWorkspace()
        streamingReasoning = ""
        streamingContent = ""
        streamingSessionId = nil
    }

    private func teardownChannel() async {
        uiNotifContinuation?.finish()
        uiNotifContinuation = nil
        await networkBridge.cancelAllStreams()
        if let ch = channel { await ch.close() }
        channel = nil
        isStreaming = false
        activeTurnId = nil
        pendingApprovals.removeAll()
    }

    private func startAndAwaitReady(
        bundleURL: URL,
        manifest: KernelManifest,
        transportFactory: (URL) throws -> IPCByteTransport
    ) async throws {
        let transport = try transportFactory(bundleURL)
        let rpcChannel = IPCChannel(transport: transport)
        self.channel = rpcChannel
        await registerNativeBridges(on: rpcChannel)
        await registerUINotifications(on: rpcChannel)

        let waiter = BootSignalWaiter()
        let token = await rpcChannel.onNotification { method, params in
            if method == "kernel.ready" {
                Task { await waiter.resolve() }
            } else if method == "kernel.fatal" {
                let msg = params["message"] as? String ?? "Kernel fatal error"
                Task { await waiter.reject(IPCFrameError.remoteError(code: -32001, message: msg)) }
            }
        }

        let watchdogTask = Task { [watchdogTimeoutSeconds] in
            try? await Task.sleep(nanoseconds: UInt64(watchdogTimeoutSeconds * 1_000_000_000))
            if !Task.isCancelled {
                await waiter.reject(IPCFrameError.timeout(method: "kernel.ready (\(manifest.dshVersion))"))
            }
        }

        defer {
            watchdogTask.cancel()
            Task { await rpcChannel.removeNotificationHandler(token) }
        }

        try await waiter.awaitSignal()
    }

    private func registerUINotifications(on rpc: IPCChannel) async {
        uiNotifContinuation?.finish()
        var captured: AsyncStream<(String, [String: Any])>.Continuation?
        let stream = AsyncStream<(String, [String: Any])> { cont in
            captured = cont
        }
        let cont = captured!
        self.uiNotifContinuation = cont

        Task { @MainActor [weak self] in
            for await (method, params) in stream {
                guard let self else { break }
                switch method {
                case "chat.delta":
                    let turnId = params["turnId"] as? String
                    if let turnId, self.cancelledTurnIds.contains(turnId) { continue }
                    if let currentTurn = self.activeTurnId, let turnId, turnId != currentTurn { continue }
                    self.isStreaming = true
                    if self.streamFirstTokenMs == nil, let t0 = self.streamStartedAt {
                        self.streamFirstTokenMs = max(1, Int(Date().timeIntervalSince(t0) * 1000))
                    }
                    if let sid = params["sessionId"] as? String { self.streamingSessionId = sid }
                    if let turnId { self.activeTurnId = turnId }
                    if let reasoning = params["reasoning"] as? String { self.pendingReasoningBuffer += reasoning }
                    if let content = params["content"] as? String { self.pendingContentBuffer += content }
                    self.scheduleStreamFlushIfNeeded()
                case "chat.done":
                    let turnId = params["turnId"] as? String
                    if let turnId, self.cancelledTurnIds.remove(turnId) != nil { continue }
                    if let currentTurn = self.activeTurnId, let turnId, turnId != currentTurn { continue }
                    if (params["status"] as? String) == "error" {
                        self.lastStreamError = params["error"] as? String ?? "流式响应中断，请重试。"
                    }
                    self.commitActiveStreamIfNeeded()
                    self.isStreaming = false
                    self.activeTurnId = nil
                    self.streamingSessionId = nil
                case "approval.request":
                    let id = params["approvalId"] as? String ?? UUID().uuidString
                    let sess = params["sessionId"] as? String ?? "main"
                    let tool = params["tool"] as? String ?? "tool"
                    let summary = params["summary"] as? String ?? "Approve tool execution?"
                    self.pendingApprovals.append(PendingApproval(id: id, sessionId: sess, tool: tool, summary: summary))
                    DSHaptics.notify(.warning)
                default:
                    break
                }
            }
        }

        _ = await rpc.onNotification { method, params in
            cont.yield((method, params))
        }
    }

    private func registerNativeBridges(on rpc: IPCChannel) async {
        await rpc.registerHandler(method: "bridge.sqlite.open") { [sqliteBridge] params in
            try sqliteBridge.open(path: params["path"] as? String ?? "")
        }
        await rpc.registerHandler(method: "bridge.sqlite.exec") { [sqliteBridge] params in
            try sqliteBridge.exec(path: params["path"] as? String ?? "", sql: params["sql"] as? String ?? "")
        }
        await rpc.registerHandler(method: "bridge.sqlite.run") { [sqliteBridge] params in
            try sqliteBridge.run(path: params["path"] as? String ?? "", sql: params["sql"] as? String ?? "", params: params["params"] as? [Any] ?? [])
        }
        await rpc.registerHandler(method: "bridge.sqlite.query") { [sqliteBridge] params in
            try sqliteBridge.query(path: params["path"] as? String ?? "", sql: params["sql"] as? String ?? "", params: params["params"] as? [Any] ?? [])
        }
        await rpc.registerHandler(method: "bridge.sqlite.close") { [sqliteBridge] params in
            try sqliteBridge.close(path: params["path"] as? String ?? "")
        }
        await rpc.registerHandler(method: "bridge.net.request") { [networkBridge] params in
            try await networkBridge.request(params: params)
        }
        await rpc.registerHandler(method: "bridge.net.sseStart") { [networkBridge] params in
            try await networkBridge.sseStart(params: params, channel: rpc)
        }
        await rpc.registerHandler(method: "bridge.net.sseCancel") { [networkBridge] params in
            await networkBridge.sseCancel(streamId: params["streamId"] as? String ?? "")
        }
        await rpc.registerHandler(method: "bridge.keychain.get") { [keychainBridge] params in
            try await keychainBridge.getSecret(account: params["account"] as? String ?? "", requireBiometrics: params["requireBiometrics"] as? Bool ?? false)
        }
        await rpc.registerHandler(method: "bridge.keychain.set") { [keychainBridge] params in
            try keychainBridge.setSecret(account: params["account"] as? String ?? "", value: params["value"] as? String ?? "")
        }
        await rpc.registerHandler(method: "bridge.keychain.delete") { [keychainBridge] params in
            try keychainBridge.deleteSecret(account: params["account"] as? String ?? "")
        }
    }
}

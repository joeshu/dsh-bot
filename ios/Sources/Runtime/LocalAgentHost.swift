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

public struct DSHPluginSource: Identifiable, Decodable, Equatable {
    public let id: String
    public let name: String
    public let url: String
    public let enabled: Bool
    public let builtIn: Bool
}

public struct DSHPluginCatalogItem: Identifiable, Decodable, Equatable {
    public let name: String
    public let title: String
    public let description: String
    public let version: String
    public let homepage: String
    public let repositoryURL: String
    public let category: String
    public let sourceId: String
    public let sourceName: String
    public let installable: Bool
    public let installSource: String

    public var id: String { "\(sourceId):\(name)" }
}

public struct DSHInstalledPlugin: Identifiable, Decodable, Equatable {
    public let name: String
    public let version: String
    public let enabled: Bool
    public var id: String { name }
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
    public static let shared = LocalAgentHost()

    private static let defaultBots: [BotProfile] = [
        BotProfile(id: "main", name: "Chief", roleLabel: "Main Bot · 团队总管", model: ModelProvider.thinkingModel, isMain: true, section: "核心团队"),
        BotProfile(id: "coder", name: "Architect", roleLabel: "架构与代码审查", model: ModelProvider.thinkingModel, section: "核心团队"),
        BotProfile(id: "team_group", name: "核心研发群", roleLabel: "群聊 · 目标与待办", model: ModelProvider.defaultModel, isGroup: true, section: "协作群聊"),
        BotProfile(id: "private_vault", name: "私密助理", roleLabel: "私密会话 · 设备解锁", model: ModelProvider.defaultModel, isPrivate: true, section: "私密空间")
    ]

    @Published public private(set) var state: LocalAgentState = .idle
    @Published public private(set) var workspaceError: String?
    @Published public private(set) var models: [String] = []
    @Published public var subagentEnabled = UserDefaults.standard.bool(forKey: "dsbot.subagentEnabled") {
        didSet { UserDefaults.standard.set(subagentEnabled, forKey: "dsbot.subagentEnabled") }
    }
    @Published public var customTools = UserDefaults.standard.bool(forKey: "dsbot.customTools") {
        didSet { UserDefaults.standard.set(customTools, forKey: "dsbot.customTools") }
    }

    public let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    public let buildNumber = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
    @Published public var bots: [BotProfile] = []
    @Published public private(set) var messagesBySession: [String: [ChatMessageItem]] = [:]
    private var legacyMessagesBySession: [String: [ChatMessageItem]] = [:]
    @Published public private(set) var streamingSessionId: String?
    @Published public private(set) var streamingReasoning: String = ""
    @Published public private(set) var streamingContent: String = ""
    @Published public private(set) var isStreaming: Bool = false
    @Published public private(set) var streamFirstTokenMs: Int?
    @Published public private(set) var lastStreamError: String?
    @Published public private(set) var lastErrorSessionId: String?
    @Published public private(set) var lastCancelledSessionId: String?
    @Published public private(set) var pendingApprovals: [PendingApproval] = []
    @Published public private(set) var pluginSources: [DSHPluginSource] = []
    @Published public private(set) var pluginCatalog: [DSHPluginCatalogItem] = []
    @Published public private(set) var installedPlugins: [DSHInstalledPlugin] = []
    @Published public private(set) var pluginSourceName: String?
    @Published public private(set) var pluginStatus: String?
    @Published public private(set) var isLoadingPlugins = false
    @Published public private(set) var pluginCatalogTotal = 0
    @Published public private(set) var embeddedRuntimeLabel: String?
    private var pluginCatalogRequest = UUID()
    private var pluginCatalogQuery = ""
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
    private var runtimeReady = false
    private var runtimeStartupError: IPCFrameError?
    private var runtimeReadyContinuation: CheckedContinuation<Void, Error>?
    private var runtimeReadyTimeoutTask: Task<Void, Never>?
    private let migrateOfficialKey: Bool
    private let keychain: KeychainBridge
    private let workspaceCapabilities: LocalAgentTransport
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
        let workspaceURL = LocalAgentTransport.defaultWorkspace
        workspace = workspaceURL
        let defaults = UserDefaults.standard
        let migrationKey = "dsbot.canMigrateOfficialKey"
        let migrationAllowed: Bool
        if let eligible = defaults.object(forKey: migrationKey) as? Bool {
            migrationAllowed = eligible
        } else {
            let old = defaults.string(forKey: "dsbot.apiBaseURL") ?? ""
            let eligible = (try? ModelProvider(old).isDeepSeek) == true
            defaults.set(eligible, forKey: migrationKey)
            migrationAllowed = eligible
        }
        migrateOfficialKey = migrationAllowed
        let keychainBridge = KeychainBridge()
        keychain = keychainBridge
        workspaceCapabilities = LocalAgentTransport(
            root: workspaceURL,
            keychain: keychainBridge,
            migrateOfficialKey: migrationAllowed
        )
        workspaceCapabilities.setNativeNotificationHandler { [weak self] method, params in
            Task { @MainActor [weak self] in
                guard let channel = self?.channel else { return }
                try? await channel.notify(method, params: params)
            }
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
        lastCancelledSessionId = nil
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
        let legacyHistory = (legacyMessagesBySession[sessionId] ?? []).suffix(12).map { message in
            ["role": message.role, "content": String(message.content.prefix(12_000))]
        }
        do {
            _ = try await channel.request("chat.send", params: [
                "sessionId": sessionId, "turnId": turnId, "model": model, "apiBaseURL": apiBaseURL,
                "systemPrompt": bot?.systemPrompt ?? "", "isGroup": bot?.isGroup ?? false,
                "subagentEnabled": subagentEnabled, "customTools": customTools, "text": trimmed, "legacyHistory": legacyHistory
            ])
        } catch {
            guard activeTurnId == turnId else { return }
            lastStreamError = error.localizedDescription
            finishTurn()
        }
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
        // DSH sessions are append-only event logs. Retrying creates another turn
        // with the same prompt so the visible transcript stays aligned with the
        // durable history after the next app launch.
        guard let lastUser = messagesBySession[sessionId]?.last(where: { $0.role == "user" }) else { return }
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
        legacyMessagesBySession.removeValue(forKey: id)
        Task { [weak self] in await self?.deleteDSHSession(id) }
        persistWorkspace()
        DSHaptics.impact(.medium)
    }

    public func boot() async {
        guard state != .starting, state != .ready else { return }
        state = .starting
        runtimeReady = false
        runtimeStartupError = nil
        runtimeReadyContinuation = nil
        runtimeReadyTimeoutTask?.cancel()
        runtimeReadyTimeoutTask = nil
        workspaceError = nil
        do {
            try loadPersistedWorkspace()
            let transport = try NodeRuntimeTransport.prepare(apiBaseURL: apiBaseURL)
            let rpc = IPCChannel(transport: transport)
            channel = rpc
            await rpc.onClose { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.resolveRuntimeReadiness(.channelClosed)
                    guard self.state == .ready else { return }
                    if let turnId = self.activeTurnId, let sessionId = self.streamingSessionId {
                        Task { await self.workspaceCapabilities.cancelNativeTool(botId: sessionId, turnId: turnId) }
                    }
                    self.pendingApprovals.removeAll()
                    let message = "内嵌 DSH 运行时已退出，请重新启动应用。"
                    if self.isStreaming {
                        self.lastStreamError = message
                        self.finishTurn(["status": "error"])
                    }
                    self.state = .failed(message)
                }
            }
            await registerUINotifications(on: rpc)
            await registerRuntimeBridge(on: rpc)
            transport.launch()
            try await waitForRuntimeReady(timeoutSeconds: 60)
            let readiness = try await rpc.request("agent.info", timeoutSeconds: 10)
            guard try EmbeddedRuntimeManifest.load().matches(readiness) else { throw IPCFrameError.invalidJSON }
            if let dsh = readiness["dshVersion"] as? String, let node = readiness["nodeVersion"] as? String {
                embeddedRuntimeLabel = "DSH \(dsh) · Node \(node)"
            }
            await loadDSHSessions(on: rpc)
            await refreshPluginState(on: rpc)
            state = .ready
        } catch {
            resolveRuntimeReadiness(.remoteError(code: -32000, message: error.localizedDescription))
            uiNotifContinuation?.finish()
            if let channel { await channel.close() }
            self.channel = nil
            state = .failed(error.localizedDescription)
        }
    }

    public func suspendForBackground() async {
        guard let channel else { return }
        if activeTurnId != nil {
            sentCancellation = true
            pendingApprovals.removeAll()
        }
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

    public func refreshPluginState() async {
        guard let channel else { return }
        await refreshPluginState(on: channel)
    }

    public func setPluginStatus(_ value: String) {
        pluginStatus = value
    }

    public func discoverPlugins(query: String = "", forceRefresh: Bool = false, nextPage: Bool = false) async {
        guard let channel else { return }
        if nextPage && (isLoadingPlugins || pluginCatalog.count >= pluginCatalogTotal || query != pluginCatalogQuery) { return }
        let request = UUID()
        pluginCatalogRequest = request
        pluginCatalogQuery = query
        if !nextPage {
            pluginCatalog = []
            pluginCatalogTotal = 0
        }
        isLoadingPlugins = true
        defer { if pluginCatalogRequest == request { isLoadingPlugins = false } }
        do {
            let result = try await channel.request("plugins.catalog.search", params: [
                "query": query, "offset": pluginCatalog.count, "limit": 80, "refresh": forceRefresh
            ], timeoutSeconds: 35)
            guard pluginCatalogRequest == request else { return }
            pluginCatalog += Self.decodeRows(result["plugins"], as: DSHPluginCatalogItem.self)
            pluginSourceName = result["source"] as? String
            pluginCatalogTotal = result["total"] as? Int ?? pluginCatalog.count
        } catch {
            if pluginCatalogRequest == request { pluginStatus = error.localizedDescription }
        }
    }

    private func invalidatePluginCatalog() {
        pluginCatalogRequest = UUID()
        isLoadingPlugins = false
        pluginCatalog = []
        pluginCatalogTotal = 0
        pluginSourceName = nil
    }

    public func setPluginSourceEnabled(id: String, enabled: Bool) async {
        guard let channel else { return }
        do {
            let result = try await channel.request("plugins.sources.enable", params: ["id": id, "enabled": enabled])
            pluginSources = Self.decodeRows(result["sources"], as: DSHPluginSource.self)
            invalidatePluginCatalog()
            pluginStatus = enabled ? "索引源已启用。" : "索引源已停用。"
        } catch { pluginStatus = error.localizedDescription }
    }

    public func addPluginSource(url: String) async {
        guard let channel else { return }
        do {
            let result = try await channel.request("plugins.sources.add", params: ["url": url])
            pluginSources = Self.decodeRows(result["sources"], as: DSHPluginSource.self)
            pluginStatus = "已添加索引源；默认关闭，启用后才能浏览。"
        } catch { pluginStatus = error.localizedDescription }
    }

    public func removePluginSource(id: String) async {
        guard let channel else { return }
        do {
            let result = try await channel.request("plugins.sources.remove", params: ["id": id])
            pluginSources = Self.decodeRows(result["sources"], as: DSHPluginSource.self)
            pluginStatus = "已移除自定义索引源。"
        } catch { pluginStatus = error.localizedDescription }
    }

    public func installPlugin(_ item: DSHPluginCatalogItem) async {
        guard item.installable, let channel else { return }
        pluginStatus = "正在下载并检查 \(item.name)@\(item.version)…"
        do {
            let outcome = try await channel.request("plugins.install.npm", params: [
                "name": item.name, "version": item.version, "sourceId": item.sourceId
            ], timeoutSeconds: 180)
            await refreshPluginState(on: channel)
            pluginStatus = try await pluginMutationStatus(outcome, on: channel, applied: "\(item.name) 已安装并启用。")
        } catch { pluginStatus = error.localizedDescription }
    }

    public func setPluginEnabled(_ plugin: DSHInstalledPlugin, enabled: Bool) async {
        guard let channel else { return }
        do {
            let outcome = try await channel.request("plugins.enable", params: ["name": plugin.name, "enabled": enabled], timeoutSeconds: 60)
            await refreshPluginState(on: channel)
            let applied = enabled ? "\(plugin.name) 已启用。" : "\(plugin.name) 已停用。"
            pluginStatus = try await pluginMutationStatus(outcome, on: channel, applied: applied)
        } catch { pluginStatus = error.localizedDescription }
    }

    public func removePlugin(_ plugin: DSHInstalledPlugin) async {
        guard let channel else { return }
        do {
            let outcome = try await channel.request("plugins.remove", params: ["name": plugin.name], timeoutSeconds: 60)
            await refreshPluginState(on: channel)
            pluginStatus = try await pluginMutationStatus(outcome, on: channel, applied: "\(plugin.name) 已卸载。")
        } catch { pluginStatus = error.localizedDescription }
    }

    public func installLocalPlugin(from url: URL) async {
        guard let channel else { return }
        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
        let importRoot = workspace.appendingPathComponent("plugin-imports", isDirectory: true)
        let staged = importRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: importRoot, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: url, to: staged)
            defer { try? FileManager.default.removeItem(at: staged) }
            pluginStatus = "正在检查本地 DSH bundle…"
            let outcome = try await channel.request("plugins.install.local", params: ["path": staged.path], timeoutSeconds: 120)
            await refreshPluginState(on: channel)
            pluginStatus = try await pluginMutationStatus(outcome, on: channel, applied: "本地插件已安装并启用。")
        } catch { pluginStatus = error.localizedDescription }
    }

    private func pluginMutationStatus(_ outcome: [String: Any], on channel: IPCChannel, applied: String) async throws -> String {
        guard outcome["restartRequired"] as? Bool == true else { return applied }
        pluginStatus = "正在重启 DSH 引擎并检查插件。"
        let result = try await channel.request("runtime.restart", timeoutSeconds: 115)
        await refreshPluginState(on: channel)
        if result["safeMode"] as? Bool == true { return "DSH 已进入恢复模式，第三方插件未加载。" }
        if result["rolledBack"] as? Bool == true { return "插件未能启动，已恢复上次可用配置。" }
        return applied
    }

    private func refreshPluginState(on rpc: IPCChannel) async {
        do {
            let sources = try await rpc.request("plugins.sources.list", timeoutSeconds: 15)
            let installed = try await rpc.request("plugins.installed.list", timeoutSeconds: 15)
            pluginSources = Self.decodeRows(sources["sources"], as: DSHPluginSource.self)
            installedPlugins = Self.decodeRows(installed["plugins"], as: DSHInstalledPlugin.self)
        } catch {
            pluginStatus = "读取插件 profile 失败：\(error.localizedDescription)"
        }
    }

    private static func decodeRows<T: Decodable>(_ value: Any?, as type: T.Type) -> [T] {
        guard let value, let data = try? JSONSerialization.data(withJSONObject: value) else { return [] }
        return (try? JSONDecoder().decode([T].self, from: data)) ?? []
    }

    public func clearSession(_ sessionId: String) async {
        guard let channel else { return }
        do {
            _ = try await channel.request("session.clear", params: ["sessionId": sessionId], timeoutSeconds: 60)
            messagesBySession[sessionId] = []
            legacyMessagesBySession[sessionId] = []
            lastStreamError = nil
            persistWorkspace()
        } catch {
            workspaceError = "清空 DSH 会话失败：\(error.localizedDescription)"
        }
    }

    private func deleteDSHSession(_ sessionId: String) async {
        guard let channel else { return }
        _ = try? await channel.request("session.clear", params: ["sessionId": sessionId], timeoutSeconds: 60)
    }

    private func loadDSHSessions(on rpc: IPCChannel) async {
        do {
            let listing = try await rpc.request("session.list", timeoutSeconds: 30)
            let sessions = listing["sessions"] as? [[String: Any]] ?? []
            messagesBySession = legacyMessagesBySession
            for session in sessions {
                guard let id = session["sessionId"] as? String,
                      bots.contains(where: { $0.id == id }) else { continue }
                let response = try await rpc.request("session.history", params: ["sessionId": id], timeoutSeconds: 30)
                let records = response["messages"] as? [[String: Any]] ?? []
                let persisted = records.compactMap { record -> ChatMessageItem? in
                    guard let role = record["role"] as? String,
                          let content = record["content"] as? String else { return nil }
                    var message = ChatMessageItem(
                        id: record["id"] as? String ?? UUID().uuidString,
                        sessionId: id,
                        role: role,
                        content: content,
                        reasoning: record["reasoning"] as? String ?? "",
                        timestamp: Self.sessionDate(record["timestamp"])
                    )
                    message.incomplete = false
                    return message
                }
                messagesBySession[id, default: []].append(contentsOf: persisted)
            }
            persistWorkspace()
        } catch {
            workspaceError = "读取 DSH 会话失败：\(error.localizedDescription)"
        }
    }

    private static func sessionDate(_ value: Any?) -> Date {
        if let milliseconds = value as? NSNumber {
            return Date(timeIntervalSince1970: milliseconds.doubleValue / 1_000)
        }
        return Date()
    }

    private func waitForRuntimeReady(timeoutSeconds: UInt64) async throws {
        if runtimeReady { return }
        if let runtimeStartupError { throw runtimeStartupError }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            if runtimeReady {
                continuation.resume()
                return
            }
            if let runtimeStartupError {
                continuation.resume(throwing: runtimeStartupError)
                return
            }
            runtimeReadyContinuation = continuation
            runtimeReadyTimeoutTask = Task { @MainActor [weak self] in
                do { try await Task.sleep(nanoseconds: min(timeoutSeconds, 300) * 1_000_000_000) }
                catch { return }
                self?.resolveRuntimeReadiness(.timeout(method: "runtime.ready"))
            }
        }
    }

    private func resolveRuntimeReadiness(_ error: IPCFrameError? = nil) {
        guard !runtimeReady else { return }
        if let error { runtimeStartupError = error }
        else { runtimeReady = true }
        runtimeReadyTimeoutTask?.cancel()
        runtimeReadyTimeoutTask = nil
        guard let continuation = runtimeReadyContinuation else { return }
        runtimeReadyContinuation = nil
        if let error { continuation.resume(throwing: error) }
        else { continuation.resume() }
    }

    private struct EmbeddedRuntimeManifest: Decodable {
        struct Node: Decodable { let version: String }
        struct Profile: Decodable { let name: String }
        let dshVersion: String
        let node: Node
        let iosProfile: Profile

        static func load() throws -> Self {
            guard let url = Bundle.main.url(forResource: "runtime-manifest", withExtension: "json", subdirectory: "DSHRuntime") else {
                throw IPCFrameError.invalidJSON
            }
            return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        }

        func matches(_ value: [String: Any]) -> Bool {
            value["engine"] as? String == "node+dsh"
                && value["dshVersion"] as? String == dshVersion
                && value["nodeVersion"] as? String == node.version
                && value["ipcProtocolVersion"] as? String == "1.0.0"
                && value["bootLifecycle"] as? String == "official-runProfile"
                && (value["profile"] as? [String: Any])?["name"] as? String == iosProfile.name
        }
    }

    private func showPluginRecovery() {
        pluginStatus = "DSH 已进入恢复模式。可在插件页停用或卸载问题插件。"
    }

    private func registerRuntimeBridge(on rpc: IPCChannel) async {
        await rpc.registerHandler(method: "runtime.ready") { [weak self] params in
            let plugins = Set(params["plugins"] as? [String] ?? [])
            guard try EmbeddedRuntimeManifest.load().matches(params),
                  plugins.contains("dsh-agent"),
                  plugins.contains("dsh-agent-loop"),
                  plugins.contains("dsh-session"),
                  plugins.contains("dsbot-ios-sqlite-session-persistence") else { throw IPCFrameError.invalidJSON }
            if params["safeMode"] as? Bool == true {
                await self?.showPluginRecovery()
            }
            await self?.resolveRuntimeReadiness()
            return ["accepted": true]
        }
        await rpc.registerHandler(method: "credential.resolve") { [weak self] params in
            guard let self else { throw IPCFrameError.channelClosed }
            let provider = try ModelProvider(params["apiBaseURL"] as? String ?? self.apiBaseURL)
            let value = try await self.keychain.modelKey(provider: provider, migrateOfficialKey: self.migrateOfficialKey)
            return ["value": value]
        }
        await rpc.registerHandler(method: "credential.describe") { [weak self] params in
            guard let self else { throw IPCFrameError.channelClosed }
            do {
                let provider = try ModelProvider(params["apiBaseURL"] as? String ?? self.apiBaseURL)
                _ = try await self.keychain.modelKey(provider: provider, migrateOfficialKey: self.migrateOfficialKey)
                return ["configured": true]
            } catch {
                return ["configured": false]
            }
        }
        await rpc.registerHandler(method: "workspace.request") { [weak self] params in
            guard let self, let method = params["method"] as? String else { throw IPCFrameError.invalidJSON }
            return try await self.workspaceCapabilities.nativeWorkspaceRequest(
                method: method,
                params: params["params"] as? [String: Any] ?? [:]
            )
        }
        await rpc.registerHandler(method: "native.tool.execute") { [weak self] params in
            guard let self, let name = params["name"] as? String else { throw IPCFrameError.invalidJSON }
            return try await self.workspaceCapabilities.executeNativeTool(
                name: name,
                arguments: params["args"] as? [String: Any] ?? [:],
                botId: params["botId"] as? String ?? "main",
                turnId: params["turnId"] as? String ?? "",
                isGroup: params["isGroup"] as? Bool ?? false
            )
        }
        await rpc.registerHandler(method: "native.tool.cancel") { [weak self] params in
            guard let self else { throw IPCFrameError.channelClosed }
            await self.workspaceCapabilities.cancelNativeTool(
                botId: params["botId"] as? String ?? "main",
                turnId: params["turnId"] as? String ?? ""
            )
            return ["cancelled": true]
        }
    }

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
            legacyMessagesBySession = messagesBySession
            workspaceReadable = true
        } catch {
            workspaceReadable = false
            throw IPCFrameError.remoteError(code: -32000, message: "无法读取本机工作区。原有文件已保留。")
        }
    }

    private func persistWorkspace() {
        guard workspaceReadable else { return }
        let botsSnapshot = bots
        let chatsSnapshot = legacyMessagesBySession
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
                if method == "runtime.failed" {
                    let message = params["message"] as? String ?? "内嵌 DSH 运行时启动失败。"
                    self.resolveRuntimeReadiness(.remoteError(code: -32000, message: message))
                    self.state = .failed(message)
                    continue
                }
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
                    if params["status"] as? String == "aborted" { self.lastCancelledSessionId = sessionId }
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

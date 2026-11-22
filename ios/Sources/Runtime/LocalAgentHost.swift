import Combine
import Foundation
#if canImport(PDFKit)
import PDFKit
#endif
#if canImport(Vision)
import Vision
#endif
#if canImport(UIKit)
import UIKit
#endif

@MainActor
public final class LocalAgentHost: ObservableObject {
    public static let shared = LocalAgentHost()

    private static let defaultBots: [BotProfile] = [
        BotProfile(id: "main", name: "Chief", roleLabel: "Main Bot · 团队总管", model: ModelProvider.thinkingModel, isMain: true, section: "核心团队"),
        BotProfile(id: "coder", name: "Architect", roleLabel: "架构与代码审查", model: ModelProvider.thinkingModel, section: "核心团队"),
        BotProfile(id: "team_group", name: "核心研发群", roleLabel: "群聊 · 目标与待办", model: ModelProvider.defaultModel, isGroup: true, section: "协作群聊"),
        BotProfile(id: "private_vault", name: "私密助理", roleLabel: "私密会话 · 设备解锁", model: ModelProvider.defaultModel, isPrivate: true, section: "私密空间")
    ]

    @Published public private(set) var runtimeGeneration = UUID()
    @Published public private(set) var state: LocalAgentState = .idle
    @Published public private(set) var workspaceError: String?
    @Published public private(set) var models: [String] = []
    @Published public var webSearchEnabled = UserDefaults.standard.bool(forKey: "dsbot.webSearchEnabled") {
        didSet { UserDefaults.standard.set(webSearchEnabled, forKey: "dsbot.webSearchEnabled") }
    }
    @Published public var subagentEnabled = UserDefaults.standard.bool(forKey: "dsbot.subagentEnabled") {
        didSet { UserDefaults.standard.set(subagentEnabled, forKey: "dsbot.subagentEnabled") }
    }
    @Published public var customTools = UserDefaults.standard.bool(forKey: "dsbot.customTools") {
        didSet { UserDefaults.standard.set(customTools, forKey: "dsbot.customTools") }
    }
    @Published public var autoReviewEnabled = UserDefaults.standard.bool(forKey: "dsbot.exp.autoReviewEnabled") {
        didSet { UserDefaults.standard.set(autoReviewEnabled, forKey: "dsbot.exp.autoReviewEnabled") }
    }
    @Published public var sessionDiagnosticsEnabled = UserDefaults.standard.bool(forKey: "dsbot.exp.sessionDiagnosticsEnabled") {
        didSet { UserDefaults.standard.set(sessionDiagnosticsEnabled, forKey: "dsbot.exp.sessionDiagnosticsEnabled") }
    }
    @Published public var collapseThinkingByDefault = UserDefaults.standard.bool(forKey: "dsbot.exp.collapseThinkingByDefault") {
        didSet { UserDefaults.standard.set(collapseThinkingByDefault, forKey: "dsbot.exp.collapseThinkingByDefault") }
    }
    @Published public var redteamModeEnabled = UserDefaults.standard.bool(forKey: "dsbot.redteamModeEnabled") {
        didSet { UserDefaults.standard.set(redteamModeEnabled, forKey: "dsbot.redteamModeEnabled") }
    }
    @Published public var redteamWebReadEnabled = UserDefaults.standard.bool(forKey: "dsbot.redteamWebReadEnabled") {
        didSet { UserDefaults.standard.set(redteamWebReadEnabled, forKey: "dsbot.redteamWebReadEnabled") }
    }
    @Published public var redteamWebWriteEnabled = UserDefaults.standard.bool(forKey: "dsbot.redteamWebWriteEnabled") {
        didSet { UserDefaults.standard.set(redteamWebWriteEnabled, forKey: "dsbot.redteamWebWriteEnabled") }
    }
    @Published public var redteamWebSensitiveEnabled = UserDefaults.standard.bool(forKey: "dsbot.redteamWebSensitiveEnabled") {
        didSet { UserDefaults.standard.set(redteamWebSensitiveEnabled, forKey: "dsbot.redteamWebSensitiveEnabled") }
    }
    @Published public var smartActionCardsEnabled: Bool = {
        UserDefaults.standard.object(forKey: "dsbot.exp.smartActionCardsEnabled") as? Bool ?? true
    }() {
        didSet { UserDefaults.standard.set(smartActionCardsEnabled, forKey: "dsbot.exp.smartActionCardsEnabled") }
    }
    @Published public var subagentMaxDepth: Int = {
        UserDefaults.standard.object(forKey: "dsbot.cfg.subagentMaxDepth") as? Int ?? 1
    }() {
        didSet { UserDefaults.standard.set(subagentMaxDepth, forKey: "dsbot.cfg.subagentMaxDepth") }
    }
    @Published public var subagentMaxActive: Int = {
        UserDefaults.standard.object(forKey: "dsbot.cfg.subagentMaxActive") as? Int ?? 1
    }() {
        didSet { UserDefaults.standard.set(subagentMaxActive, forKey: "dsbot.cfg.subagentMaxActive") }
    }
    @Published public var subagentModelSelection = UserDefaults.standard.bool(forKey: "dsbot.cfg.subagentModelSelection") {
        didSet { UserDefaults.standard.set(subagentModelSelection, forKey: "dsbot.cfg.subagentModelSelection") }
    }
    @Published public var webSearchCount: Int = {
        UserDefaults.standard.object(forKey: "dsbot.cfg.webSearchCount") as? Int ?? 5
    }() {
        didSet { UserDefaults.standard.set(webSearchCount, forKey: "dsbot.cfg.webSearchCount") }
    }
    @Published public var webSearchSendOriginalQuestion = UserDefaults.standard.bool(forKey: "dsbot.cfg.webSearchSendOriginalQuestion") {
        didSet { UserDefaults.standard.set(webSearchSendOriginalQuestion, forKey: "dsbot.cfg.webSearchSendOriginalQuestion") }
    }
    private var effectiveWebSearchSendOriginalQuestion = false
    @Published public private(set) var redteamStatus = RedteamPluginStatus()
    @Published public private(set) var autoReviewLog: [String] = []

    public let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    public let buildNumber = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
    @Published public var bots: [BotProfile] = []
    @Published public private(set) var messagesBySession: [String: [ChatMessageItem]] = [:]
    @Published private var persistedSessionIDs: Set<String> = []
    @Published private var historyCursors: [String: Int] = [:]
    private var persistedSessionActivityByID: [String: Date] = [:]
    private var persistedSessionPreviewByID: [String: String] = [:]
    private var refreshingSessionSummaries = false
    private var loadedHistoryIDs: Set<String> = []
    @Published public private(set) var loadingHistoryIDs: Set<String> = []
    private var historyEpochs: [String: UUID] = [:]
    private var legacyMessagesBySession: [String: [ChatMessageItem]] = [:]
    @Published public private(set) var streamingSessionId: String?
    @Published public var visibleChatSessionId: String?
    public let liveStream = StreamingTurnState()
    public var streamingReasoning: String { liveStream.reasoning }
    public var streamingContent: String { liveStream.content }
    @Published public private(set) var isStreaming: Bool = false
    @Published public private(set) var streamFirstTokenMs: Int?
    @Published public private(set) var lastStreamError: String?
    @Published public private(set) var lastErrorSessionId: String?
    @Published public private(set) var lastCancelledSessionId: String?
    @Published public private(set) var pendingApprovals: [PendingApproval] = []
    @Published public private(set) var pendingDSHQuestions: [PendingDSHQuestion] = []
    @Published public private(set) var dshToolActivities: [DSHToolActivity] = []
    @Published public private(set) var dshApprovalAudits: [DSHApprovalAudit] = []
    @Published public private(set) var telemetryBySession: [String: SessionLiveTelemetry] = [:]
    @Published public var unifiedNavigationV2: Bool = AppSettings.bool(.unifiedNavigationV2, default: true) {
        didSet { AppSettings.set(unifiedNavigationV2, for: .unifiedNavigationV2) }
    }
    @Published public private(set) var inFlightRequestIDs: Set<String> = []
    private var resolvedRequestIDs: Set<String> = []

    /// Resolves and validates a session address against known bots (P0-01).
    /// Returns nil for malformed IDs or unknown botIDs so writes never fall back to main.
    public func resolveAddress(_ rawSessionId: String) -> SessionAddress? {
        SessionAddress.resolve(rawSessionId, knownBotIDs: Set(bots.map(\.id)))
    }

    public func bot(for address: SessionAddress) -> BotProfile? {
        bots.first(where: { $0.id == address.botID })
    }

    /// Unified pending-action projection shared by Inbox, Chat cards, and status banners (P0-03).
    public var unifiedPendingInbox: [PendingInboxItem] {
        var items: [PendingInboxItem] = []
        for approval in pendingApprovals {
            guard let addr = resolveAddress(approval.sessionId) else { continue }
            items.append(PendingInboxItem(
                id: approval.id,
                kind: .approval,
                address: addr,
                title: "等待审批 · \(approval.tool)",
                detail: approval.summary,
                toolName: approval.tool
            ))
        }
        for question in pendingDSHQuestions {
            guard let addr = resolveAddress(question.sessionId) else { continue }
            items.append(PendingInboxItem(
                id: question.id,
                kind: .question,
                address: addr,
                title: "\(question.questions.count) 项提问",
                detail: question.questions.first?.question ?? "智能体正在等待你的补充确认",
                toolName: nil
            ))
        }
        return items
    }
    @Published public private(set) var dshAgentPresets: [DSHAgentPresetOption] = [
        DSHAgentPresetOption(id: "standard", name: "标准模式", description: "DSH 标准编码工具集。", broken: nil),
        DSHAgentPresetOption(id: "cordis", name: "创造模式", description: "面向 DSH / Cordis 扩展的工具集。", broken: nil),
        DSHAgentPresetOption(id: "ptc-python", name: "PTC 开发模式", description: "使用本机 Python/NumPy 编排 DSH 工具。", broken: nil),
        DSHAgentPresetOption(id: "minimal", name: "轻量模式", description: "只读文件与轻量对话。", broken: nil),
    ]
    @Published public private(set) var defaultAgentPreset = "standard"
    @Published public private(set) var pluginSources: [DSHPluginSource] = []
    @Published public private(set) var pluginCatalog: [DSHPluginCatalogItem] = []
    @Published public private(set) var installedPlugins: [DSHInstalledPlugin] = []
    @Published public private(set) var thirdPartyPluginTools: [RuntimePluginTool] = []
    @Published public private(set) var pluginSourceName: String?
    @Published public private(set) var pluginStatus: String?
    @Published public private(set) var pluginInstallStage: String = ""
    @Published public private(set) var isLoadingPlugins = false
    @Published public private(set) var pluginCatalogTotal = 0
    @Published public private(set) var embeddedRuntimeLabel: String?
    @Published public private(set) var isDSHRecoveryMode = false
    private var pluginCatalogRequest = UUID()
    private var pluginCatalogQuery = ""
    @Published public private(set) var activeTurnId: String?
    private var groupLeaseWatchdogTask: Task<Void, Never>?
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

    func hasSavedAPIKey() async -> Bool {
        guard let provider = try? ModelProvider(apiBaseURL) else { return false }
        return (try? await keychain.modelKey(provider: provider, migrateOfficialKey: migrateOfficialKey)) != nil
    }

    public func restartRuntime() async -> String {
        guard let channel else { return "DSH 运行时尚未连接。" }
        runtimeRestartInProgress = true
        defer { runtimeRestartInProgress = false }
        effectiveWebSearchSendOriginalQuestion = false
        do {
            let result = try await channel.request("runtime.restart", timeoutSeconds: 115)
            await refreshPluginState(on: channel)
            if result["safeMode"] as? Bool == true {
                return "DSH 已进入恢复模式，第三方插件未加载。"
            }
            do {
                try await syncLiveRuntimeConfig(on: channel)
            } catch {
                workspaceError = "DSH 已重启，但运行时设置同步失败：\(error.localizedDescription)"
                return "DSH 已重启；运行时设置同步失败，请重新保存设置。"
            }
            if result["rolledBack"] as? Bool == true {
                return "DSH 已重启，但回滚了异常插件变更。"
            }
            return "DSH 引擎已重启就绪。"
        } catch {
            return "重启失败：\(error.localizedDescription)"
        }
    }

    public func sqliteDatabaseSizeBytes() -> Int64 {
        let fm = FileManager.default
        let names = ["dsh-sessions.sqlite", "dsh-sessions.sqlite-wal", "dsh-storage.sqlite", "dsh-storage.sqlite-wal"]
        return names.reduce(Int64(0)) { total, name in
            let path = workspace.appendingPathComponent(name).path
            let size = (try? fm.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value ?? 0
            return total + size
        }
    }

    public func exportWorkspaceBackupJSON() -> String {
        struct BackupPayload: Encodable {
            let exportedAt: String
            let appVersion: String
            let apiBaseURL: String
            let bots: [BotProfile]
        }
        let payload = BackupPayload(
            exportedAt: ISO8601DateFormatter().string(from: Date()),
            appVersion: appVersion,
            apiBaseURL: apiBaseURL,
            bots: bots
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(payload) else { return "{}" }
        return SecretRedactor.redactCommonTokens(String(decoding: data, as: UTF8.self))
    }

    public func refreshSessionPersona(botId: String) async -> Bool {
        guard let channel else { return false }
        let prompt = bots.first(where: { $0.id == botId })?.systemPrompt ?? ""
        let res = try? await channel.request(
            "session.refreshPersona",
            params: ["sessionId": botId, "systemPrompt": prompt],
            timeoutSeconds: 10
        )
        return res?["refreshed"] as? Bool == true
    }

    func refreshModels() async throws -> (latency: Int, count: Int) {
        guard channel != nil else { throw IPCFrameError.channelClosed }
        let address = apiBaseURL
        let result = try await workspaceCapabilities.nativeWorkspaceRequest(method: "models.test", params: ["apiBaseURL": address])
        let ids = result["models"] as? [String] ?? []
        if apiBaseURL == address { models = ids }
        return (result["latencyMs"] as? Int ?? 0, ids.count)
    }

    private var channel: IPCChannel?
    private var runtimeReady = false
    private var runtimeStartupError: IPCFrameError?
    private var runtimeReadyContinuation: CheckedContinuation<Void, Error>?
    private var runtimeReadyTimeoutTask: Task<Void, Never>?
    private var runtimeRestartInProgress = false
    private let migrateOfficialKey: Bool
    private let keychain: KeychainBridge
    private let workspaceCapabilities: LocalAgentTransport
    public let workspace: URL
    private let persistQueue = DispatchQueue(label: "io.github.dsbot.workspace.persist", qos: .utility)
    private var workspaceReadable = true
    private var uiNotifContinuation: AsyncStream<(String, [String: Any])>.Continuation?
    private var pendingReasoningBuffer = ""
    private var pendingContentBuffer = ""
    private var flushScheduled = false
    private var streamStartedAt: Date?
    private var lastStreamActivityAt: Date?
    private var lastDraftSavedAt: Date = .distantPast
    private var lastDraftSavedLength: Int = 0
    private var pendingSteerNote: String?
    private var streamStallWatchdogTask: Task<Void, Never>?
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
                self?.handleNativeApprovalNotification(method: method, params: params)
            }
        }
    }

    private var draftInputsBySession: [String: String] = [:]

    public func draftInput(for sessionId: String) -> String {
        if let cached = draftInputsBySession[sessionId] { return cached }
        return UserDefaults.standard.string(forKey: "dsbot.draft.\(sessionId)") ?? ""
    }

    public func setDraftInput(_ text: String, for sessionId: String, isPrivate: Bool) {
        if text.isEmpty {
            draftInputsBySession.removeValue(forKey: sessionId)
            if !isPrivate { UserDefaults.standard.removeObject(forKey: "dsbot.draft.\(sessionId)") }
        } else {
            draftInputsBySession[sessionId] = text
            if !isPrivate { UserDefaults.standard.set(text, forKey: "dsbot.draft.\(sessionId)") }
        }
    }

    public func messages(for sessionId: String) -> [ChatMessageItem] {
        messagesBySession[sessionId] ?? []
    }

    public func sessionActivityDate(for sessionId: String) -> Date? {
        let stored = persistedSessionActivityByID[sessionId]
        let loaded = messagesBySession[sessionId]?.last?.timestamp
        switch (stored, loaded) {
        case let (stored?, loaded?): return max(stored, loaded)
        case let (stored?, nil): return stored
        case let (nil, loaded?): return loaded
        case (nil, nil): return nil
        }
    }

    public func sessionPreview(for sessionId: String) -> String? {
        guard bots.first(where: { $0.id == sessionId })?.isPrivate != true else { return nil }
        let message = messagesBySession[sessionId]?.last
        if let message,
           let activity = persistedSessionActivityByID[sessionId], activity > message.timestamp,
           let preview = persistedSessionPreviewByID[sessionId] {
            return preview
        }
        if let message, !message.content.isEmpty {
            return message.content
        }
        return persistedSessionPreviewByID[sessionId]
    }

    public func sortBySessionActivity(_ candidates: [BotProfile]) -> [BotProfile] {
        let originalOrder = Dictionary(
            candidates.enumerated().map { ($0.element.id, $0.offset) },
            uniquingKeysWith: { first, _ in first }
        )
        return candidates.sorted { left, right in
            let leftDate = sessionActivityDate(for: left.id) ?? .distantPast
            let rightDate = sessionActivityDate(for: right.id) ?? .distantPast
            if leftDate != rightDate { return leftDate > rightDate }
            return originalOrder[left.id, default: 0] < originalOrder[right.id, default: 0]
        }
    }

    public var recentlyActiveBots: [BotProfile] {
        sortBySessionActivity(bots)
    }

    func matchingImportedMessage(botId: String, query: String) -> ChatMessageItem? {
        guard bots.contains(where: { $0.id == botId && !$0.isPrivate }) else { return nil }
        return legacyMessagesBySession[botId]?.last { $0.content.localizedCaseInsensitiveContains(query) }
    }

    public func setAgentPreset(sessionId: String, presetId: String) {
        guard !isStreaming,
              dshAgentPresets.contains(where: { $0.id == presetId && $0.isAvailable }),
              let index = bots.firstIndex(where: { $0.id == sessionId }) else { return }
        guard bots[index].agentPreset != presetId else { return }
        bots[index].agentPreset = presetId
        persistWorkspace()
        DSHaptics.impact(.light)
    }

    public func setPermissionMode(sessionId: String, mode: String) {
        guard !isStreaming,
              ["ask", "autoReview", "readOnly"].contains(mode),
              let index = bots.firstIndex(where: { $0.id == sessionId }) else { return }
        guard bots[index].permissionMode != mode else { return }
        bots[index].permissionMode = mode
        if mode == "readOnly", bots[index].agentPreset == "redteam" {
            bots[index].agentPreset = "standard"
        }
        persistWorkspace()
        DSHaptics.impact(.light)
    }

    public func setReasoningEffort(sessionId: String, effort: String) {
        guard ["low", "medium", "high"].contains(effort),
              let index = bots.firstIndex(where: { $0.id == sessionId }) else { return }
        guard bots[index].reasoningEffort != effort else { return }
        bots[index].reasoningEffort = effort
        persistWorkspace()
        DSHaptics.impact(.light)
    }

    /// Rolls back the trailing assistant reply (if any) and the last user message in local session state,
    /// returning the user's original prompt so it can be edited and resent cleanly (`rewind`).
    @discardableResult
    public func rewindLastTurn(sessionId: String) -> String? {
        guard let address = resolveAddress(sessionId) else {
            workspaceError = "无效的会话地址，已拒绝撤回操作。"
            return nil
        }
        let targetId = address.canonicalSessionId
        guard !isStreaming, var list = messagesBySession[targetId], !list.isEmpty else { return nil }
        guard let lastUserIdx = list.lastIndex(where: { $0.role == "user" }) else { return nil }
        let userText = list[lastUserIdx].content
        list.removeSubrange(lastUserIdx..<list.count)
        messagesBySession[targetId] = list
        return userText
    }

    /// Removes a single message from the local session transcript (P1-2, bound to SessionAddress).
    public func deleteMessage(sessionId: String, messageId: String) {
        guard let address = resolveAddress(sessionId) else {
            workspaceError = "无效的会话地址，已拒绝删除消息。"
            return
        }
        let targetId = address.canonicalSessionId
        guard !isStreaming, var list = messagesBySession[targetId] else { return }
        list.removeAll { $0.id == messageId }
        messagesBySession[targetId] = list
        DSHaptics.impact(.light)
    }

    /// Updates per-Bot disabled tool names (P1-17).
    public func setDisabledTools(botId: String, disabledTools: [String]) {
        guard let index = bots.firstIndex(where: { $0.id == botId }) else { return }
        bots[index].disabledTools = Array(Set(disabledTools)).sorted()
        persistWorkspace()
    }

    public func setBotModel(sessionId: String, model: String) {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let index = bots.firstIndex(where: { $0.id == sessionId }) else { return }
        guard bots[index].model != trimmed else { return }
        bots[index].model = trimmed
        persistWorkspace()
    }

    public func addBot(name: String, roleLabel: String, model: String, systemPrompt: String = "", isPrivate: Bool, isGroup: Bool, permissionMode: String = "ask", agentPreset: String = "standard", redteamToolsEnabled: Bool = false, redteamWriteEnabled: Bool = false, redteamSensitiveDataEnabled: Bool = false) {
        let id = (isGroup ? "grp_" : "bot_") + String(UUID().uuidString.prefix(6)).lowercased()
        let effectiveGroup = isPrivate ? false : isGroup
        let section = isPrivate ? "私密空间" : (effectiveGroup ? "协作群聊" : "核心团队")
        bots.append(BotProfile(id: id, name: name, roleLabel: roleLabel, model: model, systemPrompt: systemPrompt, isPrivate: isPrivate, isGroup: effectiveGroup, section: section, permissionMode: permissionMode, agentPreset: agentPreset, redteamToolsEnabled: redteamToolsEnabled, redteamWriteEnabled: redteamWriteEnabled, redteamSensitiveDataEnabled: redteamSensitiveDataEnabled))
        persistWorkspace()
        schedulePrivateSessionAccessSync()
    }

    public func steerActiveTurn(sessionId: String, text: String, model: String) async {
        guard let address = resolveAddress(sessionId) else {
            workspaceError = "无效的会话地址，已拒绝插话引导。"
            return
        }
        let targetId = address.canonicalSessionId
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        pendingSteerNote = trimmed
        liveStream.recentSteerNote = trimmed
        if isStreaming {
            await abortActiveTurn()
            for _ in 0..<25 {
                if !isStreaming { break }
                try? await Task.sleep(nanoseconds: 80_000_000)
            }
        }
        await sendMessage(sessionId: targetId, text: "[插话引导] \(trimmed)", model: model)
    }

    /// Refreshes session summaries and reloads visible non-private history after closing the DSH Web Workbench.
    public func syncFromWebWorkbench() async {
        guard state == .ready, !isStreaming else { return }
        await refreshSessionSummaries()
        await refreshPluginState()
        if let visibleId = visibleChatSessionId,
           let address = resolveAddress(visibleId),
           bot(for: address)?.isPrivate != true {
            loadedHistoryIDs.remove(address.canonicalSessionId)
            try? await loadSessionHistory(address.canonicalSessionId)
        }
    }

    public func importConversation(from url: URL) throws -> BotProfile {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url)
        guard data.count <= 4 * 1024 * 1024 else {
            throw NSError(domain: "DSBotImport", code: 1, userInfo: [NSLocalizedDescriptionKey: "导入文件超过 4 MB 限制。"])
        }
        let baseName = url.deletingPathExtension().lastPathComponent
        var title = baseName.isEmpty ? "导入会话" : baseName
        var parsed: [(role: String, content: String)] = []

        if let json = try? JSONSerialization.jsonObject(with: data) {
            if let dict = json as? [String: Any] {
                if let t = dict["title"] as? String, !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    title = t
                }
                let rawMsgs = (dict["messages"] as? [[String: Any]]) ?? (dict["mapping"] as? [[String: Any]]) ?? []
                for m in rawMsgs {
                    let role = ((m["role"] as? String) ?? (m["author"] as? String) ?? "user").lowercased()
                    let content = (m["content"] as? String) ?? (m["text"] as? String) ?? ""
                    if !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        parsed.append((role.contains("assistant") || role.contains("bot") ? "assistant" : "user", content))
                    }
                }
            } else if let arr = json as? [[String: Any]] {
                for m in arr {
                    let role = ((m["role"] as? String) ?? "user").lowercased()
                    let content = (m["content"] as? String) ?? (m["text"] as? String) ?? ""
                    if !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        parsed.append((role.contains("assistant") || role.contains("bot") ? "assistant" : "user", content))
                    }
                }
            }
        }

        if parsed.isEmpty, let text = String(data: data, encoding: .utf8), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parsed.append(("user", "以下为导入的外部对话记录（\(title)）：\n\n" + String(text.prefix(40_000))))
        }
        guard !parsed.isEmpty else {
            throw NSError(domain: "DSBotImport", code: 2, userInfo: [NSLocalizedDescriptionKey: "未能在文件中识别到有效对话内容。"])
        }

        let id = "imp_" + String(UUID().uuidString.prefix(6)).lowercased()
        let bot = BotProfile(id: id, name: String(title.prefix(24)), roleLabel: "导入会话 · \(parsed.count) 条消息", model: ModelProvider.defaultModel, section: "核心团队")
        bots.append(bot)
        let items = parsed.prefix(200).map { ChatMessageItem(sessionId: id, role: $0.role, content: $0.content) }
        messagesBySession[id] = items
        legacyMessagesBySession[id] = items
        persistWorkspace()
        return bot
    }

    public func sendMessage(sessionId: String, text: String, model: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isStreaming, state == .ready, let channel else { return }
        lastErrorSessionId = sessionId
        guard trimmed.utf8.count <= 262_144 else {
            lastStreamError = "消息超过 256 KB。"
            return
        }
        switch CostBudgetGovernor.shared.evaluateCurrentDailySpend() {
        case .block(let reason):
            lastStreamError = reason
            DSHaptics.notify(.warning)
            return
        case .warn(let reason):
            CostBudgetGovernor.shared.activeBudgetWarning = reason
        case .allow:
            CostBudgetGovernor.shared.activeBudgetWarning = nil
        }
        guard let address = resolveAddress(sessionId) else {
            lastStreamError = "无效的会话地址（\(sessionId)），已拒绝写入。"
            DSHaptics.notify(.error)
            return
        }
        let targetSessionId = address.canonicalSessionId
        let targetBot = bot(for: address)
        if let preset = targetBot?.agentPreset, (preset == "ptc-python" || preset == "cordis"),
           !MemoryGovernor.shared.canAdmitHeavyWork() {
            lastStreamError = "系统可用内存不足（< 180 MB），已拦截重型工具执行以避免闪退，请关闭其他应用后重试。"
            DSHaptics.notify(.warning)
            return
        }
        if targetBot?.isPrivate == true,
           !(await syncPrivateSessionAccess(on: channel)) {
            lastStreamError = "私密会话 Web API 隔离尚未同步；请稍后重试。"
            return
        }
        lastCancelledSessionId = nil
        let turnId = UUID().uuidString
        messagesBySession[targetSessionId, default: []].append(ChatMessageItem(sessionId: targetSessionId, role: "user", content: trimmed))
        persistWorkspace()
        activeTurnId = turnId
        streamingSessionId = targetSessionId
        sentCancellation = false
        let steerNote = pendingSteerNote
        pendingSteerNote = nil
        liveStream.begin(sessionId: targetSessionId, steerNote: steerNote)
        lastDraftSavedAt = .distantPast
        lastDraftSavedLength = 0
        streamStartedAt = Date()
        lastStreamActivityAt = Date()
        streamFirstTokenMs = nil
        lastStreamError = nil
        isStreaming = true
        DSHaptics.impact(.light)

        streamStallWatchdogTask?.cancel()
        streamStallWatchdogTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                guard let self, self.activeTurnId == turnId, self.isStreaming else { return }
                guard self.pendingApprovals.isEmpty, self.pendingDSHQuestions.isEmpty else {
                    self.lastStreamActivityAt = Date()
                    continue
                }
                if let last = self.lastStreamActivityAt, Date().timeIntervalSince(last) >= 120 {
                    self.lastStreamError = "流式响应超过 120 秒无新数据（网络可能已断开），已安全停止，可点击重试。"
                    await self.abortActiveTurn()
                    return
                }
            }
        }

        let bot = targetBot
        let legacyHistory = (legacyMessagesBySession[targetSessionId] ?? []).suffix(12).map { message in
            ["role": message.role, "content": String(message.content.prefix(12_000))]
        }
        if bot?.isGroup == true {
            groupLeaseWatchdogTask?.cancel()
            groupLeaseWatchdogTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 90_000_000_000)
                guard let self, self.activeTurnId == turnId, self.isStreaming else { return }
                self.lastStreamError = "群聊编排超过 90 秒租约（interrupted），已安全中止等待。"
                await self.abortActiveTurn()
            }
        }
        do {
            _ = try await channel.request("chat.send", params: [
                "sessionId": targetSessionId, "turnId": turnId, "model": model, "apiBaseURL": apiBaseURL,
                "systemPrompt": bot?.systemPrompt ?? "", "isGroup": bot?.isGroup ?? false,
                "agentPreset": bot?.agentPreset ?? "standard", "permissionMode": bot?.permissionMode ?? "ask",
                "reasoningEffort": bot?.reasoningEffort ?? "medium",
                "disabledTools": bot?.disabledTools ?? [],
                "subagentEnabled": subagentEnabled, "webSearchEnabled": webSearchEnabled,
                "customTools": customTools,
                "redteamMode": bot?.redteamToolsEnabled ?? false,
                "redteamWriteEnabled": bot?.redteamWriteEnabled ?? false,
                "redteamSensitiveDataEnabled": bot?.redteamSensitiveDataEnabled ?? false,
                "text": trimmed, "legacyHistory": legacyHistory
            ])
        } catch {
            guard activeTurnId == turnId else { return }
            lastStreamError = error.localizedDescription
            finishTurn()
        }
    }

    public func refreshRedteamStatus() async {
        guard let rpc = rpc() else { return }
        if let res = try? await rpc.request("redteam.status", timeoutSeconds: 15) {
            redteamStatus = RedteamPluginStatus(res)
            if let synced = try? await rpc.request("redteam.setWebPermissions", params: [
                "read": redteamWebReadEnabled,
                "write": redteamWebWriteEnabled,
                "sensitive": redteamWebSensitiveEnabled
            ], timeoutSeconds: 15) {
                redteamStatus = RedteamPluginStatus(synced)
            }
            if redteamModeEnabled && redteamStatus.installed && !redteamStatus.redteamModeActive {
                if let mounted = try? await rpc.request("redteam.setMode", params: ["enabled": true], timeoutSeconds: 30) {
                    redteamStatus = RedteamPluginStatus(mounted)
                }
            }
        }
    }

    private func synchronizeRedteamHost(on rpc: IPCChannel) async {
        do {
            let permissions = try await rpc.request("redteam.setWebPermissions", params: [
                "read": redteamWebReadEnabled,
                "write": redteamWebWriteEnabled,
                "sensitive": redteamWebSensitiveEnabled
            ], timeoutSeconds: 15)
            redteamStatus = RedteamPluginStatus(permissions)
            if redteamModeEnabled {
                let mounted = try await rpc.request("redteam.setMode", params: ["enabled": true], timeoutSeconds: 30)
                redteamStatus = RedteamPluginStatus(mounted)
            }
        } catch {
            pluginStatus = "同步 dsh-purge-safe iOS 权限失败：\(error.localizedDescription)"
        }
    }

    public func setRedteamMode(_ enabled: Bool) async {
        let previous = redteamModeEnabled
        redteamModeEnabled = enabled
        guard let rpc = rpc() else { return }
        do {
            let res = try await rpc.request("redteam.setMode", params: ["enabled": enabled], timeoutSeconds: 30)
            redteamStatus = RedteamPluginStatus(res)
            if let synced = try? await rpc.request("redteam.setWebPermissions", params: [
                "read": redteamWebReadEnabled,
                "write": redteamWebWriteEnabled,
                "sensitive": redteamWebSensitiveEnabled
            ], timeoutSeconds: 15) {
                redteamStatus = RedteamPluginStatus(synced)
            }
            pluginStatus = enabled
                ? (redteamStatus.toolCount > 0 ? "红队演练模式已开启（已挂载 \(redteamStatus.toolCount) 个工具）" : "红队演练模式已开启")
                : "红队演练模式已关闭"
        } catch {
            redteamModeEnabled = previous
            pluginStatus = "切换红队模式失败：\(error.localizedDescription)"
        }
    }

    public func setRedteamWebPermissions(readEnabled: Bool? = nil, writeEnabled: Bool? = nil, sensitiveEnabled: Bool? = nil) async {
        let previous = (redteamWebReadEnabled, redteamWebWriteEnabled, redteamWebSensitiveEnabled)
        if let readEnabled { redteamWebReadEnabled = readEnabled }
        if let writeEnabled { redteamWebWriteEnabled = writeEnabled }
        if let sensitiveEnabled { redteamWebSensitiveEnabled = sensitiveEnabled }
        if !redteamWebReadEnabled {
            redteamWebWriteEnabled = false
            redteamWebSensitiveEnabled = false
        }
        guard let rpc = rpc() else { return }
        do {
            let result = try await rpc.request("redteam.setWebPermissions", params: [
                "read": redteamWebReadEnabled,
                "write": redteamWebWriteEnabled,
                "sensitive": redteamWebSensitiveEnabled
            ], timeoutSeconds: 15)
            redteamStatus = RedteamPluginStatus(result)
        } catch {
            redteamWebReadEnabled = previous.0
            redteamWebWriteEnabled = previous.1
            redteamWebSensitiveEnabled = previous.2
            pluginStatus = "更新 Web 演练台权限失败：\(error.localizedDescription)"
        }
    }

    public func applyLiveRuntimeConfig() async -> String {
        guard let channel else { return "已保存到本地，等待 DSH 运行时就绪后生效。" }
        guard !isStreaming else { return "当前会话仍在运行，结束后再保存运行时设置。" }
        effectiveWebSearchSendOriginalQuestion = false
        do {
            try await syncLiveRuntimeConfig(on: channel)
            return "已通过 Cordis 热更新生效（无需重启）。"
        } catch {
            effectiveWebSearchSendOriginalQuestion = false
            return "已保存到本地，热更新失败：\(error.localizedDescription)"
        }
    }

    private func syncLiveRuntimeConfig(on rpc: IPCChannel) async throws {
        effectiveWebSearchSendOriginalQuestion = false
        subagentMaxDepth = min(3, max(0, subagentMaxDepth))
        subagentMaxActive = min(8, max(1, subagentMaxActive))
        webSearchCount = min(20, max(1, webSearchCount))
        let result = try await rpc.request("runtime.config.update", params: [
            "subagentMaxDepth": subagentMaxDepth,
            "subagentMaxActive": subagentMaxActive,
            "subagentModelSelection": subagentModelSelection,
            "webSearchCount": webSearchCount,
            "webSearchSendOriginalQuestion": webSearchSendOriginalQuestion
        ], timeoutSeconds: 30)
        guard result["ok"] as? Bool == true,
              let applied = result["config"] as? [String: Any] else {
            throw IPCFrameError.remoteError(code: -32000, message: "DSH 未确认应用运行时设置。")
        }
        effectiveWebSearchSendOriginalQuestion = applied["webSearchSendOriginalQuestion"] as? Bool ?? false
        guard
              applied["subagentMaxDepth"] as? Int == subagentMaxDepth,
              applied["subagentMaxActive"] as? Int == subagentMaxActive,
              applied["subagentModelSelection"] as? Bool == subagentModelSelection,
              applied["webSearchCount"] as? Int == webSearchCount,
              applied["webSearchSendOriginalQuestion"] as? Bool == webSearchSendOriginalQuestion else {
            throw IPCFrameError.remoteError(code: -32000, message: "DSH 未确认应用全部运行时设置。")
        }
        workspaceError = nil
    }

    public func updateBot(id: String, name: String, roleLabel: String, model: String, systemPrompt: String = "", permissionMode: String? = nil, agentPreset: String? = nil, reasoningEffort: String? = nil, redteamToolsEnabled: Bool? = nil, redteamWriteEnabled: Bool? = nil, redteamSensitiveDataEnabled: Bool? = nil) {
        guard let idx = bots.firstIndex(where: { $0.id == id }) else { return }
        bots[idx].name = name
        bots[idx].roleLabel = roleLabel
        bots[idx].model = model
        bots[idx].systemPrompt = systemPrompt
        if let permissionMode { bots[idx].permissionMode = permissionMode }
        if let reasoningEffort, ["low", "medium", "high"].contains(reasoningEffort) {
            bots[idx].reasoningEffort = reasoningEffort
        }
        if streamingSessionId == id,
           (redteamToolsEnabled != nil || redteamWriteEnabled != nil || redteamSensitiveDataEnabled != nil) {
            pluginStatus = "当前 Bot 正在执行；红队权限会在本轮完成后修改。"
        } else {
            if let redteamToolsEnabled {
                bots[idx].redteamToolsEnabled = !bots[idx].isPrivate && redteamToolsEnabled
                if !bots[idx].redteamToolsEnabled {
                    bots[idx].redteamWriteEnabled = false
                    bots[idx].redteamSensitiveDataEnabled = false
                }
            }
            if let redteamWriteEnabled {
                bots[idx].redteamWriteEnabled = !bots[idx].isPrivate && bots[idx].redteamToolsEnabled && redteamWriteEnabled
            }
            if let redteamSensitiveDataEnabled {
                bots[idx].redteamSensitiveDataEnabled = !bots[idx].isPrivate && bots[idx].redteamToolsEnabled && redteamSensitiveDataEnabled
            }
        }
        if let agentPreset, agentPreset != bots[idx].agentPreset {
            if !dshAgentPresets.contains(where: { $0.id == agentPreset && $0.isAvailable }) {
                pluginStatus = "所选 DSH 模式不可用；请刷新运行时模式列表后重试。"
            } else if streamingSessionId == id {
                pluginStatus = "当前 Bot 正在生成；请等待本轮完成后再切换模式。"
            } else {
                bots[idx].agentPreset = agentPreset
            }
        }
        persistWorkspace()
        DSHaptics.notify(.success)
    }

    public func setRedteamPermissions(sessionId: String, toolsEnabled: Bool? = nil, writeEnabled: Bool? = nil, sensitiveDataEnabled: Bool? = nil) {
        guard let index = bots.firstIndex(where: { $0.id == sessionId }) else { return }
        guard streamingSessionId != sessionId else {
            pluginStatus = "当前 Bot 正在执行；红队权限会在本轮完成后修改。"
            return
        }
        guard !bots[index].isPrivate else {
            bots[index].redteamToolsEnabled = false
            bots[index].redteamWriteEnabled = false
            bots[index].redteamSensitiveDataEnabled = false
            persistWorkspace()
            pluginStatus = "私密会话禁止使用 dsh-purge-safe 红队工具。"
            return
        }
        if let toolsEnabled {
            bots[index].redteamToolsEnabled = toolsEnabled
            if !toolsEnabled {
                bots[index].redteamWriteEnabled = false
                bots[index].redteamSensitiveDataEnabled = false
            }
        }
        if let writeEnabled {
            bots[index].redteamWriteEnabled = bots[index].redteamToolsEnabled && writeEnabled
        }
        if let sensitiveDataEnabled {
            bots[index].redteamSensitiveDataEnabled = bots[index].redteamToolsEnabled && sensitiveDataEnabled
        }
        if bots[index].agentPreset == "redteam", !bots[index].redteamToolsEnabled {
            bots[index].agentPreset = "standard"
        }
        persistWorkspace()
    }

    public func regenerateLastReply(sessionId: String, model: String) async {
        guard !isStreaming, state == .ready else { return }
        guard let address = resolveAddress(sessionId) else {
            workspaceError = "无效的会话地址，已拒绝重新生成。"
            return
        }
        let targetId = address.canonicalSessionId
        // DSH sessions are append-only event logs. Retrying creates another turn
        // with the same prompt so the visible transcript stays aligned with the
        // durable history after the next app launch.
        guard let lastUser = messagesBySession[targetId]?.last(where: { $0.role == "user" }) else { return }
        await sendMessage(sessionId: targetId, text: lastUser.content, model: model)
    }

    public func exportSessionMarkdown(sessionId: String, botName: String) async throws -> String {
        guard let address = resolveAddress(sessionId) else {
            throw NSError(domain: "DSBotSession", code: 400, userInfo: [NSLocalizedDescriptionKey: "无效的会话地址，已拒绝导出。"])
        }
        let targetId = address.canonicalSessionId
        guard let rpc = rpc() else { throw IPCFrameError.channelClosed }
        let payload = try await rpc.request("session.history.markdown", params: ["sessionId": targetId], timeoutSeconds: 30)
        guard let markdown = payload["markdown"] as? String else { throw IPCFrameError.invalidJSON }
        let formatter = ISO8601DateFormatter()
        let legacy = (legacyMessagesBySession[targetId] ?? []).map { message in
            let speaker = message.role == "user" ? "用户" : "助手"
            return "## \(speaker) · \(formatter.string(from: message.timestamp))\n\n\(message.content)\n\n"
        }.joined()
        return "# DS Bot 会话导出：\(botName)\n\n" + legacy + markdown
    }

    func loadFullHistoryMessage(_ preview: ChatMessageItem) async throws -> (content: String, reasoning: String) {
        guard let sequence = preview.sequence, let rpc = rpc() else { throw IPCFrameError.channelClosed }
        let response = try await rpc.request("session.history.message", params: [
            "sessionId": preview.sessionId, "sequence": sequence
        ])
        guard response["id"] as? String == preview.id, let content = response["content"] as? String else {
            throw IPCFrameError.invalidJSON
        }
        return (content, response["reasoning"] as? String ?? "")
    }

    public struct AttachedWorkspaceFile: Identifiable, Equatable, Sendable {
        public var id: String { relativePath }
        public let relativePath: String
        public let fileName: String
        public let byteCount: Int
        public let inlineText: String?

        public func promptPrefix() -> String {
            if let inlineText, !inlineText.isEmpty {
                return "[附件文件：files/\(relativePath)（\(byteCount) 字节）]\n```\n\(inlineText)\n```\n\n"
            }
            return "[附件文件：files/\(relativePath)（\(byteCount) 字节，已存入工作区，可使用 workspace_read 或 python_exec 查看）]\n\n"
        }
    }

    private static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "heic", "heif", "webp", "bmp", "tif", "tiff", "gif"
    ]

    private static let textExtensions: Set<String> = [
        "txt", "md", "markdown", "json", "jsonl", "yaml", "yml", "xml", "csv", "tsv", "log",
        "swift", "py", "js", "mjs", "cjs", "ts", "tsx", "jsx", "html", "htm", "css", "scss",
        "sql", "sh", "bash", "zsh", "toml", "ini", "cfg", "conf", "env", "c", "h", "cpp", "hpp",
        "m", "mm", "go", "rs", "java", "kt", "rb", "php", "pl", "r", "lua", "dart", "vue", "svelte",
        "dockerfile", "makefile", "gitignore", "properties", "gradle", "plist", "svg", "tex"
    ]

    private static func sanitizeAttachmentFilename(_ rawName: String, fallbackExt: String = "bin") -> String {
        let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = trimmed.unicodeScalars.map { scalar -> Character in
            if scalar == "/" || scalar == "\\" || scalar == "\0" || scalar.value < 0x20 || scalar.value == 0x7F {
                return "_"
            }
            if scalar == ":" || scalar == "*" || scalar == "?" || scalar == "\"" || scalar == "<" || scalar == ">" || scalar == "|" {
                return "_"
            }
            return Character(scalar)
        }
        var cleaned = String(filtered).trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        while cleaned.contains("..") {
            cleaned = cleaned.replacingOccurrences(of: "..", with: ".")
        }
        if cleaned.count > 120 {
            let ext = (cleaned as NSString).pathExtension
            let stem = (cleaned as NSString).deletingPathExtension
            let maxStem = max(16, 115 - ext.count)
            cleaned = ext.isEmpty ? String(stem.prefix(120)) : "\(String(stem.prefix(maxStem))).\(ext)"
        }
        if cleaned.isEmpty {
            return "attachment_\(UUID().uuidString.prefix(6)).\(fallbackExt)"
        }
        return cleaned
    }

    private static func uniqueDestination(in filesDir: URL, preferredName: String) -> (name: String, url: URL) {
        var targetName = preferredName
        var dest = filesDir.appendingPathComponent(targetName, isDirectory: false)
        if FileManager.default.fileExists(atPath: dest.path) {
            let stem = (preferredName as NSString).deletingPathExtension
            let ext = (preferredName as NSString).pathExtension
            let suffix = String(UUID().uuidString.prefix(6)).lowercased()
            targetName = ext.isEmpty ? "\(stem)_\(suffix)" : "\(stem)_\(suffix).\(ext)"
            dest = filesDir.appendingPathComponent(targetName, isDirectory: false)
        }
        return (targetName, dest)
    }

    private static func extractInlinePreview(at dest: URL, byteCount: Int) -> String? {
        let inlineLimit = 24_576
        let ext = dest.pathExtension.lowercased()
        if ext == "pdf" {
            return extractPDFText(at: dest, maxChars: inlineLimit)
        }
        if imageExtensions.contains(ext) {
            if let data = try? Data(contentsOf: dest, options: .mappedIfSafe) {
                return extractImageOCRText(from: data, maxChars: inlineLimit)
            }
            return nil
        }
        // Read up to inlineLimit bytes for text/code files (or small UTF-8 files of any extension)
        if textExtensions.contains(ext) || byteCount <= inlineLimit {
            guard let handle = try? FileHandle(forReadingFrom: dest) else { return nil }
            defer { try? handle.close() }
            let slice = (try? handle.read(upToCount: inlineLimit)) ?? Data()
            guard !slice.isEmpty, !slice.contains(0) else { return nil }
            if let decoded = String(data: slice, encoding: .utf8) {
                if byteCount > slice.count {
                    return decoded + "\n...[已截断，完整内容请使用 workspace_read 或 python_exec 查看]"
                }
                return decoded
            }
        }
        return nil
    }

    public func importFileToWorkspace(from sourceURL: URL) throws -> AttachedWorkspaceFile {
        let accessed = sourceURL.startAccessingSecurityScopedResource()
        defer { if accessed { sourceURL.stopAccessingSecurityScopedResource() } }

        let maxImportBytes = 25 * 1024 * 1024
        let maxImageDirectBytes = 4 * 1024 * 1024
        let filesDir = LocalAgentTransport.defaultWorkspace.appendingPathComponent("files", isDirectory: true)
        try FileManager.default.createDirectory(at: filesDir, withIntermediateDirectories: true)

        var coordinatorError: NSError?
        var importError: Error?
        var importedFile: AttachedWorkspaceFile?

        let coordinator = NSFileCoordinator()
        coordinator.coordinate(readingItemAt: sourceURL, options: .withoutChanges, error: &coordinatorError) { coordinatedURL in
            do {
                let values = try coordinatedURL.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey, .fileSizeKey])
                if values.isDirectory == true && values.isPackage != true {
                    throw IPCFrameError.remoteError(code: -32602, message: "暂不支持直接附加文件夹，请选择文件或压缩包。")
                }
                let rawSize = values.fileSize ?? 0
                if rawSize > maxImportBytes {
                    throw IPCFrameError.remoteError(code: -32602, message: "单个附件不能超过 25 MB。")
                }

                let sourceExt = coordinatedURL.pathExtension.lowercased()
                let isImage = Self.imageExtensions.contains(sourceExt)
                var preferredName = Self.sanitizeAttachmentFilename(coordinatedURL.lastPathComponent)

                if isImage && rawSize > maxImageDirectBytes {
                    if let downsampled = MemoryGovernor.downsampleImage(at: coordinatedURL, maxPixelSize: 1568, compressionQuality: 0.82),
                       downsampled.count <= maxImportBytes {
                        let stem = (preferredName as NSString).deletingPathExtension
                        preferredName = "\(stem).jpg"
                        let (targetName, dest) = Self.uniqueDestination(in: filesDir, preferredName: preferredName)
                        try downsampled.write(to: dest, options: .atomic)
                        let inlineText = Self.extractInlinePreview(at: dest, byteCount: downsampled.count)
                        importedFile = AttachedWorkspaceFile(relativePath: targetName, fileName: targetName, byteCount: downsampled.count, inlineText: inlineText)
                        return
                    }
                }

                let (targetName, dest) = Self.uniqueDestination(in: filesDir, preferredName: preferredName)
                try FileManager.default.copyItem(at: coordinatedURL, to: dest)
                let copiedAttrs = try? FileManager.default.attributesOfItem(atPath: dest.path)
                let finalSize = (copiedAttrs?[.size] as? Int) ?? rawSize
                if finalSize > maxImportBytes {
                    try? FileManager.default.removeItem(at: dest)
                    throw IPCFrameError.remoteError(code: -32602, message: "单个附件不能超过 25 MB。")
                }
                let inlineText = Self.extractInlinePreview(at: dest, byteCount: finalSize)
                importedFile = AttachedWorkspaceFile(relativePath: targetName, fileName: targetName, byteCount: finalSize, inlineText: inlineText)
            } catch {
                importError = error
            }
        }

        if let coordinatorError { throw coordinatorError }
        if let importError { throw importError }
        guard let importedFile else {
            throw IPCFrameError.remoteError(code: -32603, message: "无法读取所选文件，请重试。")
        }
        return importedFile
    }

    public func importRawDataToWorkspace(_ data: Data, suggestedName: String) throws -> AttachedWorkspaceFile {
        let maxImportBytes = 25 * 1024 * 1024
        guard data.count <= maxImportBytes else {
            throw IPCFrameError.remoteError(code: -32602, message: "单个附件不能超过 25 MB。")
        }
        let filesDir = LocalAgentTransport.defaultWorkspace.appendingPathComponent("files", isDirectory: true)
        try FileManager.default.createDirectory(at: filesDir, withIntermediateDirectories: true)
        let preferredName = Self.sanitizeAttachmentFilename(suggestedName, fallbackExt: "jpg")
        let (targetName, dest) = Self.uniqueDestination(in: filesDir, preferredName: preferredName)
        try data.write(to: dest, options: .atomic)
        let inlineText = Self.extractInlinePreview(at: dest, byteCount: data.count)
        return AttachedWorkspaceFile(relativePath: targetName, fileName: targetName, byteCount: data.count, inlineText: inlineText)
    }

    private static func extractPDFText(at url: URL, maxChars: Int) -> String? {
        #if canImport(PDFKit)
        guard let doc = PDFDocument(url: url) else { return nil }
        var buffer = ""
        let pageCap = min(doc.pageCount, 30)
        for index in 0..<pageCap {
            if let pageText = doc.page(at: index)?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !pageText.isEmpty {
                if !buffer.isEmpty { buffer += "\n\n" }
                buffer += pageText
                if buffer.count >= maxChars { break }
            }
        }
        guard !buffer.isEmpty else { return nil }
        return String(buffer.prefix(maxChars))
        #else
        return nil
        #endif
    }

    private static func extractImageOCRText(from data: Data, maxChars: Int) -> String? {
        #if canImport(Vision) && canImport(UIKit)
        guard let cgImage = UIImage(data: data)?.cgImage else { return nil }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        request.usesLanguageCorrection = true
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
            let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
            let joined = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            return joined.isEmpty ? nil : String(joined.prefix(maxChars))
        } catch {
            return nil
        }
        #else
        return nil
        #endif
    }

    public func deleteBot(id: String) {
        guard let target = bots.first(where: { $0.id == id }), !target.isMain else { return }
        if target.isPrivate {
            var privateTombstones = Set(UserDefaults.standard.stringArray(forKey: "dsbot.privateSessionTombstones") ?? [])
            privateTombstones.insert(id)
            UserDefaults.standard.set(privateTombstones.sorted(), forKey: "dsbot.privateSessionTombstones")
        }
        bots.removeAll { $0.id == id }
        discardSessionHistoryCache(id)
        persistedSessionIDs.remove(id)
        persistedSessionActivityByID.removeValue(forKey: id)
        persistedSessionPreviewByID.removeValue(forKey: id)
        legacyMessagesBySession.removeValue(forKey: id)
        Task { [weak self] in
            await self?.syncPrivateSessionAccess()
            await self?.deleteDSHSession(id)
        }
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
            let privateIds = Self.privateSessionIDs(
                bots: bots,
                tombstones: UserDefaults.standard.stringArray(forKey: "dsbot.privateSessionTombstones") ?? []
            )
            let safeModeBoot = SafeModeBootGuard.shared.beginBootAttempt()
            let transport = try NodeRuntimeTransport.prepare(
                apiBaseURL: apiBaseURL,
                privateSessionIDs: privateIds,
                safeMode: safeModeBoot
            )
            let rpc = IPCChannel(transport: transport)
            channel = rpc
            await rpc.onClose { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.effectiveWebSearchSendOriginalQuestion = false
                    self.resolveRuntimeReadiness(.channelClosed)
                    guard self.state == .ready else { return }
                    if let turnId = self.activeTurnId, let sessionId = self.streamingSessionId {
                        Task {
                            await self.workspaceCapabilities.cancelNativeTool(botId: sessionId, turnId: turnId) { botId, turnId in
                                _ = try? await rpc.request("python.cancel", params: ["botId": botId, "turnId": turnId], timeoutSeconds: 5)
                            }
                        }
                    }
                    self.pendingApprovals.removeAll()
                    self.pendingDSHQuestions.removeAll()
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
            await syncPrivateSessionAccess(on: rpc)
            let readiness = try await rpc.request("agent.info", timeoutSeconds: 10)
            guard try EmbeddedRuntimeManifest.load().matches(readiness) else { throw IPCFrameError.invalidJSON }
            if let dsh = readiness["dshVersion"] as? String, let node = readiness["nodeVersion"] as? String {
                embeddedRuntimeLabel = "DSH \(dsh) · Node \(node)"
            }
            await loadDSHAgentPresets(on: rpc)
            await loadDSHSessions(on: rpc)
            if readiness["safeMode"] as? Bool == true {
                effectiveWebSearchSendOriginalQuestion = false
            } else {
                do {
                    try await syncLiveRuntimeConfig(on: rpc)
                    workspaceError = nil
                } catch {
                    effectiveWebSearchSendOriginalQuestion = false
                    workspaceError = "DSH 运行时设置同步失败：\(error.localizedDescription)"
                }
            }
            await refreshPluginState(on: rpc)
            await synchronizeRedteamHost(on: rpc)
            MemoryGovernor.shared.onPressureTrim = { _ in
                DSMarkdownText.clearRenderCache()
            }
            MemoryGovernor.shared.onCriticalPressure = { [weak self] in
                guard let self else { return }
                Task { @MainActor in
                    DSMarkdownText.clearRenderCache()
                    if self.isStreaming {
                        self.lastStreamError = "系统内存紧张，已安全暂停当前生成以保护进度。"
                        await self.abortActiveTurn()
                    }
                }
            }
            SafeModeBootGuard.shared.markBootReady()
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
        let suspendedTurnId = activeTurnId
        let suspendedSessionId = streamingSessionId
        if suspendedTurnId != nil {
            sentCancellation = true
            pendingApprovals.removeAll()
            pendingDSHQuestions.removeAll()
        }
        _ = try? await channel.request("agent.suspend", timeoutSeconds: 3)
        if let suspendedTurnId, activeTurnId == suspendedTurnId {
            if let suspendedSessionId {
                lastCancelledSessionId = suspendedSessionId
            }
            finishTurn(["status": "aborted"])
        }
    }

    public func resumeFromBackground() async {
        MemoryGovernor.shared.refreshSnapshot()
        guard let channel else { return }
        _ = try? await channel.request("agent.resume", timeoutSeconds: 5)
        do {
            let health = try await channel.request("runtime.health", timeoutSeconds: 4)
            let isHealthy = health["ok"] as? Bool == true
            let webPort = health["webPort"] as? Int ?? 0
            let webAlive = webPort == 0 || (health["webServerAlive"] as? Bool ?? true)
            let activeTurns = health["activeTurns"] as? Int ?? 0
            if isStreaming && (sentCancellation || activeTurns == 0) {
                let stuckSessionId = streamingSessionId
                finishTurn(["status": "aborted"])
                if let stuckSessionId {
                    loadedHistoryIDs.remove(stuckSessionId)
                    try? await loadSessionHistory(stuckSessionId)
                }
            }
            if (!isHealthy || !webAlive), state == .ready, !isStreaming {
                _ = await restartRuntime()
            }
        } catch {
            if isStreaming {
                finishTurn(["status": "aborted"])
            }
            if state == .ready, !isStreaming {
                _ = await restartRuntime()
            }
        }
    }

    public func abortActiveTurn() async {
        guard let turnId = activeTurnId else { return }
        if sentCancellation {
            // Second tap on Stop or already-cancelled turn: force-unblock UI and preserve partial text.
            if let sessionId = streamingSessionId { lastCancelledSessionId = sessionId }
            finishTurn(["status": "aborted"])
            return
        }
        sentCancellation = true
        liveStream.phase = .cancelling
        pendingApprovals.removeAll { $0.turnId == turnId }
        pendingDSHQuestions.removeAll { $0.turnId == turnId }
        do {
            let response = try await channel?.request("chat.abort", params: ["turnId": turnId], timeoutSeconds: 5)
            if response?["aborted"] as? Bool != true, activeTurnId == turnId { finishTurn(["status": "aborted"]) }
        } catch {
            if activeTurnId == turnId {
                lastStreamError = error.localizedDescription
                finishTurn(["status": "aborted"])
            }
        }
    }

    public func respondToApproval(id: String, approved: Bool) async {
        guard !inFlightRequestIDs.contains(id), !resolvedRequestIDs.contains(id) else { return }
        guard let approval = pendingApprovals.first(where: { $0.id == id }),
              approval.turnId == activeTurnId, !sentCancellation else {
            pendingApprovals.removeAll { $0.id == id }
            return
        }
        inFlightRequestIDs.insert(id)
        defer { inFlightRequestIDs.remove(id) }
        let params: [String: Any] = [
            "approvalId": id, "turnId": approval.turnId, "sessionId": approval.sessionId, "approved": approved
        ]
        let receipt: [String: Any]?
        if approval.isDSH {
            receipt = try? await channel?.request("approval.respond", params: params)
        } else {
            receipt = try? await workspaceCapabilities.nativeWorkspaceRequest(method: "approval.respond", params: params)
        }
        if receipt?["found"] as? Bool == true {
            resolvedRequestIDs.insert(id)
            pendingApprovals.removeAll { $0.id == id }
        } else {
            pendingApprovals.removeAll { $0.id == id }
            workspaceError = "该审批请求已失效或已被其他入口处理。"
        }
    }

    public func respondToDSHQuestion(id: String, answers: [[String: Any]]) async {
        guard !inFlightRequestIDs.contains(id), !resolvedRequestIDs.contains(id) else { return }
        guard let question = pendingDSHQuestions.first(where: { $0.id == id }),
              question.turnId == activeTurnId, !sentCancellation else {
            pendingDSHQuestions.removeAll { $0.id == id }
            return
        }
        inFlightRequestIDs.insert(id)
        defer { inFlightRequestIDs.remove(id) }
        let receipt = try? await channel?.request("user-question.respond", params: [
            "questionId": id, "turnId": question.turnId, "sessionId": question.sessionId, "answers": answers
        ])
        if receipt?["found"] as? Bool == true {
            resolvedRequestIDs.insert(id)
            pendingDSHQuestions.removeAll { $0.id == id }
        } else {
            pendingDSHQuestions.removeAll { $0.id == id }
            workspaceError = "该提问请求已失效或已被其他入口处理。"
        }
    }

    public func rpc() -> HostRPC? {
        guard state == .ready, let channel else { return nil }
        return HostRPC(channel: channel, workspace: workspaceCapabilities)
    }

    /// Only the Keychain key for the address currently selected in Settings is released to Node.
    private func configuredCredentialProvider(_ params: [String: Any]) throws -> ModelProvider {
        let configured = try ModelProvider(apiBaseURL)
        if let requested = params["apiBaseURL"] as? String,
           try ModelProvider(requested).baseURL != configured.baseURL {
            throw IPCFrameError.remoteError(code: -32003, message: "凭据只提供给当前设置的服务地址。")
        }
        return configured
    }

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
            if enabled {
                pluginStatus = "索引源已启用，正在读取插件目录…"
                await discoverPlugins(forceRefresh: true)
            } else {
                pluginStatus = "索引源已停用。"
            }
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
        pluginInstallStage = "正在准备下载 \(item.name)@\(item.version)…"
        pluginStatus = "正在下载并检查 \(item.name)@\(item.version)…"
        defer { pluginInstallStage = "" }
        do {
            let outcome = try await channel.request("plugins.install.npm", params: [
                "name": item.name, "version": item.version, "sourceId": item.sourceId
            ], timeoutSeconds: 180)
            await refreshPluginState(on: channel)
            pluginStatus = try await pluginMutationStatus(outcome, on: channel, applied: "\(item.name) 已安装并启用。")
        } catch { pluginStatus = error.localizedDescription }
    }

    public func installGithubPlugin(url: String) async {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let channel else { return }
        pluginInstallStage = "正在连接 GitHub 获取 \(trimmed)…"
        pluginStatus = "正在从 GitHub 下载并检查 \(trimmed)…"
        defer { pluginInstallStage = "" }
        do {
            let outcome = try await channel.request("plugins.install.github", params: [
                "url": trimmed
            ], timeoutSeconds: 180)
            let name = outcome["name"] as? String ?? trimmed
            await refreshPluginState(on: channel)
            pluginStatus = try await pluginMutationStatus(outcome, on: channel, applied: "\(name) 已从 GitHub 安装并启用。")
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

    public func disableAllThirdPartyPlugins() async {
        guard let channel else { return }
        do {
            let outcome = try await channel.request("plugins.disableAll", timeoutSeconds: 60)
            await refreshPluginState(on: channel)
            let count = outcome["disabledCount"] as? Int ?? 0
            pluginStatus = try await pluginMutationStatus(outcome, on: channel, applied: "已停用 \(count) 个第三方插件。")
        } catch {
            pluginStatus = "停用全部第三方插件失败：\(error.localizedDescription)"
        }
    }

    public func loadPluginConfig(name: String) async throws -> String {
        guard let channel else { throw IPCFrameError.channelClosed }
        let res = try await channel.request("plugins.config.get", params: ["name": name], timeoutSeconds: 15)
        let config = res["config"] as? [String: Any] ?? [:]
        let data = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    public func savePluginConfig(name: String, jsonText: String) async throws -> String {
        guard let channel else { throw IPCFrameError.channelClosed }
        let trimmed = jsonText.trimmingCharacters(in: .whitespacesAndNewlines)
        let raw = trimmed.isEmpty ? "{}" : trimmed
        guard let data = raw.data(using: .utf8),
              let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw IPCFrameError.remoteError(code: -32602, message: "配置必须是合法的 JSON 对象（例如 {}）。")
        }
        let outcome = try await channel.request("plugins.config.set", params: ["name": name, "config": parsed], timeoutSeconds: 15)
        let msg = outcome["restartRequired"] as? Bool == true
            ? "配置已保存，重启 DSH 引擎后生效。"
            : "配置已保存。"
        pluginStatus = msg
        return msg
    }

    public func installLocalPlugin(from url: URL) async {
        guard let channel else { return }
        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
        pluginInstallStage = "正在读取本地插件包…"
        defer { pluginInstallStage = "" }
        let importRoot = workspace.appendingPathComponent("plugin-imports", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: importRoot, withIntermediateDirectories: true)
            let lowerName = url.lastPathComponent.lowercased()
            let suffix: String
            if lowerName.hasSuffix(".tar.gz") { suffix = ".tar.gz" }
            else if lowerName.hasSuffix(".tgz") { suffix = ".tgz" }
            else { suffix = "" }
            let staged = importRoot.appendingPathComponent(UUID().uuidString + suffix, isDirectory: suffix.isEmpty)
            var coordError: NSError?
            var copyError: Error?
            NSFileCoordinator().coordinate(readingItemAt: url, options: .withoutChanges, error: &coordError) { coordinatedURL in
                do {
                    try FileManager.default.copyItem(at: coordinatedURL, to: staged)
                } catch {
                    copyError = error
                }
            }
            if let coordError { throw coordError }
            if let copyError { throw copyError }
            defer { try? FileManager.default.removeItem(at: staged) }
            pluginStatus = "正在检查本地 DSH 插件…"
            let outcome = try await channel.request("plugins.install.local", params: ["path": staged.path], timeoutSeconds: 120)
            await refreshPluginState(on: channel)
            pluginStatus = try await pluginMutationStatus(outcome, on: channel, applied: "本地插件已安装并启用。")
        } catch { pluginStatus = error.localizedDescription }
    }

    private func pluginMutationStatus(_ outcome: [String: Any], on channel: IPCChannel, applied: String) async throws -> String {
        guard outcome["restartRequired"] as? Bool == true else { return applied }
        pluginStatus = "正在重启 DSH 引擎并检查插件。"
        runtimeRestartInProgress = true
        defer { runtimeRestartInProgress = false }
        effectiveWebSearchSendOriginalQuestion = false
        let result = try await channel.request("runtime.restart", timeoutSeconds: 115)
        if result["safeMode"] as? Bool == true {
            await refreshPluginState(on: channel)
            return "DSH 已进入恢复模式，第三方插件未加载。"
        }
        do {
            try await syncLiveRuntimeConfig(on: channel)
        } catch {
            await refreshPluginState(on: channel)
            return "插件已重启，但运行时设置同步失败：\(error.localizedDescription)"
        }
        await refreshPluginState(on: channel)
        if result["rolledBack"] as? Bool == true { return "插件未能启动，已恢复上次可用配置。" }
        return applied
    }

    private func refreshPluginState(on rpc: IPCChannel) async {
        do {
            let sources = try await rpc.request("plugins.sources.list", timeoutSeconds: 15)
            let installed = try await rpc.request("plugins.installed.list", timeoutSeconds: 15)
            pluginSources = Self.decodeRows(sources["sources"], as: DSHPluginSource.self)
            installedPlugins = Self.decodeRows(installed["plugins"], as: DSHInstalledPlugin.self)
            if let caps = try? await rpc.request("plugins.runtime.capabilities", timeoutSeconds: 10) {
                thirdPartyPluginTools = Self.decodeRows(caps["thirdPartyTools"], as: RuntimePluginTool.self)
            }
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
        guard let address = resolveAddress(sessionId) else {
            workspaceError = "无效的会话地址（\(sessionId)），已拒绝清空。"
            return
        }
        let target = address.canonicalSessionId
        do {
            _ = try await channel.request("session.clear", params: ["sessionId": target], timeoutSeconds: 60)
            messagesBySession[target] = []
            legacyMessagesBySession[target] = []
            discardSessionHistoryCache(target)
            persistedSessionIDs.remove(target)
            persistedSessionActivityByID.removeValue(forKey: target)
            persistedSessionPreviewByID.removeValue(forKey: target)
            lastStreamError = nil
            persistWorkspace()
        } catch {
            workspaceError = "清空 DSH 会话失败：\(error.localizedDescription)"
        }
    }

    private func deleteDSHSession(_ sessionId: String) async {
        guard let channel else { return }
        do {
            _ = try await channel.request("session.clear", params: ["sessionId": sessionId], timeoutSeconds: 60)
        } catch {
            workspaceError = "清理 DSH 会话失败（\(sessionId)）：\(error.localizedDescription)"
        }
    }

    private func schedulePrivateSessionAccessSync() {
        guard state == .ready, let rpc = channel else { return }
        Task { [weak self] in _ = await self?.syncPrivateSessionAccess(on: rpc) }
    }

    private func syncPrivateSessionAccess() async {
        guard let channel else { return }
        _ = await syncPrivateSessionAccess(on: channel)
    }

    @discardableResult
    private func syncPrivateSessionAccess(on rpc: IPCChannel) async -> Bool {
        let tombstones = UserDefaults.standard.stringArray(forKey: "dsbot.privateSessionTombstones") ?? []
        let ids = Self.privateSessionIDs(bots: bots, tombstones: tombstones)
        do {
            _ = try await rpc.request("session.private.update", params: ["botIds": ids], timeoutSeconds: 15)
            return true
        } catch {
            workspaceError = "私密会话 Web API 隔离同步失败：\(error.localizedDescription)"
            return false
        }
    }

    private static func privateSessionIDs(bots: [BotProfile], tombstones: [String]) -> [String] {
        Array(Set(bots.filter(\.isPrivate).map(\.id) + tombstones))
            .filter { $0.range(of: "^[A-Za-z0-9_-]{1,80}$", options: .regularExpression) != nil }
            .sorted()
    }

    private func loadDSHSessions(on rpc: IPCChannel) async {
        guard !refreshingSessionSummaries else { return }
        refreshingSessionSummaries = true
        defer { refreshingSessionSummaries = false }
        let generation = runtimeGeneration
        do {
            let listing = try await rpc.request("session.list", timeoutSeconds: 30)
            try Task.checkCancellation()
            guard generation == runtimeGeneration else { return }
            let sessions = listing["sessions"] as? [[String: Any]] ?? []
            persistedSessionIDs = Set(sessions.compactMap { record in
                guard (record["eventCount"] as? Int ?? 0) > 0 else { return nil }
                return record["sessionId"] as? String
            })
            var activityByID: [String: Date] = [:]
            var previewByID: [String: String] = [:]
            for record in sessions {
                guard let id = record["sessionId"] as? String else { continue }
                if let milliseconds = record["lastActivityAt"] as? NSNumber {
                    activityByID[id] = Date(timeIntervalSince1970: milliseconds.doubleValue / 1_000)
                }
                if let preview = record["lastMessagePreview"] as? String, !preview.isEmpty {
                    previewByID[id] = preview
                }
            }
            persistedSessionActivityByID = activityByID
            persistedSessionPreviewByID = previewByID
        } catch is CancellationError {
            return
        } catch {
            workspaceError = "读取 DSH 会话列表失败：\(error.localizedDescription)"
        }
    }

    public func refreshSessionSummaries() async {
        guard let rpc = rpc() else { return }
        await loadDSHSessions(on: rpc.channel)
    }

    public func hasSessionHistory(_ id: String) -> Bool {
        persistedSessionIDs.contains(id) || messagesBySession[id]?.isEmpty == false
    }

    public func hasOlderHistory(_ id: String) -> Bool { historyCursors[id] != nil }

    public func discardSessionHistoryCache(_ id: String) {
        historyEpochs[id] = UUID()
        loadedHistoryIDs.remove(id)
        historyCursors[id] = nil
        loadingHistoryIDs.remove(id)
        messagesBySession[id] = nil
        dshToolActivities.removeAll { $0.sessionId == id }
        dshApprovalAudits.removeAll { $0.sessionId == id }
    }

    public func loadSessionHistory(_ rawId: String, older: Bool = false) async throws {
        guard let address = resolveAddress(rawId) else { return }
        let id = address.canonicalSessionId
        guard let rpc = rpc(), !loadingHistoryIDs.contains(id),
              older ? historyCursors[id] != nil : !loadedHistoryIDs.contains(id) else { return }
        let epoch = UUID()
        let generation = runtimeGeneration
        historyEpochs[id] = epoch
        loadingHistoryIDs.insert(id)
        defer {
            if historyEpochs[id] == epoch { loadingHistoryIDs.remove(id) }
        }
        var request: [String: Any] = ["sessionId": id]
        if older { request["beforeSeq"] = historyCursors[id] }
        let response = try await rpc.request("session.history.page", params: request, timeoutSeconds: 15)
        try Task.checkCancellation()
        guard historyEpochs[id] == epoch, runtimeGeneration == generation else { return }
        let persisted = Self.decodeHistoryMessages(response, sessionId: id)
        let activities = (response["toolActivities"] as? [[String: Any]] ?? []).compactMap { record -> DSHToolActivity? in
            guard let activityId = record["id"] as? String,
                  let callId = record["callId"] as? String,
                  let toolName = record["toolName"] as? String else { return nil }
            return DSHToolActivity(
                id: activityId,
                callId: callId,
                sessionId: id,
                turnId: record["turnId"] as? String ?? "history",
                toolName: toolName,
                phase: record["phase"] as? String ?? "unknown",
                arguments: record["arguments"] as? String ?? "",
                result: record["result"] as? String ?? "",
                fileSummary: record["fileSummary"] as? String,
                timestamp: Self.sessionDate(record["timestamp"]),
                sequence: record["sequence"] as? Int,
                callSequence: record["callSequence"] as? Int
            )
        }
        let approvals = (response["approvals"] as? [[String: Any]] ?? []).compactMap { record -> DSHApprovalAudit? in
            guard let auditId = record["id"] as? String,
                  let toolName = record["toolName"] as? String,
                  let outcome = record["outcome"] as? String else { return nil }
            return DSHApprovalAudit(
                id: auditId,
                sessionId: id,
                toolName: toolName,
                outcome: outcome,
                timestamp: Self.sessionDate(record["timestamp"]),
                sequence: record["sequence"] as? Int
            )
        }
        let current = messagesBySession[id] ?? legacyMessagesBySession[id] ?? []
        var known = Set(current.map(\.id))
        var merged = current
        for message in persisted where known.insert(message.id).inserted {
            let trimmedNew = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
            if let dupIndex = merged.firstIndex(where: { existing in
                existing.sequence == nil
                    && existing.role == message.role
                    && existing.content.trimmingCharacters(in: .whitespacesAndNewlines) == trimmedNew
                    && abs(existing.timestamp.timeIntervalSince(message.timestamp)) <= 45
            }) {
                // Replace optimistic client-side placeholder with durable sequenced record
                merged[dupIndex] = message
            } else {
                merged.append(message)
            }
        }
        messagesBySession[id] = Self.sortSessionMessages(merged)
        for activity in activities {
            if let existingIndex = dshToolActivities.firstIndex(where: {
                $0.sessionId == id && $0.callId == activity.callId
            }) {
                // Keep the richer live payload while adding the durable sequence
                // needed to reopen its full history record after reconnect.
                dshToolActivities[existingIndex].callSequence = activity.callSequence
                if dshToolActivities[existingIndex].sequence == nil {
                    dshToolActivities[existingIndex].sequence = activity.sequence
                }
            } else {
                dshToolActivities.append(activity)
            }
        }
        for audit in approvals {
            if let existingIndex = dshApprovalAudits.firstIndex(where: {
                $0.sessionId == id && $0.id == audit.id
            }) {
                dshApprovalAudits[existingIndex] = audit
            } else {
                dshApprovalAudits.append(audit)
            }
        }
        historyCursors[id] = response["hasMore"] as? Bool == true ? response["nextBeforeSeq"] as? Int : nil
        loadedHistoryIDs.insert(id)
    }

    func searchSessionContext(botId: String, sequence: Int) async throws -> [ChatMessageItem] {
        guard bots.contains(where: { $0.id == botId && !$0.isPrivate }), let rpc = rpc() else {
            throw IPCFrameError.channelClosed
        }
        let generation = runtimeGeneration
        let response = try await rpc.request("session.search.context", params: ["sessionId": botId, "sequence": sequence])
        try Task.checkCancellation()
        guard generation == runtimeGeneration, bots.contains(where: { $0.id == botId && !$0.isPrivate }) else {
            throw IPCFrameError.invalidJSON
        }
        return Self.decodeHistoryMessages(response, sessionId: botId)
    }

    func loadHistoryToolActivityPage(_ activity: DSHToolActivity, argumentsFrom: Int = 0,
                                     resultFrom: Int = 0) async throws -> DSHToolActivityHistoryPage {
        guard let sequence = activity.callSequence, let rpc = rpc() else { throw IPCFrameError.channelClosed }
        let generation = runtimeGeneration
        let response = try await rpc.request("session.history.tool", params: [
            "sessionId": activity.sessionId, "sequence": sequence,
            "argumentsFrom": argumentsFrom, "resultFrom": resultFrom, "pageBytes": 64 * 1024,
        ], timeoutSeconds: 30)
        try Task.checkCancellation()
        guard generation == runtimeGeneration,
              response["callId"] as? String == activity.callId,
              let arguments = response["arguments"] as? String,
              let argumentsNext = response["argumentsNext"] as? Int,
              let argumentsTotalBytes = response["argumentsTotalBytes"] as? Int,
              let result = response["result"] as? String,
              let resultNext = response["resultNext"] as? Int,
              let resultTotalBytes = response["resultTotalBytes"] as? Int,
              let phase = response["phase"] as? String else {
            throw IPCFrameError.invalidJSON
        }
        return DSHToolActivityHistoryPage(
            arguments: arguments, argumentsNext: argumentsNext, argumentsTotalBytes: argumentsTotalBytes,
            result: result, resultNext: resultNext, resultTotalBytes: resultTotalBytes, phase: phase
        )
    }

    private static func decodeHistoryMessages(_ response: [String: Any], sessionId id: String) -> [ChatMessageItem] {
        let records = response["messages"] as? [[String: Any]] ?? []
        return records.compactMap { record -> ChatMessageItem? in
            guard let role = record["role"] as? String,
                  let content = record["content"] as? String else { return nil }
            var message = ChatMessageItem(
                id: record["id"] as? String ?? UUID().uuidString,
                sessionId: id,
                role: role,
                content: content,
                reasoning: record["reasoning"] as? String ?? "",
                timestamp: Self.sessionDate(record["timestamp"]),
                sequence: record["sequence"] as? Int
            )
            message.historyPreview = record["truncated"] as? Bool
            message.incomplete = false
            return message
        }
    }

    private static func sortSessionMessages(_ messages: [ChatMessageItem]) -> [ChatMessageItem] {
        messages.enumerated().sorted { left, right in
            if left.element.timestamp != right.element.timestamp {
                return left.element.timestamp < right.element.timestamp
            }
            if let leftSequence = left.element.sequence, let rightSequence = right.element.sequence,
               leftSequence != rightSequence {
                return leftSequence < rightSequence
            }
            if left.element.sequence != nil && right.element.sequence == nil { return false }
            if left.element.sequence == nil && right.element.sequence != nil { return true }
            return left.offset < right.offset
        }.map(\.element)
    }

    private func loadDSHAgentPresets(on rpc: IPCChannel) async {
        do {
            let response = try await rpc.request("agent.presets.list", timeoutSeconds: 15)
            let presets = (response["presets"] as? [[String: Any]] ?? []).compactMap { item -> DSHAgentPresetOption? in
                guard let id = item["id"] as? String, !id.isEmpty else { return nil }
                return DSHAgentPresetOption(
                    id: id,
                    name: item["name"] as? String ?? id,
                    description: item["description"] as? String ?? "",
                    broken: item["broken"] as? String
                )
            }
            guard !presets.isEmpty else { return }
            dshAgentPresets = presets
            let requestedDefault = response["defaultId"] as? String ?? "standard"
            defaultAgentPreset = presets.contains(where: { $0.id == requestedDefault && $0.isAvailable })
                ? requestedDefault
                : (presets.first(where: { $0.isAvailable })?.id ?? "standard")
        } catch {
            pluginStatus = "读取 DSH Agent 模式失败：\(error.localizedDescription)"
        }
    }

    public func agentPresetName(_ id: String) -> String {
        if let preset = dshAgentPresets.first(where: { $0.id == id }) { return preset.name }
        switch id {
        case "cordis": return "创造模式"
        case "ptc-python": return "PTC 开发模式"
        case "minimal": return "轻量模式"
        default: return id == "standard" ? "标准模式" : id
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

    private func updatePluginRecovery(_ enabled: Bool) {
        isDSHRecoveryMode = enabled
        if enabled { pluginStatus = "DSH 已进入恢复模式。可在插件页停用或卸载问题插件。" }
    }

    private func registerRuntimeBridge(on rpc: IPCChannel) async {
        await rpc.registerHandler(method: "runtime.ready") { [weak self] params in
            let plugins = Set(params["plugins"] as? [String] ?? [])
            guard try EmbeddedRuntimeManifest.load().matches(params),
                  plugins.contains("dsh-agent"),
                  plugins.contains("dsh-agent-loop"),
                  plugins.contains("dsh-session"),
                  (plugins.contains("@dsbot/dsh-ios-host/session-persistence")
                   || plugins.contains("ios-session-persistence")
                   || plugins.contains("dsbot-ios-sqlite-session-persistence")) else { throw IPCFrameError.invalidJSON }
            let safeMode = params["safeMode"] as? Bool == true
            let shouldResyncSettings = await MainActor.run {
                self?.state == .ready && self?.runtimeRestartInProgress == false
            }
            if safeMode || shouldResyncSettings {
                await MainActor.run { self?.effectiveWebSearchSendOriginalQuestion = false }
            }
            await self?.updatePluginRecovery(params["safeMode"] as? Bool == true)
            await MainActor.run { self?.runtimeGeneration = UUID() }
            await self?.resolveRuntimeReadiness()
            if shouldResyncSettings && !safeMode {
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    do {
                        try await self.syncLiveRuntimeConfig(on: rpc)
                    } catch {
                        self.effectiveWebSearchSendOriginalQuestion = false
                        self.workspaceError = "DSH 运行时已恢复，但设置同步失败：\(error.localizedDescription)"
                    }
                }
            }
            return ["accepted": true]
        }
        await rpc.registerHandler(method: "credential.resolve") { [weak self] params in
            guard let self else { throw IPCFrameError.channelClosed }
            let provider = try self.configuredCredentialProvider(params)
            let value = try await self.keychain.modelKey(provider: provider, migrateOfficialKey: self.migrateOfficialKey)
            return ["value": value]
        }
        await rpc.registerHandler(method: "credential.describe") { [weak self] params in
            guard let self else { throw IPCFrameError.channelClosed }
            do {
                let provider = try self.configuredCredentialProvider(params)
                _ = try await self.keychain.modelKey(provider: provider, migrateOfficialKey: self.migrateOfficialKey)
                return ["configured": true]
            } catch {
                return ["configured": false]
            }
        }
        await rpc.registerHandler(method: "workspace.request") { [weak self] params in
            guard let self, let method = params["method"] as? String else { throw IPCFrameError.invalidJSON }
            guard HostRPC.nodeOriginatedMethods.contains(method) else {
                throw IPCFrameError.remoteError(code: -32003, message: "DSH runtime cannot call UI workspace method \(method).")
            }
            return try await self.workspaceCapabilities.nativeWorkspaceRequest(
                method: method,
                params: params["params"] as? [String: Any] ?? [:]
            )
        }
        await rpc.registerHandler(method: "sandbox.js_eval") { [weak self] params in
            guard let self else { throw IPCFrameError.channelClosed }
            let script = params["script"] as? String ?? ""
            let timeoutMs = Int32(params["timeoutMs"] as? Int ?? 2_000)
            return await self.workspaceCapabilities.evaluateQuickJSSandbox(script, timeoutMilliseconds: timeoutMs)
        }
        await rpc.registerHandler(method: "browser.action") { [weak self] params in
            guard let self else { throw IPCFrameError.channelClosed }
            let action = params["action"] as? String ?? ""
            let args = params["args"] as? [String: Any] ?? [:]
            return try await AgentBrowserController.shared.handleAction(action, args: args, workspace: self.workspace)
        }
        await rpc.registerHandler(method: "native.tool.execute") { [weak self] params in
            guard let self, let name = params["name"] as? String else { throw IPCFrameError.invalidJSON }
            var arguments = params["args"] as? [String: Any] ?? [:]
            if name == "web_search" {
                guard self.webSearchEnabled, self.usesOfficialModels, !self.sentCancellation,
                      let turnId = params["turnId"] as? String, turnId == self.activeTurnId,
                      let botId = params["botId"] as? String, botId == self.streamingSessionId else {
                    throw IPCFrameError.remoteError(code: -32000, message: "当前会话不能发起网页搜索。")
                }
                arguments.removeValue(forKey: "originalQuestion")
                if self.effectiveWebSearchSendOriginalQuestion {
                    guard let originalQuestion = self.webSearchOriginalQuestionContext(sessionId: botId) else {
                        throw IPCFrameError.remoteError(code: -32000, message: "无法展示将发送的原始问题上下文，已阻止网页搜索。")
                    }
                    arguments["originalQuestion"] = originalQuestion
                }
            }
            return try await self.workspaceCapabilities.executeNativeTool(
                name: name,
                arguments: arguments,
                botId: params["botId"] as? String ?? "main",
                turnId: params["turnId"] as? String ?? "",
                isGroup: params["isGroup"] as? Bool ?? false,
                pythonRunner: { code, botId, turnId in
                    let admitted = await MainActor.run { MemoryGovernor.shared.canAdmitHeavyWork() }
                    guard admitted else {
                        throw IPCFrameError.remoteError(
                            code: -32000,
                            message: "当前设备可用内存偏低（MemoryGovernor 处于紧张/临界档位），已暂缓启动离线 Python WASM 工作线程以防闪退。请关闭后台重型应用后重试。"
                        )
                    }
                    let result = try await rpc.request("python.execute", params: [
                        "botId": botId, "turnId": turnId, "code": code,
                    ], timeoutSeconds: 60)
                    return result["output"] as? String ?? ""
                }
            )
        }
        await rpc.registerHandler(method: "native.tool.cancel") { [weak self] params in
            guard let self else { throw IPCFrameError.channelClosed }
            await self.workspaceCapabilities.cancelNativeTool(
                botId: params["botId"] as? String ?? "main",
                turnId: params["turnId"] as? String ?? "",
                pythonCanceller: { botId, turnId in
                    _ = try? await rpc.request("python.cancel", params: ["botId": botId, "turnId": turnId], timeoutSeconds: 5)
                }
            )
            return ["cancelled": true]
        }
    }

    private func webSearchOriginalQuestionContext(sessionId: String) -> String? {
        guard let original = messagesBySession[sessionId]?.last(where: { $0.role == "user" })?.content else { return nil }
        let normalized = original
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let scalars = Array(normalized.unicodeScalars.prefix(128))
        let context = String(String.UnicodeScalarView(scalars))
        return context.isEmpty ? nil : context
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
            restoreInterruptedStreamingDraftIfNeeded()
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

    private func streamingDraftURL() -> URL {
        workspace.appendingPathComponent("streaming-draft.json")
    }

    private func restoreInterruptedStreamingDraftIfNeeded() {
        let url = streamingDraftURL()
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        defer { try? FileManager.default.removeItem(at: url) }
        guard let data = try? Data(contentsOf: url),
              let draft = try? JSONDecoder().decode(StreamingDraftRecord.self, from: data),
              (!draft.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
               || !draft.reasoning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) else {
            return
        }
        var recovered = ChatMessageItem(
            sessionId: draft.sessionId,
            role: "assistant",
            content: draft.content,
            reasoning: draft.reasoning,
            timestamp: draft.updatedAt
        )
        recovered.incomplete = true
        messagesBySession[draft.sessionId, default: []].append(recovered)
        persistWorkspace()
    }

    private func checkpointStreamingDraftIfNeeded() {
        guard let sessionId = streamingSessionId else { return }
        let totalLen = liveStream.content.count + liveStream.reasoning.count
        guard totalLen > 0 else { return }
        let now = Date()
        let deltaChars = totalLen - lastDraftSavedLength
        guard deltaChars >= 512 || (deltaChars > 0 && now.timeIntervalSince(lastDraftSavedAt) >= 4.0) else { return }
        lastDraftSavedAt = now
        lastDraftSavedLength = totalLen
        let draft = StreamingDraftRecord(
            sessionId: sessionId,
            content: liveStream.content,
            reasoning: liveStream.reasoning,
            updatedAt: now
        )
        let url = streamingDraftURL()
        persistQueue.async {
            if let encoded = try? JSONEncoder().encode(draft) {
                try? encoded.write(to: url, options: .atomic)
            }
        }
    }

    private func clearStreamingDraft() {
        let url = streamingDraftURL()
        persistQueue.async {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func flushPendingStreamBuffers() {
        flushScheduled = false
        var grew = false
        if !pendingReasoningBuffer.isEmpty {
            liveStream.reasoning += pendingReasoningBuffer
            pendingReasoningBuffer = ""
            if liveStream.content.isEmpty && !sentCancellation {
                liveStream.phase = .thinking
            }
            grew = true
        }
        if !pendingContentBuffer.isEmpty {
            liveStream.appendContent(pendingContentBuffer)
            pendingContentBuffer = ""
            if !sentCancellation {
                liveStream.phase = .generating
            }
            grew = true
        }
        if grew, let start = streamStartedAt {
            let elapsed = max(0.25, Date().timeIntervalSince(start))
            liveStream.elapsedSeconds = Int(elapsed)
            let totalChars = liveStream.content.count + liveStream.reasoning.count
            liveStream.charsPerSecond = max(1, Int(Double(totalChars) / elapsed))
            checkpointStreamingDraftIfNeeded()
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
        clearStreamingDraft()
        if let sessionId = streamingSessionId, let turnId = activeTurnId {
            for index in dshToolActivities.indices where dshToolActivities[index].sessionId == sessionId
                && dshToolActivities[index].turnId == turnId && dshToolActivities[index].phase == "started" {
                let wasAborted = params["status"] as? String == "aborted"
                dshToolActivities[index].phase = wasAborted ? "cancelled" : "failed"
                if dshToolActivities[index].result.isEmpty {
                    dshToolActivities[index].result = wasAborted ? "会话已取消，工具执行已中止。" : "工具未返回完成结果。"
                }
            }
        }
        if let sessionId = streamingSessionId {
            var telemetry = telemetryBySession[sessionId] ?? SessionLiveTelemetry()
            if let usage = params["usage"] as? [String: Any] {
                telemetry.inputTokens += usage["inputTokens"] as? Int ?? 0
                telemetry.cacheReadTokens += usage["cacheReadTokens"] as? Int ?? 0
                telemetry.outputTokens += usage["outputTokens"] as? Int ?? 0
            }
            if let dur = params["durationMs"] as? Int, dur > 0 {
                telemetry.modelDurationMs += dur
            } else if let start = streamStartedAt {
                telemetry.modelDurationMs += max(1, Int(Date().timeIntervalSince(start) * 1_000))
            }
            if let ttft = streamFirstTokenMs, ttft > 0 {
                telemetry.ttftSumMs += ttft
                telemetry.ttftSamples += 1
            }
            telemetryBySession[sessionId] = telemetry

            let authoritativeContent = (params["finalContent"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let authoritativeReasoning = (params["finalReasoning"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let finalText: String
            if !authoritativeContent.isEmpty && (liveStream.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || authoritativeContent.count > liveStream.content.count) {
                finalText = authoritativeContent
            } else {
                finalText = liveStream.content
            }
            let finalThink: String
            if !authoritativeReasoning.isEmpty && (liveStream.reasoning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || authoritativeReasoning.count > liveStream.reasoning.count) {
                finalThink = authoritativeReasoning
            } else {
                finalThink = liveStream.reasoning
            }
            if !finalText.isEmpty || !finalThink.isEmpty {
                var item = ChatMessageItem(sessionId: sessionId, role: "assistant", content: finalText, reasoning: finalThink)
                item.incomplete = params["status"] as? String != "completed"
                if let transcript = params["transcript"],
                   let bytes = try? JSONSerialization.data(withJSONObject: transcript) {
                    item.transcript = try? JSONDecoder().decode([ProviderMessage].self, from: bytes)
                    item.providerProfile = params["profile"] as? String
                }
                messagesBySession[sessionId, default: []].append(item)
                persistWorkspace()
            }
        }
        if let usage = params["usage"] as? [String: Any] {
            let model = usage["model"] as? String ?? ModelProvider.defaultModel
            let inputTokens = usage["inputTokens"] as? Int ?? 0
            let cacheReadTokens = usage["cacheReadTokens"] as? Int ?? 0
            let outputTokens = usage["outputTokens"] as? Int ?? 0
            CostBudgetGovernor.shared.recordUsage(
                model: model,
                inputTokens: inputTokens,
                cacheReadTokens: cacheReadTokens,
                outputTokens: outputTokens
            )
        }
        groupLeaseWatchdogTask?.cancel()
        groupLeaseWatchdogTask = nil
        streamStallWatchdogTask?.cancel()
        streamStallWatchdogTask = nil
        lastStreamActivityAt = nil
        lastDraftSavedAt = .distantPast
        lastDraftSavedLength = 0
        sentCancellation = false
        liveStream.reset()
        streamingSessionId = nil
        pendingApprovals.removeAll()
        pendingDSHQuestions.removeAll()
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
                    self.effectiveWebSearchSendOriginalQuestion = false
                    self.state = .failed(message)
                    continue
                }
                if method == "plugins.progress" {
                    if let detail = params["detail"] as? String, !detail.isEmpty {
                        self.pluginInstallStage = detail
                    }
                    continue
                }
                if method.hasPrefix("approval.") {
                    self.lastStreamActivityAt = Date()
                    self.handleNativeApprovalNotification(method: method, params: params)
                    continue
                }
                if method.hasPrefix("user-question.") {
                    self.lastStreamActivityAt = Date()
                    self.handleDSHQuestionNotification(method: method, params: params)
                    continue
                }
                if method == "dsh.tool.event" {
                    self.lastStreamActivityAt = Date()
                    self.handleDSHToolNotification(params)
                    continue
                }
                if method == "dsh.approval.event" {
                    self.lastStreamActivityAt = Date()
                    self.handleDSHApprovalAuditNotification(params)
                    continue
                }
                guard let turnId = params["turnId"] as? String, self.activeTurnId == turnId,
                      let sessionId = params["sessionId"] as? String, sessionId == self.streamingSessionId else { continue }
                switch method {
                case "chat.delta":
                    guard !self.sentCancellation else { continue }
                    self.lastStreamActivityAt = Date()
                    if self.streamFirstTokenMs == nil, let start = self.streamStartedAt {
                        let ttft = max(1, Int(Date().timeIntervalSince(start) * 1_000))
                        self.streamFirstTokenMs = ttft
                        self.liveStream.firstTokenMs = ttft
                    }
                    self.pendingReasoningBuffer += params["reasoning"] as? String ?? ""
                    self.pendingContentBuffer += params["content"] as? String ?? ""
                    self.scheduleStreamFlushIfNeeded()
                case "chat.done":
                    self.lastStreamError = params["error"] as? String
                    if params["status"] as? String == "aborted" { self.lastCancelledSessionId = sessionId }
                    self.finishTurn(params)
                default: break
                }
            }
        }
    }

    private func handleNativeApprovalNotification(method: String, params: [String: Any]) {
        if method == "approval.closed" {
            pendingApprovals.removeAll { $0.id == params["approvalId"] as? String }
            return
        }
        guard method == "approval.request",
              !sentCancellation,
              let turnId = params["turnId"] as? String, activeTurnId == turnId,
              let sessionId = params["sessionId"] as? String, sessionId == streamingSessionId,
              let id = params["approvalId"] as? String,
              let tool = params["tool"] as? String,
              let summary = params["summary"] as? String else { return }

        let botMode = bots.first(where: { $0.id == sessionId })?.permissionMode ?? "ask"
        let lowerTool = tool.lowercased()
        let isWriteOrMutate = lowerTool.contains("write") || lowerTool.contains("edit") || lowerTool.contains("patch")
            || lowerTool.contains("delete") || lowerTool.contains("memory") || lowerTool == "terminal_exec"
            || lowerTool == "python_exec" || lowerTool == "run_code" || lowerTool == "python_job_start"
            || lowerTool.hasPrefix("redteam_")

        let approval = PendingApproval(id: id, sessionId: sessionId, turnId: turnId, tool: tool, summary: summary, isDSH: params["source"] as? String == "dsh")
        pendingApprovals.append(approval)
        liveStream.phase = .awaitingApproval(tool)

        if botMode == "readOnly" && isWriteOrMutate {
            autoReviewLog.insert("[\(Date().formatted(date: .omitted, time: .shortened))] 只读保护拦截：\(tool)", at: 0)
            if autoReviewLog.count > 40 { autoReviewLog = Array(autoReviewLog.prefix(40)) }
            Task { await respondToApproval(id: id, approved: false) }
            return
        }

        if autoReviewEnabled || botMode == "autoReview" {
            autoReviewLog.insert("[\(Date().formatted(date: .omitted, time: .shortened))] 沙盒免打扰放行：\(tool)", at: 0)
            if autoReviewLog.count > 40 { autoReviewLog = Array(autoReviewLog.prefix(40)) }
            Task { await respondToApproval(id: id, approved: true) }
            return
        }
    }

    public func approveAndSwitchToAutoReview(id: String) async {
        if let approval = pendingApprovals.first(where: { $0.id == id }),
           let index = bots.firstIndex(where: { $0.id == approval.sessionId }) {
            bots[index].permissionMode = "autoReview"
            persistWorkspace()
        }
        await respondToApproval(id: id, approved: true)
    }

    private func handleDSHQuestionNotification(method: String, params: [String: Any]) {
        if method == "user-question.closed" {
            pendingDSHQuestions.removeAll { $0.id == params["questionId"] as? String }
            return
        }
        guard method == "user-question.request",
              !sentCancellation,
              let turnId = params["turnId"] as? String, activeTurnId == turnId,
              let sessionId = params["sessionId"] as? String, sessionId == streamingSessionId,
              let questionId = params["questionId"] as? String,
              let rawQuestions = params["questions"] as? [[String: Any]] else { return }
        let questions = rawQuestions.compactMap { raw -> DSHQuestionItem? in
            guard let id = raw["id"] as? String, let question = raw["question"] as? String else { return nil }
            let options = (raw["options"] as? [[String: Any]] ?? []).compactMap { item -> DSHQuestionOption? in
                guard let label = item["label"] as? String else { return nil }
                return DSHQuestionOption(label: label, description: item["description"] as? String ?? "")
            }
            return DSHQuestionItem(
                id: id,
                question: question,
                detail: raw["detail"] as? String ?? "",
                header: raw["header"] as? String ?? "",
                multiSelect: raw["multiSelect"] as? Bool ?? false,
                options: options
            )
        }
        guard !questions.isEmpty else { return }
        pendingDSHQuestions.removeAll { $0.id == questionId }
        pendingDSHQuestions.append(PendingDSHQuestion(id: questionId, sessionId: sessionId, turnId: turnId, questions: questions))
    }

    private func handleDSHToolNotification(_ params: [String: Any]) {
        guard !sentCancellation,
              let sessionId = params["sessionId"] as? String,
              let turnId = params["turnId"] as? String,
              activeTurnId == turnId, streamingSessionId == sessionId,
              let callId = params["callId"] as? String, !callId.isEmpty else { return }
        let phase = params["phase"] as? String ?? "started"
        let toolName = params["toolName"] as? String ?? "DSH tool"
        if phase == "started" {
            liveStream.phase = .toolRunning(toolName)
        }
        let redactedArgs = (params["arguments"] as? String).map { SecretRedactor.redactCommonTokens($0) }
        let redactedResult = (params["result"] as? String).map { SecretRedactor.redactCommonTokens($0) }
        if let index = dshToolActivities.firstIndex(where: {
            $0.sessionId == sessionId && $0.callId == callId
        }) {
            dshToolActivities[index].phase = phase
            if let arguments = redactedArgs { dshToolActivities[index].arguments = arguments }
            if let result = redactedResult { dshToolActivities[index].result = result }
            if let fileSummary = params["fileSummary"] as? String { dshToolActivities[index].fileSummary = fileSummary }
            if let timestamp = params["timestamp"] { dshToolActivities[index].timestamp = Self.sessionDate(timestamp) }
            if let sequence = params["sequence"] as? Int { dshToolActivities[index].sequence = sequence }
            if let callSequence = params["callSequence"] as? Int { dshToolActivities[index].callSequence = callSequence }
            if let durationMs = params["durationMs"] as? Int { dshToolActivities[index].durationMs = durationMs }
            if phase == "started", let sequence = params["sequence"] as? Int {
                dshToolActivities[index].callSequence = sequence
            }
        } else {
            dshToolActivities.append(DSHToolActivity(
                id: callId,
                callId: callId,
                sessionId: sessionId,
                turnId: turnId,
                toolName: toolName,
                phase: phase,
                arguments: redactedArgs ?? "",
                result: redactedResult ?? "",
                fileSummary: params["fileSummary"] as? String,
                timestamp: Self.sessionDate(params["timestamp"]),
                sequence: params["sequence"] as? Int,
                callSequence: params["callSequence"] as? Int ?? (phase == "started" ? params["sequence"] as? Int : nil),
                durationMs: params["durationMs"] as? Int
            ))
        }
        let sessionActivities = dshToolActivities.filter { $0.sessionId == sessionId }
        if sessionActivities.count > 40 {
            let removals = Set(sessionActivities.prefix(sessionActivities.count - 40).map(\.id))
            dshToolActivities.removeAll { $0.sessionId == sessionId && removals.contains($0.id) }
        }
    }

    private func handleDSHApprovalAuditNotification(_ params: [String: Any]) {
        guard let sessionId = params["sessionId"] as? String,
              sessionId == streamingSessionId,
              let turnId = params["turnId"] as? String, turnId == activeTurnId,
              let auditId = params["id"] as? String, !auditId.isEmpty,
              let outcome = params["outcome"] as? String else { return }
        let toolName = params["toolName"] as? String ?? "DSH 工具"
        let timestamp = Self.sessionDate(params["timestamp"])
        let sequence = params["sequence"] as? Int
        if let index = dshApprovalAudits.firstIndex(where: { $0.sessionId == sessionId && $0.id == auditId }) {
            dshApprovalAudits[index].toolName = toolName
            dshApprovalAudits[index].outcome = outcome
            dshApprovalAudits[index].timestamp = timestamp
            dshApprovalAudits[index].sequence = sequence
        } else {
            dshApprovalAudits.append(DSHApprovalAudit(
                id: auditId, sessionId: sessionId, toolName: toolName,
                outcome: outcome, timestamp: timestamp, sequence: sequence
            ))
        }
        let sessionAudits = dshApprovalAudits.filter { $0.sessionId == sessionId }
        if sessionAudits.count > 100 {
            let removals = Set(sessionAudits.prefix(sessionAudits.count - 100).map(\.id))
            dshApprovalAudits.removeAll { $0.sessionId == sessionId && removals.contains($0.id) }
        }
    }
}

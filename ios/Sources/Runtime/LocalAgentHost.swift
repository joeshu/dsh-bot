import Combine
import Foundation
import UniformTypeIdentifiers
#if canImport(PDFKit)
import PDFKit
#endif
#if canImport(Vision)
import Vision
#endif
#if canImport(ImageIO)
import ImageIO
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
    @Published public private(set) var webStandaloneSessions: [WebSessionSummary] = []
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
    @Published public private(set) var activeStreamingSessionIds: [String] = []
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

    @MainActor
    private final class ActiveTurnContext {
        let sessionId: String
        let turnId: String
        let effectiveApiBaseURL: String
        let streamState: StreamingTurnState
        var pendingReasoningBuffer = ""
        var pendingContentBuffer = ""
        var flushScheduled = false
        var startedAt = Date()
        var lastActivityAt = Date()
        var firstTokenMs: Int?
        var lastDraftSavedAt: Date = .distantPast
        var lastDraftSavedLength: Int = 0
        var sentCancellation = false
        var stallWatchdogTask: Task<Void, Never>?
        var groupLeaseWatchdogTask: Task<Void, Never>?

        init(sessionId: String, turnId: String, effectiveApiBaseURL: String, steerNote: String?) {
            self.sessionId = sessionId
            self.turnId = turnId
            self.effectiveApiBaseURL = effectiveApiBaseURL
            self.streamState = StreamingTurnState()
            self.streamState.begin(sessionId: sessionId, steerNote: steerNote)
        }
    }

    private static let maxConcurrentNativeTurns = 2
    private var activeTurnsBySession: [String: ActiveTurnContext] = [:]

    public func isSessionStreaming(_ sessionId: String) -> Bool {
        activeTurnsBySession[sessionId] != nil
    }

    public func isBotStreaming(_ botId: String) -> Bool {
        activeTurnsBySession.keys.contains { resolveAddress($0)?.botID == botId }
    }

    public func liveStream(for sessionId: String) -> StreamingTurnState {
        activeTurnsBySession[sessionId]?.streamState ?? liveStream
    }

    private func syncActiveStreamMirrors() {
        let ordered = activeTurnsBySession.values
            .sorted { $0.startedAt < $1.startedAt }
            .map(\.sessionId)
        activeStreamingSessionIds = ordered
        isStreaming = !ordered.isEmpty
        if let visible = visibleChatSessionId, let ctx = activeTurnsBySession[visible] {
            streamingSessionId = ctx.sessionId
            activeTurnId = ctx.turnId
        } else if let firstId = ordered.first, let ctx = activeTurnsBySession[firstId] {
            streamingSessionId = ctx.sessionId
            activeTurnId = ctx.turnId
        } else {
            streamingSessionId = nil
            activeTurnId = nil
        }
    }
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
    @Published public var useBubbleLayout: Bool = (UserDefaults.standard.object(forKey: "dsbot.useBubbleLayout") as? Bool) ?? true {
        didSet { UserDefaults.standard.set(useBubbleLayout, forKey: "dsbot.useBubbleLayout") }
    }
    private static let cachedModelsKey = "dsbot.cachedModelsByEndpoint"
    private static let favoriteModelsKey = "dsbot.favoriteModels"

    private static func loadCachedModels(for endpoint: String) -> [String] {
        let map = UserDefaults.standard.dictionary(forKey: cachedModelsKey) as? [String: [String]] ?? [:]
        return map[endpoint] ?? []
    }

    private static func saveCachedModels(_ ids: [String], for endpoint: String) {
        var map = UserDefaults.standard.dictionary(forKey: cachedModelsKey) as? [String: [String]] ?? [:]
        map[endpoint] = ids
        UserDefaults.standard.set(map, forKey: cachedModelsKey)
    }

    @Published public var favoriteModels: [String] = UserDefaults.standard.stringArray(forKey: "dsbot.favoriteModels") ?? [] {
        didSet { UserDefaults.standard.set(favoriteModels, forKey: Self.favoriteModelsKey) }
    }

    public func isFavoriteModel(_ modelId: String) -> Bool {
        favoriteModels.contains(modelId)
    }

    public func toggleFavoriteModel(_ modelId: String) {
        let trimmed = modelId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let idx = favoriteModels.firstIndex(of: trimmed) {
            favoriteModels.remove(at: idx)
        } else {
            favoriteModels.insert(trimmed, at: 0)
        }
    }

    @Published public private(set) var modelsCatalogRevision = UUID()

    public func isOfficialEndpoint(_ endpointURL: String?) -> Bool {
        let target = (endpointURL ?? apiBaseURL).trimmingCharacters(in: .whitespacesAndNewlines)
        let effective = target.isEmpty ? apiBaseURL : target
        return (try? ModelProvider(effective).isDeepSeek) == true
    }

    public func orderedAvailableModels(for endpointURL: String? = nil) -> [String] {
        let target = (endpointURL ?? apiBaseURL).trimmingCharacters(in: .whitespacesAndNewlines)
        let effective = target.isEmpty ? apiBaseURL : target
        let official = (try? ModelProvider(effective).isDeepSeek) == true
        let endpointModels: [String] = (effective == apiBaseURL)
            ? models
            : Self.loadCachedModels(for: effective)
        var base: [String] = []
        if official {
            base = [ModelProvider.defaultModel, ModelProvider.thinkingModel, "deepseek-v4-pro"]
            for id in endpointModels where !base.contains(id) {
                base.append(id)
            }
        } else {
            base = endpointModels
        }
        let favSet = Set(favoriteModels)
        let pinned = favoriteModels.filter { base.contains($0) }
        let rest = base.filter { !favSet.contains($0) }
        return pinned + rest
    }

    public var orderedAvailableModels: [String] {
        orderedAvailableModels(for: nil)
    }

    @Published public var apiBaseURL: String = UserDefaults.standard.string(forKey: "dsbot.apiBaseURL") ?? ModelProvider.defaultAddress {
        didSet {
            UserDefaults.standard.set(apiBaseURL, forKey: "dsbot.apiBaseURL")
            models = Self.loadCachedModels(for: apiBaseURL)
            Task { @MainActor [weak self] in
                await self?.syncProviderModelCatalogToDSH()
            }
        }
    }

    public func syncProviderModelCatalogToDSH(on rpc: IPCChannel? = nil) async {
        guard let target = rpc ?? channel else { return }
        let address = apiBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let currentModels = usesOfficialModels ? [] : models
        let activeDefaultModel = (bots.first(where: \.isMain)?.model ?? bots.first?.model ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try? await target.request(
            "models.catalog.sync",
            params: [
                "apiBaseURL": address,
                "models": currentModels,
                "defaultModel": activeDefaultModel
            ],
            timeoutSeconds: 15
        )
    }

    public func applyModelToAllBots(_ modelId: String) {
        let trimmed = modelId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        for index in bots.indices {
            bots[index].model = trimmed
        }
        persistWorkspace()
        Task { @MainActor [weak self] in
            await self?.syncProviderModelCatalogToDSH()
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

    func refreshModels(for endpointURL: String? = nil) async throws -> (latency: Int, count: Int) {
        guard channel != nil else { throw IPCFrameError.channelClosed }
        let requested = (endpointURL ?? apiBaseURL).trimmingCharacters(in: .whitespacesAndNewlines)
        let address = requested.isEmpty ? apiBaseURL : requested
        let result = try await workspaceCapabilities.nativeWorkspaceRequest(method: "models.test", params: ["apiBaseURL": address])
        let ids = result["models"] as? [String] ?? []
        if !ids.isEmpty {
            Self.saveCachedModels(ids, for: address)
            modelsCatalogRevision = UUID()
        }
        if apiBaseURL == address {
            models = ids
            if !usesOfficialModels, let firstCustom = ids.first {
                let officialIds: Set<String> = [
                    ModelProvider.defaultModel,
                    ModelProvider.thinkingModel,
                    "deepseek-v4-pro",
                    "deepseek-chat",
                    "deepseek-reasoner"
                ]
                var migrated = false
                for idx in bots.indices where (bots[idx].providerProfileId ?? "").isEmpty {
                    let cur = bots[idx].model.trimmingCharacters(in: .whitespacesAndNewlines)
                    if (cur.isEmpty || officialIds.contains(cur)) && !ids.contains(cur) {
                        bots[idx].model = firstCustom
                        migrated = true
                    }
                }
                if migrated { persistWorkspace() }
            }
            await syncProviderModelCatalogToDSH()
        }
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
    private var persistDebounceWorkItem: DispatchWorkItem?
    private var workspaceReadable = true
    private var uiNotifContinuation: AsyncStream<(String, [String: Any])>.Continuation?
    private var pendingSteerNoteBySession: [String: String] = [:]

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
        models = Self.loadCachedModels(for: apiBaseURL)
        workspaceCapabilities.setNativeNotificationHandler { [weak self] method, params in
            Task { @MainActor [weak self] in
                self?.handleNativeApprovalNotification(method: method, params: params)
            }
        }
        NotificationCenter.default.addObserver(
            forName: Notification.Name("dsbot.providerProfileDeleted"),
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let deletedID = notification.object as? String else { return }
            Task { @MainActor [weak self] in
                self?.clearDanglingProviderProfile(deletedID)
            }
        }
    }

    private func clearDanglingProviderProfile(_ deletedID: String) {
        var changed = false
        for idx in bots.indices where bots[idx].providerProfileId == deletedID {
            bots[idx].providerProfileId = nil
            changed = true
        }
        if changed { persistWorkspace() }
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

    public func botMaxActivityDate(for botId: String) -> Date? {
        let threadIds = BotThreadStore.shared.threads(for: botId, includeArchived: true).map(\.sessionId)
        var latest = sessionActivityDate(for: botId)
        for sid in threadIds {
            if let date = sessionActivityDate(for: sid) {
                latest = max(latest ?? date, date)
            }
        }
        return latest
    }

    public func sessionPreview(for sessionId: String) -> String? {
        let rootBotId = resolveAddress(sessionId)?.botID ?? sessionId
        guard bots.first(where: { $0.id == rootBotId })?.isPrivate != true else { return nil }
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
            let leftDate = botMaxActivityDate(for: left.id) ?? .distantPast
            let rightDate = botMaxActivityDate(for: right.id) ?? .distantPast
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
        let rootId = resolveAddress(sessionId)?.botID ?? sessionId
        guard !isBotStreaming(rootId),
              dshAgentPresets.contains(where: { $0.id == presetId && $0.isAvailable }),
              let index = bots.firstIndex(where: { $0.id == rootId }) else { return }
        guard !(bots[index].isPrivate && presetId == "redteam") else { return }
        guard bots[index].agentPreset != presetId else { return }
        bots[index].agentPreset = presetId
        persistWorkspace()
        DSHaptics.impact(.light)
    }

    public func setPermissionMode(sessionId: String, mode: String) {
        let rootId = resolveAddress(sessionId)?.botID ?? sessionId
        guard !isBotStreaming(rootId),
              ["ask", "autoReview", "readOnly"].contains(mode),
              let index = bots.firstIndex(where: { $0.id == rootId }) else { return }
        guard bots[index].permissionMode != mode else { return }
        bots[index].permissionMode = mode
        if mode == "readOnly", bots[index].agentPreset == "redteam" {
            bots[index].agentPreset = "standard"
        }
        persistWorkspace()
        DSHaptics.impact(.light)
    }

    public func setReasoningEffort(sessionId: String, effort: String) {
        let rootId = resolveAddress(sessionId)?.botID ?? sessionId
        guard ["low", "medium", "high"].contains(effort),
              let index = bots.firstIndex(where: { $0.id == rootId }) else { return }
        guard bots[index].reasoningEffort != effort else { return }
        bots[index].reasoningEffort = effort
        persistWorkspace()
        DSHaptics.impact(.light)
    }

    /// Rolls back the trailing assistant reply (if any) and the last user message in local session state + SQLite,
    /// returning the user's original prompt so it can be edited and resent cleanly (`rewind`).
    @discardableResult
    public func rewindLastTurn(sessionId: String) async -> String? {
        guard let address = resolveAddress(sessionId) else {
            workspaceError = "无效的会话地址，已拒绝撤回操作。"
            return nil
        }
        let targetId = address.canonicalSessionId
        guard !isSessionStreaming(targetId), var list = messagesBySession[targetId], !list.isEmpty else { return nil }
        guard let lastUserIdx = list.lastIndex(where: { $0.role == "user" }) else { return nil }
        let userText = list[lastUserIdx].content
        let truncateSeq = list[lastUserIdx].sequence
        if let truncateSeq, let channel {
            _ = try? await channel.request("session.truncateFromSeq", params: ["sessionId": targetId, "sequence": truncateSeq], timeoutSeconds: 15)
            dshToolActivities.removeAll { $0.sessionId == targetId && (($0.sequence ?? Int.max) >= truncateSeq || ($0.callSequence ?? Int.max) >= truncateSeq) }
            dshApprovalAudits.removeAll { $0.sessionId == targetId && ($0.sequence ?? Int.max) >= truncateSeq }
        }
        list.removeSubrange(lastUserIdx..<list.count)
        messagesBySession[targetId] = list
        await refreshSessionSummaries()
        return userText
    }

    /// Removes a message and all subsequent turns from the session transcript and awaits SQLite truncation.
    public func deleteMessage(sessionId: String, messageId: String) async {
        guard let address = resolveAddress(sessionId) else {
            workspaceError = "无效的会话地址，已拒绝删除消息。"
            return
        }
        let targetId = address.canonicalSessionId
        guard !isSessionStreaming(targetId), var list = messagesBySession[targetId] else { return }
        let removedSeq = list.first(where: { $0.id == messageId })?.sequence
        if let removedSeq, let channel {
            _ = try? await channel.request("session.truncateFromSeq", params: ["sessionId": targetId, "sequence": removedSeq], timeoutSeconds: 15)
            dshToolActivities.removeAll { $0.sessionId == targetId && (($0.sequence ?? Int.max) >= removedSeq || ($0.callSequence ?? Int.max) >= removedSeq) }
            dshApprovalAudits.removeAll { $0.sessionId == targetId && ($0.sequence ?? Int.max) >= removedSeq }
        }
        if let idx = list.firstIndex(where: { $0.id == messageId }) {
            list.removeSubrange(idx..<list.count)
        } else {
            list.removeAll { $0.id == messageId }
        }
        messagesBySession[targetId] = list
        await refreshSessionSummaries()
        DSHaptics.impact(.light)
    }

    /// Updates per-Bot disabled tool names (P1-17).
    public func setDisabledTools(botId: String, disabledTools: [String]) {
        guard let index = bots.firstIndex(where: { $0.id == botId }) else { return }
        bots[index].disabledTools = Array(Set(disabledTools)).sorted()
        persistWorkspace()
        schedulePrivateSessionAccessSync()
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
        pendingSteerNoteBySession[targetId] = trimmed
        activeTurnsBySession[targetId]?.streamState.recentSteerNote = trimmed
        if isSessionStreaming(targetId) {
            if let channel,
               let res = try? await channel.request("chat.steer", params: ["sessionId": targetId, "text": trimmed], timeoutSeconds: 10),
               res["steered"] as? Bool == true {
                DSHaptics.impact(.light)
                return
            }
            await abortActiveTurn(sessionId: targetId)
            for _ in 0..<50 {
                if !isSessionStreaming(targetId) { break }
                try? await Task.sleep(nanoseconds: 80_000_000)
            }
            if isSessionStreaming(targetId) {
                lastErrorSessionId = targetId
                lastStreamError = "上一轮正在中止收敛中，插话内容已保留，可稍候点击重发。"
                DSHaptics.notify(.warning)
                return
            }
        }
        await sendMessage(sessionId: targetId, text: "[插话引导] \(trimmed)", model: model)
    }

    /// Refreshes session summaries and cleanly reloads non-private histories modified by Web Workbench or background tasks.
    public func syncFromWebWorkbench() async {
        guard state == .ready else { return }
        await refreshSessionSummaries()
        await refreshPluginState()
        // Invalidate cached non-private non-streaming sessions so returning to any Bot reloads fresh SQLite truth.
        let cachedIds = Array(loadedHistoryIDs)
        for cachedId in cachedIds {
            guard !isSessionStreaming(cachedId) else { continue }
            if let address = resolveAddress(cachedId), bot(for: address)?.isPrivate == true { continue }
            loadedHistoryIDs.remove(cachedId)
            messagesBySession[cachedId] = nil
        }
        if let visibleId = visibleChatSessionId,
           let address = resolveAddress(visibleId),
           !isSessionStreaming(address.canonicalSessionId),
           bot(for: address)?.isPrivate != true {
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

        // Support BotExportPayload config template import directly
        if let exported = try? JSONDecoder().decode(BotExportPayload.self, from: data) {
            let id = "imp_" + String(UUID().uuidString.prefix(6)).lowercased()
            let bot = BotProfile(
                id: id,
                name: String(exported.name.prefix(24)),
                roleLabel: exported.roleLabel,
                model: exported.model,
                systemPrompt: exported.systemPrompt,
                section: "核心团队",
                permissionMode: exported.permissionMode,
                agentPreset: exported.agentPreset,
                reasoningEffort: exported.reasoningEffort,
                disabledTools: exported.disabledTools
            )
            bots.append(bot)
            persistWorkspace()
            return bot
        }

        if let json = try? JSONSerialization.jsonObject(with: data) {
            if let dict = json as? [String: Any] {
                if let t = dict["title"] as? String, !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    title = t
                }
                if let mappingDict = dict["mapping"] as? [String: [String: Any]] {
                    var orderedNodes: [(createTime: Double, role: String, content: String)] = []
                    // Prefer walking parent chain from current_node if available
                    if let currentId = dict["current_node"] as? String, !currentId.isEmpty {
                        var cursor: String? = currentId
                        var chain: [[String: Any]] = []
                        var visited = Set<String>()
                        while let nodeId = cursor, visited.insert(nodeId).inserted, let node = mappingDict[nodeId] {
                            chain.append(node)
                            cursor = node["parent"] as? String
                        }
                        for node in chain.reversed() {
                            if let msg = node["message"] as? [String: Any],
                               let author = msg["author"] as? [String: Any],
                               let role = (author["role"] as? String)?.lowercased(),
                               role == "user" || role == "assistant",
                               let contentObj = msg["content"] as? [String: Any] {
                                let parts = (contentObj["parts"] as? [Any] ?? []).compactMap { $0 as? String }
                                let body = parts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                                if !body.isEmpty {
                                    parsed.append((role, body))
                                }
                            }
                        }
                    }
                    if parsed.isEmpty {
                        for node in mappingDict.values {
                            if let msg = node["message"] as? [String: Any],
                               let author = msg["author"] as? [String: Any],
                               let role = (author["role"] as? String)?.lowercased(),
                               role == "user" || role == "assistant",
                               let contentObj = msg["content"] as? [String: Any] {
                                let parts = (contentObj["parts"] as? [Any] ?? []).compactMap { $0 as? String }
                                let body = parts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                                if !body.isEmpty {
                                    let ct = msg["create_time"] as? Double ?? 0
                                    orderedNodes.append((ct, role, body))
                                }
                            }
                        }
                        orderedNodes.sort { $0.createTime < $1.createTime }
                        parsed = orderedNodes.map { ($0.role, $0.content) }
                    }
                }
                if parsed.isEmpty {
                    let rawMsgs = (dict["messages"] as? [[String: Any]]) ?? (dict["mapping"] as? [[String: Any]]) ?? []
                    for m in rawMsgs {
                        let role = ((m["role"] as? String) ?? (m["author"] as? String) ?? "user").lowercased()
                        let content = (m["content"] as? String) ?? (m["text"] as? String) ?? ""
                        if !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            parsed.append((role.contains("assistant") || role.contains("bot") ? "assistant" : "user", content))
                        }
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

    public func effectiveApiBaseURL(for bot: BotProfile?) -> String {
        if let profileId = bot?.providerProfileId,
           !profileId.isEmpty,
           let profile = ProviderProfileStore.shared.profiles.first(where: { $0.id == profileId }),
           !profile.apiBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return profile.apiBaseURL
        }
        return apiBaseURL
    }

    public func setBotProviderProfile(sessionId: String, profileId: String?) {
        let rootId = resolveAddress(sessionId)?.botID ?? sessionId
        guard let idx = bots.firstIndex(where: { $0.id == rootId }) else { return }
        let normalized = profileId?.trimmingCharacters(in: .whitespacesAndNewlines)
        bots[idx].providerProfileId = (normalized?.isEmpty == true) ? nil : normalized
        if let profileId = bots[idx].providerProfileId,
           let profile = ProviderProfileStore.shared.profiles.first(where: { $0.id == profileId }),
           !profile.defaultModel.isEmpty {
            bots[idx].model = profile.defaultModel
        }
        persistWorkspace()
    }

    public func sendMessage(sessionId: String, text: String, model: String, imagePaths: [String] = []) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, state == .ready, let channel else { return }
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
        guard activeTurnsBySession[targetSessionId] == nil else { return }
        guard activeTurnsBySession.count < Self.maxConcurrentNativeTurns else {
            lastStreamError = "当前已有 \(Self.maxConcurrentNativeTurns) 个会话正在并发生成，请等待其中一个完成或停止后再发。"
            DSHaptics.notify(.warning)
            return
        }
        let targetBot = bot(for: address)
        let targetProfile: ProviderProfile? = {
            guard let pid = targetBot?.providerProfileId, !pid.isEmpty else { return nil }
            return ProviderProfileStore.shared.profiles.first(where: { $0.id == pid })
        }()
        let effectiveURL = effectiveApiBaseURL(for: targetBot)
        if activeTurnsBySession.values.contains(where: { $0.effectiveApiBaseURL != effectiveURL }) {
            lastErrorSessionId = targetSessionId
            lastStreamError = "当前有其他模型服务商地址的会话正在生成，请等待其完成后再并发发送不同服务商的请求。"
            DSHaptics.notify(.warning)
            return
        }
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
        if lastCancelledSessionId == targetSessionId { lastCancelledSessionId = nil }
        let turnId = UUID().uuidString
        messagesBySession[targetSessionId, default: []].append(ChatMessageItem(sessionId: targetSessionId, role: "user", content: trimmed))
        persistWorkspace()
        let steerNote = pendingSteerNoteBySession.removeValue(forKey: targetSessionId)
        let ctx = ActiveTurnContext(sessionId: targetSessionId, turnId: turnId, effectiveApiBaseURL: effectiveURL, steerNote: steerNote)
        activeTurnsBySession[targetSessionId] = ctx
        streamFirstTokenMs = nil
        lastStreamError = nil
        syncActiveStreamMirrors()
        DSHaptics.impact(.light)

        ctx.stallWatchdogTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                guard let self, let active = self.activeTurnsBySession[targetSessionId], active.turnId == turnId else { return }
                let hasPending = self.pendingApprovals.contains { $0.sessionId == targetSessionId }
                    || self.pendingDSHQuestions.contains { $0.sessionId == targetSessionId }
                if hasPending {
                    active.lastActivityAt = Date()
                    continue
                }
                if Date().timeIntervalSince(active.lastActivityAt) >= 120 {
                    self.lastErrorSessionId = targetSessionId
                    self.lastStreamError = "流式响应超过 120 秒无新数据（网络可能已断开），已安全停止，可点击重试。"
                    await self.abortActiveTurn(sessionId: targetSessionId)
                    return
                }
            }
        }

        let bot = targetBot
        let legacyHistory = (legacyMessagesBySession[targetSessionId] ?? []).suffix(12).map { message in
            ["role": message.role, "content": String(message.content.prefix(12_000))]
        }
        var pinnedMemoriesText = ""
        if bot?.isPrivate != true {
            let rootBotId = address.botID
            if let memRes = try? await channel.request("memory.journal", params: ["botId": rootBotId], timeoutSeconds: 5),
               let records = memRes["records"] as? [[String: Any]] {
                let pinned = records.filter { ($0["layer"] as? String) == "pinned" }.suffix(12)
                if !pinned.isEmpty {
                    pinnedMemoriesText = pinned.compactMap { row in
                        let title = row["title"] as? String ?? ""
                        let content = row["content"] as? String ?? ""
                        guard !content.isEmpty else { return nil }
                        return title.isEmpty ? "- \(String(content.prefix(400)))" : "- [\(title)] \(String(content.prefix(400)))"
                    }.joined(separator: "\n")
                }
            }
        }
        let effectiveCustomTools = (targetProfile?.supportsTools ?? true) && customTools
        let effectiveSupportsTools = targetProfile?.supportsTools ?? true
        let endpointModels = orderedAvailableModels(for: effectiveURL)
        var groupContextText = ""
        if bot?.isGroup == true {
            var parts: [String] = []
            let roster = bots.filter { !$0.isPrivate && !$0.isGroup }.prefix(12)
                .map { "- @\($0.name)（\($0.roleLabel)）" }.joined(separator: "\n")
            if !roster.isEmpty {
                parts.append("当前群聊协作团队成员名册：\n\(roster)")
            }
            if let gRes = try? await channel.request("group.state", params: ["groupId": address.botID], timeoutSeconds: 5) {
                if let goals = gRes["goals"] as? [[String: Any]], !goals.isEmpty {
                    let goalLines = goals.prefix(12).compactMap { g -> String? in
                        let title = g["title"] as? String ?? ""
                        let status = g["status"] as? String ?? "open"
                        guard !title.isEmpty else { return nil }
                        return "- [\(status)] \(title)"
                    }.joined(separator: "\n")
                    if !goalLines.isEmpty { parts.append("群目标：\n\(goalLines)") }
                }
                if let todos = gRes["todos"] as? [[String: Any]], !todos.isEmpty {
                    let todoLines = todos.prefix(20).compactMap { t -> String? in
                        let title = t["title"] as? String ?? ""
                        let done = t["done"] as? Bool == true
                        let assignee = t["assignee"] as? String ?? ""
                        guard !title.isEmpty else { return nil }
                        return "- [\(done ? "x" : " ")] \(title)\(assignee.isEmpty ? "" : " (@\(assignee))")"
                    }.joined(separator: "\n")
                    if !todoLines.isEmpty { parts.append("群待办：\n\(todoLines)") }
                }
            }
            groupContextText = parts.joined(separator: "\n\n")
            ctx.groupLeaseWatchdogTask = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 15_000_000_000)
                    guard let self, let active = self.activeTurnsBySession[targetSessionId], active.turnId == turnId else { return }
                    let waitingUser = self.pendingApprovals.contains { $0.turnId == turnId }
                        || self.pendingDSHQuestions.contains { $0.turnId == turnId }
                    if waitingUser { continue }
                    let idleSeconds = Date().timeIntervalSince(active.lastActivityAt)
                    if idleSeconds >= 90 {
                        self.lastErrorSessionId = targetSessionId
                        self.lastStreamError = "群聊编排连续 90 秒无输出（interrupted），已安全中止等待。"
                        await self.abortActiveTurn(sessionId: targetSessionId)
                        return
                    }
                }
            }
        }
        do {
            _ = try await channel.request("chat.send", params: [
                "sessionId": targetSessionId, "turnId": turnId, "model": model, "apiBaseURL": effectiveURL,
                "endpointModels": endpointModels,
                "systemPrompt": bot?.systemPrompt ?? "",
                "pinnedMemories": pinnedMemoriesText,
                "isGroup": bot?.isGroup ?? false,
                "groupContext": groupContextText,
                "agentPreset": bot?.agentPreset ?? "standard", "permissionMode": bot?.permissionMode ?? "ask",
                "reasoningEffort": bot?.reasoningEffort ?? "medium",
                "disabledTools": bot?.disabledTools ?? [],
                "subagentEnabled": subagentEnabled, "webSearchEnabled": webSearchEnabled,
                "customTools": effectiveCustomTools,
                "supportsTools": effectiveSupportsTools,
                "redteamMode": bot?.redteamToolsEnabled ?? false,
                "redteamWriteEnabled": bot?.redteamWriteEnabled ?? false,
                "redteamSensitiveDataEnabled": bot?.redteamSensitiveDataEnabled ?? false,
                "imagePaths": imagePaths,
                "text": trimmed, "legacyHistory": legacyHistory
            ])
        } catch {
            guard activeTurnsBySession[targetSessionId]?.turnId == turnId else { return }
            lastErrorSessionId = targetSessionId
            lastStreamError = error.localizedDescription
            finishTurn(for: targetSessionId)
        }
    }

    /// Executes a real DSH slash command (`/compact`, `/plan`, etc.) via `ctx.commands.execute`
    /// instead of sending the slash text as a normal chat prompt.
    @discardableResult
    public func executeSlashCommand(sessionId: String, commandLine: String) async throws -> String {
        guard state == .ready, let channel else { throw IPCFrameError.channelClosed }
        guard let address = resolveAddress(sessionId) else {
            throw NSError(domain: "DSBotCommand", code: 400, userInfo: [NSLocalizedDescriptionKey: "无效的会话地址"])
        }
        let targetId = address.canonicalSessionId
        let response = try await channel.request("command.execute", params: [
            "sessionId": targetId,
            "commandLine": commandLine,
        ], timeoutSeconds: 65)
        loadedHistoryIDs.remove(targetId)
        messagesBySession[targetId] = nil
        try? await loadSessionHistory(targetId)
        await refreshSessionSummaries()
        return response["result"] as? String ?? ""
    }

    /// Ensures an `ios:<sessionId>` header exists in SQLite, is attached to the default workspace,
    /// and carries a readable title before deep-linking into the Web Workbench.
    public func ensureSessionWebReady(sessionId: String, title: String) async {
        guard state == .ready, let channel else { return }
        guard let address = resolveAddress(sessionId), bot(for: address)?.isPrivate != true else { return }
        _ = try? await channel.request("session.ensureWebReady", params: [
            "sessionId": address.canonicalSessionId,
            "title": title,
        ], timeoutSeconds: 15)
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
        await syncProviderModelCatalogToDSH(on: rpc)
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
        let botIsStreaming = isBotStreaming(id)
        if botIsStreaming,
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
            } else if bots[idx].isPrivate && agentPreset == "redteam" {
                pluginStatus = "私密会话禁止使用红队模式。"
            } else if botIsStreaming {
                pluginStatus = "当前 Bot 正在生成；请等待本轮完成后再切换模式。"
            } else {
                bots[idx].agentPreset = agentPreset
            }
        }
        persistWorkspace()
        DSHaptics.notify(.success)
    }

    public func setRedteamPermissions(sessionId: String, toolsEnabled: Bool? = nil, writeEnabled: Bool? = nil, sensitiveDataEnabled: Bool? = nil) {
        let rootId = resolveAddress(sessionId)?.botID ?? sessionId
        guard let index = bots.firstIndex(where: { $0.id == rootId }) else { return }
        guard !isBotStreaming(rootId) else {
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
        guard state == .ready else { return }
        guard let address = resolveAddress(sessionId) else {
            workspaceError = "无效的会话地址，已拒绝重新生成。"
            return
        }
        let targetId = address.canonicalSessionId
        guard !isSessionStreaming(targetId) else { return }
        guard let prompt = await rewindLastTurn(sessionId: targetId) else { return }
        await sendMessage(sessionId: targetId, text: prompt, model: model)
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
        // Read up to inlineLimit bytes for text/code files (or small text files of any extension)
        if textExtensions.contains(ext) || byteCount <= inlineLimit {
            guard let handle = try? FileHandle(forReadingFrom: dest) else { return nil }
            defer { try? handle.close() }
            let slice = (try? handle.read(upToCount: inlineLimit)) ?? Data()
            guard !slice.isEmpty else { return nil }
            let gb18030 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
            let decoded: String? = {
                if !slice.contains(0), let utf8 = String(data: slice, encoding: .utf8) { return utf8 }
                if !slice.contains(0), let gb = String(data: slice, encoding: gb18030) { return gb }
                if let utf16 = String(data: slice, encoding: .utf16) { return utf16 }
                return nil
            }()
            if let decoded {
                if byteCount > slice.count {
                    return decoded + "\n...[已截断，完整内容请使用 workspace_read 或 python_exec 查看]"
                }
                return decoded
            }
        }
        return nil
    }

    public static let supportedImportContentTypes: [UTType] = [
        .item, .data, .content, .directory, .folder, .package,
        .plainText, .text, .utf8PlainText, .sourceCode, .pdf, .image, .audio, .movie, .archive
    ]

    public func importFileToWorkspace(from sourceURL: URL) throws -> AttachedWorkspaceFile {
        let accessed = sourceURL.startAccessingSecurityScopedResource()
        defer { if accessed { sourceURL.stopAccessingSecurityScopedResource() } }

        let maxInMemoryCopyBytes = 16 * 1024 * 1024
        let maxImageDirectBytes = 4 * 1024 * 1024
        let filesDir = workspace.appendingPathComponent("files", isDirectory: true)
        try FileManager.default.createDirectory(at: filesDir, withIntermediateDirectories: true)

        func performImport(from readableURL: URL) throws -> AttachedWorkspaceFile {
            let values = try? readableURL.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey, .fileSizeKey])
            let isDir = values?.isDirectory == true
            let rawSize = values?.fileSize ?? 0

            let sourceExt = readableURL.pathExtension.lowercased()
            let isImage = !isDir && Self.imageExtensions.contains(sourceExt)
            var preferredName = Self.sanitizeAttachmentFilename(
                readableURL.lastPathComponent.isEmpty ? sourceURL.lastPathComponent : readableURL.lastPathComponent,
                fallbackExt: isDir ? "" : (sourceExt.isEmpty ? "txt" : sourceExt)
            )
            if isDir && preferredName.hasSuffix(".") {
                preferredName.removeLast()
            }

            if isDir {
                let (targetName, dest) = Self.uniqueDestination(in: filesDir, preferredName: preferredName)
                try FileManager.default.copyItem(at: readableURL, to: dest)
                let itemCount = (try? FileManager.default.contentsOfDirectory(atPath: dest.path).count) ?? 0
                return AttachedWorkspaceFile(
                    relativePath: targetName,
                    fileName: targetName,
                    byteCount: rawSize,
                    inlineText: "[已导入目录：files/\(targetName)（共 \(itemCount) 项，可使用 workspace_list / workspace_read 查看）]"
                )
            }

            if isImage && rawSize > maxImageDirectBytes {
                if let downsampled = MemoryGovernor.downsampleImage(at: readableURL, maxPixelSize: 1568, compressionQuality: 0.82) {
                    let stem = (preferredName as NSString).deletingPathExtension
                    preferredName = "\(stem).jpg"
                    let (targetName, dest) = Self.uniqueDestination(in: filesDir, preferredName: preferredName)
                    try downsampled.write(to: dest, options: .atomic)
                    let inlineText = Self.extractInlinePreview(at: dest, byteCount: downsampled.count)
                    return AttachedWorkspaceFile(relativePath: targetName, fileName: targetName, byteCount: downsampled.count, inlineText: inlineText)
                }
            }

            let (targetName, dest) = Self.uniqueDestination(in: filesDir, preferredName: preferredName)
            // For files <= 16 MB, read & atomically write to avoid Cocoa error 257 on external FileProviders.
            // For larger files, copyItem streams on disk without spiking iOS Jetsam memory.
            if rawSize <= maxInMemoryCopyBytes, let data = try? Data(contentsOf: readableURL, options: .mappedIfSafe) {
                try data.write(to: dest, options: .atomic)
                let inlineText = Self.extractInlinePreview(at: dest, byteCount: data.count)
                return AttachedWorkspaceFile(relativePath: targetName, fileName: targetName, byteCount: data.count, inlineText: inlineText)
            }

            do {
                try FileManager.default.copyItem(at: readableURL, to: dest)
            } catch {
                // Chunked stream copy fallback for large files from restrictive FileProviders
                guard let input = InputStream(url: readableURL),
                      let output = OutputStream(url: dest, append: false) else {
                    throw error
                }
                input.open()
                output.open()
                defer {
                    input.close()
                    output.close()
                }
                var buffer = [UInt8](repeating: 0, count: 65_536)
                while input.hasBytesAvailable {
                    let readCount = input.read(&buffer, maxLength: buffer.count)
                    if readCount < 0 { throw input.streamError ?? error }
                    if readCount == 0 { break }
                    var written = 0
                    while written < readCount {
                        let w = buffer.withUnsafeBytes { ptr -> Int in
                            guard let base = ptr.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return -1 }
                            return output.write(base.advanced(by: written), maxLength: readCount - written)
                        }
                        if w <= 0 { throw output.streamError ?? error }
                        written += w
                    }
                }
            }
            let copiedAttrs = try? FileManager.default.attributesOfItem(atPath: dest.path)
            let finalSize = (copiedAttrs?[.size] as? Int) ?? rawSize
            let inlineText = Self.extractInlinePreview(at: dest, byteCount: finalSize)
            return AttachedWorkspaceFile(relativePath: targetName, fileName: targetName, byteCount: finalSize, inlineText: inlineText)
        }

        var coordinatorError: NSError?
        var importError: Error?
        var importedFile: AttachedWorkspaceFile?

        // Use default options ([]) so iOS materializes iCloud Drive / third-party FileProvider items before reading.
        let coordinator = NSFileCoordinator()
        coordinator.coordinate(readingItemAt: sourceURL, options: [], error: &coordinatorError) { coordinatedURL in
            do {
                importedFile = try performImport(from: coordinatedURL)
            } catch {
                importError = error
            }
        }

        if let importedFile { return importedFile }
        // Fallback: some transient Inbox / FileProvider URLs succeed on direct read even if coordination errored.
        if let direct = try? performImport(from: sourceURL) {
            return direct
        }
        if let importError { throw importError }
        if let coordinatorError { throw coordinatorError }
        throw IPCFrameError.remoteError(code: -32603, message: "无法读取所选文件，请重试。")
    }

    public func importRawDataToWorkspace(_ data: Data, suggestedName: String) throws -> AttachedWorkspaceFile {
        let filesDir = workspace.appendingPathComponent("files", isDirectory: true)
        try FileManager.default.createDirectory(at: filesDir, withIntermediateDirectories: true)
        let ext = (suggestedName as NSString).pathExtension
        let preferredName = Self.sanitizeAttachmentFilename(suggestedName, fallbackExt: ext.isEmpty ? "txt" : ext)
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
        return autoreleasepool {
            let cgImage: CGImage? = {
                #if canImport(ImageIO)
                let createOpts: [CFString: Any] = [kCGImageSourceShouldCache: false]
                if let source = CGImageSourceCreateWithData(data as CFData, createOpts as CFDictionary) {
                    let thumbOpts: [CFString: Any] = [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceShouldCacheImmediately: true,
                        kCGImageSourceThumbnailMaxPixelSize: 2048,
                    ]
                    if let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOpts as CFDictionary) {
                        return thumb
                    }
                }
                #endif
                return UIImage(data: data)?.cgImage
            }()
            guard let cgImage else { return nil }
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
        }
        #else
        return nil
        #endif
    }

    public func deleteBot(id: String) {
        guard let target = bots.first(where: { $0.id == id }), !target.isMain else { return }
        var deletedSessionIds = BotThreadStore.shared.threads(for: id, includeArchived: true).map(\.sessionId)
        if !deletedSessionIds.contains(id) { deletedSessionIds.append(id) }
        if target.isPrivate {
            var privateTombstones = Set(UserDefaults.standard.stringArray(forKey: "dsbot.privateSessionTombstones") ?? [])
            privateTombstones.insert(id)
            for sid in deletedSessionIds { privateTombstones.insert(sid) }
            UserDefaults.standard.set(privateTombstones.sorted(), forKey: "dsbot.privateSessionTombstones")
        }
        bots.removeAll { $0.id == id }
        BotThreadStore.shared.removeAllThreads(for: id)
        for sid in deletedSessionIds {
            if isSessionStreaming(sid) {
                Task { [weak self] in await self?.abortActiveTurn(sessionId: sid) }
            }
            discardSessionHistoryCache(sid)
            persistedSessionIDs.remove(sid)
            persistedSessionActivityByID.removeValue(forKey: sid)
            persistedSessionPreviewByID.removeValue(forKey: sid)
            legacyMessagesBySession.removeValue(forKey: sid)
            setDraftInput("", for: sid, isPrivate: false)
        }
        Task { [weak self] in
            await self?.syncPrivateSessionAccess()
            for sid in deletedSessionIds {
                await self?.deleteDSHSession(sid)
            }
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
                    for ctx in self.activeTurnsBySession.values {
                        let sId = ctx.sessionId
                        let tId = ctx.turnId
                        Task {
                            await self.workspaceCapabilities.cancelNativeTool(botId: sId, turnId: tId) { botId, turnId in
                                _ = try? await rpc.request("python.cancel", params: ["botId": botId, "turnId": turnId], timeoutSeconds: 5)
                            }
                        }
                    }
                    self.pendingApprovals.removeAll()
                    self.pendingDSHQuestions.removeAll()
                    let message = "内嵌 DSH 运行时已退出，请重新启动应用。"
                    if !self.activeTurnsBySession.isEmpty {
                        self.lastStreamError = message
                        for sId in Array(self.activeTurnsBySession.keys) {
                            self.finishTurn(for: sId, params: ["status": "error"])
                        }
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
            MemoryGovernor.shared.onPressureTrim = { [weak self] _ in
                Task { @MainActor in
                    self?.trimMemoryCachesForPressure()
                }
            }
            MemoryGovernor.shared.onCriticalPressure = { [weak self] in
                guard let self else { return }
                Task { @MainActor in
                    self.trimMemoryCachesForPressure()
                    if !self.activeTurnsBySession.isEmpty {
                        self.lastStreamError = "系统内存紧张，已安全暂停当前生成以保护进度。"
                        for sId in Array(self.activeTurnsBySession.keys) {
                            await self.abortActiveTurn(sessionId: sId)
                        }
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

    /// Reclaims SwiftUI render caches, inactive session transcripts, and excess tool/audit records under iOS memory pressure.
    public func trimMemoryCachesForPressure() {
        DSMarkdownText.clearRenderCache()
        var keepIds = Set(activeTurnsBySession.keys)
        if let visibleChatSessionId { keepIds.insert(visibleChatSessionId) }
        for sessionId in Array(messagesBySession.keys) where !keepIds.contains(sessionId) {
            messagesBySession.removeValue(forKey: sessionId)
            loadedHistoryIDs.remove(sessionId)
            historyCursors.removeValue(forKey: sessionId)
        }
        if dshToolActivities.count > 120 {
            let protected = dshToolActivities.filter { keepIds.contains($0.sessionId) }
            let others = dshToolActivities.filter { !keepIds.contains($0.sessionId) }.suffix(max(0, 120 - protected.count))
            dshToolActivities = Array(others) + protected
        }
        if dshApprovalAudits.count > 100 {
            let protected = dshApprovalAudits.filter { keepIds.contains($0.sessionId) }
            let others = dshApprovalAudits.filter { !keepIds.contains($0.sessionId) }.suffix(max(0, 100 - protected.count))
            dshApprovalAudits = Array(others) + protected
        }
    }

    public func suspendForBackground() async {
        await flushWorkspacePersistence()
        guard let channel else { return }
        let suspendedSnapshots = activeTurnsBySession.map { ($0.key, $0.value.turnId) }
        if !suspendedSnapshots.isEmpty {
            for ctx in activeTurnsBySession.values {
                ctx.sentCancellation = true
            }
            pendingApprovals.removeAll()
            pendingDSHQuestions.removeAll()
        }
        _ = try? await channel.request("agent.suspend", timeoutSeconds: 12)
        for (sId, tId) in suspendedSnapshots {
            if activeTurnsBySession[sId]?.turnId == tId {
                lastCancelledSessionId = sId
                finishTurn(for: sId, params: ["status": "aborted"])
            }
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
            if !activeTurnsBySession.isEmpty && (activeTurns == 0 || activeTurnsBySession.values.allSatisfy(\.sentCancellation)) {
                let stuckIds = Array(activeTurnsBySession.keys)
                for sId in stuckIds {
                    finishTurn(for: sId, params: ["status": "aborted"])
                    loadedHistoryIDs.remove(sId)
                    try? await loadSessionHistory(sId)
                }
            }
            if (!isHealthy || !webAlive), state == .ready, !isStreaming {
                _ = await restartRuntime()
            }
        } catch {
            if !activeTurnsBySession.isEmpty {
                for sId in Array(activeTurnsBySession.keys) {
                    finishTurn(for: sId, params: ["status": "aborted"])
                }
            }
            if state == .ready, !isStreaming {
                _ = await restartRuntime()
            }
        }
    }

    public func abortActiveTurn(sessionId: String? = nil) async {
        let targetSessionId = sessionId ?? streamingSessionId
        guard let targetSessionId, let ctx = activeTurnsBySession[targetSessionId] else { return }
        let turnId = ctx.turnId
        if ctx.sentCancellation {
            // Second tap on Stop or already-cancelled turn: force-unblock UI and preserve partial text.
            lastCancelledSessionId = targetSessionId
            finishTurn(for: targetSessionId, params: ["status": "aborted"])
            return
        }
        ctx.sentCancellation = true
        ctx.streamState.phase = .cancelling
        pendingApprovals.removeAll { $0.turnId == turnId }
        pendingDSHQuestions.removeAll { $0.turnId == turnId }
        do {
            let response = try await channel?.request("chat.abort", params: ["turnId": turnId], timeoutSeconds: 5)
            if response?["aborted"] as? Bool != true, activeTurnsBySession[targetSessionId]?.turnId == turnId {
                finishTurn(for: targetSessionId, params: ["status": "aborted"])
            }
        } catch {
            if activeTurnsBySession[targetSessionId]?.turnId == turnId {
                lastErrorSessionId = targetSessionId
                lastStreamError = error.localizedDescription
                finishTurn(for: targetSessionId, params: ["status": "aborted"])
            }
        }
    }

    public func respondToApproval(id: String, approved: Bool) async {
        guard !inFlightRequestIDs.contains(id), !resolvedRequestIDs.contains(id) else { return }
        guard let approval = pendingApprovals.first(where: { $0.id == id }),
              let ctx = activeTurnsBySession[approval.sessionId],
              approval.turnId == ctx.turnId, !ctx.sentCancellation else {
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
            if resolvedRequestIDs.count > 500 { resolvedRequestIDs.removeAll(keepingCapacity: true) }
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
              let ctx = activeTurnsBySession[question.sessionId],
              question.turnId == ctx.turnId, !ctx.sentCancellation else {
            pendingDSHQuestions.removeAll { $0.id == id }
            return
        }
        inFlightRequestIDs.insert(id)
        defer { inFlightRequestIDs.remove(id) }
        let receipt = try? await channel?.request("user-question.respond", params: [
            "questionId": id, "turnId": question.turnId, "sessionId": question.sessionId, "answers": answers
        ])
        if receipt?["found"] as? Bool == true {
            if resolvedRequestIDs.count > 500 { resolvedRequestIDs.removeAll(keepingCapacity: true) }
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

    /// Only the Keychain key for the global endpoint or an explicitly saved ProviderProfile is released to Node.
    private func configuredCredentialProvider(_ params: [String: Any]) throws -> ModelProvider {
        let configured = try ModelProvider(apiBaseURL)
        if let requestedRaw = params["apiBaseURL"] as? String {
            let requested = try ModelProvider(requestedRaw)
            if requested.baseURL == configured.baseURL {
                return configured
            }
            let allowedProfileURLs = ProviderProfileStore.shared.profiles.compactMap {
                try? ModelProvider($0.apiBaseURL).baseURL
            }
            if allowedProfileURLs.contains(requested.baseURL) {
                return requested
            }
            throw IPCFrameError.remoteError(code: -32003, message: "凭据只提供给当前设置或已保存档案的服务地址。")
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
            telemetryBySession.removeValue(forKey: target)
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
            await syncBotPolicies(on: rpc)
            return true
        } catch {
            workspaceError = "私密会话 Web API 隔离同步失败：\(error.localizedDescription)"
            return false
        }
    }

    private func syncBotPolicies(on rpc: IPCChannel) async {
        let payload: [[String: Any]] = bots.map { bot in
            [
                "id": bot.id,
                "name": bot.isPrivate ? "" : bot.name,
                "systemPrompt": bot.isPrivate ? "" : bot.systemPrompt,
                "permissionMode": bot.permissionMode,
                "agentPreset": bot.agentPreset,
                "disabledTools": bot.disabledTools,
                "isGroup": bot.isGroup,
            ]
        }
        _ = try? await rpc.request("bots.policy.sync", params: ["bots": payload], timeoutSeconds: 15)
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
            if let webListing = try? await rpc.request("web.sessions.list", timeoutSeconds: 15),
               generation == runtimeGeneration {
                let rawWeb = webListing["sessions"] as? [[String: Any]] ?? []
                webStandaloneSessions = rawWeb.compactMap { record -> WebSessionSummary? in
                    guard let id = record["sessionId"] as? String, !id.isEmpty else { return nil }
                    let ts = Self.sessionDate(record["lastActivityAt"] ?? record["createdAt"])
                    let preview = (record["lastMessagePreview"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    let count = record["eventCount"] as? Int ?? 0
                    return WebSessionSummary(
                        sessionId: id,
                        lastActivityAt: ts,
                        lastMessagePreview: preview,
                        eventCount: count
                    )
                }
            }
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
        await rpc.registerHandler(method: "native.image.process") { params in
            guard let b64 = params["base64"] as? String,
                  let inputData = Data(base64Encoded: b64),
                  !inputData.isEmpty else {
                throw IPCFrameError.invalidJSON
            }
            let maxWidth = (params["maxWidth"] as? NSNumber)?.intValue ?? 0
            let maxHeight = (params["maxHeight"] as? NSNumber)?.intValue ?? 0
            let maxBytes = (params["maxBytes"] as? NSNumber)?.intValue ?? 4 * 1024 * 1024
            let preserveAlpha = params["preserveAlpha"] as? Bool ?? false
            let probeOnly = params["probeOnly"] as? Bool ?? false
            return try await Task.detached(priority: .userInitiated) {
                #if canImport(ImageIO) && canImport(CoreGraphics)
                guard let source = CGImageSourceCreateWithData(inputData as CFData, nil),
                      let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                      let rawW = props[kCGImagePropertyPixelWidth] as? Int,
                      let rawH = props[kCGImagePropertyPixelHeight] as? Int,
                      rawW > 0, rawH > 0 else {
                    throw NSError(domain: "DSBotImageIO", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid image data"])
                }
                let orientation = (props[kCGImagePropertyOrientation] as? Int) ?? 1
                let swapped = orientation >= 5 && orientation <= 8
                let effW = swapped ? rawH : rawW
                let effH = swapped ? rawW : rawH
                let hasAlpha = (props[kCGImagePropertyHasAlpha] as? Bool) ?? false
                let srcType = CGImageSourceGetType(source) as String? ?? ""
                let detectedMime: String = {
                    if srcType.contains("png") { return "image/png" }
                    if srcType.contains("jpeg") || srcType.contains("jpg") { return "image/jpeg" }
                    if srcType.contains("webp") { return "image/webp" }
                    if srcType.contains("gif") { return "image/gif" }
                    return hasAlpha ? "image/png" : "image/jpeg"
                }()
                if probeOnly {
                    return [
                        "width": effW,
                        "height": effH,
                        "mediaType": detectedMime,
                        "hasAlpha": hasAlpha,
                    ]
                }
                let targetMaxEdge: Int = {
                    let capW = maxWidth > 0 ? maxWidth : effW
                    let capH = maxHeight > 0 ? maxHeight : effH
                    return max(1, min(max(effW, effH), max(capW, capH)))
                }()
                let thumbOpts: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceShouldCacheImmediately: true,
                    kCGImageSourceThumbnailMaxPixelSize: targetMaxEdge,
                ]
                guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOpts as CFDictionary)
                    ?? CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                    throw NSError(domain: "DSBotImageIO", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to decode image"])
                }
                let outW = cgImage.width
                let outH = cgImage.height
                let wantPNG = preserveAlpha && hasAlpha
                let qualities: [CGFloat] = [0.85, 0.72, 0.58, 0.44]
                var encodedData: Data?
                var outMime = wantPNG ? "image/png" : "image/jpeg"
                if wantPNG {
                    let mutable = NSMutableData()
                    if let dest = CGImageDestinationCreateWithData(mutable, UTType.png.identifier as CFString, 1, nil) {
                        CGImageDestinationAddImage(dest, cgImage, nil)
                        if CGImageDestinationFinalize(dest), mutable.length <= maxBytes {
                            encodedData = mutable as Data
                        }
                    }
                }
                if encodedData == nil {
                    outMime = "image/jpeg"
                    for q in qualities {
                        let mutable = NSMutableData()
                        if let dest = CGImageDestinationCreateWithData(mutable, UTType.jpeg.identifier as CFString, 1, nil) {
                            CGImageDestinationAddImage(dest, cgImage, [kCGImageDestinationLossyCompressionQuality: q] as CFDictionary)
                            if CGImageDestinationFinalize(dest) {
                                encodedData = mutable as Data
                                if mutable.length <= maxBytes { break }
                            }
                        }
                    }
                }
                guard let finalBytes = encodedData, !finalBytes.isEmpty else {
                    throw NSError(domain: "DSBotImageIO", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed to encode image"])
                }
                return [
                    "base64": finalBytes.base64EncodedString(),
                    "width": outW,
                    "height": outH,
                    "mediaType": outMime,
                    "hasAlpha": outMime == "image/png" ? hasAlpha : false,
                ]
                #else
                throw NSError(domain: "DSBotImageIO", code: 4, userInfo: [NSLocalizedDescriptionKey: "ImageIO unavailable"])
                #endif
            }.value
        }

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
            await MainActor.run {
                self?.updatePluginRecovery(safeMode)
                self?.runtimeGeneration = UUID()
                self?.resolveRuntimeReadiness()
            }
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
            let (provider, migrate) = try await MainActor.run {
                (try self.configuredCredentialProvider(params), self.migrateOfficialKey)
            }
            let value = try await self.keychain.modelKey(provider: provider, migrateOfficialKey: migrate)
            return ["value": value]
        }
        await rpc.registerHandler(method: "credential.describe") { [weak self] params in
            guard let self else { throw IPCFrameError.channelClosed }
            do {
                let (provider, migrate) = try await MainActor.run {
                    (try self.configuredCredentialProvider(params), self.migrateOfficialKey)
                }
                _ = try await self.keychain.modelKey(provider: provider, migrateOfficialKey: migrate)
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
            let ws = await MainActor.run { self.workspace }
            return try await AgentBrowserController.shared.handleAction(action, args: args, workspace: ws)
        }
        await rpc.registerHandler(method: "native.tool.execute") { [weak self] params in
            guard let self, let name = params["name"] as? String else { throw IPCFrameError.invalidJSON }
            var arguments = params["args"] as? [String: Any] ?? [:]
            if name == "web_search" {
                let botId = params["botId"] as? String ?? ""
                let turnId = params["turnId"] as? String ?? ""
                let originalQuestion: String? = try await MainActor.run {
                    let targetBot = self.resolveAddress(botId).flatMap { self.bot(for: $0) }
                    let botUsesOfficial = (try? ModelProvider(self.effectiveApiBaseURL(for: targetBot)).isDeepSeek) == true
                    guard self.webSearchEnabled, botUsesOfficial,
                          let ctx = self.activeTurnsBySession[botId],
                          ctx.turnId == turnId, !ctx.sentCancellation else {
                        throw IPCFrameError.remoteError(code: -32000, message: "当前会话不能发起网页搜索。")
                    }
                    if self.effectiveWebSearchSendOriginalQuestion {
                        guard let q = self.webSearchOriginalQuestionContext(sessionId: botId) else {
                            throw IPCFrameError.remoteError(code: -32000, message: "无法展示将发送的原始问题上下文，已阻止网页搜索。")
                        }
                        return q
                    }
                    return nil
                }
                arguments.removeValue(forKey: "originalQuestion")
                if let originalQuestion {
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
            legacyMessagesBySession = messagesBySession
            workspaceReadable = true
            restoreInterruptedStreamingDraftIfNeeded()
        } catch {
            workspaceReadable = false
            throw IPCFrameError.remoteError(code: -32000, message: "无法读取本机工作区。原有文件已保留。")
        }
    }

    private func flushWorkspacePersistence() async {
        guard workspaceReadable else { return }
        persistDebounceWorkItem?.cancel()
        persistDebounceWorkItem = nil
        let botsSnapshot = bots
        let chatsSnapshot = legacyMessagesBySession
        let root = workspace
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            persistQueue.async { [weak self] in
                do {
                    try JSONEncoder().encode(botsSnapshot).write(
                        to: root.appendingPathComponent("bots.json"),
                        options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
                    )
                    try JSONEncoder().encode(chatsSnapshot).write(
                        to: root.appendingPathComponent("chats.json"),
                        options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
                    )
                    Task { @MainActor in self?.workspaceError = nil }
                } catch {
                    Task { @MainActor in self?.workspaceError = "保存本机工作区失败。请检查存储空间后重试。" }
                }
                continuation.resume()
            }
        }
    }

    private var lastPersistedLegacySignature: Int = -1

    private func persistWorkspace(immediate: Bool = false) {
        guard workspaceReadable else { return }
        persistDebounceWorkItem?.cancel()
        persistDebounceWorkItem = nil
        let botsSnapshot = bots
        var sig = legacyMessagesBySession.count
        for (k, msgs) in legacyMessagesBySession {
            sig = sig &* 31 &+ k.hashValue &+ msgs.count &+ (msgs.last?.id.hashValue ?? 0)
        }
        let shouldWriteLegacyChats = (sig != lastPersistedLegacySignature)
        let chatsSnapshot: [String: [ChatMessageItem]]? = shouldWriteLegacyChats ? legacyMessagesBySession : nil
        if shouldWriteLegacyChats {
            lastPersistedLegacySignature = sig
        }
        let root = workspace
        let writeBlock: @Sendable () -> Void = { [weak self] in
            do {
                try JSONEncoder().encode(botsSnapshot).write(
                    to: root.appendingPathComponent("bots.json"),
                    options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
                )
                if let chatsSnapshot {
                    try JSONEncoder().encode(chatsSnapshot).write(
                        to: root.appendingPathComponent("chats.json"),
                        options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
                    )
                }
                Task { @MainActor in self?.workspaceError = nil }
            } catch {
                Task { @MainActor in self?.workspaceError = "保存本机工作区失败。请检查存储空间后重试。" }
            }
        }
        if immediate {
            persistQueue.async(execute: writeBlock)
            return
        }
        let item = DispatchWorkItem(block: writeBlock)
        persistDebounceWorkItem = item
        persistQueue.asyncAfter(deadline: .now() + .milliseconds(250), execute: item)
    }

    private func streamingDraftURL(turnId: String? = nil) -> URL {
        if let turnId, !turnId.isEmpty {
            let safeId = turnId.replacingOccurrences(of: "[^A-Za-z0-9._-]", with: "_", options: .regularExpression)
            return workspace
                .appendingPathComponent("streaming-drafts", isDirectory: true)
                .appendingPathComponent("\(safeId).json")
        }
        return workspace.appendingPathComponent("streaming-draft.json")
    }

    private func restoreInterruptedStreamingDraftIfNeeded() {
        var draftURLs: [URL] = []
        let legacyURL = streamingDraftURL()
        if FileManager.default.fileExists(atPath: legacyURL.path) {
            draftURLs.append(legacyURL)
        }
        let draftsDir = workspace.appendingPathComponent("streaming-drafts", isDirectory: true)
        if let files = try? FileManager.default.contentsOfDirectory(at: draftsDir, includingPropertiesForKeys: nil) {
            draftURLs.append(contentsOf: files.filter { $0.pathExtension == "json" })
        }
        guard !draftURLs.isEmpty else { return }
        var recoveredAny = false
        for url in draftURLs {
            defer { try? FileManager.default.removeItem(at: url) }
            guard let data = try? Data(contentsOf: url),
                  let draft = try? JSONDecoder().decode(StreamingDraftRecord.self, from: data),
                  (!draft.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                   || !draft.reasoning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) else {
                continue
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
            legacyMessagesBySession[draft.sessionId, default: []].append(recovered)
            recoveredAny = true
        }
        if recoveredAny {
            persistWorkspace(immediate: true)
        }
    }

    private func checkpointStreamingDraftIfNeeded(for ctx: ActiveTurnContext) {
        let totalLen = ctx.streamState.content.count + ctx.streamState.reasoning.count
        guard totalLen > 0 else { return }
        let now = Date()
        let deltaChars = totalLen - ctx.lastDraftSavedLength
        guard deltaChars >= 512 || (deltaChars > 0 && now.timeIntervalSince(ctx.lastDraftSavedAt) >= 4.0) else { return }
        ctx.lastDraftSavedAt = now
        ctx.lastDraftSavedLength = totalLen
        let draft = StreamingDraftRecord(
            sessionId: ctx.sessionId,
            content: ctx.streamState.content,
            reasoning: ctx.streamState.reasoning,
            updatedAt: now
        )
        let url = streamingDraftURL(turnId: ctx.turnId)
        persistQueue.async {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let encoded = try? JSONEncoder().encode(draft) {
                try? encoded.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            }
        }
    }

    private func clearStreamingDraft(turnId: String? = nil) {
        let url = streamingDraftURL(turnId: turnId)
        let legacyURL = streamingDraftURL()
        persistQueue.async {
            try? FileManager.default.removeItem(at: url)
            if turnId == nil {
                try? FileManager.default.removeItem(at: legacyURL)
            }
        }
    }

    private func flushPendingStreamBuffers(for sessionId: String) {
        guard let ctx = activeTurnsBySession[sessionId] else { return }
        ctx.flushScheduled = false
        var grew = false
        if !ctx.pendingReasoningBuffer.isEmpty {
            ctx.streamState.reasoning += ctx.pendingReasoningBuffer
            ctx.pendingReasoningBuffer = ""
            if ctx.streamState.content.isEmpty && !ctx.sentCancellation {
                ctx.streamState.phase = .thinking
            }
            grew = true
        }
        if !ctx.pendingContentBuffer.isEmpty {
            ctx.streamState.appendContent(ctx.pendingContentBuffer)
            ctx.pendingContentBuffer = ""
            if !ctx.sentCancellation {
                ctx.streamState.phase = .generating
            }
            grew = true
        }
        if grew {
            let elapsed = max(0.25, Date().timeIntervalSince(ctx.startedAt))
            ctx.streamState.elapsedSeconds = Int(elapsed)
            let totalChars = ctx.streamState.content.count + ctx.streamState.reasoning.count
            ctx.streamState.charsPerSecond = max(1, Int(Double(totalChars) / elapsed))
            checkpointStreamingDraftIfNeeded(for: ctx)
        }
    }

    private func scheduleStreamFlushIfNeeded(for sessionId: String) {
        guard let ctx = activeTurnsBySession[sessionId], !ctx.flushScheduled else { return }
        ctx.flushScheduled = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 33_000_000) // ~30 FPS coalescing
            self?.flushPendingStreamBuffers(for: sessionId)
        }
    }

    private func finishTurn(for sessionId: String? = nil, params: [String: Any] = [:]) {
        let targetSessionId = sessionId ?? streamingSessionId
        guard let targetSessionId, let ctx = activeTurnsBySession[targetSessionId] else {
            syncActiveStreamMirrors()
            return
        }
        flushPendingStreamBuffers(for: targetSessionId)
        clearStreamingDraft(turnId: ctx.turnId)
        if activeTurnsBySession.count <= 1 {
            clearStreamingDraft()
        }
        let turnId = ctx.turnId
        for index in dshToolActivities.indices where dshToolActivities[index].sessionId == targetSessionId
            && dshToolActivities[index].turnId == turnId && dshToolActivities[index].phase == "started" {
            let wasAborted = params["status"] as? String == "aborted"
            dshToolActivities[index].phase = wasAborted ? "cancelled" : "failed"
            if dshToolActivities[index].result.isEmpty {
                dshToolActivities[index].result = wasAborted ? "会话已取消，工具执行已中止。" : "工具未返回完成结果。"
            }
        }
        var telemetry = telemetryBySession[targetSessionId] ?? SessionLiveTelemetry()
        if let usage = params["usage"] as? [String: Any] {
            telemetry.inputTokens += usage["inputTokens"] as? Int ?? 0
            telemetry.cacheReadTokens += usage["cacheReadTokens"] as? Int ?? 0
            telemetry.outputTokens += usage["outputTokens"] as? Int ?? 0
        }
        if let dur = params["durationMs"] as? Int, dur > 0 {
            telemetry.modelDurationMs += dur
        } else {
            telemetry.modelDurationMs += max(1, Int(Date().timeIntervalSince(ctx.startedAt) * 1_000))
        }
        if let ttft = ctx.firstTokenMs, ttft > 0 {
            telemetry.ttftSumMs += ttft
            telemetry.ttftSamples += 1
        }
        telemetryBySession[targetSessionId] = telemetry

        // Stamp authoritative SQLite id & sequence onto the user message sent in this turn so rewind/delete always truncate SQLite.
        if let userMeta = params["userMessage"] as? [String: Any],
           let userSeq = userMeta["seq"] as? Int,
           var list = messagesBySession[targetSessionId],
           let lastUserIdx = list.lastIndex(where: { $0.role == "user" && $0.sequence == nil }) {
            let existing = list[lastUserIdx]
            let authId = (userMeta["id"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? existing.id
            let authTs: Date = {
                if let ms = userMeta["timestamp"] as? NSNumber { return Date(timeIntervalSince1970: ms.doubleValue / 1_000) }
                return existing.timestamp
            }()
            list[lastUserIdx] = ChatMessageItem(
                id: authId,
                sessionId: existing.sessionId,
                role: existing.role,
                content: existing.content,
                reasoning: existing.reasoning,
                timestamp: authTs,
                sequence: userSeq
            )
            messagesBySession[targetSessionId] = list
        }

        let isIncomplete = params["status"] as? String != "completed"
        if let persistedRounds = params["assistantMessages"] as? [[String: Any]], !persistedRounds.isEmpty {
            var appendedAny = false
            for round in persistedRounds {
                let text = round["content"] as? String ?? ""
                let think = round["reasoning"] as? String ?? ""
                guard !text.isEmpty || !think.isEmpty else { continue }
                let msgId = (round["id"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? UUID().uuidString
                let seq = round["seq"] as? Int
                let ts: Date = {
                    if let ms = round["timestamp"] as? NSNumber { return Date(timeIntervalSince1970: ms.doubleValue / 1_000) }
                    return Date()
                }()
                var item = ChatMessageItem(id: msgId, sessionId: targetSessionId, role: "assistant", content: text, reasoning: think, timestamp: ts, sequence: seq)
                item.incomplete = isIncomplete
                if let existingIdx = messagesBySession[targetSessionId]?.firstIndex(where: { $0.id == msgId }) {
                    messagesBySession[targetSessionId]?[existingIdx] = item
                } else {
                    messagesBySession[targetSessionId, default: []].append(item)
                }
                appendedAny = true
            }
            if appendedAny { persistWorkspace() }
        } else {
            let authoritativeContent = (params["finalContent"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let authoritativeReasoning = (params["finalReasoning"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let finalText: String
            if !authoritativeContent.isEmpty && (ctx.streamState.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || authoritativeContent.count > ctx.streamState.content.count) {
                finalText = authoritativeContent
            } else {
                finalText = ctx.streamState.content
            }
            let finalThink: String
            if !authoritativeReasoning.isEmpty && (ctx.streamState.reasoning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || authoritativeReasoning.count > ctx.streamState.reasoning.count) {
                finalThink = authoritativeReasoning
            } else {
                finalThink = ctx.streamState.reasoning
            }
            if !finalText.isEmpty || !finalThink.isEmpty {
                var item = ChatMessageItem(sessionId: targetSessionId, role: "assistant", content: finalText, reasoning: finalThink)
                item.incomplete = isIncomplete
                if let transcript = params["transcript"],
                   let bytes = try? JSONSerialization.data(withJSONObject: transcript) {
                    item.transcript = try? JSONDecoder().decode([ProviderMessage].self, from: bytes)
                    item.providerProfile = params["profile"] as? String
                }
                messagesBySession[targetSessionId, default: []].append(item)
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
        ctx.groupLeaseWatchdogTask?.cancel()
        ctx.groupLeaseWatchdogTask = nil
        ctx.stallWatchdogTask?.cancel()
        ctx.stallWatchdogTask = nil
        ctx.streamState.reset()
        activeTurnsBySession.removeValue(forKey: targetSessionId)
        pendingApprovals.removeAll { $0.turnId == turnId }
        pendingDSHQuestions.removeAll { $0.turnId == turnId }
        syncActiveStreamMirrors()
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
                if method == "session.changed" {
                    if let changedId = params["sessionId"] as? String,
                       !changedId.isEmpty,
                       !self.isSessionStreaming(changedId) {
                        self.loadedHistoryIDs.remove(changedId)
                        self.messagesBySession[changedId] = nil
                        if self.visibleChatSessionId == changedId {
                            Task { @MainActor [weak self] in
                                try? await self?.loadSessionHistory(changedId)
                            }
                        }
                    }
                    continue
                }
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
                    if let sId = params["sessionId"] as? String {
                        self.activeTurnsBySession[sId]?.lastActivityAt = Date()
                    }
                    self.handleNativeApprovalNotification(method: method, params: params)
                    continue
                }
                if method.hasPrefix("user-question.") {
                    if let sId = params["sessionId"] as? String {
                        self.activeTurnsBySession[sId]?.lastActivityAt = Date()
                    }
                    self.handleDSHQuestionNotification(method: method, params: params)
                    continue
                }
                if method == "dsh.tool.event" {
                    if let sId = params["sessionId"] as? String {
                        self.activeTurnsBySession[sId]?.lastActivityAt = Date()
                    }
                    self.handleDSHToolNotification(params)
                    continue
                }
                if method == "dsh.approval.event" {
                    if let sId = params["sessionId"] as? String {
                        self.activeTurnsBySession[sId]?.lastActivityAt = Date()
                    }
                    self.handleDSHApprovalAuditNotification(params)
                    continue
                }
                guard let sessionId = params["sessionId"] as? String,
                      let turnId = params["turnId"] as? String,
                      let ctx = self.activeTurnsBySession[sessionId],
                      ctx.turnId == turnId else { continue }
                switch method {
                case "chat.delta":
                    guard !ctx.sentCancellation else { continue }
                    ctx.lastActivityAt = Date()
                    if ctx.firstTokenMs == nil {
                        let ttft = max(1, Int(Date().timeIntervalSince(ctx.startedAt) * 1_000))
                        ctx.firstTokenMs = ttft
                        self.streamFirstTokenMs = ttft
                        ctx.streamState.firstTokenMs = ttft
                    }
                    ctx.pendingReasoningBuffer += params["reasoning"] as? String ?? ""
                    ctx.pendingContentBuffer += params["content"] as? String ?? ""
                    self.scheduleStreamFlushIfNeeded(for: sessionId)
                case "chat.done":
                    if let err = params["error"] as? String {
                        self.lastErrorSessionId = sessionId
                        self.lastStreamError = err
                    }
                    if params["status"] as? String == "aborted" { self.lastCancelledSessionId = sessionId }
                    self.finishTurn(for: sessionId, params: params)
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
              let sessionId = params["sessionId"] as? String,
              let turnId = params["turnId"] as? String,
              let ctx = activeTurnsBySession[sessionId],
              ctx.turnId == turnId, !ctx.sentCancellation,
              let id = params["approvalId"] as? String,
              let tool = params["tool"] as? String,
              let summary = params["summary"] as? String else { return }

        let rootBotId = resolveAddress(sessionId)?.botID ?? sessionId
        let botMode = bots.first(where: { $0.id == rootBotId })?.permissionMode ?? "ask"
        let lowerTool = tool.lowercased()
        let isWriteOrMutate = lowerTool.contains("write") || lowerTool.contains("edit") || lowerTool.contains("patch")
            || lowerTool.contains("delete") || lowerTool.contains("memory") || lowerTool == "terminal_exec"
            || lowerTool == "python_exec" || lowerTool == "run_code" || lowerTool == "python_job_start"
            || lowerTool == "web_fetch" || lowerTool == "web_search" || lowerTool.hasPrefix("remote_mcp")
            || lowerTool.hasPrefix("redteam_") || lowerTool.hasPrefix("browser_")

        let approval = PendingApproval(id: id, sessionId: sessionId, turnId: turnId, tool: tool, summary: summary, isDSH: params["source"] as? String == "dsh")
        pendingApprovals.append(approval)
        ctx.streamState.phase = .awaitingApproval(tool)

        if botMode == "readOnly" && isWriteOrMutate {
            autoReviewLog.insert("[\(Date().formatted(date: .omitted, time: .shortened))] 只读保护拦截：\(tool)", at: 0)
            if autoReviewLog.count > 40 { autoReviewLog = Array(autoReviewLog.prefix(40)) }
            Task { await respondToApproval(id: id, approved: false) }
            return
        }

        if botMode == "autoReview" {
            autoReviewLog.insert("[\(Date().formatted(date: .omitted, time: .shortened))] 沙盒免打扰放行：\(tool)", at: 0)
            if autoReviewLog.count > 40 { autoReviewLog = Array(autoReviewLog.prefix(40)) }
            Task { await respondToApproval(id: id, approved: true) }
            return
        }

        if autoReviewEnabled && !isWriteOrMutate {
            autoReviewLog.insert("[\(Date().formatted(date: .omitted, time: .shortened))] 只读自动审查放行：\(tool)", at: 0)
            if autoReviewLog.count > 40 { autoReviewLog = Array(autoReviewLog.prefix(40)) }
            Task { await respondToApproval(id: id, approved: true) }
            return
        }
    }

    public func approveAndSwitchToAutoReview(id: String) async {
        if let approval = pendingApprovals.first(where: { $0.id == id }) {
            let rootBotId = resolveAddress(approval.sessionId)?.botID ?? approval.sessionId
            if let index = bots.firstIndex(where: { $0.id == rootBotId }) {
                bots[index].permissionMode = "autoReview"
                persistWorkspace()
            }
        }
        await respondToApproval(id: id, approved: true)
    }

    private func handleDSHQuestionNotification(method: String, params: [String: Any]) {
        if method == "user-question.closed" {
            pendingDSHQuestions.removeAll { $0.id == params["questionId"] as? String }
            return
        }
        guard method == "user-question.request",
              let sessionId = params["sessionId"] as? String,
              let turnId = params["turnId"] as? String,
              let ctx = activeTurnsBySession[sessionId],
              ctx.turnId == turnId, !ctx.sentCancellation,
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
        guard let sessionId = params["sessionId"] as? String,
              let turnId = params["turnId"] as? String,
              let ctx = activeTurnsBySession[sessionId],
              ctx.turnId == turnId, !ctx.sentCancellation,
              let callId = params["callId"] as? String, !callId.isEmpty else { return }
        let phase = params["phase"] as? String ?? "started"
        let toolName = params["toolName"] as? String ?? "DSH tool"
        if phase == "started" {
            ctx.streamState.phase = .toolRunning(toolName)
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
              let turnId = params["turnId"] as? String,
              let ctx = activeTurnsBySession[sessionId],
              ctx.turnId == turnId,
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

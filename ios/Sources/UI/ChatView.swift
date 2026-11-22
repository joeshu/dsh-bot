import SwiftUI
import UniformTypeIdentifiers
#if canImport(PhotosUI)
import PhotosUI
#endif
#if canImport(UIKit)
import UIKit
#endif

private enum ChatTranscriptRow: Identifiable {
    case message(ChatMessageItem)
    case tool(DSHToolActivity)
    case toolBurst([DSHToolActivity])
    case approval(DSHApprovalAudit)

    var id: String {
        switch self {
        case .message(let message): return "message-\(message.id)"
        case .tool(let activity): return "tool-\(activity.id)"
        case .toolBurst(let items): return "toolburst-\(items.first?.id ?? UUID().uuidString)"
        case .approval(let audit): return "approval-\(audit.id)"
        }
    }

    var timestamp: Date {
        switch self {
        case .message(let message): return message.timestamp
        case .tool(let activity): return activity.timestamp
        case .toolBurst(let items): return items.first?.timestamp ?? .distantPast
        case .approval(let audit): return audit.timestamp
        }
    }

    var sequence: Int? {
        switch self {
        case .message(let message): return message.sequence
        case .tool(let activity): return activity.sequence
        case .toolBurst(let items): return items.first?.sequence
        case .approval(let audit): return audit.sequence
        }
    }
}

private enum ChatActiveSheet: Identifiable {
    case botProfile
    case sideChat
    case groupWorkspace
    case memory
    case workspaceFiles
    case editBot
    case diagnostics
    case scheduleManager
    case jobsManager
    case referenceChatPicker
    case history(SessionHistoryPresentation)

    var id: String {
        switch self {
        case .botProfile: return "botProfile"
        case .sideChat: return "sideChat"
        case .groupWorkspace: return "groupWorkspace"
        case .memory: return "memory"
        case .workspaceFiles: return "workspaceFiles"
        case .editBot: return "editBot"
        case .diagnostics: return "diagnostics"
        case .scheduleManager: return "scheduleManager"
        case .jobsManager: return "jobsManager"
        case .referenceChatPicker: return "referenceChatPicker"
        case .history(let presentation): return "history-\(presentation.id)"
        }
    }
}

public struct ChatView: View {
    let bot: BotProfile
    @ObservedObject var host: LocalAgentHost
    private let searchResultMessageID: String?
    @State private var input = ""
    @State private var selectedModel: String
    @State private var activeSectionTitle = ""
    @State private var isPrivateUnlocked = false
    @State private var historyError: String?
    @State private var restoringOlderHistory = false
    @State private var followsLiveOutput = true
    @State private var showClearConfirm = false
    @State private var showFileImporter = false
    @State private var activeSheet: ChatActiveSheet?
    @State private var referencedBot: BotProfile?
    @State private var attachedFiles: [LocalAgentHost.AttachedWorkspaceFile] = []
    #if canImport(PhotosUI)
    @State private var selectedPhotoItems: [PhotosPickerItem] = []
    #endif
    @StateObject private var speechInput = SpeechInputController()
    @State private var actionStatus = ""
    @State private var lastScrollAt = Date.distantPast
    @State private var expandStreamingReasoning = true
    @State private var pendingSearchMessageID: String?
    @Environment(\.scenePhase) private var chatScenePhase

    @MainActor
    public init(bot: BotProfile, host: LocalAgentHost, targetMessageID: String? = nil) {
        self.bot = bot
        self.host = host
        self.searchResultMessageID = targetMessageID
        _pendingSearchMessageID = State(initialValue: targetMessageID)
        _selectedModel = State(initialValue: host.modelSelection(bot.model))
        _expandStreamingReasoning = State(initialValue: !host.collapseThinkingByDefault)
    }

    private var liveBot: BotProfile {
        host.bots.first(where: { $0.id == bot.id }) ?? bot
    }

    private func redteamPresetAllowed(for profile: BotProfile) -> Bool {
        !profile.isPrivate && host.redteamStatus.installed
    }

    private func redteamDisabledHint(for profile: BotProfile) -> String {
        if profile.isPrivate { return "私密会话不可用" }
        if !host.redteamStatus.installed { return "未安装 dsh-purge-safe" }
        return "不可用"
    }

    private var isLocked: Bool { liveBot.isPrivate && !isPrivateUnlocked }

    private var sessionMessages: [ChatMessageItem] {
        isLocked ? [] : host.messages(for: liveBot.id)
    }

    private var transcriptRows: [ChatTranscriptRow] {
        let messages = sessionMessages.map(ChatTranscriptRow.message)
        let activities = (isLocked ? [] : host.dshToolActivities.filter { $0.sessionId == liveBot.id })
            .map(ChatTranscriptRow.tool)
        let approvalAudits = (isLocked ? [] : host.dshApprovalAudits.filter { $0.sessionId == liveBot.id })
            .map(ChatTranscriptRow.approval)
        let sorted = (messages + activities + approvalAudits).sorted { left, right in
            if left.timestamp != right.timestamp { return left.timestamp < right.timestamp }
            if let leftSequence = left.sequence, let rightSequence = right.sequence, leftSequence != rightSequence {
                return leftSequence < rightSequence
            }
            if left.sequence != nil && right.sequence == nil { return true }
            if left.sequence == nil && right.sequence != nil { return false }
            return left.id < right.id
        }
        var grouped: [ChatTranscriptRow] = []
        var pendingTools: [DSHToolActivity] = []
        func flushPendingTools() {
            guard !pendingTools.isEmpty else { return }
            if pendingTools.count == 1 {
                grouped.append(.tool(pendingTools[0]))
            } else {
                grouped.append(.toolBurst(pendingTools))
            }
            pendingTools.removeAll(keepingCapacity: true)
        }
        for row in sorted {
            if case .tool(let activity) = row {
                if let prev = pendingTools.last, prev.turnId != activity.turnId {
                    flushPendingTools()
                }
                pendingTools.append(activity)
            } else {
                flushPendingTools()
                grouped.append(row)
            }
        }
        flushPendingTools()
        return grouped
    }

    private var latestHeadings: [MarkdownHeading] {
        guard !host.isStreaming else { return [] }
        let candidate = sessionMessages.last(where: { $0.role == "assistant" })?.content ?? ""
        return MarkdownOutlineParser.extractHeadings(from: candidate)
    }

    public var body: some View {
        Group {
            if isLocked {
                PrivateBotLockOverlay(botName: liveBot.name) { isPrivateUnlocked = true }
            } else {
                conversation
            }
        }
        .task(id: isLocked) {
            if !isLocked { await loadHistory() }
        }
        .navigationTitle(liveBot.name)
        .onChange(of: liveBot.model) { selectedModel = host.modelSelection($0) }
        .onChange(of: selectedModel) { nextModel in
            host.setBotModel(sessionId: liveBot.id, model: nextModel)
        }
        .onChange(of: host.apiBaseURL) { _ in selectedModel = host.modelSelection(liveBot.model) }
        .onAppear {
            host.visibleChatSessionId = liveBot.id
        }
        .onDisappear {
            if host.visibleChatSessionId == liveBot.id { host.visibleChatSessionId = nil }
            if liveBot.isPrivate { lockPrivateConversation() }
        }
        .onChange(of: chatScenePhase) { phase in
            if phase == .background && liveBot.isPrivate { lockPrivateConversation() }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            if !isLocked {
                ToolbarItem(placement: .principal) {
                    Button {
                        activeSheet = .botProfile
                    } label: {
                        VStack(spacing: 1) {
                            HStack(spacing: 4) {
                                Text(liveBot.name)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                if liveBot.isPrivate {
                                    Image(systemName: "lock.fill")
                                        .font(.caption2)
                                        .foregroundStyle(DSTheme.warning)
                                }
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundStyle(.tertiary)
                            }
                            Text("\(host.agentPresetName(liveBot.agentPreset)) · \(selectedModel) · \(liveBot.permissionModeLabel)")
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .buttonStyle(.plain)
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    // Menu 1: Live Strategy (Mode, Approval Tier, Model, RedTeam Permissions)
                    Menu {
                        Section("实时模式与审批（热切换）") {
                            Picker(host.agentPresetName(liveBot.agentPreset), selection: Binding(
                                get: { liveBot.agentPreset },
                                set: { nextPreset in
                                    if nextPreset == "redteam" && redteamPresetAllowed(for: liveBot) {
                                        if !host.redteamModeEnabled {
                                            host.setRedteamMode(true)
                                        }
                                        if !liveBot.redteamToolsEnabled {
                                            host.setRedteamPermissions(sessionId: liveBot.id, toolsEnabled: true)
                                        }
                                        host.setAgentPreset(sessionId: liveBot.id, presetId: nextPreset)
                                        actionStatus = "已开启红队宿主并切换至红队模式"
                                    } else {
                                        host.setAgentPreset(sessionId: liveBot.id, presetId: nextPreset)
                                    }
                                }
                            )) {
                                ForEach(host.dshAgentPresets) { preset in
                                    let allowed = preset.isAvailable && (preset.id != "redteam" || redteamPresetAllowed(for: liveBot))
                                    let label: String = {
                                        if allowed { return preset.name }
                                        if preset.id == "redteam" { return "\(preset.name)（\(redteamDisabledHint(for: liveBot))）" }
                                        return "\(preset.name)（不可用）"
                                    }()
                                    Text(label)
                                        .tag(preset.id)
                                        .disabled(!allowed)
                                }
                                if !host.dshAgentPresets.contains(where: { $0.id == liveBot.agentPreset }) {
                                    Text(host.agentPresetName(liveBot.agentPreset)).tag(liveBot.agentPreset)
                                }
                            }
                            .disabled(host.isStreaming)
                            Picker("审批档位：\(liveBot.permissionModeLabel)", selection: Binding(
                                get: { liveBot.permissionMode },
                                set: { host.setPermissionMode(sessionId: liveBot.id, mode: $0) }
                            )) {
                                Text("只读保护").tag("readOnly")
                                Text("标准审批").tag("ask")
                                Text("沙盒免打扰").tag("autoReview")
                            }
                            .disabled(host.isStreaming)
                        }
                        if host.usesOfficialModels || !host.models.isEmpty {
                            ModelSelectionView(host: host, model: $selectedModel, allowsTyping: false)
                        }
                        if host.redteamStatus.installed {
                            Section("dsh-purge-safe 会话授权") {
                                Toggle("允许本 Bot 调用红队工具", isOn: Binding(
                                    get: { liveBot.redteamToolsEnabled },
                                    set: { host.setRedteamPermissions(sessionId: liveBot.id, toolsEnabled: $0) }
                                ))
                                Toggle("允许写入红队演练台", isOn: Binding(
                                    get: { liveBot.redteamWriteEnabled },
                                    set: { host.setRedteamPermissions(sessionId: liveBot.id, writeEnabled: $0) }
                                ))
                                .disabled(!liveBot.redteamToolsEnabled)
                                Toggle("允许敏感工具（凭据 / 入口 / WebShell / 隧道 / PoC / 探测 / 清理）", isOn: Binding(
                                    get: { liveBot.redteamSensitiveDataEnabled },
                                    set: { host.setRedteamPermissions(sessionId: liveBot.id, sensitiveDataEnabled: $0) }
                                ))
                                .disabled(!liveBot.redteamToolsEnabled)
                                if liveBot.isPrivate {
                                    Text("私密会话始终禁止调用红队工具。")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                } else if !host.redteamModeEnabled {
                                    Text("请先在“设置 → 插件与红队宿主”启用全局宿主。")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                } else {
                                    Text("审批档位：\(liveBot.permissionModeLabel)。只读保护拦截写入与敏感工具；标准审批逐次确认；沙盒免打扰自动放行已授权工具并记录审计日志。")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .disabled(liveBot.isPrivate || !host.redteamModeEnabled || host.isStreaming)
                        }
                        Section {
                            Button {
                                activeSheet = .editBot
                            } label: {
                                Label("编辑智能体人设与高级配置", systemImage: "person.crop.circle.badge.exclamationmark")
                            }
                        }
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                    }
                    .help("模式、模型与审批策略")

                    // Menu 2: Session Quick Actions (non-overlapping with BotProfileSheet)
                    Menu {
                        Section("会话快捷操作") {
                            Button {
                                activeSheet = .sideChat
                            } label: {
                                Label("侧边旁路对话 (/side)", systemImage: "bubble.left.and.exclamationmark.bubble.right")
                            }
                            Button {
                                Task { await host.sendMessage(sessionId: liveBot.id, text: "/compact", model: selectedModel) }
                            } label: {
                                Label("压缩当前上下文 (/compact)", systemImage: "arrow.down.right.and.arrow.up.left")
                            }
                            .disabled(host.isStreaming || sessionMessages.isEmpty)
                            Button {
                                activeSheet = .workspaceFiles
                            } label: {
                                Label("工作区文件 (files/)", systemImage: "folder.fill")
                            }
                            if liveBot.isGroup {
                                Button {
                                    activeSheet = .groupWorkspace
                                } label: {
                                    Label("群目标与共享待办 (/goal)", systemImage: "checklist")
                                }
                            }
                        }
                        Section("档案、诊断与记录") {
                            Button {
                                activeSheet = .botProfile
                            } label: {
                                Label("打开 5-Tab 智能体档案", systemImage: "person.text.rectangle")
                            }
                            Button {
                                activeSheet = .diagnostics
                            } label: {
                                Label("会话数据诊断", systemImage: "doc.text.magnifyingglass")
                            }
                            Button {
                                activeSheet = .history(.export)
                            } label: {
                                Label("导出会话为 Markdown", systemImage: "square.and.arrow.up")
                            }
                            .disabled(host.streamingSessionId == bot.id)
                            if liveBot.isPrivate {
                                Button {
                                    lockPrivateConversation()
                                } label: {
                                    Label("立即锁定私密会话", systemImage: "lock.fill")
                                }
                            }
                            Button(role: .destructive) {
                                showClearConfirm = true
                            } label: {
                                Label("清空当前会话", systemImage: "trash")
                            }
                            .disabled(host.isStreaming)
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .help("会话快捷操作")
                }
            }
        }
        .sheet(item: $activeSheet) { sheet in
            if !isLocked {
                sheetContent(for: sheet)
            }
        }
        .confirmationDialog("确定清空「\(liveBot.name)」的全部聊天记录？", isPresented: $showClearConfirm, titleVisibility: .visible) {
            Button("清空记录", role: .destructive) {
                guard !isLocked, !host.isStreaming else { return }
                Task {
                    await host.clearSession(bot.id)
                    DSHaptics.notify(.warning)
                }
            }
            Button("取消", role: .cancel) {}
        }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.item, .data, .content],
            allowsMultipleSelection: true
        ) { result in
            guard !liveBot.isPrivate else { return }
            switch result {
            case .success(let urls):
                var addedCount = 0
                var lastError: String?
                for url in urls.prefix(10) {
                    do {
                        let imported = try host.importFileToWorkspace(from: url)
                        if !attachedFiles.contains(where: { $0.relativePath == imported.relativePath }) {
                            attachedFiles.append(imported)
                        }
                        addedCount += 1
                    } catch {
                        lastError = error.localizedDescription
                    }
                }
                if addedCount > 0 {
                    actionStatus = addedCount == 1
                        ? "已附加：files/\(attachedFiles.last?.relativePath ?? "")"
                        : "已附加 \(addedCount) 个文件到工作区"
                    DSHaptics.notify(.success)
                } else if let lastError {
                    actionStatus = "附加失败：\(lastError)"
                    DSHaptics.notify(.error)
                }
            case .failure(let error):
                actionStatus = "附加失败：\(error.localizedDescription)"
                DSHaptics.notify(.error)
            }
        }
        #if canImport(PhotosUI)
        .onChange(of: selectedPhotoItems) { items in
            guard !items.isEmpty, !liveBot.isPrivate else { return }
            let picked = items
            selectedPhotoItems = []
            Task {
                var added = 0
                var lastError: String?
                for (idx, item) in picked.prefix(5).enumerated() {
                    do {
                        if let rawData = try await item.loadTransferable(type: Data.self) {
                            let stamp = Int(Date().timeIntervalSince1970)
                            let name = "photo_\(stamp)_\(idx + 1).jpg"
                            let imported = try host.importRawDataToWorkspace(rawData, suggestedName: name)
                            await MainActor.run {
                                attachedFiles.append(imported)
                            }
                            added += 1
                        }
                    } catch {
                        lastError = error.localizedDescription
                    }
                }
                await MainActor.run {
                    if added > 0 {
                        actionStatus = added == 1
                            ? "已附加图片：files/\(attachedFiles.last?.relativePath ?? "")"
                            : "已附加 \(added) 张图片到工作区"
                        DSHaptics.notify(.success)
                    } else if let lastError {
                        actionStatus = "图片附加失败：\(lastError)"
                        DSHaptics.notify(.error)
                    }
                }
            }
        }
        #endif
    }

    @ViewBuilder
    private func sheetContent(for sheet: ChatActiveSheet) -> some View {
        switch sheet {
        case .history(let presentation):
            SessionHistoryDetailView(host: host, bot: liveBot, presentation: presentation)
        case .sideChat:
            SideChatSheet(host: host, model: selectedModel, botId: liveBot.id,
                          botName: liveBot.name, isPrivate: liveBot.isPrivate)
        case .groupWorkspace:
            GroupWorkspaceSheet(host: host, groupId: bot.id)
        case .memory:
            NavigationStack { MemoryVaultView(host: host, botId: liveBot.id) }
        case .workspaceFiles:
            NavigationStack {
                WorkspaceFilesView(host: host)
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button("关闭") { activeSheet = nil }
                        }
                    }
            }
        case .editBot:
            EditBotSheet(bot: liveBot, host: host)
        case .botProfile:
            BotProfileSheet(bot: liveBot, host: host)
        case .diagnostics:
            SessionDiagnosticsSheet(host: host, bot: liveBot)
        case .scheduleManager:
            NavigationStack { ScheduleManagerView(host: host, botId: liveBot.id) }
        case .jobsManager:
            NavigationStack { JobsManagerView(host: host, botId: liveBot.id) }
        case .referenceChatPicker:
            NavigationStack {
                List {
                    let candidates = host.bots.filter { $0.id != liveBot.id && !$0.isPrivate }
                    if candidates.isEmpty {
                        DSEmptyStateView(
                            icon: "quote.bubble",
                            title: "暂无可引用的其他会话",
                            subtitle: "非私密的活跃智能体会话将显示在这里。"
                        )
                        .listRowBackground(Color.clear)
                    } else {
                        ForEach(candidates) { candidate in
                            Button {
                                referencedBot = candidate
                                activeSheet = nil
                            } label: {
                                HStack(spacing: 12) {
                                    DSBotAvatar(
                                        initials: candidate.name,
                                        color: DSTheme.botAvatarColor(candidate),
                                        isPrivate: false,
                                        size: 36
                                    )
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(candidate.name).font(.subheadline.weight(.semibold))
                                        Text("\(host.messages(for: candidate.id).count) 条消息 · \(candidate.roleLabel)")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }
                .navigationTitle("引用历史对话")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("取消") { activeSheet = nil }
                    }
                }
            }
        }
    }

    private func loadHistory(older: Bool = false) async {
        guard !isLocked else { return }
        historyError = nil
        restoringOlderHistory = older
        let previousCount = sessionMessages.count
        defer { if previousCount == sessionMessages.count { restoringOlderHistory = false } }
        do {
            try await host.loadSessionHistory(bot.id, older: older)
        } catch is CancellationError {
            return
        } catch {
            if !isLocked { historyError = "无法读取会话记录。请重试。" }
        }
    }

    private func lockPrivateConversation() {
        isPrivateUnlocked = false
        host.discardSessionHistoryCache(bot.id)
        historyError = nil
        activeSheet = nil
        showFileImporter = false
        attachedFiles.removeAll()
        speechInput.stop()
        showClearConfirm = false
        actionStatus = ""
        Task { _ = try? await host.rpc()?.request("device.stopSpeaking") }
        if host.streamingSessionId == bot.id { Task { await host.abortActiveTurn() } }
    }

    private var conversation: some View {
        ScrollViewReader { proxy in
            ZStack(alignment: .top) {
                VStack(spacing: 0) {
                    if host.isStreaming,
                       let activeId = host.streamingSessionId,
                       activeId != liveBot.id,
                       let activeBot = host.bots.first(where: { $0.id == activeId }) {
                        HStack(spacing: 8) {
                            ProgressView().scaleEffect(0.7)
                            Text("「\(activeBot.name)」正在后台流式生成中")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Spacer()
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(DSTheme.brand.opacity(0.08))
                    }
                    ZStack(alignment: .bottomTrailing) {
                        conversationScrollView(proxy: proxy)
                        if !followsLiveOutput && (!sessionMessages.isEmpty || (host.isStreaming && host.streamingSessionId == bot.id)) {
                            Button {
                                followsLiveOutput = true
                                withAnimation(.easeOut(duration: 0.2)) {
                                    proxy.scrollTo("chat_bottom", anchor: .bottom)
                                }
                            } label: {
                                HStack(spacing: 6) {
                                    if host.isStreaming && host.streamingSessionId == bot.id {
                                        Circle()
                                            .fill(DSTheme.brand)
                                            .frame(width: 7, height: 7)
                                    }
                                    Image(systemName: "arrow.down")
                                        .font(.caption.weight(.bold))
                                    Text(host.isStreaming && host.streamingSessionId == bot.id ? "回到最新输出" : "回到底部")
                                        .font(.caption.weight(.semibold))
                                }
                                .foregroundStyle(.primary)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(.ultraThinMaterial)
                                .clipShape(Capsule())
                                .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
                            }
                            .padding(.trailing, 14)
                            .padding(.bottom, 12)
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                        }
                    }
                    conversationFooterNotices
                    composerBar
                }
                conversationReadingPill(proxy: proxy)
            }
        }
    }

    private func conversationScrollView(proxy: ScrollViewProxy) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                Color.clear.frame(height: 1).id("chat_top")
                conversationHeaderSection
                conversationTranscriptSection(proxy: proxy)
                conversationPendingSection
                Color.clear.frame(height: 1).id("chat_bottom")
                    .onAppear { followsLiveOutput = true }
                    .onDisappear { followsLiveOutput = false }
            }
            .padding()
        }
        .scrollDismissesKeyboard(.interactively)
        .onAppear {
            scrollToSearchResult(using: proxy)
        }
        .onChange(of: sessionMessages.count) { _ in
            if restoringOlderHistory {
                restoringOlderHistory = false
                return
            }
            if !scrollToSearchResult(using: proxy) {
                withAnimation { proxy.scrollTo("chat_bottom", anchor: .bottom) }
            }
        }
        .onChange(of: host.pendingApprovals.count) { _ in
            withAnimation { proxy.scrollTo("chat_bottom", anchor: .bottom) }
        }
        .onChange(of: host.pendingDSHQuestions.count) { _ in
            withAnimation { proxy.scrollTo("chat_bottom", anchor: .bottom) }
        }
        .onChange(of: host.dshToolActivities.count) { _ in
            guard followsLiveOutput else { return }
            withAnimation { proxy.scrollTo("chat_bottom", anchor: .bottom) }
        }
        .onChange(of: host.dshApprovalAudits.count) { _ in
            guard followsLiveOutput else { return }
            withAnimation { proxy.scrollTo("chat_bottom", anchor: .bottom) }
        }
        .onDisappear {
            speechInput.stop()
        }
    }

    private func scrollToBottomIfFollowing(proxy: ScrollViewProxy) {
        guard followsLiveOutput, host.streamingSessionId == bot.id else { return }
        let now = Date()
        if now.timeIntervalSince(lastScrollAt) >= 0.12 {
            lastScrollAt = now
            proxy.scrollTo("chat_bottom", anchor: .bottom)
        }
    }

    @ViewBuilder
    private var conversationHeaderSection: some View {
        if bot.isPrivate {
            DSBannerCard(
                icon: "lock.shield.fill",
                tint: DSTheme.warning,
                message: "私密会话保存在本机并受 Web API / 导出全链路隔离。发送消息后，当前上下文会发给设置中选定的模型服务。"
            )
        }

        if host.loadingHistoryIDs.contains(bot.id) {
            HStack {
                Spacer()
                ProgressView("正在读取持久记录…")
                    .font(.caption)
                Spacer()
            }
            .padding(.vertical, 6)
        } else if let historyError {
            DSBannerCard(
                icon: "exclamationmark.circle.fill",
                tint: DSTheme.warning,
                message: historyError,
                actionTitle: "重试"
            ) {
                Task { await loadHistory(older: host.hasOlderHistory(bot.id)) }
            }
        } else if host.hasOlderHistory(bot.id) {
            HStack {
                Spacer()
                Button {
                    Task { await loadHistory(older: true) }
                } label: {
                    Label("加载更早记录", systemImage: "clock.arrow.circlepath")
                        .font(.caption.weight(.medium))
                }
                .buttonStyle(.bordered)
                Spacer()
            }
        }

        if sessionMessages.isEmpty && !host.hasSessionHistory(bot.id)
            && !host.loadingHistoryIDs.contains(bot.id) && !host.isStreaming {
            emptyWelcomeView
        }
    }

    @ViewBuilder
    private func conversationTranscriptSection(proxy: ScrollViewProxy) -> some View {
        ForEach(transcriptRows) { row in
            switch row {
            case .message(let msg):
                messageRow(msg).id(msg.id)
            case .tool(let activity):
                DSHToolActivityCard(activity: activity) {
                    activeSheet = .history(.tool(activity))
                }
                .id(activity.id)
            case .toolBurst(let burst):
                DSHToolBurstCard(activities: burst) { activity in
                    activeSheet = .history(.tool(activity))
                }
                .id(row.id)
            case .approval(let audit):
                DSHApprovalAuditCard(audit: audit).id(audit.id)
            }
        }

        if host.isStreaming && host.streamingSessionId == bot.id {
            StreamingTurnRow(
                botName: liveBot.name,
                liveStream: host.liveStream,
                collapseThinkingByDefault: host.collapseThinkingByDefault
            ) {
                scrollToBottomIfFollowing(proxy: proxy)
            }
        }
    }

    @ViewBuilder
    private var conversationPendingSection: some View {
        ForEach(host.pendingApprovals.filter { $0.sessionId == bot.id }) { approval in
            DSHPendingApprovalCard(
                approval: approval,
                onRespond: { approved in
                    Task { await host.respondToApproval(id: approval.id, approved: approved) }
                },
                onApproveAndTrustSandbox: {
                    Task { await host.approveAndSwitchToAutoReview(id: approval.id) }
                }
            )
        }

        ForEach(host.pendingDSHQuestions.filter { $0.sessionId == bot.id }) { request in
            DSHUserQuestionCard(request: request) { answers in
                Task { await host.respondToDSHQuestion(id: request.id, answers: answers) }
            }
        }

        if host.smartActionCardsEnabled,
           !host.isStreaming,
           let lastAssistant = sessionMessages.last(where: { $0.role == "assistant" }),
           !lastAssistant.content.isEmpty {
            smartActionCardsBar(for: lastAssistant)
        }
    }

    @ViewBuilder
    private var conversationFooterNotices: some View {
        if let budgetWarn = CostBudgetGovernor.shared.activeBudgetWarning {
            DSBannerCard(
                icon: "dollarsign.circle.fill",
                tint: DSTheme.warning,
                message: budgetWarn,
                actionTitle: "知道了"
            ) {
                CostBudgetGovernor.shared.activeBudgetWarning = nil
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 6)
        }
        if host.lastErrorSessionId == bot.id, let errMsg = host.lastStreamError, !host.isStreaming {
            DSBannerCard(
                icon: "exclamationmark.triangle.fill",
                tint: DSTheme.danger,
                message: errMsg,
                actionTitle: "重试"
            ) {
                Task { await host.regenerateLastReply(sessionId: liveBot.id, model: selectedModel) }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 6)
        }

        if !host.isStreaming, host.lastCancelledSessionId == bot.id {
            HStack(spacing: 6) {
                Image(systemName: "stop.circle")
                    .font(.caption2)
                Text("已停止生成")
                    .font(.caption)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(DSTheme.surfaceSecondary.opacity(0.9))
            .clipShape(Capsule())
            .padding(.top, 6)
            .padding(.bottom, 6)
        }
        if !actionStatus.isEmpty {
            HStack(spacing: 6) {
                Text(actionStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Button {
                    actionStatus = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(DSTheme.surfaceSecondary.opacity(0.9))
            .clipShape(Capsule())
            .padding(.horizontal, 12)
            .padding(.top, 4)
            .padding(.bottom, 6)
        }
    }

    @ViewBuilder
    private func conversationReadingPill(proxy: ScrollViewProxy) -> some View {
        if latestHeadings.count >= 2 {
            LongReplyReadingPill(
                currentSection: activeSectionTitle.isEmpty ? (latestHeadings.first?.title ?? "章节导航") : activeSectionTitle,
                headings: latestHeadings,
                onJumpTop: {
                    withAnimation { proxy.scrollTo("chat_top", anchor: .top) }
                },
                onJumpHeading: { heading in
                    activeSectionTitle = heading.title
                    let targetId = sessionMessages.last(where: { $0.role == "assistant" })?.id ?? "chat_bottom"
                    withAnimation { proxy.scrollTo(targetId, anchor: .top) }
                }
            )
            .padding(.top, 8)
        }
    }

    @discardableResult
    private func scrollToSearchResult(using proxy: ScrollViewProxy) -> Bool {
        guard let messageID = pendingSearchMessageID,
              sessionMessages.contains(where: { $0.id == messageID }) else { return false }
        pendingSearchMessageID = nil
        Task { @MainActor in
            await Task.yield()
            withAnimation(.easeInOut(duration: 0.25)) {
                proxy.scrollTo(messageID, anchor: .center)
            }
        }
        return true
    }

    private var starterPrompts: [String] {
        if bot.isGroup {
            return ["先对齐本次群目标并拆解阶段", "查看当前群待办清单", "@Architect 帮我审查最新架构"]
        } else if bot.isPrivate {
            return ["帮我整理一份私密备忘并存入常驻记忆", "总结这段敏感文本的要点"]
        } else if liveBot.agentPreset == "ptc-python" {
            return ["用离线 Python 与 NumPy 模拟一个蒙特卡洛分布并汇总统计", "分析工作区文件并用 Python 处理数据"]
        } else if liveBot.agentPreset == "cordis" {
            return ["检查当前 DSH 运行时已注册的工具与 Cordis 服务", "帮我在工作区编写一个示例 SKILL.md 并校验格式"]
        } else if liveBot.agentPreset == "redteam" {
            return ["查看当前授权红队演练台的资产与阶段进度", "汇总当前演练发现并生成待复核清单"]
        }
        return ["用端侧 JS 沙盒计算 10 万年化 6% 复利 5 年", "查看当前工作区 files/ 中的文件", "帮我拟一份会议议程"]
    }

    private var emptyWelcomeView: some View {
        VStack(spacing: 12) {
            DSBotAvatar(
                initials: liveBot.name,
                color: DSTheme.botAvatarColor(liveBot),
                isPrivate: liveBot.isPrivate,
                size: 58
            )
            Text(liveBot.name)
                .font(.title3.weight(.semibold))
            Text(liveBot.roleLabel)
                .font(.caption)
                .foregroundColor(.secondary)

            HStack(spacing: 6) {
                DSPresetBadge(presetId: liveBot.agentPreset, label: host.agentPresetName(liveBot.agentPreset))
                DSStatusBadge(liveBot.permissionModeLabel, color: .secondary, icon: "checkmark.shield")
            }

            VStack(spacing: 8) {
                ForEach(starterPrompts, id: \.self) { prompt in
                    Button {
                        Task { await host.sendMessage(sessionId: bot.id, text: prompt, model: selectedModel) }
                    } label: {
                        HStack {
                            Text(prompt)
                                .font(.caption)
                                .foregroundColor(.primary)
                                .multilineTextAlignment(.leading)
                            Spacer()
                            Image(systemName: "arrow.up.right")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(DSTheme.surfaceSecondary)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                }
            }
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    @ViewBuilder
    private func messageRow(_ msg: ChatMessageItem) -> some View {
        let isUser = msg.role == "user"
        VStack(alignment: isUser && host.useBubbleLayout ? .trailing : .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(isUser ? "你" : liveBot.name)
                    .font(.caption2.weight(.semibold))
                    .foregroundColor(.secondary)
                Text(msg.timestamp.formatted(date: .omitted, time: .shortened))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            if msg.incomplete == true {
                HStack(spacing: 8) {
                    DSStatusBadge("回复未完成", color: DSTheme.warning, icon: "exclamationmark.circle")
                    if !isUser && !host.isStreaming && msg.id == sessionMessages.last(where: { $0.role == "assistant" })?.id {
                        Button {
                            Task {
                                await host.sendMessage(
                                    sessionId: bot.id,
                                    text: "请从刚才中断的位置继续完成上面的回答，不要重复已输出的内容。",
                                    model: selectedModel
                                )
                            }
                        } label: {
                            Label("继续生成", systemImage: "play.circle.fill")
                                .font(.caption.weight(.semibold))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                    }
                }
            }

            if !msg.reasoning.isEmpty {
                DisclosureGroup("深度思考过程") {
                    Text(msg.reasoning)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 4)
                }
                .font(.caption.weight(.medium))
                .padding(10)
                .background(DSTheme.surfaceSecondary)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }

            if msg.historyPreview == true {
                Button {
                    activeSheet = .history(.message(msg))
                } label: {
                    Label("查看完整消息", systemImage: "arrow.up.left.and.arrow.down.right")
                        .font(.caption)
                }
            }

            DSMarkdownText(msg.content)
                .contextMenu {
                    Button {
                        #if canImport(UIKit)
                        UIPasteboard.general.string = msg.content
                        #endif
                        DSHaptics.impact(.light)
                    } label: {
                        Label(msg.historyPreview == true ? "复制预览" : "复制全文", systemImage: "doc.on.doc")
                    }
                    Button {
                        Task {
                            do {
                                guard let rpc = host.rpc() else { throw IPCFrameError.channelClosed }
                                _ = try await rpc.request("device.speak", params: ["text": msg.content])
                                actionStatus = ""
                            } catch { actionStatus = error.localizedDescription }
                        }
                    } label: {
                        Label("朗读回复", systemImage: "speaker.wave.2")
                    }
                    Button {
                        Task {
                            do {
                                guard let rpc = host.rpc() else { throw IPCFrameError.channelClosed }
                                _ = try await rpc.request("memory.add", params: [
                                    "botId": bot.id, "title": String(msg.content.prefix(24)),
                                    "content": msg.content, "layer": "pinned"
                                ])
                                actionStatus = "已存入常驻记忆。"
                            } catch { actionStatus = error.localizedDescription }
                        }
                    } label: {
                        Label("存入常驻记忆", systemImage: "brain.head.profile")
                    }
                    if !isUser && !host.isStreaming {
                        Button {
                            Task { await host.regenerateLastReply(sessionId: bot.id, model: selectedModel) }
                        } label: {
                            Label("再次回答", systemImage: "arrow.clockwise")
                        }
                    }
                }
                .padding(host.useBubbleLayout ? 12 : 4)
                .background(
                    host.useBubbleLayout
                        ? (isUser ? DSTheme.brand.opacity(0.14) : DSTheme.surfaceSecondary)
                        : Color.clear
                )
                .clipShape(RoundedRectangle(cornerRadius: DSTheme.cornerBubble, style: .continuous))
        }
        .frame(maxWidth: .infinity, alignment: isUser && host.useBubbleLayout ? .trailing : .leading)
        .padding(8)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(searchResultMessageID == msg.id ? DSTheme.brand.opacity(0.10) : .clear)
        }
        .overlay {
            if searchResultMessageID == msg.id {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(DSTheme.brand.opacity(0.45), lineWidth: 1)
            }
        }
    }

    @ViewBuilder
    private func smartActionCardsBar(for lastAssistant: ChatMessageItem) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Button {
                    activeSheet = .sideChat
                } label: {
                    Label("旁白追问", systemImage: "bubble.left.and.exclamationmark.bubble.right")
                        .font(.caption)
                }
                .buttonStyle(.bordered)

                if lastAssistant.content.count >= 600 {
                    Button {
                        saveAssistantSummaryToMemory(lastAssistant.content)
                    } label: {
                        Label("存为记忆", systemImage: "brain")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                }

                if sessionMessages.count >= 8 {
                    Button {
                        Task { await host.sendMessage(sessionId: bot.id, text: "/compact", model: selectedModel) }
                    } label: {
                        Label("压缩上下文", systemImage: "arrow.down.right.and.arrow.up.left")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                }

                if !liveBot.isPrivate && lastAssistant.content.contains("```") {
                    Button {
                        saveAssistantContentToWorkspace(lastAssistant.content)
                    } label: {
                        Label("存为工作区文件", systemImage: "doc.badge.plus")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func saveAssistantSummaryToMemory(_ content: String) {
        Task {
            do {
                guard let rpc = host.rpc() else { return }
                let summary = String(content.prefix(600))
                let title = "对话要点 · \(Date().formatted(date: .abbreviated, time: .shortened))"
                _ = try await rpc.request("memory.add", params: [
                    "botId": liveBot.id,
                    "title": title,
                    "content": summary,
                    "layer": "delta"
                ])
                actionStatus = "已存入 Bot 记忆"
                DSHaptics.notify(.success)
            } catch {
                actionStatus = error.localizedDescription
            }
        }
    }

    private func saveAssistantContentToWorkspace(_ content: String) {
        guard !liveBot.isPrivate else { return }
        let dir = LocalAgentTransport.defaultWorkspace.appendingPathComponent("files", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fileName = "snippet-\(Int(Date().timeIntervalSince1970)).md"
        let target = dir.appendingPathComponent(fileName, isDirectory: false)
        if (try? content.write(to: target, atomically: true, encoding: .utf8)) != nil {
            actionStatus = "已保存到工作区：files/\(fileName)"
            DSHaptics.notify(.success)
        }
    }

    private var composerBar: some View {
        VStack(spacing: 0) {
            Divider()
            if input.trimmingCharacters(in: .whitespaces).hasPrefix("/") {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        Button("/side 侧边对话") {
                            input = ""
                            activeSheet = .sideChat
                        }
                        .buttonStyle(.bordered)
                        .font(.caption)
                        if liveBot.isGroup {
                            Button("/goal 群目标") {
                                input = ""
                                activeSheet = .groupWorkspace
                            }
                            .buttonStyle(.bordered)
                            .font(.caption)
                        }
                        Button("/compact 压缩上下文") {
                            input = ""
                            Task { await host.sendMessage(sessionId: bot.id, text: "/compact", model: selectedModel) }
                        }
                        .buttonStyle(.bordered)
                        .font(.caption)
                        Button("/clear 清空会话") {
                            input = ""
                            showClearConfirm = true
                        }
                        .buttonStyle(.bordered)
                        .font(.caption)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                }
                .background(DSTheme.surfaceSecondary.opacity(0.6))
            }
            if !attachedFiles.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(attachedFiles) { file in
                            HStack(spacing: 6) {
                                Image(systemName: Self.attachmentIcon(for: file.fileName))
                                    .font(.caption)
                                    .foregroundColor(DSTheme.brand)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(file.fileName)
                                        .font(.caption.weight(.medium))
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Text(ByteCountFormatter.string(fromByteCount: Int64(file.byteCount), countStyle: .file))
                                        .font(.system(size: 10))
                                        .foregroundStyle(.secondary)
                                }
                                Button {
                                    attachedFiles.removeAll { $0.id == file.id }
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(DSTheme.surfacePrimary)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .stroke(DSTheme.brand.opacity(0.22), lineWidth: 1)
                            )
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                }
                .background(DSTheme.surfaceSecondary.opacity(0.75))
            }
            if let ref = referencedBot {
                HStack(spacing: 8) {
                    Image(systemName: "quote.bubble.fill")
                        .font(.caption)
                        .foregroundColor(.indigo)
                    Text("引用会话：\(ref.name)")
                        .font(.caption)
                        .lineLimit(1)
                    Spacer()
                    Button {
                        referencedBot = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(Color.indigo.opacity(0.08))
            }
            HStack(spacing: 8) {
                Menu {
                    if !liveBot.isPrivate {
                        Button {
                            Task { @MainActor in
                                try? await Task.sleep(nanoseconds: 200_000_000)
                                showFileImporter = true
                            }
                        } label: {
                            Label("选择任意文件（PDF/文档/代码/压缩包）", systemImage: "paperclip")
                        }
                        Button { activeSheet = .workspaceFiles } label: { Label("/files 浏览与编辑工作区", systemImage: "folder.fill") }
                    }
                    Button { activeSheet = .referenceChatPicker } label: { Label("引用历史对话作为上下文", systemImage: "quote.bubble") }
                    Button { activeSheet = .sideChat } label: { Label("/side 侧边对话", systemImage: "bubble.left.and.exclamationmark.bubble.right") }
                    if liveBot.isGroup { Button { activeSheet = .groupWorkspace } label: { Label("/goal 群目标与待办", systemImage: "target") } }
                    Button { showClearConfirm = true } label: { Label("/clear 清空当前会话", systemImage: "trash") }
                    Menu {
                        ForEach(host.bots.filter { !$0.isPrivate && !$0.isGroup }) { member in
                            Button("@\(member.name)") { input = "@\(member.name) " }
                        }
                    } label: {
                        Label("@ 提及成员 Bot", systemImage: "at")
                    }
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.title3)
                        .foregroundColor(.secondary)
                }

                if !liveBot.isPrivate {
                    Button {
                        showFileImporter = true
                    } label: {
                        Image(systemName: "paperclip")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundColor(attachedFiles.isEmpty ? .secondary : DSTheme.brand)
                    }
                    .disabled(host.isStreaming)
                    .help("附加任意文件")

                    #if canImport(PhotosUI)
                    PhotosPicker(selection: $selectedPhotoItems, maxSelectionCount: 5, matching: .images) {
                        Image(systemName: "photo")
                            .font(.system(size: 17, weight: .medium))
                            .foregroundColor(.secondary)
                    }
                    .disabled(host.isStreaming)
                    .help("从相册选择图片")
                    #endif
                }

                TextField(host.isStreaming && host.streamingSessionId == bot.id ? "输入插话引导内容（Steer）…" : "给 \(liveBot.name) 发消息…", text: $input, axis: .vertical)
                    .lineLimit(1...4)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(DSTheme.surfaceSecondary)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

                Button {
                    speechInput.toggle { transcript in
                        input = transcript
                    }
                    if let err = speechInput.errorMessage {
                        actionStatus = err
                    }
                } label: {
                    Image(systemName: speechInput.isRecording ? "mic.circle.fill" : "mic.circle")
                        .font(.title3)
                        .foregroundColor(speechInput.isRecording ? DSTheme.danger : .secondary)
                }
                .disabled(host.isStreaming)

                if host.isStreaming && host.streamingSessionId == bot.id {
                    let steerText = input.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !steerText.isEmpty {
                        Button {
                            let toSend = steerText
                            input = ""
                            Task { await host.steerActiveTurn(sessionId: bot.id, text: toSend, model: selectedModel) }
                        } label: {
                            Image(systemName: "arrow.triangle.turn.up.right.circle.fill")
                                .font(.title2)
                                .foregroundColor(.orange)
                        }
                        .help("插话引导（Steer）")
                    }
                    Button {
                        Task { await host.abortActiveTurn() }
                    } label: {
                        Image(systemName: "stop.circle.fill")
                            .font(.title2)
                            .foregroundColor(DSTheme.danger)
                    }
                } else {
                    Button {
                        speechInput.stop()
                        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !text.isEmpty || !attachedFiles.isEmpty else { return }
                        if text == "/side" {
                            input = ""
                            activeSheet = .sideChat
                            return
                        }
                        if text == "/files", !liveBot.isPrivate {
                            input = ""
                            activeSheet = .workspaceFiles
                            return
                        }
                        if text == "/profile" {
                            input = ""
                            activeSheet = .botProfile
                            return
                        }
                        if text == "/goal", liveBot.isGroup {
                            input = ""
                            activeSheet = .groupWorkspace
                            return
                        }
                        if text == "/clear" {
                            input = ""
                            showClearConfirm = true
                            return
                        }
                        var refPrefix = ""
                        if let ref = referencedBot {
                            let snippet = host.messages(for: ref.id).suffix(6).map { msg in
                                "\(msg.role == "user" ? "用户" : ref.name): \(String(msg.content.prefix(600)))"
                            }.joined(separator: "\n")
                            if !snippet.isEmpty {
                                refPrefix = "[引用历史会话「\(ref.name)」]\n\(snippet)\n\n"
                            }
                        }
                        let attachmentPrefix = attachedFiles.map { $0.promptPrefix() }.joined()
                        let prefix = refPrefix + attachmentPrefix
                        let body = text.isEmpty ? "请查看我刚附加的工作区文件。" : text
                        let payload = prefix + body
                        input = ""
                        attachedFiles.removeAll()
                        referencedBot = nil
                        Task { await host.sendMessage(sessionId: bot.id, text: payload, model: selectedModel) }
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title2)
                            .foregroundColor((input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachedFiles.isEmpty) ? .secondary : DSTheme.brand)
                    }
                    .disabled(host.state != .ready || host.isStreaming || (input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachedFiles.isEmpty))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(DSTheme.surfacePrimary)
        }
    }

    private static func attachmentIcon(for fileName: String) -> String {
        let ext = (fileName as NSString).pathExtension.lowercased()
        switch ext {
        case "png", "jpg", "jpeg", "heic", "heif", "webp", "gif", "bmp", "tif", "tiff":
            return "photo"
        case "pdf":
            return "doc.richtext"
        case "zip", "tar", "gz", "7z", "rar":
            return "doc.zipper"
        case "swift", "py", "js", "ts", "mjs", "json", "yaml", "yml", "xml", "html", "css", "sh", "sql", "c", "cpp", "go", "rs":
            return "chevron.left.forwardslash.chevron.right"
        case "doc", "docx", "pages", "rtf", "txt", "md", "csv", "xlsx", "pptx":
            return "doc.text"
        default:
            return "paperclip"
        }
    }
}

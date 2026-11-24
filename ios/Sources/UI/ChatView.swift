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
    case threads
    case sideChat
    case groupWorkspace
    case memory
    case workspaceFiles
    case editBot
    case diagnostics
    case scheduleManager
    case jobsManager
    case referenceChatPicker
    case agentBrowser
    case pluginManager
    case webWorkbench
    case sessionConfig
    case modelPicker
    case rulesEditor
    case skillsManager
    case history(SessionHistoryPresentation)

    var id: String {
        switch self {
        case .botProfile: return "botProfile"
        case .threads: return "threads"
        case .sideChat: return "sideChat"
        case .groupWorkspace: return "groupWorkspace"
        case .memory: return "memory"
        case .workspaceFiles: return "workspaceFiles"
        case .editBot: return "editBot"
        case .diagnostics: return "diagnostics"
        case .scheduleManager: return "scheduleManager"
        case .jobsManager: return "jobsManager"
        case .referenceChatPicker: return "referenceChatPicker"
        case .agentBrowser: return "agentBrowser"
        case .pluginManager: return "pluginManager"
        case .webWorkbench: return "webWorkbench"
        case .sessionConfig: return "sessionConfig"
        case .modelPicker: return "modelPicker"
        case .rulesEditor: return "rulesEditor"
        case .skillsManager: return "skillsManager"
        case .history(let presentation): return "history-\(presentation.id)"
        }
    }
}

public struct ChatView: View {
    let bot: BotProfile
    @ObservedObject var host: LocalAgentHost
    @ObservedObject private var browserController = AgentBrowserController.shared
    @ObservedObject private var threadStore = BotThreadStore.shared
    private let searchResultMessageID: String?
    private let initialAddress: SessionAddress?
    @State private var input = ""
    @State private var selectedModel: String
    @State private var sessionViewMode: ChatSessionViewMode = .dialogue
    @State private var showCommandPalette = false
    @State private var isPlanMode = false
    @State private var activeSectionTitle = ""
    @State private var isPrivateUnlocked = false
    @State private var historyError: String?
    @State private var restoringOlderHistory = false
    @State private var followsLiveOutput = true
    @State private var showClearConfirm = false
    @State private var showPrivateExportConfirm = false
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
    public init(bot: BotProfile, host: LocalAgentHost, targetMessageID: String? = nil, initialAddress: SessionAddress? = nil) {
        self.bot = bot
        self.host = host
        self.searchResultMessageID = targetMessageID
        self.initialAddress = initialAddress
        if let initialAddress, initialAddress.botID == bot.id {
            BotThreadStore.shared.selectAddress(initialAddress)
        }
        let initialSessionId = BotThreadStore.shared.activeSessionId(for: bot.id)
        _pendingSearchMessageID = State(initialValue: targetMessageID)
        _selectedModel = State(initialValue: host.modelSelection(bot.model))
        _input = State(initialValue: bot.isPrivate ? "" : host.draftInput(for: initialSessionId))
        _expandStreamingReasoning = State(initialValue: !host.collapseThinkingByDefault)
    }

    private var liveBot: BotProfile {
        host.bots.first(where: { $0.id == bot.id }) ?? bot
    }

    private var activeThread: BotThread {
        threadStore.activeThread(for: liveBot.id)
    }

    private var activeSessionId: String {
        activeThread.sessionId
    }

    private var isPrivateSnapshotShielded: Bool {
        liveBot.isPrivate && chatScenePhase != .active
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
        isLocked ? [] : host.messages(for: activeSessionId)
    }

    private var transcriptRows: [ChatTranscriptRow] {
        let messages = sessionMessages.map(ChatTranscriptRow.message)
        let activities = (isLocked ? [] : host.dshToolActivities.filter { $0.sessionId == activeSessionId })
            .map(ChatTranscriptRow.tool)
        let approvalAudits = (isLocked ? [] : host.dshApprovalAudits.filter { $0.sessionId == activeSessionId })
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
        .overlay {
            if isPrivateSnapshotShielded && !isLocked {
                ZStack {
                    Color(.systemBackground).ignoresSafeArea()
                    VStack(spacing: 12) {
                        Image(systemName: "lock.shield.fill")
                            .font(.system(size: 40))
                            .foregroundStyle(DSTheme.warning)
                        Text("私密会话已遮罩保护")
                            .font(.headline)
                        Text("返回应用后自动恢复显示")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .task(id: "\(isLocked)-\(activeSessionId)") {
            if !isLocked { await loadHistory() }
        }
        .navigationTitle(liveBot.name)
        .onChange(of: liveBot.model) { selectedModel = host.modelSelection($0) }
        .onChange(of: selectedModel) { nextModel in
            host.setBotModel(sessionId: liveBot.id, model: nextModel)
        }
        .onChange(of: activeSessionId) { nextId in
            host.visibleChatSessionId = nextId
            if !liveBot.isPrivate {
                input = host.draftInput(for: nextId)
            }
        }
        .onChange(of: input) { nextText in
            if !isLocked {
                host.setDraftInput(nextText, for: activeSessionId, isPrivate: liveBot.isPrivate)
            }
        }
        .onChange(of: host.apiBaseURL) { _ in selectedModel = host.modelSelection(liveBot.model) }
        .onAppear {
            host.visibleChatSessionId = activeSessionId
        }
        .onDisappear {
            if host.visibleChatSessionId == activeSessionId { host.visibleChatSessionId = nil }
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
                    VStack(spacing: 1) {
                        Button {
                            activeSheet = .botProfile
                        } label: {
                            HStack(spacing: 4) {
                                Text(liveBot.name)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                if !activeThread.isDefault {
                                    Text("· \(activeThread.title)")
                                        .font(.caption.weight(.medium))
                                        .foregroundStyle(DSTheme.brand)
                                        .lineLimit(1)
                                }
                                if liveBot.isPrivate {
                                    Image(systemName: "lock.fill")
                                        .font(.caption2)
                                        .foregroundStyle(DSTheme.warning)
                                }
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .buttonStyle(.plain)

                        Button {
                            if !host.isStreaming {
                                activeSheet = .modelPicker
                            }
                        } label: {
                            HStack(spacing: 3) {
                                Text("\(host.agentPresetName(liveBot.agentPreset)) · \(selectedModel) · \(liveBot.permissionModeLabel)")
                                    .font(.system(size: 10.5, weight: .medium))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                Image(systemName: "chevron.down")
                                    .font(.system(size: 8, weight: .semibold))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    // Menu 1: Live Strategy (Mode, Approval Tier, Model, RedTeam Permissions)
                    Menu {
                        Section("实时模式与审批（热切换）") {
                            Picker(host.agentPresetName(liveBot.agentPreset), selection: Binding(
                                get: { liveBot.agentPreset },
                                set: { nextPreset in
                                    if nextPreset == "redteam" && redteamPresetAllowed(for: liveBot) {
                                        let targetId = liveBot.id
                                        let needsTools = !liveBot.redteamToolsEnabled
                                        Task { @MainActor in
                                            if !host.redteamModeEnabled {
                                                await host.setRedteamMode(true)
                                            }
                                            if needsTools {
                                                host.setRedteamPermissions(sessionId: targetId, toolsEnabled: true)
                                            }
                                            host.setAgentPreset(sessionId: targetId, presetId: nextPreset)
                                            actionStatus = "已开启红队宿主并切换至红队模式"
                                        }
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
                        ModelSelectionView(host: host, model: $selectedModel, allowsTyping: false)
                        Button {
                            activeSheet = .modelPicker
                        } label: {
                            Label("搜索 / 刷新全部模型…", systemImage: "magnifyingglass")
                        }
                        .disabled(host.isStreaming)
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
                        Section("多话题与会话操作") {
                            Button {
                                activeSheet = .threads
                            } label: {
                                Label("切换 / 新建话题（当前：\(activeThread.title)）", systemImage: "bubble.left.and.bubble.right")
                            }
                            Button {
                                activeSheet = .sideChat
                            } label: {
                                Label("侧边旁路对话 (/side)", systemImage: "bubble.left.and.exclamationmark.bubble.right")
                            }
                            Button {
                                Task { await host.sendMessage(sessionId: activeSessionId, text: "/compact", model: selectedModel) }
                            } label: {
                                Label("压缩当前上下文 (/compact)", systemImage: "arrow.down.right.and.arrow.up.left")
                            }
                            .disabled(host.isStreaming || sessionMessages.isEmpty)
                            Button {
                                activeSheet = .workspaceFiles
                            } label: {
                                Label("工作区文件 (files/)", systemImage: "folder.fill")
                            }
                            #if canImport(UIKit)
                            Button {
                                let text = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                                guard !text.isEmpty else {
                                    actionStatus = "剪贴板为空。"
                                    return
                                }
                                do {
                                    let stamp = Int(Date().timeIntervalSince1970)
                                    let imported = try host.importRawDataToWorkspace(Data(text.utf8), suggestedName: "clipboard_\(stamp).txt")
                                    attachedFiles.append(imported)
                                    actionStatus = "已附加剪贴板文本：files/\(imported.relativePath)"
                                    DSHaptics.notify(.success)
                                } catch {
                                    actionStatus = "附加剪贴板失败：\(error.localizedDescription)"
                                }
                            } label: {
                                Label("粘贴剪贴板文本为附件", systemImage: "doc.on.clipboard")
                            }
                            .disabled(host.isStreaming)
                            #endif
                            if !liveBot.isPrivate {
                                Button {
                                    activeSheet = .agentBrowser
                                } label: {
                                    Label("内置浏览器（Bot 可控）", systemImage: "safari")
                                }
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
                                if liveBot.isPrivate {
                                    showPrivateExportConfirm = true
                                } else {
                                    activeSheet = .history(.export)
                                }
                            } label: {
                                Label("导出会话为 Markdown", systemImage: "square.and.arrow.up")
                            }
                            .disabled(host.streamingSessionId == activeSessionId)
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
                                Label("清空当前话题（\(activeThread.title)）", systemImage: "trash")
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
        .confirmationDialog("确定清空「\(liveBot.name) · \(activeThread.title)」的全部聊天记录？其他话题不受影响。", isPresented: $showClearConfirm, titleVisibility: .visible) {
            Button("清空当前话题", role: .destructive) {
                guard !isLocked, !host.isStreaming else { return }
                let targetId = activeSessionId
                Task {
                    await host.clearSession(targetId)
                    DSHaptics.notify(.warning)
                }
            }
            Button("取消", role: .cancel) {}
        }
        .confirmationDialog("私密会话跨空间导出确认", isPresented: $showPrivateExportConfirm, titleVisibility: .visible) {
            Button("确认导出私密内容", role: .destructive) {
                guard !isLocked else { return }
                performSessionMarkdownExport()
            }
            Button("取消（不写入任何文件）", role: .cancel) {}
        } message: {
            Text("当前为私密会话。继续操作将把本话题内容导出到系统共享表单；点击取消不会写入任何文件。")
        }
        .background(
            Color.clear
                .fileImporter(
                    isPresented: $showFileImporter,
                    allowedContentTypes: LocalAgentHost.supportedImportContentTypes,
                    allowsMultipleSelection: true
                ) { result in
                    switch result {
                    case .success(let urls):
                        var addedCount = 0
                        var lastError: String?
                        for url in urls {
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
        )
        #if canImport(PhotosUI)
        .onChange(of: selectedPhotoItems) { items in
            guard !items.isEmpty else { return }
            let picked = items
            selectedPhotoItems = []
            Task {
                var added = 0
                var lastError: String?
                for (idx, item) in picked.enumerated() {
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
        case .threads:
            BotThreadsSheet(
                bot: liveBot,
                threadStore: threadStore,
                onSelectThread: { thread in
                    threadStore.selectThread(thread)
                },
                onDeleteSession: { sessionId in
                    Task { await host.clearSession(sessionId) }
                }
            )
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
        case .agentBrowser:
            AgentBrowserSheet(workspace: host.workspace) { prompt in
                guard !host.isStreaming else {
                    input = prompt
                    return
                }
                let targetId = activeSessionId
                Task { await host.sendMessage(sessionId: targetId, text: prompt, model: selectedModel) }
            }
        case .pluginManager:
            NavigationStack {
                PluginManagerView(host: host)
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button("完成") { activeSheet = nil }
                        }
                    }
            }
        case .webWorkbench:
            DSHWebUIView(host: host)
        case .sessionConfig:
            ChatSessionConfigSheet(host: host, bot: liveBot, selectedModel: $selectedModel)
        case .modelPicker:
            ModelPickerSheet(
                host: host,
                model: $selectedModel,
                title: "切换当前对话模型"
            ) { chosen in
                host.applyModelToAllBots(chosen)
            }
        case .rulesEditor:
            SessionRulesEditorSheet(workspace: host.workspace)
        case .skillsManager:
            SessionSkillsSheet(workspace: host.workspace) { skillName, skillBody in
                let clipped = String(skillBody.prefix(2_500))
                input = "[使用用户 Skill：\(skillName)]\n\(clipped)\n\n请基于以上 Skill 规范帮我："
            }
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
        let targetId = activeSessionId
        historyError = nil
        restoringOlderHistory = older
        let previousCount = sessionMessages.count
        defer { if previousCount == sessionMessages.count { restoringOlderHistory = false } }
        do {
            try await host.loadSessionHistory(targetId, older: older)
        } catch is CancellationError {
            return
        } catch {
            if !isLocked { historyError = "无法读取会话记录。请重试。" }
        }
    }

    private func lockPrivateConversation() {
        isPrivateUnlocked = false
        for thread in threadStore.threads(for: liveBot.id, includeArchived: true) {
            host.discardSessionHistoryCache(thread.sessionId)
            if host.streamingSessionId == thread.sessionId {
                Task { await host.abortActiveTurn() }
            }
        }
        historyError = nil
        activeSheet = nil
        showFileImporter = false
        attachedFiles.removeAll()
        speechInput.stop()
        showClearConfirm = false
        showPrivateExportConfirm = false
        actionStatus = ""
        Task { _ = try? await host.rpc()?.request("device.stopSpeaking") }
    }

    private var conversation: some View {
        ScrollViewReader { proxy in
            ZStack(alignment: .top) {
                VStack(spacing: 0) {
                    let sessionActivities = host.dshToolActivities.filter { $0.sessionId == activeSessionId }
                    let sessionAudits = host.dshApprovalAudits.filter { $0.sessionId == activeSessionId }
                    let turnCount = sessionMessages.filter { $0.role == "user" }.count
                    ChatSessionSubTabBar(
                        mode: $sessionViewMode,
                        stepCount: sessionActivities.count,
                        isPrivate: liveBot.isPrivate,
                        enabledPlugins: host.installedPlugins.filter(\.enabled),
                        thirdPartyTools: host.thirdPartyPluginTools,
                        onOpenPlugins: { activeSheet = .pluginManager },
                        onOpenWebWorkbench: { activeSheet = .webWorkbench },
                        onOpenBrowser: { activeSheet = .agentBrowser },
                        onInsertToolPrompt: { snippet in
                            sessionViewMode = .dialogue
                            input = snippet
                        }
                    )
                    if host.isStreaming,
                       let activeId = host.streamingSessionId,
                       activeId != activeSessionId,
                       let activeAddress = host.resolveAddress(activeId),
                       let activeBot = host.bot(for: activeAddress) {
                        HStack(spacing: 8) {
                            ProgressView().scaleEffect(0.7)
                            let threadSuffix = (!activeBot.isPrivate ? threadStore.threadTitle(for: activeAddress).map { " · \($0)" } : nil) ?? ""
                            Text("「\(activeBot.isPrivate ? "私密会话" : activeBot.name)\(threadSuffix)」正在后台流式生成中")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Spacer()
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(DSTheme.brand.opacity(0.08))
                    }
                    if !liveBot.isPrivate, !browserController.currentURL.isEmpty {
                        let isTakeoverActive = browserController.needsHumanTakeover || browserController.isHumanControlling
                        Button {
                            activeSheet = .agentBrowser
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: isTakeoverActive ? (browserController.needsHumanTakeover ? "hand.raised.fill" : "lock.fill") : (browserController.isLoading ? "globe.badge.chevron.backward" : "safari.fill"))
                                    .font(.caption)
                                    .foregroundStyle(isTakeoverActive ? .orange : DSTheme.brand)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(browserController.needsHumanTakeover
                                         ? "内置浏览器 · 需要你手动接管"
                                         : (browserController.isHumanControlling
                                            ? "内置浏览器 · 人工接管中（已暂停 Bot）"
                                            : (browserController.pageTitle.isEmpty ? (URL(string: browserController.currentURL)?.host ?? browserController.currentURL) : browserController.pageTitle)))
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                    if !browserController.lastActionSummary.isEmpty {
                                        Text(browserController.lastActionSummary)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                }
                                Spacer()
                                Text(browserController.needsHumanTakeover ? "立即接管" : (browserController.isHumanControlling ? "继续操作" : "查看 / 接管"))
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(isTakeoverActive ? .orange : DSTheme.brand)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 6)
                            .background(isTakeoverActive ? Color.orange.opacity(0.14) : DSTheme.surfaceSecondary)
                        }
                        .buttonStyle(.plain)
                    }
                    if sessionViewMode == .trajectory {
                        ChatTrajectoryView(
                            activities: sessionActivities,
                            audits: sessionAudits,
                            turnCount: turnCount
                        )
                    } else {
                        ZStack(alignment: .bottomTrailing) {
                            conversationScrollView(proxy: proxy)
                            if !liveBot.isPrivate {
                                VStack {
                                    Spacer()
                                    Button {
                                        activeSheet = .workspaceFiles
                                    } label: {
                                        Image(systemName: "chevron.left")
                                            .font(.caption.weight(.bold))
                                            .foregroundStyle(.secondary)
                                            .frame(width: 22, height: 48)
                                            .background(.ultraThinMaterial)
                                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                                    .strokeBorder(Color.secondary.opacity(0.22), lineWidth: 0.75)
                                            )
                                    }
                                    .buttonStyle(.plain)
                                    .offset(x: 6)
                                    .accessibilityLabel("打开工作区文件侧边栏")
                                    Spacer()
                                }
                            }
                            if !followsLiveOutput && (!sessionMessages.isEmpty || (host.isStreaming && host.streamingSessionId == activeSessionId)) {
                                Button {
                                    followsLiveOutput = true
                                    withAnimation(.easeOut(duration: 0.2)) {
                                        proxy.scrollTo("chat_bottom", anchor: .bottom)
                                    }
                                } label: {
                                    HStack(spacing: 6) {
                                        if host.isStreaming && host.streamingSessionId == activeSessionId {
                                            Circle()
                                                .fill(DSTheme.brand)
                                                .frame(width: 7, height: 7)
                                        }
                                        Image(systemName: "arrow.down")
                                            .font(.caption.weight(.bold))
                                        Text(host.isStreaming && host.streamingSessionId == activeSessionId ? "回到最新输出" : "回到底部")
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
        .simultaneousGesture(
            DragGesture(minimumDistance: 12)
                .onChanged { value in
                    if value.translation.height > 12 {
                        followsLiveOutput = false
                    }
                }
        )
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
        guard followsLiveOutput, host.streamingSessionId == activeSessionId else { return }
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

        if host.loadingHistoryIDs.contains(activeSessionId) {
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
                Task { await loadHistory(older: host.hasOlderHistory(activeSessionId)) }
            }
        } else if host.hasOlderHistory(activeSessionId) {
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

        if sessionMessages.isEmpty && !host.hasSessionHistory(activeSessionId)
            && !host.loadingHistoryIDs.contains(activeSessionId) && !host.isStreaming {
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

        if host.isStreaming && host.streamingSessionId == activeSessionId {
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
        ForEach(host.pendingApprovals.filter { $0.sessionId == activeSessionId }) { approval in
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

        ForEach(host.pendingDSHQuestions.filter { $0.sessionId == activeSessionId }) { request in
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
        if host.lastErrorSessionId == activeSessionId, let errMsg = host.lastStreamError, !host.isStreaming {
            DSBannerCard(
                icon: "exclamationmark.triangle.fill",
                tint: DSTheme.danger,
                message: errMsg,
                actionTitle: "重试"
            ) {
                Task { await host.regenerateLastReply(sessionId: activeSessionId, model: selectedModel) }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 6)
        }

        if !host.isStreaming, host.lastCancelledSessionId == activeSessionId {
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
                        Task { await host.sendMessage(sessionId: activeSessionId, text: prompt, model: selectedModel) }
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
                                    sessionId: activeSessionId,
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
                DisclosureGroup("深度思考过程 · \(msg.reasoning.count) 字") {
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
                .equatable()
                .contextMenu {
                    if isUser && !host.isStreaming {
                        Button {
                            input = msg.content
                            DSHaptics.impact(.light)
                        } label: {
                            Label("编辑并重发", systemImage: "pencil.line")
                        }
                    }
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
                    if !host.isStreaming {
                        Button(role: .destructive) {
                            host.deleteMessage(sessionId: activeSessionId, messageId: msg.id)
                        } label: {
                            Label("删除此条消息", systemImage: "trash")
                        }
                    }
                    if !isUser && !host.isStreaming {
                        if msg.incomplete == true {
                            Button {
                                Task {
                                    await host.sendMessage(
                                        sessionId: activeSessionId,
                                        text: "请从刚才中断的位置继续完成上面的回答，不要重复已输出的内容。",
                                        model: selectedModel
                                    )
                                }
                            } label: {
                                Label("继续生成", systemImage: "play.circle")
                            }
                        }
                        Button {
                            Task { await host.regenerateLastReply(sessionId: activeSessionId, model: selectedModel) }
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

            if !isUser && !liveBot.isPrivate {
                MessageWorkspaceFileCards(text: msg.content, workspace: host.workspace)
            }
            if !isUser {
                MessageFooterActionBar(
                    text: msg.content,
                    timestamp: msg.timestamp,
                    canRegenerate: !host.isStreaming && msg.id == sessionMessages.last(where: { $0.role != "user" })?.id,
                    onRegenerate: {
                        Task { await host.regenerateLastReply(sessionId: activeSessionId, model: selectedModel) }
                    }
                )
            }
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
                        Task { await host.sendMessage(sessionId: activeSessionId, text: "/compact", model: selectedModel) }
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

    private func exportSessionMarkdown() {
        if liveBot.isPrivate {
            showPrivateExportConfirm = true
            return
        }
        performSessionMarkdownExport()
    }

    private func performSessionMarkdownExport() {
        let threadSuffix = activeThread.isDefault ? "" : "（\(activeThread.title)）"
        var lines: [String] = ["# \(liveBot.name)\(threadSuffix) · 会话日志导出", ""]
        for msg in sessionMessages {
            let roleTitle = msg.role == "user" ? "用户" : liveBot.name
            lines.append("## \(roleTitle)")
            if !msg.reasoning.isEmpty {
                lines.append("<details><summary>思考过程</summary>\n\n\(msg.reasoning)\n\n</details>")
            }
            lines.append(msg.content)
            lines.append("")
        }
        let sessionActivities = host.dshToolActivities.filter { $0.sessionId == activeSessionId }
        if !sessionActivities.isEmpty {
            lines.append("## 执行轨迹（\(sessionActivities.count) 步）")
            for (idx, act) in sessionActivities.enumerated() {
                let dur = act.formattedDuration ?? "—"
                lines.append("- **#\(idx + 1) \(act.displayLabel)** (`\(act.phase)`, \(dur)) \(act.fileSummary ?? "")")
            }
        }
        let body = lines.joined(separator: "\n")
        let safeName = liveBot.name.replacingOccurrences(of: "/", with: "_")
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("\(safeName)-session-\(Int(Date().timeIntervalSince1970)).md")
        guard (try? body.write(to: dest, atomically: true, encoding: .utf8)) != nil else { return }
        #if canImport(UIKit)
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let root = scenes.first(where: { $0.activationState == .foregroundActive })?.windows.first(where: \.isKeyWindow)?.rootViewController
            ?? scenes.first?.windows.first?.rootViewController
        var presenter = root
        while let next = presenter?.presentedViewController { presenter = next }
        guard let presenter else { return }
        let sheet = UIActivityViewController(activityItems: [dest], applicationActivities: nil)
        sheet.popoverPresentationController?.sourceView = presenter.view
        sheet.popoverPresentationController?.sourceRect = CGRect(x: presenter.view.bounds.midX, y: presenter.view.bounds.maxY - 60, width: 1, height: 1)
        presenter.present(sheet, animated: true)
        #endif
    }

    private func rewindLastUserTurn() {
        guard let previous = host.rewindLastTurn(sessionId: activeSessionId) else {
            actionStatus = "当前没有可回退的上一轮消息。"
            return
        }
        input = previous
        actionStatus = "已撤回上一轮并回填到输入框，可直接修改重发。"
        DSHaptics.impact(.light)
    }

    private var composerBar: some View {
        VStack(spacing: 0) {
            Divider()
            if showCommandPalette || input.trimmingCharacters(in: .whitespaces).hasPrefix("/") {
                ChatSlashCommandPalette(
                    query: input,
                    isPrivate: liveBot.isPrivate,
                    isGroup: liveBot.isGroup,
                    isPlanMode: isPlanMode,
                    thirdPartyTools: host.thirdPartyPluginTools,
                    onPickFile: {
                        showCommandPalette = false
                        if input.hasPrefix("/") { input = "" }
                        presentAttachmentPicker()
                    },
                    onOpenGoal: {
                        showCommandPalette = false
                        if input.hasPrefix("/") { input = "" }
                        if liveBot.isGroup {
                            activeSheet = .groupWorkspace
                        } else {
                            input = "请帮我制定并跟踪以下长期目标：\n"
                        }
                    },
                    onTogglePlanMode: {
                        showCommandPalette = false
                        if input.hasPrefix("/") { input = "" }
                        withAnimation(.easeInOut(duration: 0.16)) {
                            isPlanMode.toggle()
                        }
                        DSHaptics.impact(.light)
                    },
                    onQuoteChat: {
                        showCommandPalette = false
                        if input.hasPrefix("/") { input = "" }
                        activeSheet = .referenceChatPicker
                    },
                    onCompact: {
                        showCommandPalette = false
                        input = ""
                        Task { await host.sendMessage(sessionId: activeSessionId, text: "/compact", model: selectedModel) }
                    },
                    onOpenConfig: {
                        showCommandPalette = false
                        if input.hasPrefix("/") { input = "" }
                        activeSheet = .sessionConfig
                    },
                    onOpenSchedules: {
                        showCommandPalette = false
                        if input.hasPrefix("/") { input = "" }
                        activeSheet = .scheduleManager
                    },
                    onOpenSideChat: {
                        showCommandPalette = false
                        if input.hasPrefix("/") { input = "" }
                        activeSheet = .sideChat
                    },
                    onOpenWorkspace: {
                        showCommandPalette = false
                        if input.hasPrefix("/") { input = "" }
                        activeSheet = .workspaceFiles
                    },
                    onExport: {
                        showCommandPalette = false
                        if input.hasPrefix("/") { input = "" }
                        exportSessionMarkdown()
                    },
                    onPurge: {
                        showCommandPalette = false
                        input = "/purge status"
                    },
                    onRewind: {
                        showCommandPalette = false
                        rewindLastUserTurn()
                    },
                    onOpenRules: {
                        showCommandPalette = false
                        if input.hasPrefix("/") { input = "" }
                        activeSheet = .rulesEditor
                    },
                    onOpenSkills: {
                        showCommandPalette = false
                        if input.hasPrefix("/") { input = "" }
                        activeSheet = .skillsManager
                    },
                    onClear: {
                        showCommandPalette = false
                        if input.hasPrefix("/") { input = "" }
                        showClearConfirm = true
                    },
                    onInsertText: { snippet in
                        showCommandPalette = false
                        input = snippet
                    }
                )
            } else if !liveBot.isPrivate, let atRange = input.range(of: "@[^\\s@]*$", options: .regularExpression) {
                let mentionQuery = String(input[atRange].dropFirst())
                ChatAtMentionPalette(
                    query: mentionQuery,
                    workspace: host.workspace,
                    bots: host.bots,
                    currentBotId: liveBot.id,
                    onSelectFile: { relPath in
                        input.replaceSubrange(atRange, with: "\(relPath) ")
                    },
                    onSelectBot: { targetBot in
                        if liveBot.isGroup {
                            input.replaceSubrange(atRange, with: "@\(targetBot.name) ")
                        } else {
                            input.removeSubrange(atRange)
                            referencedBot = targetBot
                        }
                    }
                )
            }
            if isPlanMode {
                HStack(spacing: 6) {
                    Image(systemName: "list.bullet.clipboard.fill")
                        .font(.caption)
                        .foregroundStyle(DSTheme.brand)
                    Text("计划模式已开启 · 将先输出分步方案再执行")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(DSTheme.brand)
                    Spacer()
                    Button {
                        withAnimation(.easeInOut(duration: 0.16)) { isPlanMode = false }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(DSTheme.brand.opacity(0.09))
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
                Button {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        showCommandPalette.toggle()
                    }
                    DSHaptics.impact(.light)
                } label: {
                    Image(systemName: showCommandPalette ? "xmark.circle.fill" : "plus.circle.fill")
                        .font(.title3)
                        .foregroundColor(showCommandPalette ? DSTheme.brand : .secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("打开添加与指令面板")

                if !liveBot.isPrivate {
                    ChatPermissionQuickMenu(currentMode: liveBot.permissionMode) { nextMode in
                        host.setPermissionMode(sessionId: liveBot.id, mode: nextMode)
                        DSHaptics.impact(.light)
                    }
                }

                Button {
                    presentAttachmentPicker()
                } label: {
                    Image(systemName: "paperclip")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundColor(attachedFiles.isEmpty ? .secondary : DSTheme.brand)
                }
                .disabled(host.isStreaming)
                .help("附加任意本地文件或目录")

                #if canImport(PhotosUI)
                PhotosPicker(selection: $selectedPhotoItems, matching: .images) {
                    Image(systemName: "photo")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundColor(.secondary)
                }
                .disabled(host.isStreaming)
                .help("从相册选择图片")
                #endif

                TextField(host.isStreaming && host.streamingSessionId == activeSessionId ? "输入插话引导内容（Steer）…" : "给 \(liveBot.name) 发消息…", text: $input, axis: .vertical)
                    .lineLimit(1...4)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(DSTheme.surfaceSecondary)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

                Button {
                    activeSheet = .sessionConfig
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(host.subagentEnabled ? DSTheme.brand : .secondary)
                }
                .help("模型、安全权限与智能体协作")

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

                if host.isStreaming && host.streamingSessionId == activeSessionId {
                    let steerText = input.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !steerText.isEmpty {
                        Button {
                            let toSend = steerText
                            input = ""
                            Task { await host.steerActiveTurn(sessionId: activeSessionId, text: toSend, model: selectedModel) }
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
                            showCommandPalette = false
                            input = ""
                            showClearConfirm = true
                            return
                        }
                        if text == "/plan" {
                            showCommandPalette = false
                            input = ""
                            withAnimation(.easeInOut(duration: 0.16)) { isPlanMode.toggle() }
                            return
                        }
                        if text == "/rewind" {
                            showCommandPalette = false
                            input = ""
                            rewindLastUserTurn()
                            return
                        }
                        if text == "/export", !liveBot.isPrivate {
                            showCommandPalette = false
                            input = ""
                            exportSessionMarkdown()
                            return
                        }
                        if text == "/rules", !liveBot.isPrivate {
                            showCommandPalette = false
                            input = ""
                            activeSheet = .rulesEditor
                            return
                        }
                        if text == "/skills", !liveBot.isPrivate {
                            showCommandPalette = false
                            input = ""
                            activeSheet = .skillsManager
                            return
                        }
                        if text == "/schedule", !liveBot.isPrivate {
                            showCommandPalette = false
                            input = ""
                            activeSheet = .scheduleManager
                            return
                        }
                        if text == "/permission" || text == "/model" {
                            showCommandPalette = false
                            input = ""
                            activeSheet = .sessionConfig
                            return
                        }
                        if text == "/browser", !liveBot.isPrivate {
                            showCommandPalette = false
                            input = ""
                            activeSheet = .agentBrowser
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
                        let planPrefix = isPlanMode ? "[计划模式：请先给出清晰的分步执行计划，待我确认后再执行任何修改操作]\n\n" : ""
                        let attachmentPrefix = attachedFiles.map { $0.promptPrefix() }.joined()
                        let imageExts: Set<String> = ["jpg", "jpeg", "png", "webp", "gif"]
                        let imagePaths = attachedFiles
                            .map(\.relativePath)
                            .filter { path in
                                let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
                                return imageExts.contains(ext)
                            }
                        let prefix = planPrefix + refPrefix + attachmentPrefix
                        let body = text.isEmpty ? "请查看我刚附加的工作区文件。" : text
                        let payload = prefix + body
                        showCommandPalette = false
                        input = ""
                        attachedFiles.removeAll()
                        referencedBot = nil
                        Task { await host.sendMessage(sessionId: activeSessionId, text: payload, model: selectedModel, imagePaths: imagePaths) }
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

            if !liveBot.isPrivate {
                let sessionActs = host.dshToolActivities.filter { $0.sessionId == activeSessionId }
                let turns = sessionMessages.filter { $0.role == "user" }.count
                let steps = sessionActs.count
                let toolDurationMs = sessionActs.compactMap(\.durationMs).reduce(0, +)
                let msgChars = sessionMessages.reduce(0) { $0 + $1.content.count + $1.reasoning.count }
                let outChars = sessionMessages.filter { $0.role != "user" }.reduce(0) { $0 + $1.content.count + $1.reasoning.count }
                let sysTokens = max(1_200, liveBot.systemPrompt.count / 3 + 1_200)
                let toolSchemaTokens = (host.customTools ? 3_800 : 0) + host.thirdPartyPluginTools.count * 260
                let msgTokens = max(0, msgChars / 3)
                let outTokens = max(0, outChars / 3)
                ChatSessionTelemetryBar(
                    turnCount: turns,
                    stepCount: steps,
                    toolDurationMs: toolDurationMs,
                    firstTokenMs: host.streamFirstTokenMs,
                    liveTelemetry: host.telemetryBySession[activeSessionId],
                    systemPromptTokens: sysTokens,
                    toolSchemaTokens: toolSchemaTokens,
                    messageTokens: msgTokens,
                    outputTokens: outTokens,
                    contextLimit: 128_000,
                    enabledPluginCount: host.installedPlugins.filter(\.enabled).count,
                    onTapTrajectory: {
                        withAnimation(.easeInOut(duration: 0.16)) {
                            sessionViewMode = sessionViewMode == .trajectory ? .dialogue : .trajectory
                        }
                    },
                    onTapCompact: {
                        guard !host.isStreaming else { return }
                        Task { await host.sendMessage(sessionId: activeSessionId, text: "/compact", model: selectedModel) }
                    }
                )
                .background(DSTheme.surfacePrimary)
            }
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

    private func presentAttachmentPicker() {
        #if canImport(UIKit)
        NativeDocumentPicker.present(allowsMultipleSelection: true) { urls in
            guard !urls.isEmpty else { return }
            var addedCount = 0
            var lastError: String?
            for url in urls {
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
        }
        #else
        showFileImporter = true
        #endif
    }
}

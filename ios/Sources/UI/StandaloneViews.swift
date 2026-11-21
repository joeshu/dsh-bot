import SwiftUI
import UniformTypeIdentifiers
#if canImport(UIKit)
import UIKit
#endif

/// Native agent navigation.
public struct MainTabView: View {
    @ObservedObject var host: LocalAgentHost

    public var body: some View {
        TabView {
            SessionsTabView(host: host)
                .tabItem { Label("会话", systemImage: "bubble.left.and.bubble.right") }

            BotRosterTabView(host: host)
                .tabItem { Label("Bot", systemImage: "face.smiling") }

            ToolsHubTabView(host: host)
                .tabItem { Label("小工具", systemImage: "square.grid.2x2") }

            PluginManagerView(host: host)
                .tabItem { Label("探索", systemImage: "safari") }

            AgentSettingsView(host: host)
                .tabItem { Label("设置", systemImage: "gearshape") }
        }
    }
}

// MARK: - Tab 1: 会话 (Sessions)

public struct SessionsTabView: View {
    @ObservedObject var host: LocalAgentHost
    @State private var searchText = ""
    @State private var showCreateSheet = false

    private var searchQuery: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var botSearchSnapshot: (bots: [BotProfile], messages: [String: ChatMessageItem]) {
        let query = searchQuery
        guard !query.isEmpty else { return (host.recentlyActiveBots, [:]) }
        var matches: [String: ChatMessageItem] = [:]
        let matchingBots = host.bots.filter { bot in
            let matchesIdentity = bot.name.localizedCaseInsensitiveContains(query)
                || bot.roleLabel.localizedCaseInsensitiveContains(query)
            if !bot.isPrivate, let message = host.matchingImportedMessage(botId: bot.id, query: query) {
                matches[bot.id] = message
            }
            return matchesIdentity || matches[bot.id] != nil
        }
        return (host.sortBySessionActivity(matchingBots), matches)
    }

    public var body: some View {
        let searchSnapshot = botSearchSnapshot
        NavigationStack {
            List {
                Section {
                    agentStatusCard
                }
                .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                .listRowBackground(Color.clear)

                NavigationLink {
                    SessionInboxView(host: host)
                } label: {
                    Label("待处理", systemImage: "tray")
                }

                if !searchQuery.isEmpty {
                    SessionSearchResults(host: host, query: searchQuery)
                        .id(searchQuery)
                }

                Section(searchQuery.isEmpty ? "最近会话" : "匹配的会话") {
                    ForEach(searchSnapshot.bots) { bot in
                        let matchedMessage = searchSnapshot.messages[bot.id]
                        NavigationLink {
                            ChatView(bot: bot, host: host, targetMessageID: matchedMessage?.id)
                        } label: {
                            HStack(spacing: 12) {
                                DSBotAvatar(
                                    initials: bot.name,
                                    color: bot.isMain ? DSTheme.brand : (bot.isGroup ? .indigo : (bot.isPrivate ? DSTheme.warning : .teal)),
                                    isPrivate: bot.isPrivate,
                                    size: 42
                                )
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack(spacing: 6) {
                                        Text(bot.name)
                                            .font(.headline)
                                        if bot.isMain {
                                            DSStatusBadge("Main", color: DSTheme.brand)
                                        } else if bot.isGroup {
                                            DSStatusBadge("群聊", color: .indigo)
                                        }
                                    }
                                    Text(lastPreview(for: bot, matching: matchedMessage))
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                        .lineLimit(2)
                                }
                                Spacer()
                                VStack(alignment: .trailing, spacing: 3) {
                                    if !bot.isPrivate, let timestamp = host.sessionActivityDate(for: bot.id) {
                                        Text(timestamp.formatted(date: .omitted, time: .shortened))
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                    }
                                }
                            }
                            .padding(.vertical, 3)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .refreshable { await host.refreshSessionSummaries() }
            .navigationTitle("会话")
            .searchable(text: $searchText, prompt: "搜索会话和消息")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showCreateSheet = true } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.title3)
                    }
                }
            }
            .sheet(isPresented: $showCreateSheet) {
                CreateBotSheet(host: host)
            }
        }
    }

    private func lastPreview(for bot: BotProfile, matching message: ChatMessageItem? = nil) -> String {
        if bot.isPrivate { return "私密会话" }
        if let message {
            let sender = message.role == "user" ? "你" : bot.name
            return "\(sender)：\(message.content)"
        }
        if let last = host.messages(for: bot.id).last {
            return last.content
        }
        if let persistedPreview = host.sessionPreview(for: bot.id) {
            return persistedPreview
        }
        return bot.roleLabel
    }

    private var agentStatusCard: some View {
        HStack(spacing: 12) {
            Image(systemName: statusIcon)
                .font(.title2)
                .foregroundColor(statusColor)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(host.embeddedRuntimeLabel ?? "Node.js + DSH 0.2.2-rc.5")
                        .font(.subheadline.weight(.semibold))
                    DSStatusBadge(host.isDSHRecoveryMode ? "恢复模式" : statusBadge, color: host.isDSHRecoveryMode ? DSTheme.warning : statusColor)
                }
                Text(host.workspaceError ?? statusDescription)
                    .font(.caption)
                    .foregroundColor(.secondary)
                if case .failed = host.state {
                    Button("重试启动") { Task { await host.boot() } }
                        .font(.caption)
                }
            }
            Spacer()
        }
        .padding(14)
        .background(DSTheme.surfacePrimary)
        .clipShape(RoundedRectangle(cornerRadius: DSTheme.cornerCard, style: .continuous))
        .shadow(color: .black.opacity(0.04), radius: 6, y: 2)
    }

    private var statusBadge: String {
        switch host.state {
        case .ready: return "就绪"
        case .failed: return "异常"
        default: return "启动中"
        }
    }

    private var statusIcon: String {
        switch host.state {
        case .ready: return "cpu.fill"
        case .failed: return "exclamationmark.triangle.fill"
        default: return "clock.fill"
        }
    }

    private var statusColor: Color {
        switch host.state {
        case .ready: return DSTheme.success
        case .failed: return DSTheme.danger
        default: return .secondary
        }
    }

    private var statusDescription: String {
        switch host.state {
        case .idle, .starting: return "正在读取本机工作区…"
        case .ready: return "应用版本 \(host.appVersion)"
        case .failed(let message): return message
        }
    }

}

// MARK: - Tab 2: Bot (Grouped Team Roster)

public struct BotRosterTabView: View {
    @ObservedObject var host: LocalAgentHost
    @State private var showCreateSheet = false
    @State private var editingBot: BotProfile?
    @State private var pendingDeleteBot: BotProfile?

    private var sections: [String] {
        Array(NSOrderedSet(array: host.bots.map(\.section))) as? [String] ?? []
    }

    public var body: some View {
        NavigationStack {
            List {
                ForEach(sections, id: \.self) { sec in
                    Section(sec) {
                        ForEach(host.bots.filter { $0.section == sec }) { bot in
                            NavigationLink {
                                ChatView(bot: bot, host: host)
                            } label: {
                                HStack(spacing: 12) {
                                    DSBotAvatar(
                                        initials: bot.name,
                                        color: bot.isMain ? DSTheme.brand : (bot.isGroup ? .indigo : (bot.isPrivate ? DSTheme.warning : .teal)),
                                        isPrivate: bot.isPrivate,
                                        size: 38
                                    )
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(bot.name).font(.headline)
                                        Text(bot.roleLabel).font(.caption).foregroundColor(.secondary)
                                    }
                                    Spacer()
                                    Text(host.modelSelection(bot.model)).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .swipeActions(edge: .trailing) {
                                if !bot.isMain {
                                    Button("删除", role: .destructive) {
                                        pendingDeleteBot = bot
                                    }
                                }
                                Button("编辑") {
                                    editingBot = bot
                                }
                                .tint(DSTheme.brand)
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Bot 团队")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showCreateSheet = true } label: {
                        Label("新建", systemImage: "plus")
                    }
                }
            }
            .sheet(isPresented: $showCreateSheet) {
                CreateBotSheet(host: host)
            }
            .sheet(item: $editingBot) { target in
                EditBotSheet(bot: target, host: host)
            }
            .confirmationDialog(
                "确定删除「\(pendingDeleteBot?.name ?? "")」及其聊天记录？",
                isPresented: Binding(
                    get: { pendingDeleteBot != nil },
                    set: { if !$0 { pendingDeleteBot = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("删除", role: .destructive) {
                    if let target = pendingDeleteBot {
                        pendingDeleteBot = nil
                        host.deleteBot(id: target.id)
                    }
                }
                Button("取消", role: .cancel) { pendingDeleteBot = nil }
            }
        }
    }
}

// MARK: - Tab 3: 小工具 (DS-Bot Ported Capabilities Hub)

public struct ToolsHubTabView: View {
    @ObservedObject var host: LocalAgentHost

    public var body: some View {
        NavigationStack {
            List {
                Section {
                    WidgetBlueprintCardView(
                        title: "端侧运行态势（实时）",
                        metrics: [
                            WidgetMetricItem(label: "应用版本", value: host.appVersion),
                            WidgetMetricItem(label: "Bot / 群聊", value: "\(host.bots.count)"),
                            WidgetMetricItem(label: "活跃会话", value: "\(host.messagesBySession.count)"),
                            WidgetMetricItem(label: "待审批", value: "\(host.pendingApprovals.count)")
                        ]
                    )
                }
                .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                .listRowBackground(Color.clear)

                Section("核心智能体工具") {
                    NavigationLink {
                        MemoryVaultView(host: host, botId: "main")
                    } label: {
                        toolRow(icon: "brain.head.profile", color: .purple, title: "主 Bot 记忆", subtitle: "查看、添加和撤销本机记忆")
                    }

                    NavigationLink {
                        ConnectorsAndUsageView(host: host)
                    } label: {
                        toolRow(icon: "cable.connector", color: DSTheme.brand, title: "Remote MCP 与用量", subtitle: "设定 HTTPS 连接器与工具发现")
                    }

                    NavigationLink {
                        ScheduleBotPickerView(host: host)
                    } label: {
                        toolRow(icon: "calendar.badge.clock", color: .orange, title: "定时任务", subtitle: "按 Bot 查看、编辑、暂停和查看投递记录")
                    }

                    NavigationLink {
                        JobsBotPickerView(host: host)
                    } label: {
                        toolRow(icon: "hourglass", color: .purple, title: "后台任务", subtitle: "按 Bot 查看离线 Python 任务、读取输出和取消")
                    }

                    NavigationLink {
                        JSSandboxPlaygroundView(host: host)
                    } label: {
                        toolRow(icon: "chevron.left.forwardslash.chevron.right", color: DSTheme.success, title: "端侧 JS 沙盒与设备探针", subtitle: "离线执行脚本并查看本机电量和温控")
                    }

                    NavigationLink {
                        WorkspaceFilesView(host: host)
                    } label: {
                        toolRow(icon: "folder.fill", color: .orange, title: "工作区文件（files/）", subtitle: "管理智能体可读写的沙盒文档与导入附件")
                    }

                    NavigationLink {
                        SkillsManagerView(host: host)
                    } label: {
                        toolRow(icon: "wand.and.stars", color: .pink, title: "Skill 技能管理（SKILL.md）", subtitle: "新建与编辑 DSH 技能，对话自动发现调用")
                    }

                    NavigationLink {
                        DSHWebUIView(host: host)
                    } label: {
                        toolRow(icon: "macwindow.on.rectangle", color: .indigo, title: "DSH Web 工作台", subtitle: "完整官方 Web UI 与社区 dsh-client-ui-* 插件")
                    }
                }

                Section("DSH 开发工具使用") {
                    Label("新建 / 编辑 Bot，或在空会话菜单中选择标准、创造或轻量模式。", systemImage: "slider.horizontal.3")
                        .font(.subheadline)
                    Text("标准模式提供文件读写、补丁、搜索、Skill、计划、提问和待办；创造模式额外提供只读 Cordis API 检查。对话中会显示工具名称、运行状态及截断后的输入和结果。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("文件修改需要审批；选择只读权限会拒绝写入。自定义模型需在设置中打开「服务支持工具调用」。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

            }
            .listStyle(.insetGrouped)
            .navigationTitle("小工具")
        }
    }

    private func toolRow(icon: String, color: Color, title: String, subtitle: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundColor(color)
                .frame(width: 34, height: 34)
                .background(color.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(subtitle).font(.caption).foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Enhanced ChatView (Reading Pill + / Slash Commands + Model Switcher + Streaming Commit + Approvals)

private struct DSHUserQuestionCard: View {
    let request: PendingDSHQuestion
    let onSubmit: ([[String: Any]]) -> Void
    @State private var selected: [String: Set<String>] = [:]
    @State private var customText: [String: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("DSH 需要你的回答", systemImage: "questionmark.circle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(DSTheme.brand)

            ForEach(request.questions) { item in
                VStack(alignment: .leading, spacing: 8) {
                    if !item.header.isEmpty {
                        Text(item.header.uppercased())
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    Text(item.question).font(.subheadline.weight(.medium))
                    if !item.detail.isEmpty {
                        Text(item.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    ForEach(item.options) { option in
                        let isSelected = selected[item.id, default: []].contains(option.label)
                        Button {
                            var values = selected[item.id, default: []]
                            if item.multiSelect {
                                if isSelected { values.remove(option.label) } else { values.insert(option.label) }
                            } else {
                                values = [option.label]
                            }
                            selected[item.id] = values
                        } label: {
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: isSelected
                                      ? (item.multiSelect ? "checkmark.square.fill" : "largecircle.fill.circle")
                                      : (item.multiSelect ? "square" : "circle"))
                                    .foregroundStyle(isSelected ? DSTheme.brand : Color.secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(option.label).font(.callout.weight(.medium))
                                    if !option.description.isEmpty {
                                        Text(option.description).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer(minLength: 0)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    TextField("补充说明（可选）", text: Binding(
                        get: { customText[item.id, default: ""] },
                        set: { customText[item.id] = $0 }
                    ), axis: .vertical)
                    .lineLimit(1...4)
                    .textFieldStyle(.roundedBorder)
                }
            }

            Button("提交回答") {
                let answers: [[String: Any]] = request.questions.map { item in
                    var answer: [String: Any] = [
                        "id": item.id,
                        "selected": item.options.filter { selected[item.id, default: []].contains($0.label) }.map(\.label),
                    ]
                    let custom = customText[item.id]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    if !custom.isEmpty { answer["custom"] = custom }
                    return answer
                }
                onSubmit(answers)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(12)
        .background(DSTheme.brand.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: DSTheme.cornerCard, style: .continuous))
    }
}

private struct DSHToolActivityCard: View {
    let activity: DSHToolActivity
    let onViewFull: () -> Void

    private var workspacePathSummary: String? {
        if let fileSummary = activity.fileSummary { return fileSummary }
        guard ["write", "edit", "apply_patch", "patch", "delete"].contains(activity.toolName),
              let data = activity.arguments.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let arguments = object as? [String: Any] else { return nil }
        let directPath = arguments["file_path"] as? String ?? arguments["path"] as? String
        if let directPath, !directPath.isEmpty { return directPath }
        let patchText = arguments["patch"] as? String ?? arguments["patch_text"] as? String ?? ""
        let paths = patchText.split(separator: "\n").compactMap { line -> String? in
            let value = String(line)
            for prefix in ["*** Add File: ", "*** Update File: ", "*** Delete File: "] where value.hasPrefix(prefix) {
                return String(value.dropFirst(prefix.count))
            }
            return nil
        }
        if !paths.isEmpty { return paths.prefix(3).joined(separator: ", ") + (paths.count > 3 ? " …" : "") }
        return activity.toolName == "apply_patch" || activity.toolName == "patch" ? "多文件 patch" : nil
    }

    private var statusIcon: String {
        switch activity.phase {
        case "started": return "gearshape.2.fill"
        case "completed": return "checkmark.circle.fill"
        case "failed": return "exclamationmark.triangle.fill"
        case "cancelled": return "xmark.circle.fill"
        default: return "wrench.and.screwdriver.fill"
        }
    }

    private var statusTint: Color {
        switch activity.phase {
        case "started": return DSTheme.brand
        case "failed": return DSTheme.danger
        case "cancelled": return DSTheme.warning
        default: return .secondary
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: statusIcon).foregroundStyle(statusTint)
                Text(activity.toolName).font(.subheadline.weight(.semibold))
                Spacer()
                Text(activity.phaseLabel).font(.caption).foregroundStyle(statusTint)
            }
            if let workspacePathSummary {
                Label {
                    Text("工作区 · \(workspacePathSummary)").lineLimit(2)
                } icon: {
                    Image(systemName: "doc.badge.gearshape")
                }
                .font(.caption2)
                .foregroundStyle(activity.phase == "completed" ? DSTheme.brand : .secondary)
            }
            DisclosureGroup("查看工具输入与结果") {
                if !activity.arguments.isEmpty {
                    Text("输入").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Text(activity.arguments)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(.secondary.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                if !activity.result.isEmpty {
                    Text("结果").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Text(activity.result)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(.secondary.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
            .font(.caption)
            if activity.callSequence != nil {
                Button("查看完整工具记录") { onViewFull() }
                    .font(.caption)
            }
        }
        .padding(12)
        .background(Color.secondary.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: DSTheme.cornerCard, style: .continuous))
    }
}

private struct DSHApprovalAuditCard: View {
    let audit: DSHApprovalAudit

    private var tint: Color {
        switch audit.outcome {
        case "allowed-once": return DSTheme.brand
        case "rejected", "unavailable": return DSTheme.danger
        case "cancelled": return DSTheme.warning
        default: return .secondary
        }
    }

    private var icon: String {
        switch audit.outcome {
        case "allowed-once": return "checkmark.shield.fill"
        case "rejected", "unavailable": return "xmark.shield.fill"
        case "cancelled": return "nosign"
        default: return "questionmark.shield"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 3) {
                Text("审批 · \(audit.toolName)").font(.caption.weight(.semibold))
                Text(audit.outcomeLabel).font(.caption).foregroundStyle(tint)
            }
            Spacer(minLength: 0)
            Text(audit.timestamp.formatted(date: .omitted, time: .shortened))
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(tint.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: DSTheme.cornerCard, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

private enum ChatTranscriptRow: Identifiable {
    case message(ChatMessageItem)
    case tool(DSHToolActivity)
    case approval(DSHApprovalAudit)

    var id: String {
        switch self {
        case .message(let message): return "message-\(message.id)"
        case .tool(let activity): return "tool-\(activity.id)"
        case .approval(let audit): return "approval-\(audit.id)"
        }
    }

    var timestamp: Date {
        switch self {
        case .message(let message): return message.timestamp
        case .tool(let activity): return activity.timestamp
        case .approval(let audit): return audit.timestamp
        }
    }

    var sequence: Int? {
        switch self {
        case .message(let message): return message.sequence
        case .tool(let activity): return activity.sequence
        case .approval(let audit): return audit.sequence
        }
    }
}

public struct ChatView: View {
    let bot: BotProfile
    @ObservedObject var host: LocalAgentHost
    private let searchResultMessageID: String?
    @State private var input = ""
    @State private var selectedModel: String
    @State private var showSideChat = false
    @State private var showGroupWorkspace = false
    @State private var activeSectionTitle = ""
    @State private var isPrivateUnlocked = false
    @State private var historyError: String?
    @State private var historyPresentation: SessionHistoryPresentation?
    @State private var restoringOlderHistory = false
    @State private var followsLiveOutput = true
    @State private var showClearConfirm = false
    @State private var showEditBot = false
    @State private var showMemory = false
    @State private var showFileImporter = false
    @State private var showDiagnostics = false
    @State private var showScheduleManager = false
    @State private var showJobsManager = false
    @State private var showReferenceChatPicker = false
    @State private var referencedBot: BotProfile?
    @State private var attachedFile: LocalAgentHost.AttachedWorkspaceFile?
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
        !profile.isPrivate && host.redteamModeEnabled && profile.redteamToolsEnabled
            && profile.redteamWriteEnabled && profile.redteamSensitiveDataEnabled
            && profile.permissionMode != "readOnly"
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
        return (messages + activities + approvalAudits).sorted { left, right in
            if left.timestamp != right.timestamp { return left.timestamp < right.timestamp }
            if let leftSequence = left.sequence, let rightSequence = right.sequence, leftSequence != rightSequence {
                return leftSequence < rightSequence
            }
            if left.sequence != nil && right.sequence == nil { return true }
            if left.sequence == nil && right.sequence != nil { return false }
            return left.id < right.id
        }
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
        .onChange(of: host.apiBaseURL) { _ in selectedModel = host.modelSelection(liveBot.model) }
        .onDisappear { if liveBot.isPrivate { lockPrivateConversation() } }
        .onChange(of: chatScenePhase) { phase in
            if phase == .background && liveBot.isPrivate { lockPrivateConversation() }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !isLocked {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if host.sessionDiagnosticsEnabled {
                        Button {
                            showDiagnostics = true
                        } label: {
                            Image(systemName: "waveform.path.ecg")
                        }
                        .help("会话数据诊断")
                    }
                    Menu {
                        Section("DSH Agent 模式") {
                            Picker(host.agentPresetName(liveBot.agentPreset), selection: Binding(
                                get: { liveBot.agentPreset },
                                set: { host.setAgentPreset(sessionId: liveBot.id, presetId: $0) }
                            )) {
                                ForEach(host.dshAgentPresets) { preset in
                                    let allowed = preset.isAvailable && (preset.id != "redteam" || redteamPresetAllowed(for: liveBot))
                                    Text(allowed ? preset.name : "\(preset.name)（不可用/未授权）")
                                        .tag(preset.id)
                                        .disabled(!allowed)
                                }
                                if !host.dshAgentPresets.contains(where: { $0.id == liveBot.agentPreset }) {
                                    Text(host.agentPresetName(liveBot.agentPreset)).tag(liveBot.agentPreset)
                                }
                            }
                            .disabled(host.hasSessionHistory(bot.id) || host.isStreaming)
                        }
                        if host.usesOfficialModels || !host.models.isEmpty {
                            ModelSelectionView(host: host, model: $selectedModel, allowsTyping: false)
                        }
                        Button("侧边对话 (/side)") { showSideChat = true }
                        Button("定时任务") { showScheduleManager = true }
                        if liveBot.agentPreset == "standard" || liveBot.agentPreset == "cordis" {
                            Button("后台任务") { showJobsManager = true }
                        }
                        if liveBot.isGroup { Button("群目标与待办") { showGroupWorkspace = true } }
                        if liveBot.isPrivate { Button("锁定私密会话") { lockPrivateConversation() } }
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
                                    Text("请先在“探索与插件”启用全局插件工具宿主。")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                } else {
                                    Text("审批策略：\(liveBot.permissionModeLabel)。每次询问会逐次确认写入和敏感操作；自动审查仍会确认敏感操作；只读模式禁止写入。")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .disabled(liveBot.isPrivate || !host.redteamModeEnabled || host.isStreaming)
                        }
                        Button("会话数据诊断") { showDiagnostics = true }
                        Button {
                            historyPresentation = .export
                        } label: {
                            Label("导出会话为 Markdown", systemImage: "square.and.arrow.up")
                        }
                        .disabled(host.streamingSessionId == bot.id)
                        Button("记忆") { showMemory = true }
                        Button("编辑 Bot 设置") { showEditBot = true }
                        Button("清空当前会话", role: .destructive) { showClearConfirm = true }
                            .disabled(host.isStreaming)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
        .sheet(item: $historyPresentation) { presentation in
            if !isLocked {
                SessionHistoryDetailView(host: host, bot: liveBot, presentation: presentation)
            }
        }
        .sheet(isPresented: $showSideChat) {
            if !isLocked {
                SideChatSheet(host: host, model: selectedModel, botId: liveBot.id,
                              botName: liveBot.name, isPrivate: liveBot.isPrivate)
            }
        }
        .sheet(isPresented: $showGroupWorkspace) {
            if !isLocked { GroupWorkspaceSheet(host: host, groupId: bot.id) }
        }
        .sheet(isPresented: $showMemory) {
            if !isLocked { NavigationStack { MemoryVaultView(host: host, botId: liveBot.id) } }
        }
        .sheet(isPresented: $showEditBot) {
            if !isLocked { EditBotSheet(bot: liveBot, host: host) }
        }
        .sheet(isPresented: $showDiagnostics) {
            if !isLocked { SessionDiagnosticsSheet(host: host, bot: liveBot) }
        }
        .sheet(isPresented: $showScheduleManager) {
            if !isLocked {
                NavigationStack { ScheduleManagerView(host: host, botId: liveBot.id) }
            }
        }
        .sheet(isPresented: $showJobsManager) {
            if !isLocked {
                NavigationStack { JobsManagerView(host: host, botId: liveBot.id) }
            }
        }
        .sheet(isPresented: $showReferenceChatPicker) {
            NavigationStack {
                List {
                    let candidates = host.bots.filter { $0.id != liveBot.id && !$0.isPrivate }
                    if candidates.isEmpty {
                        Text("暂无可引用的其他会话").foregroundStyle(.secondary)
                    } else {
                        ForEach(candidates) { candidate in
                            Button {
                                referencedBot = candidate
                                showReferenceChatPicker = false
                            } label: {
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
                .navigationTitle("引用历史对话")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("取消") { showReferenceChatPicker = false }
                    }
                }
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
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.item]) { result in
            guard !liveBot.isPrivate else { return }
            switch result {
            case .success(let url):
                do {
                    attachedFile = try host.importFileToWorkspace(from: url)
                    actionStatus = "已附加：files/\(attachedFile?.relativePath ?? "")"
                    DSHaptics.notify(.success)
                } catch {
                    actionStatus = "附加失败：\(error.localizedDescription)"
                    DSHaptics.notify(.error)
                }
            case .failure(let error):
                actionStatus = "附加失败：\(error.localizedDescription)"
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
        historyPresentation = nil
        showSideChat = false
        showGroupWorkspace = false
        showScheduleManager = false
        showJobsManager = false
        showEditBot = false
        showMemory = false
        showFileImporter = false
        attachedFile = nil
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
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 14) {
                            Color.clear.frame(height: 1).id("chat_top")

                            if bot.isPrivate {
                                DSBannerCard(
                                    icon: "lock.shield.fill",
                                    tint: DSTheme.warning,
                                    message: "聊天记录保存在本机。发送后，消息和对话上下文会发给设置中选定的模型服务。"
                                )
                            }

                            if host.loadingHistoryIDs.contains(bot.id) {
                                ProgressView("正在读取记录")
                            } else if let historyError {
                                Text(historyError).font(.caption).foregroundStyle(.secondary)
                                Button("重试读取记录") {
                                    Task { await loadHistory(older: host.hasOlderHistory(bot.id)) }
                                }
                            } else if host.hasOlderHistory(bot.id) {
                                Button("加载更早记录") {
                                    Task { await loadHistory(older: true) }
                                }
                            }

                            if sessionMessages.isEmpty && !host.hasSessionHistory(bot.id)
                                && !host.loadingHistoryIDs.contains(bot.id) && !host.isStreaming {
                                emptyWelcomeView
                            }

                            ForEach(transcriptRows) { row in
                                switch row {
                                case .message(let msg):
                                    messageRow(msg).id(msg.id)
                                case .tool(let activity):
                                    DSHToolActivityCard(activity: activity) {
                                        historyPresentation = .tool(activity)
                                    }
                                    .id(activity.id)
                                case .approval(let audit):
                                    DSHApprovalAuditCard(audit: audit).id(audit.id)
                                }
                            }

                            if host.isStreaming && host.streamingSessionId == bot.id {
                                streamingRow
                            }

                            ForEach(host.pendingApprovals.filter { $0.sessionId == bot.id }) { approval in
                                approvalCard(approval)
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
                    .onChange(of: host.streamingContent.count) { _ in
                        guard followsLiveOutput, host.streamingSessionId == bot.id else { return }
                        let now = Date()
                        if now.timeIntervalSince(lastScrollAt) >= 0.12 {
                            lastScrollAt = now
                            proxy.scrollTo("chat_bottom", anchor: .bottom)
                        }
                    }
                    .onChange(of: host.streamingReasoning.count) { _ in
                        guard followsLiveOutput, host.streamingSessionId == bot.id else { return }
                        let now = Date()
                        if now.timeIntervalSince(lastScrollAt) >= 0.12 {
                            lastScrollAt = now
                            proxy.scrollTo("chat_bottom", anchor: .bottom)
                        }
                    }
                    .onChange(of: host.pendingApprovals.count) { _ in
                        withAnimation { proxy.scrollTo("chat_bottom", anchor: .bottom) }
                    }
                    .onChange(of: host.pendingDSHQuestions.count) { _ in
                        withAnimation { proxy.scrollTo("chat_bottom", anchor: .bottom) }
                    }
                    .onChange(of: host.dshToolActivities.count) { _ in
                        withAnimation { proxy.scrollTo("chat_bottom", anchor: .bottom) }
                    }
                    .onChange(of: host.dshApprovalAudits.count) { _ in
                        withAnimation { proxy.scrollTo("chat_bottom", anchor: .bottom) }
                    }
                    .onDisappear {
                        speechInput.stop()
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

                    if !host.isStreaming, host.lastCancelledSessionId == liveBot.id {
                        Text("已停止生成").font(.caption).foregroundStyle(.secondary)
                    }
                    if !actionStatus.isEmpty {
                        Text(actionStatus).font(.caption).foregroundStyle(.secondary)
                    }
                    composerBar
                }

                // Mounted LongReplyReadingPill whenever latest reply has >= 2 Markdown headings
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
        }
        return ["用端侧 JS 沙盒计算 10 万年化 6% 复利 5 年", "查看当前 iPhone 设备状态", "帮我拟一份会议议程"]
    }

    private var emptyWelcomeView: some View {
        VStack(spacing: 12) {
            DSBotAvatar(
                initials: liveBot.name,
                color: liveBot.isMain ? DSTheme.brand : (liveBot.isGroup ? .indigo : (liveBot.isPrivate ? DSTheme.warning : .teal)),
                isPrivate: liveBot.isPrivate,
                size: 56
            )
            Text(liveBot.name).font(.title3.weight(.semibold))
            Text(liveBot.roleLabel).font(.caption).foregroundColor(.secondary)
            VStack(spacing: 8) {
                ForEach(starterPrompts, id: \.self) { prompt in
                    Button {
                        Task { await host.sendMessage(sessionId: bot.id, text: prompt, model: selectedModel) }
                    } label: {
                        HStack {
                            Text(prompt).font(.caption).foregroundColor(.primary)
                            Spacer()
                            Image(systemName: "arrow.up.right").font(.caption2).foregroundColor(.secondary)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(DSTheme.surfaceSecondary)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                }
            }
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    @ViewBuilder
    private func messageRow(_ msg: ChatMessageItem) -> some View {
        let isUser = msg.role == "user"
        VStack(alignment: isUser && host.useBubbleLayout ? .trailing : .leading, spacing: 6) {
            Text(isUser ? "你" : liveBot.name)
                .font(.caption2.weight(.medium))
                .foregroundColor(.secondary)

            if msg.incomplete == true {
                Text("回复未完成").font(.caption).foregroundStyle(.secondary)
            }

            if !msg.reasoning.isEmpty {
                DisclosureGroup("深度思考过程") {
                    Text(msg.reasoning)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 4)
                }
                .padding(10)
                .background(DSTheme.surfaceSecondary)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }

            if msg.historyPreview == true {
                Button("查看完整消息") { historyPresentation = .message(msg) }
                    .font(.caption)
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

    private var streamingRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                ProgressView().scaleEffect(0.75)
                if let ttfb = host.streamFirstTokenMs {
                    Text("\(liveBot.name) 正在生成 · 首字 \(ttfb)ms · \(host.streamingContent.count) 字")
                        .font(.caption2.monospacedDigit())
                        .foregroundColor(.secondary)
                } else {
                    Text("\(liveBot.name) 正在连接与思考…")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            if !host.streamingReasoning.isEmpty {
                DisclosureGroup("深度思考中…", isExpanded: $expandStreamingReasoning) {
                    Text(host.streamingReasoning)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 4)
                }
                .padding(10)
                .background(DSTheme.surfaceSecondary)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            if !host.streamingContent.isEmpty {
                Text(host.streamingContent)
                    .padding(12)
                    .background(DSTheme.surfaceSecondary)
                    .clipShape(RoundedRectangle(cornerRadius: DSTheme.cornerBubble, style: .continuous))
            }
        }
    }

    @ViewBuilder
    private func smartActionCardsBar(for lastAssistant: ChatMessageItem) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Button {
                    showSideChat = true
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

    private func approvalCard(_ approval: PendingApproval) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "hand.raised.fill").foregroundColor(DSTheme.warning)
                Text("需要审批：\(approval.tool)").font(.subheadline.weight(.semibold))
            }
            if approval.tool == "run_code" || approval.tool == "python_job_start" {
                Text(approval.tool == "run_code"
                     ? "本次运行将在本机隔离 Python Worker 中执行；嵌套文件修改、联网等工具仍会按各自规则审批。"
                     : "本次运行将在本机隔离 Python Worker 中执行，作为后台任务最多运行 120 秒，不会访问应用文件、网络、进程、MCP 或 DSH 工具。App 切到后台后是否继续运行由 iOS 决定。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                DisclosureGroup(approval.tool == "run_code" ? "查看完整 Python 程序" : "查看完整后台任务程序") {
                    ScrollView(.vertical) {
                        Text(approval.summary)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 320)
                }
                .font(.caption)
            } else {
                Text(approval.summary).font(.caption).foregroundColor(.secondary).textSelection(.enabled)
            }
            Text("工具结果会返回当前模型服务。").font(.caption2).foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Button("批准") {
                    Task { await host.respondToApproval(id: approval.id, approved: true) }
                }
                .buttonStyle(.borderedProminent)
                Button("拒绝", role: .destructive) {
                    Task { await host.respondToApproval(id: approval.id, approved: false) }
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(12)
        .background(DSTheme.warning.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: DSTheme.cornerCard, style: .continuous))
    }

    private var composerBar: some View {
        VStack(spacing: 0) {
            Divider()
            if input.trimmingCharacters(in: .whitespaces).hasPrefix("/") {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        Button("/side 侧边对话") {
                            input = ""
                            showSideChat = true
                        }
                        .buttonStyle(.bordered)
                        .font(.caption)
                        if liveBot.isGroup {
                            Button("/goal 群目标") {
                                input = ""
                                showGroupWorkspace = true
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
            if let file = attachedFile {
                HStack(spacing: 8) {
                    Image(systemName: "paperclip")
                        .font(.caption)
                        .foregroundColor(DSTheme.brand)
                    Text("files/\(file.relativePath) (\(ByteCountFormatter.string(fromByteCount: Int64(file.byteCount), countStyle: .file)))")
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button {
                        attachedFile = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(DSTheme.surfaceSecondary.opacity(0.7))
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
                        Button { showFileImporter = true } label: { Label("附加文件到工作区", systemImage: "paperclip") }
                    }
                    Button { showReferenceChatPicker = true } label: { Label("引用历史对话作为上下文", systemImage: "quote.bubble") }
                    Button { showSideChat = true } label: { Label("/side 侧边对话", systemImage: "bubble.left.and.exclamationmark.bubble.right") }
                    if liveBot.isGroup { Button { showGroupWorkspace = true } label: { Label("/goal 群目标与待办", systemImage: "target") } }
                    Button { showClearConfirm = true } label: { Label("/clear 清空当前会话", systemImage: "trash") }
                    Menu {
                        ForEach(host.bots.filter { !$0.isPrivate && !$0.isGroup }) { member in
                            Button("@\(member.name)") { input = "@\(member.name) " }
                        }
                    } label: {
                        Label("@ 提及成员 Bot", systemImage: "at")
                    }
                } label: {
                    Image(systemName: "plus.circle")
                        .font(.title3)
                        .foregroundColor(.secondary)
                }

                TextField(host.isStreaming && host.streamingSessionId == bot.id ? "输入插话引导内容（Steer）…" : "给 \(liveBot.name) 发消息（支持 /side、/goal）…", text: $input, axis: .vertical)
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
                        guard !text.isEmpty || attachedFile != nil else { return }
                        if text == "/side" {
                            input = ""
                            showSideChat = true
                            return
                        }
                        if text == "/goal", liveBot.isGroup {
                            input = ""
                            showGroupWorkspace = true
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
                        let prefix = refPrefix + (attachedFile?.promptPrefix() ?? "")
                        let body = text.isEmpty ? "请查看我刚附加的工作区文件。" : text
                        let payload = prefix + body
                        input = ""
                        attachedFile = nil
                        referencedBot = nil
                        Task { await host.sendMessage(sessionId: bot.id, text: payload, model: selectedModel) }
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title2)
                            .foregroundColor((input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachedFile == nil) ? .secondary : DSTheme.brand)
                    }
                    .disabled(host.state != .ready || host.isStreaming || (input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachedFile == nil))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(DSTheme.surfacePrimary)
        }
    }
}

// MARK: - Create Bot / Group Sheet

private struct CreateBotSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var host: LocalAgentHost
    @State private var name = ""
    @State private var roleLabel = ""
    @State private var model = ModelProvider.defaultModel
    @State private var systemPrompt = ""
    @State private var isPrivate = false
    @State private var isGroup = false
    @State private var permissionMode = "ask"
    @State private var agentPreset = "standard"
    @State private var redteamToolsEnabled = false
    @State private var redteamWriteEnabled = false
    @State private var redteamSensitiveDataEnabled = false

    private static let presets: [(title: String, role: String, model: String, prompt: String)] = [
        ("代码架构师", "架构设计与代码审查", ModelProvider.thinkingModel, "你是资深软件架构师，先给出清晰结论，再提供可验证的代码与边界风险分析。"),
        ("研报分析师", "资料提炼与结构化研报", ModelProvider.thinkingModel, "你擅长将长文档和网页信息提炼为结构化研报，区分事实、推断与待核查项。"),
        ("英文润色", "地道学术与商务英文润色", ModelProvider.defaultModel, "你负责将中英文内容润色为自然地道的表达，并简要列出关键修改理由。"),
        ("红队评测", "提示词安全与边界评测", ModelProvider.thinkingModel, "你负责评估系统提示词与安全策略的鲁棒性，输出客观复现步骤与修复建议。"),
        ("日常翻译", "中英日精准互译", ModelProvider.defaultModel, "请准确自然地翻译用户输入，保留专业术语与排版格式。")
    ]

    private func redteamPresetAllowed(_ preset: DSHAgentPresetOption) -> Bool {
        preset.isAvailable && !isPrivate && host.redteamModeEnabled && redteamToolsEnabled
            && redteamWriteEnabled && redteamSensitiveDataEnabled && permissionMode != "readOnly"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("快捷角色模板") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(Self.presets, id: \.title) { preset in
                                Button(preset.title) {
                                    name = preset.title
                                    roleLabel = preset.role
                                    model = preset.model
                                    systemPrompt = preset.prompt
                                    DSHaptics.impact(.light)
                                }
                                .buttonStyle(.bordered)
                                .font(.caption)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
                Section("基本信息") {
                    TextField("名称（如 研报助手）", text: $name)
                    TextField("职责描述", text: $roleLabel)
                    ModelSelectionView(host: host, model: $model)
                    Picker("DSH Agent 模式", selection: $agentPreset) {
                        ForEach(host.dshAgentPresets) { preset in
                            let allowed = preset.id == "redteam" ? redteamPresetAllowed(preset) : preset.isAvailable
                            Text(allowed ? preset.name : "\(preset.name)（不可用/未授权）")
                                .tag(preset.id)
                                .disabled(!allowed)
                        }
                    }
                    .onAppear {
                        if let defaultPreset = host.dshAgentPresets.first(where: { $0.id == host.defaultAgentPreset }),
                           defaultPreset.isAvailable,
                           (defaultPreset.id != "redteam" || redteamPresetAllowed(defaultPreset)) {
                            agentPreset = host.defaultAgentPreset
                        }
                    }
                }
                Section("系统提示词（可选）") {
                    TextEditor(text: $systemPrompt)
                        .frame(minHeight: 72)
                }
                Section("权限预设与隔离") {
                    Picker("工具审批策略", selection: $permissionMode) {
                        Text("每次询问").tag("ask")
                        Text("自动审查").tag("autoReview")
                        Text("只读模式").tag("readOnly")
                    }
                    Toggle("创建群会话与待办", isOn: $isGroup)
                        .onChange(of: isGroup) { v in if v { isPrivate = false } }
                    Toggle("锁定私密会话（独立隔离，禁止入群）", isOn: $isPrivate)
                        .onChange(of: isPrivate) { v in
                            if v {
                                isGroup = false
                                redteamToolsEnabled = false
                                redteamWriteEnabled = false
                                redteamSensitiveDataEnabled = false
                            }
                        }
                }
                if host.redteamStatus.installed {
                    Section("dsh-purge-safe 工具授权") {
                        Toggle("允许本 Bot 调用红队工具", isOn: $redteamToolsEnabled)
                            .onChange(of: redteamToolsEnabled) { enabled in
                                if !enabled {
                                    redteamWriteEnabled = false
                                    redteamSensitiveDataEnabled = false
                                }
                            }
                        Toggle("允许写入红队演练台", isOn: $redteamWriteEnabled)
                            .disabled(!redteamToolsEnabled)
                        Toggle("允许敏感工具（凭据 / 入口 / WebShell / 隧道 / PoC / 探测 / 清理）", isOn: $redteamSensitiveDataEnabled)
                            .disabled(!redteamToolsEnabled)
                        Text("敏感工具仍按上方审批策略确认；只读模式禁止写入。私密会话不能授权红队工具。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .disabled(isPrivate || !host.redteamModeEnabled)
                }
            }
            .navigationTitle("新建 Bot / 群聊")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("创建") {
                        host.addBot(
                            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                            roleLabel: roleLabel.isEmpty ? "自定义智能体" : roleLabel,
                            model: model,
                            systemPrompt: systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines),
                            isPrivate: isPrivate,
                            isGroup: isGroup,
                            permissionMode: permissionMode,
                            agentPreset: agentPreset,
                            redteamToolsEnabled: redteamToolsEnabled,
                            redteamWriteEnabled: redteamWriteEnabled,
                            redteamSensitiveDataEnabled: redteamSensitiveDataEnabled
                        )
                        DSHaptics.notify(.success)
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

// MARK: - 设置

private struct ModelSelectionView: View {
    @ObservedObject var host: LocalAgentHost
    @Binding var model: String
    var allowsTyping = true

    var body: some View {
        if host.usesOfficialModels {
            Picker("模型", selection: $model) {
                Text("DeepSeek Flash").tag(ModelProvider.defaultModel)
                Text("DeepSeek Flash · 思考").tag(ModelProvider.thinkingModel)
                Text("DeepSeek V4 Pro").tag("deepseek-v4-pro")
                if ![ModelProvider.defaultModel, ModelProvider.thinkingModel, "deepseek-v4-pro"].contains(model) {
                    Text(model).tag(model)
                }
            }
        } else {
            if allowsTyping {
                TextField("服务商模型 ID", text: $model)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            if !host.models.isEmpty {
                Menu("选择服务商模型") {
                    ForEach(host.models, id: \.self) { id in Button(id) { model = id } }
                }
            }
        }
    }
}

public struct AgentSettingsView: View {
    @ObservedObject var host: LocalAgentHost
    @State private var apiKey = ""
    @State private var status = ""
    @State private var keyConfigured = false

    public var body: some View {
        NavigationStack {
            Form {
                Section("运行诊断") {
                    LabeledContent("应用", value: "\(host.appVersion) (\(host.buildNumber))")
                    LabeledContent("引擎", value: host.embeddedRuntimeLabel ?? "Node.js + DSH 0.2.2-rc.5")
                    LabeledContent("Web 工作台", value: "已内嵌（支持 dsh-client-ui-*）")
                    LabeledContent("本地数据库", value: ByteCountFormatter.string(fromByteCount: host.sqliteDatabaseSizeBytes(), countStyle: .file))
                    Button("重启 DSH 引擎") {
                        status = "正在重启 DSH 引擎…"
                        Task {
                            status = await host.restartRuntime()
                        }
                    }
                    Button("复制诊断 JSON") {
                        Task {
                            do {
                                guard let rpc = host.rpc() else { throw IPCFrameError.channelClosed }
                                let info = try await rpc.request("agent.info")
                                let data = try JSONSerialization.data(withJSONObject: info, options: [.prettyPrinted, .sortedKeys])
                                UIPasteboard.general.string = String(decoding: data, as: UTF8.self)
                                status = "已复制诊断。"
                            } catch { status = error.localizedDescription }
                        }
                    }
                    ShareLink(
                        item: host.exportWorkspaceBackupJSON(),
                        subject: Text("DS Bot 工作区配置备份"),
                        message: Text("包含 Bot 团队配置与服务地址（不含 Keychain 密钥）")
                    ) {
                        Label("导出工作区配置备份 (JSON)", systemImage: "square.and.arrow.up")
                    }
                }

                Section("模型服务") {
                    LabeledContent("当前地址密钥") {
                        DSStatusBadge(keyConfigured ? "已配置" : "未配置", color: keyConfigured ? DSTheme.success : DSTheme.warning)
                    }
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            Button("DeepSeek 官方") { host.apiBaseURL = ModelProvider.defaultAddress }
                                .buttonStyle(.bordered)
                                .font(.caption)
                            Button("OpenRouter") { host.apiBaseURL = "https://openrouter.ai/api" }
                                .buttonStyle(.bordered)
                                .font(.caption)
                            Button("智谱 Anthropic") { host.apiBaseURL = "https://open.bigmodel.cn/api/anthropic" }
                                .buttonStyle(.bordered)
                                .font(.caption)
                        }
                        .padding(.vertical, 2)
                    }
                    TextField("HTTPS Base URL", text: $host.apiBaseURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onChange(of: host.apiBaseURL) { _ in
                            apiKey = ""
                            status = ""
                            Task { keyConfigured = await host.hasSavedAPIKey() }
                        }
                    if !host.usesOfficialModels {
                        Button("恢复官方地址（api.deepseek.com）") {
                            host.apiBaseURL = ModelProvider.defaultAddress
                        }
                        .font(.caption)
                        Text("DSH 自定义服务需兼容 Anthropic Messages API；模型 ID 可在 Bot 设置中手动填写。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Toggle("服务支持工具调用", isOn: $host.customTools)
                    }
                    SecureField("当前地址的 API Key", text: $apiKey)
                    Button("保存至 Keychain") {
                        do {
                            try host.saveAPIKey(apiKey.trimmingCharacters(in: .whitespacesAndNewlines))
                            apiKey = ""
                            status = "已为当前服务地址保存密钥。"
                            Task { keyConfigured = await host.hasSavedAPIKey() }
                        } catch { status = error.localizedDescription }
                    }
                    .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("测试连接并读取模型列表") {
                        status = "正在读取服务模型…"
                        Task {
                            do {
                                let result = try await host.refreshModels()
                                status = "已读到 \(result.count) 个模型，耗时 \(result.latency) ms。"
                            } catch {
                                status = "\(error.localizedDescription) 自定义服务可在 Bot 设置手填模型 ID。"
                            }
                        }
                    }
                }

                Section("实验性与界面") {
                    NavigationLink {
                        ExperimentalFeaturesView(host: host)
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("实验性插件与能力")
                                Text("自动授权审查、会话诊断统计、DeepSeek 会话导入等")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "flask.fill")
                                .foregroundStyle(.indigo)
                        }
                    }
                    Toggle("消息气泡布局", isOn: $host.useBubbleLayout)
                }
                if !status.isEmpty { Section { Text(status).font(.caption) } }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("设置")
            .task { keyConfigured = await host.hasSavedAPIKey() }
        }
    }
}

// MARK: - Edit Bot Sheet

private struct EditBotSheet: View {
    @Environment(\.dismiss) private var dismiss
    let bot: BotProfile
    @ObservedObject var host: LocalAgentHost
    @State private var name: String
    @State private var roleLabel: String
    @State private var model: String
    @State private var systemPrompt: String
    @State private var permissionMode: String
    @State private var agentPreset: String
    @State private var redteamToolsEnabled: Bool
    @State private var redteamWriteEnabled: Bool
    @State private var redteamSensitiveDataEnabled: Bool

    @MainActor
    init(bot: BotProfile, host: LocalAgentHost) {
        self.bot = bot
        self.host = host
        _name = State(initialValue: bot.name)
        _roleLabel = State(initialValue: bot.roleLabel)
        _model = State(initialValue: host.modelSelection(bot.model))
        _systemPrompt = State(initialValue: bot.systemPrompt)
        _permissionMode = State(initialValue: bot.permissionMode)
        _agentPreset = State(initialValue: bot.agentPreset)
        _redteamToolsEnabled = State(initialValue: bot.redteamToolsEnabled)
        _redteamWriteEnabled = State(initialValue: bot.redteamWriteEnabled)
        _redteamSensitiveDataEnabled = State(initialValue: bot.redteamSensitiveDataEnabled)
    }

    private var redteamPresetAllowed: Bool {
        !bot.isPrivate && host.redteamModeEnabled && redteamToolsEnabled
            && redteamWriteEnabled && redteamSensitiveDataEnabled && permissionMode != "readOnly"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Bot 信息") {
                    TextField("名称", text: $name)
                    TextField("职责描述", text: $roleLabel)
                    ModelSelectionView(host: host, model: $model)
                    Picker("DSH Agent 模式", selection: $agentPreset) {
                        ForEach(host.dshAgentPresets) { preset in
                            let allowed = preset.isAvailable && (preset.id != "redteam" || redteamPresetAllowed)
                            Text(allowed ? preset.name : "\(preset.name)（不可用/未授权）")
                                .tag(preset.id)
                                .disabled(!allowed)
                        }
                        if !host.dshAgentPresets.contains(where: { $0.id == agentPreset }) {
                            Text(host.agentPresetName(agentPreset)).tag(agentPreset)
                        }
                    }
                    .disabled(host.hasSessionHistory(bot.id) || host.isStreaming)
                    if host.hasSessionHistory(bot.id) {
                        Text("会话开始后模式固定；切换模式请新建 Bot。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Section("权限预设") {
                    Picker("工具审批策略", selection: $permissionMode) {
                        Text("每次询问").tag("ask")
                        Text("自动审查").tag("autoReview")
                        Text("只读模式").tag("readOnly")
                    }
                    Text("自动审查会放行只读查询工具；只读模式会拦截写入/修改类工具。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if host.redteamStatus.installed {
                    Section("dsh-purge-safe 工具授权") {
                        Toggle("允许本 Bot 调用红队工具", isOn: $redteamToolsEnabled)
                            .onChange(of: redteamToolsEnabled) { enabled in
                                if !enabled {
                                    redteamWriteEnabled = false
                                    redteamSensitiveDataEnabled = false
                                }
                            }
                        Toggle("允许写入红队演练台", isOn: $redteamWriteEnabled)
                            .disabled(!redteamToolsEnabled)
                        Toggle("允许敏感工具（凭据 / 入口 / WebShell / 隧道 / PoC / 探测 / 清理）", isOn: $redteamSensitiveDataEnabled)
                            .disabled(!redteamToolsEnabled)
                        Text("敏感工具要求独立授权；每次询问策略会逐次审批写入和敏感操作，自动审查策略会逐次审批敏感操作。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .disabled(bot.isPrivate || !host.redteamModeEnabled || host.streamingSessionId == bot.id)
                }
                Section("系统提示词（人设与指令）") {
                    TextEditor(text: $systemPrompt)
                        .frame(minHeight: 84)
                }
            }
            .navigationTitle("编辑 \(bot.name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("保存") {
                        host.updateBot(
                            id: bot.id,
                            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                            roleLabel: roleLabel.trimmingCharacters(in: .whitespacesAndNewlines),
                            model: model,
                            systemPrompt: systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines),
                            permissionMode: permissionMode,
                            agentPreset: agentPreset,
                            redteamToolsEnabled: redteamToolsEnabled,
                            redteamWriteEnabled: redteamWriteEnabled,
                            redteamSensitiveDataEnabled: redteamSensitiveDataEnabled
                        )
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

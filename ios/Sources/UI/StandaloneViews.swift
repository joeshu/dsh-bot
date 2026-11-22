import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

private enum AppTab: Hashable {
    case sessions
    case agents
    case workbench
    case settings
}

/// Native 4-Tab Agent Navigation (会话 / 智能体 / 工作台 / 设置)
/// with iPadOS adaptive sidebar (iOS 18+) and iOS 26 Liquid Glass progressive enhancement.
public struct MainTabView: View {
    @ObservedObject var host: LocalAgentHost
    @State private var selectedTab: AppTab = .sessions
    @State private var dismissedPulseTurnId: String?
    @State private var pulseTargetBot: BotProfile?

    public init(host: LocalAgentHost) {
        self.host = host
    }

    private var pendingInboxCount: Int {
        host.pendingApprovals.count + host.pendingDSHQuestions.count
    }

    private var pulseSessionId: String? {
        host.streamingSessionId ?? host.pendingApprovals.first?.sessionId
    }

    private var activePulseBot: BotProfile? {
        guard let sid = pulseSessionId else { return nil }
        return host.bots.first(where: { $0.id == sid })
    }

    private var showPulseBar: Bool {
        guard let sid = pulseSessionId else { return false }
        if host.visibleChatSessionId == sid { return false }
        if let activeTurn = host.activeTurnId, dismissedPulseTurnId == activeTurn, host.pendingApprovals.isEmpty {
            return false
        }
        return host.isStreaming || !host.pendingApprovals.isEmpty
    }

    @ViewBuilder
    private var rootTabView: some View {
        let base = TabView(selection: $selectedTab) {
            SessionsTabView(host: host)
                .tabItem { Label("会话", systemImage: "bubble.left.and.bubble.right.fill") }
                .badge(pendingInboxCount > 0 ? pendingInboxCount : 0)
                .tag(AppTab.sessions)

            BotRosterTabView(host: host)
                .tabItem { Label("智能体", systemImage: "person.2.crop.square.stack.fill") }
                .tag(AppTab.agents)

            ToolsHubTabView(host: host)
                .tabItem { Label("工作台", systemImage: "square.grid.2x2.fill") }
                .tag(AppTab.workbench)

            SettingsAndExploreTabView(host: host)
                .tabItem { Label("设置", systemImage: "gearshape.fill") }
                .tag(AppTab.settings)
        }
        if #available(iOS 26.0, *) {
            base
                .tabViewStyle(.sidebarAdaptable)
                .tabBarMinimizeBehavior(.onScrollDown)
        } else if #available(iOS 18.0, *) {
            base.tabViewStyle(.sidebarAdaptable)
        } else {
            base
        }
    }

    public var body: some View {
        ZStack(alignment: .bottom) {
            rootTabView

            if showPulseBar {
                GlobalBotPulseBar(
                    host: host,
                    onTapOpen: {
                        if let bot = activePulseBot {
                            pulseTargetBot = bot
                        }
                    },
                    onDismiss: {
                        dismissedPulseTurnId = host.activeTurnId
                    }
                )
                .padding(.horizontal, 12)
                .padding(.bottom, 58)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: showPulseBar)
        .onChange(of: host.activeTurnId) { _ in
            dismissedPulseTurnId = nil
        }
        .sheet(item: $pulseTargetBot) { target in
            NavigationStack {
                ChatView(bot: target, host: host)
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button("完成") { pulseTargetBot = nil }
                        }
                    }
            }
        }
    }
}

private struct GlobalBotPulseBar: View {
    @ObservedObject var host: LocalAgentHost
    let onTapOpen: () -> Void
    let onDismiss: () -> Void

    private var activeBotName: String {
        if let sid = host.streamingSessionId ?? host.pendingApprovals.first?.sessionId,
           let bot = host.bots.first(where: { $0.id == sid }) {
            return bot.name
        }
        return "智能体"
    }

    private var statusSubtitle: String {
        if let approval = host.pendingApprovals.first {
            return "待审批：\(approval.tool)"
        }
        if let activeTool = host.dshToolActivities.last(where: { $0.phase == "started" }) {
            return "正在执行：\(activeTool.toolName)"
        }
        return "正在生成回复…"
    }

    private var barContent: some View {
        HStack(spacing: 10) {
            Button(action: onTapOpen) {
                HStack(spacing: 10) {
                    Image(systemName: host.pendingApprovals.isEmpty ? "waveform" : "exclamationmark.shield.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(host.pendingApprovals.isEmpty ? DSTheme.brand : DSTheme.warning)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(activeBotName)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Text(statusSubtitle)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .buttonStyle(.plain)
            Spacer(minLength: 4)
            if let approval = host.pendingApprovals.first {
                Button("批准") {
                    Task { await host.respondToApproval(id: approval.id, approved: true) }
                }
                .font(.caption.weight(.semibold))
                .buttonStyle(.borderedProminent)
                .controlSize(.mini)
            }
            if host.isStreaming {
                Button("停止") {
                    Task { await host.abortActiveTurn() }
                }
                .font(.caption.weight(.semibold))
                .buttonStyle(.bordered)
                .tint(DSTheme.danger)
                .controlSize(.mini)
            }
            if host.pendingApprovals.isEmpty {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("隐藏状态条")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    @ViewBuilder
    var body: some View {
        if #available(iOS 26.0, *) {
            barContent
                .glassEffect(.regular, in: Capsule())
                .shadow(color: .black.opacity(0.10), radius: 8, y: 3)
        } else {
            barContent
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().stroke(Color.secondary.opacity(0.22), lineWidth: 0.75))
                .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
        }
    }
}

// MARK: - Tab 1: 会话 (Sessions)

public struct SessionsTabView: View {
    @ObservedObject var host: LocalAgentHost
    @State private var searchText = ""
    @State private var createKind: CreateBotInitialKind?
    @State private var editingBot: BotProfile?
    @State private var profileBot: BotProfile?

    public init(host: LocalAgentHost) {
        self.host = host
    }

    private var searchQuery: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var pendingCount: Int {
        host.pendingApprovals.count + host.pendingDSHQuestions.count
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
                    DSRuntimeStatusBanner(host: host)
                }
                .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                .listRowBackground(Color.clear)

                if pendingCount > 0 {
                    Section {
                        NavigationLink {
                            SessionInboxView(host: host)
                        } label: {
                            HStack(spacing: 12) {
                                ZStack {
                                    Circle()
                                        .fill(DSTheme.warning.opacity(0.18))
                                        .frame(width: 36, height: 36)
                                    Image(systemName: "bell.badge.fill")
                                        .foregroundStyle(DSTheme.warning)
                                }
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("有 \(pendingCount) 项待处理的审批或提问")
                                        .font(.subheadline.weight(.semibold))
                                    Text("点击进入收件箱，立即批准工具操作或回答智能体追问")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                DSStatusBadge("\(pendingCount)", color: DSTheme.warning)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }

                if !searchQuery.isEmpty {
                    SessionSearchResults(host: host, query: searchQuery)
                        .id(searchQuery)
                }

                Section(searchQuery.isEmpty ? "活跃会话 (\(searchSnapshot.bots.count))" : "匹配的智能体会话") {
                    if searchSnapshot.bots.isEmpty {
                        DSEmptyStateView(
                            icon: "bubble.left.and.bubble.right",
                            title: searchQuery.isEmpty ? "暂无会话" : "没有找到匹配的会话",
                            subtitle: searchQuery.isEmpty ? "点击右上角新建智能体或协作群聊。" : "尝试更换关键词，或查看上方的历史消息全文检索结果。"
                        )
                        .listRowBackground(Color.clear)
                    } else {
                        ForEach(searchSnapshot.bots) { bot in
                            let matchedMessage = searchSnapshot.messages[bot.id]
                            let botPendingCount = host.pendingApprovals.filter { $0.sessionId == bot.id }.count
                                + host.pendingDSHQuestions.filter { $0.sessionId == bot.id }.count
                            NavigationLink {
                                ChatView(bot: bot, host: host, targetMessageID: matchedMessage?.id)
                            } label: {
                                HStack(spacing: 12) {
                                    DSBotAvatar(
                                        initials: bot.name,
                                        color: DSTheme.botAvatarColor(bot),
                                        isPrivate: bot.isPrivate,
                                        size: 44
                                    )
                                    VStack(alignment: .leading, spacing: 4) {
                                        HStack(spacing: 5) {
                                            Text(bot.name)
                                                .font(.headline)
                                                .lineLimit(1)
                                            if bot.isMain {
                                                DSStatusBadge("Main", color: DSTheme.brand)
                                            } else if bot.isGroup {
                                                DSStatusBadge("群聊", color: .indigo)
                                            } else if bot.isPrivate {
                                                DSStatusBadge("私密", color: DSTheme.warning, icon: "lock.fill")
                                            }
                                            DSPresetBadge(
                                                presetId: bot.agentPreset,
                                                label: host.agentPresetName(bot.agentPreset)
                                            )
                                            if bot.permissionMode == "autoReview" {
                                                DSStatusBadge("免打扰", color: DSTheme.success)
                                            } else if bot.permissionMode == "readOnly" {
                                                DSStatusBadge("只读", color: .secondary)
                                            }
                                        }
                                        Text(lastPreview(for: bot, matching: matchedMessage))
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                            .lineLimit(2)
                                    }
                                    Spacer(minLength: 4)
                                    VStack(alignment: .trailing, spacing: 5) {
                                        if !bot.isPrivate, let timestamp = host.sessionActivityDate(for: bot.id) {
                                            Text(timestamp.formatted(date: .omitted, time: .shortened))
                                                .font(.caption2)
                                                .foregroundColor(.secondary)
                                        }
                                        if host.isStreaming && host.streamingSessionId == bot.id {
                                            DSStatusBadge("生成中", color: DSTheme.brand)
                                        } else if botPendingCount > 0 {
                                            DSStatusBadge("\(botPendingCount) 待办", color: DSTheme.warning)
                                        }
                                    }
                                }
                                .padding(.vertical, 4)
                            }
                            .swipeActions(edge: .trailing) {
                                Button("编辑") { editingBot = bot }
                                    .tint(DSTheme.brand)
                                if !bot.isPrivate {
                                    Button("档案") { profileBot = bot }
                                        .tint(.indigo)
                                }
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .refreshable { await host.refreshSessionSummaries() }
            .navigationTitle("会话")
            .searchable(text: $searchText, prompt: "搜索会话与公开历史消息")
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    NavigationLink {
                        DSHWebUIView(host: host)
                    } label: {
                        Image(systemName: "macwindow.on.rectangle")
                    }
                    .help("打开 DSH Web 工作台")

                    NavigationLink {
                        SessionInboxView(host: host)
                    } label: {
                        Image(systemName: pendingCount > 0 ? "tray.full.fill" : "tray")
                            .foregroundStyle(pendingCount > 0 ? DSTheme.warning : .primary)
                    }
                    .help("待处理收件箱")

                    Menu {
                        Button {
                            createKind = .standard
                        } label: {
                            Label("新建智能体", systemImage: "person.badge.plus")
                        }
                        Button {
                            createKind = .group
                        } label: {
                            Label("新建协作群聊", systemImage: "person.3.fill")
                        }
                        Button {
                            createKind = .privateSpace
                        } label: {
                            Label("新建私密会话 (Face ID)", systemImage: "lock.shield.fill")
                        }
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.title3)
                    }
                    .help("新建智能体或协作群聊")
                }
            }
            .sheet(item: $createKind) { kind in
                CreateBotSheet(host: host, initialKind: kind)
            }
            .sheet(item: $editingBot) { target in
                EditBotSheet(bot: target, host: host)
            }
            .sheet(item: $profileBot) { target in
                BotProfileSheet(bot: target, host: host)
            }
        }
    }

    private func lastPreview(for bot: BotProfile, matching message: ChatMessageItem? = nil) -> String {
        if bot.isPrivate { return "私密会话 · 需验证面容或锁屏密码后查看" }
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
}

// MARK: - Tab 2: 智能体 (Agents & Groups Team Roster)

private enum RosterFilter: String, CaseIterable, Identifiable {
    case all = "全部"
    case core = "核心团队"
    case group = "协作群聊"
    case privateSpace = "私密空间"
    var id: String { rawValue }
}

public struct BotRosterTabView: View {
    @ObservedObject var host: LocalAgentHost
    @State private var filter: RosterFilter = .all
    @State private var searchText = ""
    @State private var createKind: CreateBotInitialKind?
    @State private var editingBot: BotProfile?
    @State private var profileBot: BotProfile?
    @State private var pendingDeleteBot: BotProfile?

    public init(host: LocalAgentHost) {
        self.host = host
    }

    private var filteredBots: [BotProfile] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return host.bots.filter { bot in
            let matchesFilter: Bool
            switch filter {
            case .all: matchesFilter = true
            case .core: matchesFilter = !bot.isGroup && !bot.isPrivate
            case .group: matchesFilter = bot.isGroup
            case .privateSpace: matchesFilter = bot.isPrivate
            }
            let matchesQuery = query.isEmpty
                || bot.name.localizedCaseInsensitiveContains(query)
                || bot.roleLabel.localizedCaseInsensitiveContains(query)
                || bot.model.localizedCaseInsensitiveContains(query)
            return matchesFilter && matchesQuery
        }
    }

    private var sections: [String] {
        Array(NSOrderedSet(array: filteredBots.map(\.section))) as? [String] ?? []
    }

    public var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("分类", selection: $filter) {
                        ForEach(RosterFilter.allCases) { item in
                            Text(item.rawValue).tag(item)
                        }
                    }
                    .pickerStyle(.segmented)
                }
                .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                .listRowBackground(Color.clear)

                if sections.isEmpty {
                    Section {
                        DSEmptyStateView(
                            icon: "person.2.slash",
                            title: "此分类下暂无智能体",
                            subtitle: "你可以点击右上角新建自定义智能体、协作群聊或私密会话。",
                            actionTitle: "新建智能体"
                        ) {
                            createKind = filter == .group ? .group : (filter == .privateSpace ? .privateSpace : .standard)
                        }
                    }
                    .listRowBackground(Color.clear)
                } else {
                    ForEach(sections, id: \.self) { sec in
                        Section(sec) {
                            ForEach(filteredBots.filter { $0.section == sec }) { bot in
                                NavigationLink {
                                    ChatView(bot: bot, host: host)
                                } label: {
                                    HStack(spacing: 12) {
                                        DSBotAvatar(
                                            initials: bot.name,
                                            color: DSTheme.botAvatarColor(bot),
                                            isPrivate: bot.isPrivate,
                                            size: 42
                                        )
                                        VStack(alignment: .leading, spacing: 4) {
                                            HStack(spacing: 6) {
                                                Text(bot.name)
                                                    .font(.headline)
                                                if bot.isMain {
                                                    DSStatusBadge("Main", color: DSTheme.brand)
                                                }
                                                if bot.redteamToolsEnabled && !bot.isPrivate {
                                                    DSStatusBadge("RedTeam", color: DSTheme.danger, icon: "shield.lefthalf.filled")
                                                }
                                            }
                                            Text(bot.roleLabel)
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                                .lineLimit(1)
                                            HStack(spacing: 6) {
                                                DSPresetBadge(
                                                    presetId: bot.agentPreset,
                                                    label: host.agentPresetName(bot.agentPreset)
                                                )
                                                DSStatusBadge(bot.permissionModeLabel, color: .secondary)
                                                Text(host.modelSelection(bot.model))
                                                    .font(.caption2.monospaced())
                                                    .foregroundStyle(.secondary)
                                                    .lineLimit(1)
                                            }
                                        }
                                        Spacer(minLength: 4)
                                    }
                                    .padding(.vertical, 3)
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
                                    if !bot.isPrivate {
                                        Button("档案") {
                                            profileBot = bot
                                        }
                                        .tint(.indigo)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .searchable(text: $searchText, prompt: "按名称、职责或模型筛选")
            .navigationTitle("智能体团队")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            createKind = .standard
                        } label: {
                            Label("新建智能体", systemImage: "person.badge.plus")
                        }
                        Button {
                            createKind = .group
                        } label: {
                            Label("新建协作群聊", systemImage: "person.3.fill")
                        }
                        Button {
                            createKind = .privateSpace
                        } label: {
                            Label("新建私密会话 (Face ID)", systemImage: "lock.shield.fill")
                        }
                    } label: {
                        Label("新建", systemImage: "plus.circle.fill")
                    }
                }
            }
            .sheet(item: $createKind) { kind in
                CreateBotSheet(host: host, initialKind: kind)
            }
            .sheet(item: $editingBot) { target in
                EditBotSheet(bot: target, host: host)
            }
            .sheet(item: $profileBot) { target in
                BotProfileSheet(bot: target, host: host)
            }
            .confirmationDialog(
                "确定删除「\(pendingDeleteBot?.name ?? "")」及其全部聊天记录？",
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

// MARK: - Tab 3: 工作台 (Workbench & Sandboxed Tools Hub)

public struct ToolsHubTabView: View {
    @ObservedObject var host: LocalAgentHost
    @ObservedObject private var memoryGovernor = MemoryGovernor.shared
    @ObservedObject private var budgetGovernor = CostBudgetGovernor.shared

    public init(host: LocalAgentHost) {
        self.host = host
    }

    public var body: some View {
        NavigationStack {
            List {
                // Hero Section: Embedded DSH Web Workbench + Real-time Metrics
                Section {
                    NavigationLink {
                        DSHWebUIView(host: host)
                    } label: {
                        HStack(spacing: 14) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .fill(DSTheme.brand.gradient)
                                    .frame(width: 48, height: 48)
                                Image(systemName: "macwindow.on.rectangle")
                                    .font(.title3.weight(.semibold))
                                    .foregroundStyle(.white)
                            }
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 6) {
                                    Text("打开 DSH Web 工作台")
                                        .font(.headline)
                                    DSStatusBadge("Loopback", color: DSTheme.brand)
                                }
                                Text("内嵌官方 Web UI、会话 ZIP/Markdown 导出与社区 dsh-client-ui-* 插件")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }
                        .padding(.vertical, 6)
                    }
                }

                Section {
                    let memMB = memoryGovernor.snapshot.physFootprintMB
                    let memText = memMB > 0
                        ? String(format: "%.0f MB · %@", memMB, memoryGovernor.tier.displayName)
                        : host.appVersion
                    let spendText = CostDisplayState.exact(budgetGovernor.todayEstimatedSpendUSD).formattedLabel
                    WidgetBlueprintCardView(
                        title: "端侧运行态势（实时）",
                        metrics: [
                            WidgetMetricItem(label: "端侧内存", value: memText),
                            WidgetMetricItem(label: "今日花费", value: spendText),
                            WidgetMetricItem(label: "智能体 / 群", value: "\(host.bots.count)"),
                            WidgetMetricItem(label: "待处理项", value: "\(host.pendingApprovals.count + host.pendingDSHQuestions.count)")
                        ]
                    )
                }
                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 6, trailing: 16))
                .listRowBackground(Color.clear)

                Section("开发者沙盒工具（桌面级适配）") {
                    NavigationLink {
                        VirtualTerminalFeatureView(host: host)
                    } label: {
                        toolRow(
                            icon: "terminal.fill",
                            color: .teal,
                            title: "沙盒虚拟终端 (PTY)",
                            subtitle: "在 /workspace 安全执行 shell、node、python 与目录巡检"
                        )
                    }

                    NavigationLink {
                        GitWorktreeTrackerView(host: host)
                    } label: {
                        toolRow(
                            icon: "arrow.triangle.branch",
                            color: .indigo,
                            title: "Git 工作树与 PR 追踪",
                            subtitle: "查看本地变更 Diff、快照提交与 GitHub Pull Requests"
                        )
                    }

                    NavigationLink {
                        BackendDevToolsInspectorView(host: host)
                    } label: {
                        toolRow(
                            icon: "wrench.and.screwdriver.fill",
                            color: .blue,
                            title: "后端 DevTools 与 Jetsam 遥测",
                            subtitle: "查看 Node/V8/Jetsam 内存水位、Cordis Fiber 树与 REPL 控制台"
                        )
                    }
                }

                Section("任务与沙盒执行") {
                    NavigationLink {
                        JobsBotPickerView(host: host)
                    } label: {
                        toolRow(
                            icon: "hourglass",
                            color: .purple,
                            title: "后台任务 (DSH Jobs)",
                            subtitle: "按 Bot 查看离线 Python/NumPy 计算任务、流式输出与取消控制"
                        )
                    }

                    NavigationLink {
                        ScheduleBotPickerView(host: host)
                    } label: {
                        toolRow(
                            icon: "calendar.badge.clock",
                            color: .orange,
                            title: "定时任务 (DSH Schedule)",
                            subtitle: "按 Bot 查看、编辑 RRULE 规则、暂停恢复与投递回执"
                        )
                    }

                    NavigationLink {
                        JSSandboxPlaygroundView(host: host)
                    } label: {
                        toolRow(
                            icon: "chevron.left.forwardslash.chevron.right",
                            color: DSTheme.success,
                            title: "端侧 QuickJS 沙盒与设备探针",
                            subtitle: "免 JIT 离线运行脚本，探测本机电量与温控状态"
                        )
                    }
                }

                Section("知识、文件与技能资产") {
                    NavigationLink {
                        MemoryVaultView(host: host, botId: "main", allowsSwitchingBot: true)
                    } label: {
                        toolRow(
                            icon: "brain.head.profile",
                            color: .purple,
                            title: "智能体记忆中心",
                            subtitle: "按 Bot 切换管理常驻/本机记忆、一键撤销及旧记忆认领"
                        )
                    }

                    NavigationLink {
                        WorkspaceFilesView(host: host)
                    } label: {
                        toolRow(
                            icon: "folder.fill",
                            color: .orange,
                            title: "沙盒工作区文件 (files/)",
                            subtitle: "管理智能体可安全读写的本地文档、代码片段与导入附件"
                        )
                    }

                    NavigationLink {
                        SkillsManagerView(host: host)
                    } label: {
                        toolRow(
                            icon: "wand.and.stars",
                            color: .pink,
                            title: "Skill 技能管理 (SKILL.md)",
                            subtitle: "新建与编辑本机 DSH 技能，对话中自动发现并调用"
                        )
                    }
                }

                Section("连接器生态与用量观测") {
                    NavigationLink {
                        ConnectorMarketplaceView(host: host)
                    } label: {
                        toolRow(
                            icon: "puzzlepiece.extension.fill",
                            color: .indigo,
                            title: "Remote MCP 连接器市场",
                            subtitle: "38 个官方 MCP 目录（GitHub / Notion / Exa 等）与自定义接入"
                        )
                    }

                    NavigationLink {
                        ConnectorsAndUsageView(host: host)
                    } label: {
                        toolRow(
                            icon: "chart.bar.xaxis",
                            color: DSTheme.brand,
                            title: "多维 Token 用量与缓存看板",
                            subtitle: "按 7 天、按 Bot、按模型统计 DSH 真实调用与缓存命中"
                        )
                    }
                }

                Section("DSH Agent 模式与审批说明") {
                    Label("任意会话中途均可无损热切换 5 种模式与 3 档审批", systemImage: "slider.horizontal.3")
                        .font(.subheadline.weight(.medium))
                    Text("• 标准模式：工作区读写/补丁/搜索、Skill、计划、提问、待办、Schedule 与 Jobs。\n• 创造模式：额外挂载只读 Cordis API 检查器，适合插件研发。\n• PTC 开发模式：在离线 Pyodide Worker 中运行经源码审批的 Python/NumPy 程序并编排受控工具。\n• 轻量模式：仅只读文件与轻量对话，节省上下文与开销。\n• 红队演练模式：已安装并授权 dsh-purge-safe 后按三档审批可控挂载。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("工作台")
        }
    }

    private func toolRow(icon: String, color: Color, title: String, subtitle: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundColor(color)
                .frame(width: 36, height: 36)
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

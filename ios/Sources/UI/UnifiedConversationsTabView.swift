import SwiftUI
import UniformTypeIdentifiers
#if canImport(UIKit)
import UIKit
#endif

public typealias SessionsTabView = UnifiedConversationsTabView
public typealias BotRosterTabView = UnifiedConversationsTabView

private enum ConversationFilter: String, CaseIterable, Identifiable {
    case recent = "最近"
    case teams = "团队"
    case groups = "群聊"
    case privateSpace = "私密"
    case webSessions = "Web"

    var id: String { rawValue }
}

private struct ConversationNavTarget: Identifiable {
    let bot: BotProfile
    let address: SessionAddress
    var id: String { address.canonicalSessionId }
}

/// Unified Tab 1 ("对话"): merges recent sessions, team roster, multi-thread management,
/// external conversation import, and standalone Web Workbench sessions into a single cohesive hub.
public struct UnifiedConversationsTabView: View {
    @ObservedObject var host: LocalAgentHost
    @ObservedObject private var threadStore = BotThreadStore.shared

    @State private var filter: ConversationFilter = .recent
    @State private var searchText = ""
    @State private var showInbox = false
    @State private var createKind: CreateBotInitialKind?
    @State private var editingBot: BotProfile?
    @State private var profileBot: BotProfile?
    @State private var threadsBot: BotProfile?
    @State private var pendingDeleteBot: BotProfile?
    @State private var showDeleteConfirm = false
    @State private var navigatedTarget: ConversationNavTarget?
    @State private var showNavigatedChat = false
    @State private var webSessionToOpen: String?
    @State private var showWebSession = false
    @State private var importBanner: String?

    public init(host: LocalAgentHost) {
        self.host = host
    }

    private var pendingCount: Int {
        host.pendingApprovals.count + host.pendingDSHQuestions.count
    }

    private func pendingCount(for botId: String) -> Int {
        let approvalCount = host.pendingApprovals.filter {
            host.resolveAddress($0.sessionId)?.botID == botId
        }.count
        let questionCount = host.pendingDSHQuestions.filter {
            host.resolveAddress($0.sessionId)?.botID == botId
        }.count
        return approvalCount + questionCount
    }

    private func lastActivityDate(for botId: String) -> Date {
        let activeId = threadStore.activeSessionId(for: botId)
        let activeDate = host.sessionActivityDate(for: activeId)
        let rootDate = host.sessionActivityDate(for: botId)
        switch (activeDate, rootDate) {
        case let (a?, b?): return max(a, b)
        case let (a?, nil): return a
        case let (nil, b?): return b
        case (nil, nil): return .distantPast
        }
    }

    private var filteredBots: [BotProfile] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let base: [BotProfile]
        switch filter {
        case .recent:
            base = host.bots.sorted { lhs, rhs in
                let lhsPending = pendingCount(for: lhs.id)
                let rhsPending = pendingCount(for: rhs.id)
                if lhsPending != rhsPending { return lhsPending > rhsPending }
                let lhsStreaming = host.isBotStreaming(lhs.id)
                let rhsStreaming = host.isBotStreaming(rhs.id)
                if lhsStreaming != rhsStreaming { return lhsStreaming }
                let lhsDate = lastActivityDate(for: lhs.id)
                let rhsDate = lastActivityDate(for: rhs.id)
                if lhsDate != rhsDate { return lhsDate > rhsDate }
                if lhs.isMain != rhs.isMain { return lhs.isMain }
                return lhs.name < rhs.name
            }
        case .teams:
            base = host.bots
        case .groups:
            base = host.bots.filter(\.isGroup)
        case .privateSpace:
            base = host.bots.filter(\.isPrivate)
        case .webSessions:
            base = []
        }
        guard !q.isEmpty else { return base }
        return base.filter {
            $0.name.localizedCaseInsensitiveContains(q)
                || $0.roleLabel.localizedCaseInsensitiveContains(q)
                || $0.model.localizedCaseInsensitiveContains(q)
                || $0.section.localizedCaseInsensitiveContains(q)
        }
    }

    private var groupedSections: [(title: String, bots: [BotProfile])] {
        let order = ["核心团队", "默认团队", "协作群聊", "私密空间"]
        var map: [String: [BotProfile]] = [:]
        for bot in filteredBots {
            let key = bot.isPrivate ? "私密空间" : (bot.isGroup ? "协作群聊" : (bot.section.isEmpty ? "默认团队" : bot.section))
            map[key, default: []].append(bot)
        }
        let sortedKeys = map.keys.sorted { lhs, rhs in
            let li = order.firstIndex(of: lhs) ?? Int.max
            let ri = order.firstIndex(of: rhs) ?? Int.max
            if li != ri { return li < ri }
            return lhs < rhs
        }
        return sortedKeys.compactMap { key in
            guard let list = map[key], !list.isEmpty else { return nil }
            return (title: key, bots: list)
        }
    }

    private var filteredWebSessions: [WebSessionSummary] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return host.webStandaloneSessions }
        return host.webStandaloneSessions.filter {
            $0.sessionId.localizedCaseInsensitiveContains(q)
                || $0.lastMessagePreview.localizedCaseInsensitiveContains(q)
        }
    }

    private var showRuntimeBanner: Bool {
        host.state != .ready || host.isDSHRecoveryMode || host.workspaceError != nil
    }

    private func previewText(for bot: BotProfile) -> String {
        if bot.isPrivate { return "私密会话 · 需要 Face ID / 密码解锁" }
        let activeAddr = threadStore.activeAddress(for: bot.id)
        if host.isSessionStreaming(activeAddr.canonicalSessionId) || host.isBotStreaming(bot.id) {
            return "正在生成回复…"
        }
        if let last = host.sessionPreview(for: activeAddr.canonicalSessionId), !last.isEmpty {
            return last
        }
        if let rootLast = host.sessionPreview(for: bot.id), !rootLast.isEmpty {
            return rootLast
        }
        return bot.roleLabel
    }

    private func shortModelLabel(_ model: String) -> String {
        switch model {
        case ModelProvider.defaultModel: return "Flash"
        case ModelProvider.thinkingModel: return "Thinking"
        case "deepseek-v4-pro": return "V4 Pro"
        default:
            let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.count > 16 { return String(trimmed.prefix(15)) + "…" }
            return trimmed.isEmpty ? "默认模型" : trimmed
        }
    }

    public var body: some View {
        NavigationStack {
            conversationList
                .listStyle(.insetGrouped)
                .searchable(text: $searchText, prompt: "搜索智能体、职责、模型或 Web 会话")
                .refreshable {
                    await host.refreshSessionSummaries()
                }
                .navigationTitle("对话")
                .navigationDestination(isPresented: $showNavigatedChat) {
                    if let target = navigatedTarget {
                        ChatView(bot: target.bot, host: host, initialAddress: target.address)
                    }
                }
                .toolbar { toolbarContent }
                .sheet(isPresented: $showInbox) {
                    SessionInboxView(host: host)
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
                .sheet(item: $threadsBot) { target in
                    BotThreadsSheet(
                        bot: target,
                        threadStore: threadStore,
                        onSelectThread: { chosenThread in
                            threadsBot = nil
                            navigatedTarget = ConversationNavTarget(bot: target, address: chosenThread.address)
                            showNavigatedChat = true
                        },
                        onDeleteSession: { sessionId in
                            Task { await host.clearSession(sessionId) }
                        }
                    )
                }
                .fullScreenCover(isPresented: $showWebSession) {
                    if let sid = webSessionToOpen {
                        DSHWebUIView(host: host, initialSessionId: sid)
                    }
                }
                .confirmationDialog(
                    "确定删除「\(pendingDeleteBot?.name ?? "")」及其全部聊天记录？",
                    isPresented: $showDeleteConfirm,
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

    @ViewBuilder
    private var conversationList: some View {
        List {
            if showRuntimeBanner {
                Section {
                    DSRuntimeStatusBanner(host: host)
                }
                .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                .listRowBackground(Color.clear)
            }

            if let importBanner {
                Section {
                    DSBannerCard(
                        icon: "square.and.arrow.down.fill",
                        tint: DSTheme.brand,
                        message: importBanner,
                        actionTitle: "知道了"
                    ) {
                        self.importBanner = nil
                    }
                }
                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                .listRowBackground(Color.clear)
            }

            if pendingCount > 0 {
                Section {
                    Button {
                        showInbox = true
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "bell.badge.fill")
                                .font(.title3)
                                .foregroundStyle(DSTheme.warning)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("有 \(pendingCount) 项待审批或智能体提问")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.primary)
                                Text("点击集中处理，避免阻塞正在执行的会话")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 4)
                    }
                }
            }

            filterChipsSection

            if filter == .webSessions {
                webSessionsSection
            } else if filter == .teams {
                if groupedSections.isEmpty {
                    emptyStateSection
                } else {
                    ForEach(groupedSections, id: \.title) { group in
                        Section(group.title) {
                            ForEach(group.bots) { bot in
                                botConversationRow(bot)
                            }
                        }
                    }
                }
            } else {
                Section(header: Text(sectionHeaderTitle)) {
                    if filteredBots.isEmpty {
                        emptyStateSection
                    } else {
                        ForEach(filteredBots) { bot in
                            botConversationRow(bot)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var filterChipsSection: some View {
        Section {
            Picker("筛选对话", selection: $filter) {
                ForEach(ConversationFilter.allCases) { item in
                    Text(item.rawValue).tag(item)
                }
            }
            .pickerStyle(.segmented)
        }
        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
        .listRowBackground(Color.clear)
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                showInbox = true
            } label: {
                Image(systemName: pendingCount > 0 ? "tray.full.fill" : "tray")
                    .foregroundStyle(pendingCount > 0 ? DSTheme.warning : .primary)
            }
            .accessibilityLabel("待处理收件箱")
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                if let mainBot = host.bots.first(where: \.isMain) ?? host.bots.first {
                    Button {
                        let thread = threadStore.createThread(for: mainBot.id)
                        navigatedTarget = ConversationNavTarget(bot: mainBot, address: thread.address)
                        showNavigatedChat = true
                        DSHaptics.impact(.light)
                    } label: {
                        Label("在「\(mainBot.name)」开启新话题", systemImage: "plus.bubble")
                    }
                }
                Button {
                    presentConversationImporter()
                } label: {
                    Label("导入外部对话 (JSON / Markdown)", systemImage: "square.and.arrow.down")
                }
                Divider()
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
            }
            .accessibilityLabel("新建或导入对话")
        }
    }

    private var sectionHeaderTitle: String {
        switch filter {
        case .recent:
            let streamingCount = host.activeStreamingSessionIds.count
            return streamingCount > 0 ? "最近对话（\(streamingCount) 个正在生成）" : "最近对话（\(filteredBots.count)）"
        case .groups: return "协作群聊（\(filteredBots.count)）"
        case .privateSpace: return "私密空间 · Face ID 保护（\(filteredBots.count)）"
        default: return "对话列表"
        }
    }

    @ViewBuilder
    private var emptyStateSection: some View {
        DSEmptyStateView(
            icon: filter == .privateSpace ? "lock.shield" : "bubble.left.and.bubble.right",
            title: searchText.isEmpty ? "暂无\(filter.rawValue)" : "未找到匹配对话",
            subtitle: searchText.isEmpty ? "点击右上角 + 创建智能体、协作群聊或导入外部对话。" : "尝试更换搜索关键词。"
        )
        .listRowBackground(Color.clear)
    }

    @ViewBuilder
    private var webSessionsSection: some View {
        Section {
            if filteredWebSessions.isEmpty {
                DSEmptyStateView(
                    icon: "globe",
                    title: "暂无独立的 Web 工作台会话",
                    subtitle: "在「工作台 → 打开 DSH Web 工作台」中直接创建的会话会显示在这里，点击可一键续聊。"
                )
                .listRowBackground(Color.clear)
            } else {
                ForEach(filteredWebSessions) { session in
                    Button {
                        webSessionToOpen = session.sessionId
                        showWebSession = true
                    } label: {
                        HStack(spacing: 12) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(DSTheme.brand.opacity(0.14))
                                    .frame(width: 40, height: 40)
                                Image(systemName: "macwindow")
                                    .foregroundStyle(DSTheme.brand)
                            }
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text(session.sessionId)
                                        .font(.subheadline.monospaced().weight(.semibold))
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                    Spacer()
                                    Text(session.lastActivityAt, style: .relative)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Text(session.lastMessagePreview.isEmpty ? "\(session.eventCount) 条事件记录" : session.lastMessagePreview)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }
                        .padding(.vertical, 3)
                    }
                    .buttonStyle(.plain)
                }
            }
        } header: {
            Text("Web 工作台独立会话（\(filteredWebSessions.count)）")
        } footer: {
            Text("私密空间会话已自动隔离，不会出现在 Web 会话列表中。")
        }
    }

    @ViewBuilder
    private func botConversationRow(_ bot: BotProfile) -> some View {
        let isBotStreaming = host.isBotStreaming(bot.id)
        let botPending = pendingCount(for: bot.id)
        let threads = threadStore.threads(for: bot.id)
        let activeAddr = threadStore.activeAddress(for: bot.id)
        let activeTitle = threadStore.threadTitle(for: activeAddr)

        NavigationLink {
            ChatView(bot: bot, host: host, initialAddress: activeAddr)
        } label: {
            HStack(spacing: 12) {
                ZStack(alignment: .bottomTrailing) {
                    DSBotAvatar(initials: bot.name, color: DSTheme.botAvatarColor(bot), size: 46)
                    if isBotStreaming {
                        Circle()
                            .fill(DSTheme.brand)
                            .frame(width: 12, height: 12)
                            .overlay(Circle().stroke(DSTheme.surfacePrimary, lineWidth: 2))
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(bot.name)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        if bot.isMain {
                            DSStatusBadge("主", color: DSTheme.brand)
                        } else if bot.isPrivate {
                            DSStatusBadge("私密", color: DSTheme.warning, icon: "lock.fill")
                        } else if bot.isGroup {
                            DSStatusBadge("群聊", color: DSTheme.success)
                        }
                        Spacer(minLength: 4)
                        if botPending > 0 {
                            DSStatusBadge("\(botPending) 待办", color: DSTheme.warning)
                        } else if isBotStreaming {
                            DSStatusBadge("运行中", color: DSTheme.brand)
                        } else if !bot.isPrivate {
                            let lastDate = lastActivityDate(for: bot.id)
                            if lastDate > .distantPast {
                                Text(lastDate, style: .relative)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    Text(previewText(for: bot))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    HStack(spacing: 6) {
                        Text(shortModelLabel(bot.model))
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color(.tertiarySystemFill))
                            .clipShape(Capsule())

                        if let profileId = bot.providerProfileId,
                           let profile = ProviderProfileStore.shared.profiles.first(where: { $0.id == profileId }) {
                            Text(profile.name)
                                .font(.caption2)
                                .foregroundStyle(.indigo)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.indigo.opacity(0.10))
                                .clipShape(Capsule())
                                .lineLimit(1)
                        }

                        if threads.count > 1 || activeTitle != nil {
                            Button {
                                threadsBot = bot
                            } label: {
                                HStack(spacing: 3) {
                                    Image(systemName: "text.bubble")
                                        .font(.system(size: 9))
                                    Text(threads.count > 1 ? "\(threads.count) 话题" : (activeTitle ?? "话题"))
                                        .font(.caption2.weight(.medium))
                                        .lineLimit(1)
                                    Image(systemName: "chevron.down")
                                        .font(.system(size: 8, weight: .bold))
                                }
                                .foregroundStyle(DSTheme.brand)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(DSTheme.brandSoft)
                                .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(.vertical, 3)
        }
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button {
                let thread = threadStore.createThread(for: bot.id)
                navigatedTarget = ConversationNavTarget(bot: bot, address: thread.address)
                showNavigatedChat = true
                DSHaptics.impact(.light)
            } label: {
                Label("新话题", systemImage: "plus.bubble")
            }
            .tint(DSTheme.brand)
        }
        .swipeActions(edge: .trailing) {
            if !bot.isMain {
                Button("删除", role: .destructive) {
                    pendingDeleteBot = bot
                    showDeleteConfirm = true
                }
            }
            Button("编辑") {
                editingBot = bot
            }
            .tint(DSTheme.brand)
            Button("话题") {
                threadsBot = bot
            }
            .tint(.indigo)
        }
        .contextMenu {
            if !bot.isPrivate {
                Button {
                    profileBot = bot
                } label: {
                    Label("查看档案与服务商", systemImage: "person.text.rectangle")
                }
            }
            Button {
                threadsBot = bot
            } label: {
                Label("管理子话题（\(threads.count)）", systemImage: "text.bubble")
            }
            Button {
                let thread = threadStore.createThread(for: bot.id)
                navigatedTarget = ConversationNavTarget(bot: bot, address: thread.address)
                showNavigatedChat = true
            } label: {
                Label("新建子话题", systemImage: "plus.bubble")
            }
            Button {
                editingBot = bot
            } label: {
                Label("编辑智能体", systemImage: "slider.horizontal.3")
            }
            if !bot.isMain {
                Divider()
                Button(role: .destructive) {
                    pendingDeleteBot = bot
                    showDeleteConfirm = true
                } label: {
                    Label("删除智能体", systemImage: "trash")
                }
            }
        }
    }

    private func presentConversationImporter() {
        #if canImport(UIKit)
        NativeDocumentPicker.present(contentTypes: [.json, .plainText, .text], allowsMultipleSelection: false) { urls in
            guard let url = urls.first else { return }
            do {
                let bot = try host.importConversation(from: url)
                importBanner = "已导入对话「\(bot.name)」，可直接点击进入继续追问。"
                DSHaptics.notify(.success)
            } catch {
                importBanner = "导入对话失败：\(error.localizedDescription)"
                DSHaptics.notify(.error)
            }
        }
        #endif
    }
}

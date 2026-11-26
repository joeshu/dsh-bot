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

private enum ConversationsActiveSheet: Identifiable {
    case create(CreateBotInitialKind)
    case edit(BotProfile)
    case profile(BotProfile)
    case threads(BotProfile)
    case threadChat(BotProfile, SessionAddress)

    var id: String {
        switch self {
        case .create(let kind): return "create:\(kind.id)"
        case .edit(let bot): return "edit:\(bot.id)"
        case .profile(let bot): return "profile:\(bot.id)"
        case .threads(let bot): return "threads:\(bot.id)"
        case .threadChat(_, let addr): return "chat:\(addr.canonicalSessionId)"
        }
    }
}

/// Unified Tab 1 ("对话"): merges recent sessions, team roster, multi-thread management,
/// external conversation import, and standalone Web Workbench sessions into a single cohesive hub.
public struct UnifiedConversationsTabView: View {
    @ObservedObject var host: LocalAgentHost
    @ObservedObject private var threadStore = BotThreadStore.shared

    @State private var filter: ConversationFilter = .recent
    @State private var searchText = ""
    @State private var showSearch = false
    @State private var activeSheet: ConversationsActiveSheet?
    @State private var pendingDeleteBot: BotProfile?
    @State private var showDeleteConfirm = false
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
        host.botMaxActivityDate(for: botId) ?? .distantPast
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
                .refreshable {
                    await host.refreshSessionSummaries()
                }
                .navigationTitle("对话")
                .toolbar { toolbarContent }
                .sheet(item: $activeSheet) { sheet in
                    switch sheet {
                    case .create(let kind):
                        CreateBotSheet(host: host, initialKind: kind)
                    case .edit(let target):
                        EditBotSheet(bot: target, host: host)
                    case .profile(let target):
                        BotProfileSheet(bot: target, host: host)
                    case .threads(let target):
                        BotThreadsSheet(
                            bot: target,
                            threadStore: threadStore,
                            onSelectThread: { chosenThread in
                                threadStore.selectThread(chosenThread)
                                DispatchQueue.main.async {
                                    activeSheet = .threadChat(target, chosenThread.address)
                                }
                            },
                            onDeleteSession: { sessionId in
                                Task { await host.clearSession(sessionId) }
                            }
                        )
                    case .threadChat(let bot, let address):
                        NavigationStack {
                            ChatView(bot: bot, host: host, initialAddress: address)
                                .toolbar {
                                    ToolbarItem(placement: .topBarLeading) {
                                        Button("完成") { activeSheet = nil }
                                    }
                                }
                        }
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
            Section {
                DSRuntimeStatusBanner(host: host)
            }
            .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
            .listRowBackground(Color.clear)

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
                    NavigationLink {
                        SessionInboxView(host: host)
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
                        }
                        .padding(.vertical, 4)
                    }
                }
            }

            if showSearch {
                Section {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.secondary)
                        TextField("搜索智能体、职责、模型或 Web 会话", text: $searchText)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        if !searchText.isEmpty {
                            Button {
                                searchText = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            let trimmedQuery = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            if filter == .webSessions {
                webSessionsSection
            } else if filter == .teams || !host.unifiedNavigationV2 {
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
                Section(sectionHeaderTitle) {
                    if filteredBots.isEmpty {
                        emptyStateSection
                    } else {
                        ForEach(filteredBots) { bot in
                            botConversationRow(bot)
                        }
                    }
                }
            }

            if !trimmedQuery.isEmpty && filter != .privateSpace && filter != .webSessions {
                SessionSearchResults(host: host, query: trimmedQuery)
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Menu {
                ForEach(ConversationFilter.allCases) { item in
                    Button {
                        filter = item
                        DSHaptics.impact(.light)
                    } label: {
                        if filter == item {
                            Label(item.rawValue, systemImage: "checkmark")
                        } else {
                            Text(item.rawValue)
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(filter.rawValue)
                        .font(.subheadline.weight(.semibold))
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.bold))
                }
            }
            .accessibilityLabel("切换对话筛选视图")
        }

        ToolbarItemGroup(placement: .topBarTrailing) {
            Button {
                showSearch.toggle()
                if !showSearch { searchText = "" }
            } label: {
                Image(systemName: showSearch ? "magnifyingglass.circle.fill" : "magnifyingglass")
            }
            .accessibilityLabel("搜索对话")

            NavigationLink {
                SessionInboxView(host: host)
            } label: {
                Image(systemName: pendingCount > 0 ? "tray.full.fill" : "tray")
                    .foregroundStyle(pendingCount > 0 ? DSTheme.warning : .primary)
            }
            .accessibilityLabel("待处理收件箱")

            Menu {
                if let mainBot = host.bots.first(where: \.isMain) ?? host.bots.first {
                    Button {
                        let thread = threadStore.createThread(for: mainBot.id)
                        activeSheet = .threadChat(mainBot, thread.address)
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
                    activeSheet = .create(.standard)
                } label: {
                    Label("新建智能体", systemImage: "person.badge.plus")
                }
                Button {
                    activeSheet = .create(.group)
                } label: {
                    Label("新建协作群聊", systemImage: "person.3.fill")
                }
                Button {
                    activeSheet = .create(.privateSpace)
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
                    NavigationLink {
                        DSHWebUIView(host: host, initialSessionId: session.sessionId)
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
                                    Text(session.lastActivityAt.formatted(date: .omitted, time: .shortened))
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
            ChatView(bot: bot, host: host)
        } label: {
            HStack(spacing: 12) {
                ZStack(alignment: .bottomTrailing) {
                    DSBotAvatar(initials: bot.name, color: DSTheme.botAvatarColor(bot), isPrivate: bot.isPrivate, size: 46)
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
                                Text(lastDate.formatted(date: .omitted, time: .shortened))
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

                        if !bot.isPrivate && (threads.count > 1 || activeTitle != nil) {
                            Button {
                                activeSheet = .threads(bot)
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
        .swipeActions(edge: .leading, allowsFullSwipe: !bot.isPrivate) {
            if !bot.isPrivate {
                Button {
                    let thread = threadStore.createThread(for: bot.id)
                    activeSheet = .threadChat(bot, thread.address)
                    DSHaptics.impact(.light)
                } label: {
                    Label("新话题", systemImage: "plus.bubble")
                }
                .tint(DSTheme.brand)
            }
        }
        .swipeActions(edge: .trailing) {
            if !bot.isMain {
                Button("删除", role: .destructive) {
                    pendingDeleteBot = bot
                    showDeleteConfirm = true
                }
            }
            if !bot.isPrivate {
                Button("编辑") {
                    activeSheet = .edit(bot)
                }
                .tint(DSTheme.brand)
                Button("话题") {
                    activeSheet = .threads(bot)
                }
                .tint(.indigo)
            }
        }
        .contextMenu {
            if !bot.isPrivate {
                Button {
                    activeSheet = .profile(bot)
                } label: {
                    Label("查看档案与服务商", systemImage: "person.text.rectangle")
                }
                Button {
                    activeSheet = .threads(bot)
                } label: {
                    Label("管理子话题（\(threads.count)）", systemImage: "text.bubble")
                }
                Button {
                    let thread = threadStore.createThread(for: bot.id)
                    activeSheet = .threadChat(bot, thread.address)
                } label: {
                    Label("新建子话题", systemImage: "plus.bubble")
                }
                Button {
                    activeSheet = .edit(bot)
                } label: {
                    Label("编辑智能体", systemImage: "slider.horizontal.3")
                }
            }
            if !bot.isMain {
                if !bot.isPrivate { Divider() }
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

import SwiftUI
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

    private var filteredBots: [BotProfile] {
        guard !searchText.isEmpty else { return host.bots }
        return host.bots.filter { bot in
            bot.name.localizedCaseInsensitiveContains(searchText)
            || bot.roleLabel.localizedCaseInsensitiveContains(searchText)
            || (!bot.isPrivate && host.messages(for: bot.id).contains { $0.content.localizedCaseInsensitiveContains(searchText) })
        }
    }

    public var body: some View {
        NavigationStack {
            List {
                Section {
                    agentStatusCard
                }
                .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                .listRowBackground(Color.clear)

                Section("最近会话") {
                    ForEach(filteredBots) { bot in
                        NavigationLink {
                            ChatView(bot: bot, host: host)
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
                                    Text(lastPreview(for: bot))
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                                VStack(alignment: .trailing, spacing: 3) {
                                    if !bot.isPrivate, let lastTs = host.messages(for: bot.id).last?.timestamp {
                                        Text(lastTs.formatted(date: .omitted, time: .shortened))
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
            .navigationTitle("会话")
            .searchable(text: $searchText, prompt: "搜索 Bot 或群聊")
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

    private func lastPreview(for bot: BotProfile) -> String {
        if bot.isPrivate { return "私密会话" }
        if let last = host.messages(for: bot.id).last {
            return last.content
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
                    Text("Swift 原生引擎")
                        .font(.subheadline.weight(.semibold))
                    DSStatusBadge(statusBadge, color: statusColor)
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
                                        host.deleteBot(id: bot.id)
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
                        JSSandboxPlaygroundView(host: host)
                    } label: {
                        toolRow(icon: "chevron.left.forwardslash.chevron.right", color: DSTheme.success, title: "端侧 JS 沙盒与设备探针", subtitle: "离线执行脚本并查看本机电量和温控")
                    }
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

public struct ChatView: View {
    let bot: BotProfile
    @ObservedObject var host: LocalAgentHost
    @State private var input = ""
    @State private var selectedModel: String
    @State private var showSideChat = false
    @State private var showGroupWorkspace = false
    @State private var activeSectionTitle = ""
    @State private var isPrivateUnlocked = false
    @State private var showClearConfirm = false
    @State private var showEditBot = false
    @State private var showMemory = false
    @State private var actionStatus = ""
    @State private var lastScrollAt = Date.distantPast
    @State private var expandStreamingReasoning = true
    @Environment(\.scenePhase) private var chatScenePhase

    @MainActor
    public init(bot: BotProfile, host: LocalAgentHost) {
        self.bot = bot
        self.host = host
        _selectedModel = State(initialValue: host.modelSelection(bot.model))
    }

    private var liveBot: BotProfile {
        host.bots.first(where: { $0.id == bot.id }) ?? bot
    }

    private var isLocked: Bool { liveBot.isPrivate && !isPrivateUnlocked }

    private var sessionMessages: [ChatMessageItem] {
        isLocked ? [] : host.messages(for: liveBot.id)
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
                    Menu {
                        if host.usesOfficialModels || !host.models.isEmpty {
                            ModelSelectionView(host: host, model: $selectedModel, allowsTyping: false)
                        }
                        Button("侧边对话 (/side)") { showSideChat = true }
                        if liveBot.isGroup { Button("群目标与待办") { showGroupWorkspace = true } }
                        if liveBot.isPrivate { Button("锁定私密会话") { lockPrivateConversation() } }
                        ShareLink(item: host.exportSessionMarkdown(sessionId: liveBot.id, botName: liveBot.name)) {
                            Label("导出会话为 Markdown", systemImage: "square.and.arrow.up")
                        }
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
        .sheet(isPresented: $showSideChat) {
            if !isLocked { SideChatSheet(host: host, model: selectedModel) }
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
    }

    private func lockPrivateConversation() {
        isPrivateUnlocked = false
        showSideChat = false
        showGroupWorkspace = false
        showEditBot = false
        showMemory = false
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

                            if sessionMessages.isEmpty && !host.isStreaming {
                                emptyWelcomeView
                            }

                            ForEach(sessionMessages) { msg in
                                messageRow(msg).id(msg.id)
                            }

                            if host.isStreaming && host.streamingSessionId == bot.id {
                                streamingRow
                            }

                            ForEach(host.pendingApprovals.filter { $0.sessionId == bot.id }) { approval in
                                approvalCard(approval)
                            }

                            Color.clear.frame(height: 1).id("chat_bottom")
                        }
                        .padding()
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .onChange(of: sessionMessages.count) { _ in
                        withAnimation { proxy.scrollTo("chat_bottom", anchor: .bottom) }
                    }
                    .onChange(of: host.streamingContent.count) { _ in
                        let now = Date()
                        if now.timeIntervalSince(lastScrollAt) >= 0.12 {
                            lastScrollAt = now
                            proxy.scrollTo("chat_bottom", anchor: .bottom)
                        }
                    }
                    .onChange(of: host.streamingReasoning.count) { _ in
                        let now = Date()
                        if now.timeIntervalSince(lastScrollAt) >= 0.12 {
                            lastScrollAt = now
                            proxy.scrollTo("chat_bottom", anchor: .bottom)
                        }
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
                initials: bot.name,
                color: bot.isMain ? DSTheme.brand : (bot.isGroup ? .indigo : (bot.isPrivate ? DSTheme.warning : .teal)),
                isPrivate: bot.isPrivate,
                size: 56
            )
            Text(liveBot.name).font(.title3.weight(.semibold))
            Text(bot.roleLabel).font(.caption).foregroundColor(.secondary)
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

            DSMarkdownText(msg.content)
                .contextMenu {
                    Button {
                        #if canImport(UIKit)
                        UIPasteboard.general.string = msg.content
                        #endif
                        DSHaptics.impact(.light)
                    } label: {
                        Label("复制全文", systemImage: "doc.on.doc")
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

    private func approvalCard(_ approval: PendingApproval) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "hand.raised.fill").foregroundColor(DSTheme.warning)
                Text("需要审批：\(approval.tool)").font(.subheadline.weight(.semibold))
            }
            Text(approval.summary).font(.caption).foregroundColor(.secondary).textSelection(.enabled)
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
            HStack(spacing: 8) {
                Menu {
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

                TextField("给 \(liveBot.name) 发消息（支持 /side、/goal）…", text: $input, axis: .vertical)
                    .lineLimit(1...4)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(DSTheme.surfaceSecondary)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

                if host.isStreaming && host.streamingSessionId == bot.id {
                    Button {
                        Task { await host.abortActiveTurn() }
                    } label: {
                        Image(systemName: "stop.circle.fill")
                            .font(.title2)
                            .foregroundColor(DSTheme.danger)
                    }
                } else {
                    Button {
                        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !text.isEmpty else { return }
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
                        input = ""
                        Task { await host.sendMessage(sessionId: bot.id, text: text, model: selectedModel) }
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title2)
                            .foregroundColor(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .secondary : DSTheme.brand)
                    }
                    .disabled(host.state != .ready || host.isStreaming || input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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

    var body: some View {
        NavigationStack {
            Form {
                Section("基本信息") {
                    TextField("名称（如 研报助手）", text: $name)
                    TextField("职责描述", text: $roleLabel)
                    ModelSelectionView(host: host, model: $model)
                }
                Section("系统提示词（可选）") {
                    TextEditor(text: $systemPrompt)
                        .frame(minHeight: 72)
                }
                Section("形态与隔离") {
                    Toggle("创建群会话与待办", isOn: $isGroup)
                        .onChange(of: isGroup) { v in if v { isPrivate = false } }
                    Toggle("锁定私密会话", isOn: $isPrivate)
                        .onChange(of: isPrivate) { v in if v { isGroup = false } }
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
                            isGroup: isGroup
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

    public var body: some View {
        NavigationStack {
            Form {
                Section("运行诊断") {
                    LabeledContent("应用", value: "\(host.appVersion) (\(host.buildNumber))")
                    LabeledContent("引擎", value: "Node.js + DSH 0.2.2-rc.5")
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
                }

                Section("模型服务") {
                    TextField("HTTPS Base URL", text: $host.apiBaseURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onChange(of: host.apiBaseURL) { _ in apiKey = ""; status = "" }
                    if !host.usesOfficialModels {
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

                Section("界面") {
                    Toggle("消息气泡布局", isOn: $host.useBubbleLayout)
                }
                if !status.isEmpty { Section { Text(status).font(.caption) } }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("设置")
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

    @MainActor
    init(bot: BotProfile, host: LocalAgentHost) {
        self.bot = bot
        self.host = host
        _name = State(initialValue: bot.name)
        _roleLabel = State(initialValue: bot.roleLabel)
        _model = State(initialValue: host.modelSelection(bot.model))
        _systemPrompt = State(initialValue: bot.systemPrompt)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Bot 信息") {
                    TextField("名称", text: $name)
                    TextField("职责描述", text: $roleLabel)
                    ModelSelectionView(host: host, model: $model)
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
                            systemPrompt: systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
                        )
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

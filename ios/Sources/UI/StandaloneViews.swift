import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Modern 5-Tab iOS architecture matching Apple HIG & DSH mobile ecosystem:
/// 1. 会话 (Chats)  2. Bot (Team)  3. 小工具 (Tools)  4. 探索 (Plugin Store)  5. 设置 (Kernel & Vault)
public struct MainTabView: View {
    @ObservedObject var host: BareWorkletHost

    public var body: some View {
        TabView {
            SessionsTabView(host: host)
                .tabItem { Label("会话", systemImage: "bubble.left.and.bubble.right") }

            BotRosterTabView(host: host)
                .tabItem { Label("Bot", systemImage: "face.smiling") }

            ToolsHubTabView(host: host)
                .tabItem { Label("小工具", systemImage: "square.grid.2x2") }

            PluginStoreView(host: host)
                .tabItem { Label("探索", systemImage: "safari") }

            KernelSettingsView(host: host)
                .tabItem { Label("设置", systemImage: "gearshape") }
        }
    }
}

// MARK: - Tab 1: 会话 (Sessions)

public struct SessionsTabView: View {
    @ObservedObject var host: BareWorkletHost
    @State private var searchText = ""
    @State private var showCreateSheet = false

    private var filteredBots: [BotProfile] {
        guard !searchText.isEmpty else { return host.bots }
        return host.bots.filter { bot in
            bot.name.localizedCaseInsensitiveContains(searchText)
            || bot.roleLabel.localizedCaseInsensitiveContains(searchText)
            || host.messages(for: bot.id).contains { $0.content.localizedCaseInsensitiveContains(searchText) }
        }
    }

    public var body: some View {
        NavigationStack {
            List {
                Section {
                    kernelStatusCard
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
                                    if let lastTs = host.messages(for: bot.id).last?.timestamp {
                                        Text(lastTs.formatted(date: .omitted, time: .shortened))
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                    }
                                    Text(bot.model == "deepseek-reasoner" ? "R1" : "V3")
                                        .font(.caption2.monospaced().weight(.semibold))
                                        .foregroundColor(.secondary)
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
        if let last = host.messages(for: bot.id).last {
            return last.content
        }
        return bot.roleLabel
    }

    private var kernelStatusCard: some View {
        HStack(spacing: 12) {
            Image(systemName: statusIcon)
                .font(.title2)
                .foregroundColor(statusColor)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("DSH \(host.activeVersion)")
                        .font(.subheadline.weight(.semibold))
                    DSStatusBadge(isBaselineBadge, color: statusColor)
                }
                Text(statusDescription)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
        .padding(14)
        .background(DSTheme.surfacePrimary)
        .clipShape(RoundedRectangle(cornerRadius: DSTheme.cornerCard, style: .continuous))
        .shadow(color: .black.opacity(0.04), radius: 6, y: 2)
    }

    private var isBaselineBadge: String {
        switch host.state {
        case .ready(_, let isBase): return isBase ? "基线核" : "热更核"
        case .rolledBack: return "已回滚"
        case .failed: return "异常"
        default: return "启动中"
        }
    }

    private var statusIcon: String {
        switch host.state {
        case .ready: return "cpu.fill"
        case .rolledBack: return "arrow.uturn.backward.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        default: return "clock.fill"
        }
    }

    private var statusColor: Color {
        switch host.state {
        case .ready: return DSTheme.success
        case .rolledBack: return DSTheme.warning
        case .failed: return DSTheme.danger
        default: return .secondary
        }
    }

    private var statusDescription: String {
        switch host.state {
        case .idle: return "独立端侧内核待命"
        case .booting(let v): return "正在初始化 DSH \(v)..."
        case .ready: return "独立 iOS 端侧就绪 · 零桌面依赖"
        case .rolledBack(let from, let to, _): return "已从 \(from) 自动回滚至 \(to)"
        case .failed(let msg): return msg
        }
    }
}

// MARK: - Tab 2: Bot (Grouped Team Roster)

public struct BotRosterTabView: View {
    @ObservedObject var host: BareWorkletHost
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
                                        Text(liveBot.roleLabel).font(.caption).foregroundColor(.secondary)
                                    }
                                    Spacer()
                                    DSStatusBadge(bot.model == "deepseek-reasoner" ? "深度思考" : "标准", color: .secondary)
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
    @ObservedObject var host: BareWorkletHost

    public var body: some View {
        NavigationStack {
            List {
                Section {
                    WidgetBlueprintCardView(
                        title: "端侧运行态势（实时）",
                        metrics: [
                            WidgetMetricItem(label: "DSH 内核", value: host.activeVersion),
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
                        toolRow(icon: "brain.head.profile", color: .purple, title: "四层记忆与撤销", subtitle: "常驻 / 增量 / 召回 / 按需 · journal.jsonl 单条逆操作撤销")
                    }

                    NavigationLink {
                        ConnectorsAndUsageView(host: host)
                    } label: {
                        toolRow(icon: "cable.connector", color: DSTheme.brand, title: "通用连接器与 Remote MCP", subtitle: "GitHub · 邮箱 · 远程 MCP · 凭据仅存 Keychain")
                    }

                    NavigationLink {
                        JSSandboxPlaygroundView(host: host)
                    } label: {
                        toolRow(icon: "chevron.left.forwardslash.chevron.right", color: DSTheme.success, title: "端侧 JS 沙盒与设备探针", subtitle: "离线运行 JavaScriptCore 脚本与读取本机电量/温控状态")
                    }
                }

                Section("端侧原生能力") {
                    toolRow(icon: "doc.text.magnifyingglass", color: .orange, title: "超长回复外置落盘", subtitle: "超过 20,000 字自动存为沙盒文件，保护 iOS 内存不闪退")
                    toolRow(icon: "lock.shield", color: DSTheme.warning, title: "隐私 Bot 隔离保护", subtitle: "禁入群、禁作 Main Bot、外发前强制 Face ID 与用户审批")
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
    @ObservedObject var host: BareWorkletHost
    @State private var input = ""
    @State private var selectedModel: String
    @State private var showSideChat = false
    @State private var showGroupWorkspace = false
    @State private var activeSectionTitle = ""
    @State private var isPrivateUnlocked = false
    @State private var showClearConfirm = false
    @State private var showEditBot = false
    @State private var lastScrollAt = Date.distantPast
    @State private var expandStreamingReasoning = true
    @Environment(\.scenePhase) private var chatScenePhase

    public init(bot: BotProfile, host: BareWorkletHost) {
        self.bot = bot
        self.host = host
        _selectedModel = State(initialValue: bot.model)
    }

    private var liveBot: BotProfile {
        host.bots.first(where: { $0.id == bot.id }) ?? bot
    }

    private var sessionMessages: [ChatMessageItem] {
        host.messages(for: liveBot.id)
    }

    private var latestHeadings: [MarkdownHeading] {
        guard !host.isStreaming else { return [] }
        let candidate = sessionMessages.last(where: { $0.role == "assistant" })?.content ?? ""
        return MarkdownOutlineParser.extractHeadings(from: candidate)
    }

    public var body: some View {
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
                                    message: "隐私 Bot 模式：独立记忆与沙盒目录，其他 Bot 不可读取，外发前需审批。"
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

                            ForEach(host.pendingApprovals.filter { $0.sessionId == bot.id || $0.sessionId == "main" }) { approval in
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
                    .onChange(of: chatScenePhase) { phase in
                        if phase == .background && bot.isPrivate {
                            isPrivateUnlocked = false
                        }
                    }

                    if let errMsg = host.lastStreamError, !host.isStreaming {
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
                if bot.isPrivate && !isPrivateUnlocked {
                    PrivateBotLockOverlay(botName: bot.name) {
                        isPrivateUnlocked = true
                    }
                }
            }
        }
        .navigationTitle(liveBot.name)
        .onChange(of: liveBot.model) { selectedModel = $0 }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Menu {
                    Picker("模型", selection: $selectedModel) {
                        Text("DeepSeek V3 (标准)").tag("deepseek-chat")
                        Text("DeepSeek R1 (深度思考)").tag("deepseek-reasoner")
                    }
                    Divider()
                    Button { showSideChat = true } label: {
                        Label("侧边对话 (/side)", systemImage: "bubble.left.and.exclamationmark.bubble.right")
                    }
                    Button { showGroupWorkspace = true } label: {
                        Label("群目标与待办", systemImage: "checklist")
                    }
                    if bot.isPrivate && isPrivateUnlocked {
                        Button {
                            isPrivateUnlocked = false
                            DSHaptics.impact(.medium)
                        } label: {
                            Label("立即锁定隐私 Bot", systemImage: "lock.fill")
                        }
                    }
                    ShareLink(item: host.exportSessionMarkdown(sessionId: liveBot.id, botName: liveBot.name)) {
                        Label("导出会话为 Markdown", systemImage: "square.and.arrow.up")
                    }
                    Button {
                        showEditBot = true
                    } label: {
                        Label("编辑 Bot 设置", systemImage: "slider.horizontal.3")
                    }
                    Button(role: .destructive) {
                        showClearConfirm = true
                    } label: {
                        Label("清空当前会话", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .sheet(isPresented: $showSideChat) {
            SideChatSheet(host: host, parentSessionId: bot.id)
        }
        .sheet(isPresented: $showGroupWorkspace) {
            GroupWorkspaceSheet(host: host, groupId: bot.id)
        }
        .sheet(isPresented: $showEditBot) {
            EditBotSheet(bot: liveBot, host: host)
        }
        .confirmationDialog("确定清空「\(liveBot.name)」的全部聊天记录？", isPresented: $showClearConfirm, titleVisibility: .visible) {
            Button("清空记录", role: .destructive) {
                host.clearSession(bot.id)
                DSHaptics.notify(.warning)
            }
            Button("取消", role: .cancel) {}
        }
    }

    private var starterPrompts: [String] {
        if bot.isGroup {
            return ["先对齐本次群目标并拆解阶段", "查看当前群待办清单", "@Architect 帮我审查最新架构"]
        } else if bot.isPrivate {
            return ["帮我整理一份私密备忘并存入常驻记忆", "总结这段敏感文本的要点"]
        }
        return ["用端侧 JS 沙盒计算 10 万年化 6% 复利 5 年", "查看当前 iPhone 设备状态", "介绍一下内置 DSH 0.2.2-rc.5 的能力"]
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
                        Task { _ = try? await host.rpc()?.request("device.speak", params: ["text": msg.content]) }
                        DSHaptics.impact(.soft)
                    } label: {
                        Label("朗读回复", systemImage: "speaker.wave.2")
                    }
                    Button {
                        Task {
                            _ = try? await host.rpc()?.request("memory.add", params: [
                                "botId": bot.id,
                                "title": String(msg.content.prefix(24)),
                                "content": msg.content,
                                "layer": "pinned"
                            ])
                            DSHaptics.notify(.success)
                        }
                    } label: {
                        Label("存入常驻记忆", systemImage: "brain.head.profile")
                    }
                    if !isUser && !host.isStreaming {
                        Button {
                            Task { await host.regenerateLastReply(sessionId: bot.id, model: selectedModel) }
                        } label: {
                            Label("重新生成回复", systemImage: "arrow.clockwise")
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
            Text(approval.summary).font(.caption).foregroundColor(.secondary)
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
                    Button { showGroupWorkspace = true } label: { Label("/goal 群目标与待办", systemImage: "target") }
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
                        if text == "/goal" {
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
                    .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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
    @ObservedObject var host: BareWorkletHost
    @State private var name = ""
    @State private var roleLabel = ""
    @State private var model = "deepseek-chat"
    @State private var systemPrompt = ""
    @State private var isPrivate = false
    @State private var isGroup = false

    var body: some View {
        NavigationStack {
            Form {
                Section("基本信息") {
                    TextField("名称（如 研报助手）", text: $name)
                    TextField("职责描述", text: $roleLabel)
                    Picker("默认模型", selection: $model) {
                        Text("DeepSeek V3").tag("deepseek-chat")
                        Text("DeepSeek R1 深度思考").tag("deepseek-reasoner")
                    }
                }
                Section("系统提示词（可选）") {
                    TextEditor(text: $systemPrompt)
                        .frame(minHeight: 72)
                }
                Section("形态与隔离") {
                    Toggle("创建为多 Bot 协作群聊", isOn: $isGroup)
                        .onChange(of: isGroup) { v in if v { isPrivate = false } }
                    Toggle("开启隐私 Bot（隔离且不可进群）", isOn: $isPrivate)
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

// MARK: - Tab 5: 设置 (DSH 0.2.2-rc.5 Kernel, Hot-Swap, Keychain Vault & Layout)

public struct KernelSettingsView: View {
    @ObservedObject var host: BareWorkletHost
    @State private var apiKey = ""
    @State private var manifestURLText = ""
    @State private var statusBanner = ""
    @State private var showResetConfirm = false

    public var body: some View {
        NavigationStack {
            Form {
                Section("内置 DSH 内核") {
                    LabeledContent("基线版本", value: KernelManager.baselineVersion)
                    LabeledContent("当前激活", value: host.activeVersion)
                    LabeledContent("IPC 协议", value: IPCFrameCodec.protocolVersion)
                    Button("复制内核诊断 JSON") {
                        Task {
                            if let diag = try? await host.rpc()?.request("kernel.diagnostics"),
                               let data = try? JSONSerialization.data(withJSONObject: diag, options: [.prettyPrinted, .sortedKeys]),
                               let str = String(data: data, encoding: .utf8) {
                                #if canImport(UIKit)
                                UIPasteboard.general.string = str
                                #endif
                                statusBanner = "已复制内核诊断 JSON 至剪贴板。"
                                DSHaptics.notify(.success)
                            }
                        }
                    }
                    Button("重置回基线内核 (\(KernelManager.baselineVersion))", role: .destructive) {
                        showResetConfirm = true
                    }
                }

                Section("免重签热更新 DSH 内核") {
                    TextField("https://.../kernel-manifest.json", text: $manifestURLText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("拉取校验 SHA-256 并热切换") {
                        guard let url = URL(string: manifestURLText.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                            statusBanner = "请输入有效的 HTTPS manifest 地址。"
                            return
                        }
                        Task {
                            do {
                                let installed = try await host.kernelManager.downloadAndInstallHotSwap(manifestURL: url)
                                statusBanner = "已校验并切换至 DSH \(installed.dshVersion)。"
                                DSHaptics.notify(.success)
                                await host.boot { _ in LocalAgentTransport(dshVersion: installed.dshVersion) }
                            } catch {
                                statusBanner = error.localizedDescription
                                DSHaptics.notify(.error)
                            }
                        }
                    }
                }

                Section("模型接入（DeepSeek / OpenAI 兼容）") {
                    TextField("Base URL (默认 https://api.deepseek.com)", text: $host.apiBaseURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("API Key (sk-...)", text: $apiKey)
                    Button("安全保存至 Keychain") {
                        let vault = KeychainBridge()
                        do {
                            _ = try vault.setSecret(account: "deepseek_api_key", value: apiKey.trimmingCharacters(in: .whitespacesAndNewlines))
                            statusBanner = "API Key 已安全写入 iOS Keychain，返回「会话」即可直连流式对话。"
                            apiKey = ""
                            DSHaptics.notify(.success)
                        } catch {
                            statusBanner = error.localizedDescription
                        }
                    }
                    .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("测试 API 连通性与延迟") {
                        statusBanner = "正在测试模型服务连通性..."
                        Task {
                            if let res = try? await host.rpc()?.request("models.test", params: ["apiBaseURL": host.apiBaseURL]) {
                                if (res["ok"] as? Bool) == true {
                                    let ms = res["latencyMs"] as? Int ?? 0
                                    let cnt = res["modelCount"] as? Int ?? 0
                                    statusBanner = "连接正常（延迟 \(ms) ms，可用模型 \(cnt) 个）。"
                                    DSHaptics.notify(.success)
                                } else {
                                    statusBanner = "连通性测试失败：\(res["error"] as? String ?? "未知错误")"
                                    DSHaptics.notify(.error)
                                }
                            }
                        }
                    }
                }

                Section("界面与布局") {
                    Toggle("消息气泡布局（关闭则平铺展示）", isOn: $host.useBubbleLayout)
                }

                if !statusBanner.isEmpty {
                    Section("操作状态") {
                        Text(statusBanner)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("设置")
            .confirmationDialog("重置回内置基线内核 \(KernelManager.baselineVersion)？", isPresented: $showResetConfirm, titleVisibility: .visible) {
                Button("确认重置", role: .destructive) {
                    host.kernelManager.resetToBaseline()
                    statusBanner = "已重置为内置基线内核 \(KernelManager.baselineVersion)。"
                    DSHaptics.notify(.warning)
                    Task { await host.boot { _ in LocalAgentTransport(dshVersion: KernelManager.baselineVersion) } }
                }
                Button("取消", role: .cancel) {}
            }
        }
    }
}


// MARK: - Edit Bot Sheet

private struct EditBotSheet: View {
    @Environment(\.dismiss) private var dismiss
    let bot: BotProfile
    @ObservedObject var host: BareWorkletHost
    @State private var name: String
    @State private var roleLabel: String
    @State private var model: String
    @State private var systemPrompt: String

    init(bot: BotProfile, host: BareWorkletHost) {
        self.bot = bot
        self.host = host
        _name = State(initialValue: bot.name)
        _roleLabel = State(initialValue: bot.roleLabel)
        _model = State(initialValue: bot.model)
        _systemPrompt = State(initialValue: bot.systemPrompt)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Bot 信息") {
                    TextField("名称", text: $name)
                    TextField("职责描述", text: $roleLabel)
                    Picker("默认模型", selection: $model) {
                        Text("DeepSeek V3").tag("deepseek-chat")
                        Text("DeepSeek R1 深度思考").tag("deepseek-reasoner")
                    }
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

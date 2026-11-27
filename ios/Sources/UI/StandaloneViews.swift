import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

private enum AppTab: Hashable {
    case conversations
    case workbench
    case settings
}

private struct PulseOpenTarget: Identifiable {
    let bot: BotProfile
    let address: SessionAddress
    var id: String { address.canonicalSessionId }
}

/// Native 3-Tab Agent Navigation (对话 / 工作台 / 设置)
/// with iPadOS adaptive sidebar (iOS 18+) and iOS 26 Liquid Glass progressive enhancement.
public struct MainTabView: View {
    @ObservedObject var host: LocalAgentHost
    @State private var selectedTab: AppTab = .conversations
    @State private var dismissedPulseTurnId: String?
    @State private var pulseOpenTarget: PulseOpenTarget?

    public init(host: LocalAgentHost) {
        self.host = host
    }

    private var pendingInboxCount: Int {
        host.pendingApprovals.count + host.pendingDSHQuestions.count
    }

    private var pulseSessionId: String? {
        host.streamingSessionId ?? host.pendingApprovals.first?.sessionId
    }

    private var activePulseTarget: PulseOpenTarget? {
        guard let sid = pulseSessionId,
              let address = host.resolveAddress(sid),
              let bot = host.bot(for: address) else { return nil }
        return PulseOpenTarget(bot: bot, address: address)
    }

    private var showPulseBar: Bool {
        guard let sid = pulseSessionId else { return false }
        if host.visibleChatSessionId != nil { return false }
        if let activeTurn = host.activeTurnId, dismissedPulseTurnId == activeTurn, host.pendingApprovals.isEmpty {
            return false
        }
        return host.isStreaming || !host.pendingApprovals.isEmpty
    }

    @ViewBuilder
    private var rootTabView: some View {
        let base = TabView(selection: $selectedTab) {
            UnifiedConversationsTabView(host: host)
                .tabItem { Label("对话", systemImage: "bubble.left.and.bubble.right.fill") }
                .badge(pendingInboxCount > 0 ? pendingInboxCount : 0)
                .tag(AppTab.conversations)

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
                        if let target = activePulseTarget {
                            pulseOpenTarget = target
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
        .sheet(item: $pulseOpenTarget) { target in
            NavigationStack {
                ChatView(bot: target.bot, host: host, initialAddress: target.address)
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button("完成") { pulseOpenTarget = nil }
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

    private var primarySessionId: String? {
        host.streamingSessionId ?? host.pendingApprovals.first?.sessionId
    }

    private var isPrivatePrimaryBot: Bool {
        guard let sid = primarySessionId,
              let address = host.resolveAddress(sid),
              let bot = host.bot(for: address) else { return false }
        return bot.isPrivate
    }

    private var activeBotName: String {
        guard let sid = primarySessionId,
              let address = host.resolveAddress(sid),
              let bot = host.bot(for: address) else { return "智能体" }
        let baseName = bot.isPrivate ? "私密会话" : bot.name
        let threadSuffix = (!bot.isPrivate ? BotThreadStore.shared.threadTitle(for: address).map { " · \($0)" } : nil) ?? ""
        let extra = host.activeStreamingSessionIds.count > 1 ? " (+\(host.activeStreamingSessionIds.count - 1))" : ""
        return baseName + threadSuffix + extra
    }

    private var statusSubtitle: String {
        if isPrivatePrimaryBot {
            return host.pendingApprovals.isEmpty ? "正在执行后台任务…" : "需解锁私密会话后查看并处理"
        }
        if let approval = host.pendingApprovals.first {
            return "待审批：\(approval.tool)"
        }
        if let sid = primarySessionId,
           let activeTool = host.dshToolActivities.last(where: { $0.sessionId == sid && $0.phase == "started" }) {
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
            if !isPrivatePrimaryBot, let approval = host.pendingApprovals.first {
                Button("批准") {
                    Task { await host.respondToApproval(id: approval.id, approved: true) }
                }
                .font(.caption.weight(.semibold))
                .buttonStyle(.borderedProminent)
                .controlSize(.mini)
            }
            if host.isStreaming {
                Button("停止") {
                    Task { await host.abortActiveTurn(sessionId: primarySessionId) }
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
                .shadow(color: .black.opacity(0.10), radius: 8, y: 3)
        }
    }
}

// MARK: - Tab 2: 工作台 (Workbench & Sandboxed Tools Hub)

public struct ToolsHubTabView: View {
    @ObservedObject var host: LocalAgentHost
    @ObservedObject private var memoryGovernor = MemoryGovernor.shared
    @ObservedObject private var budgetGovernor = CostBudgetGovernor.shared
    @State private var showAgentBrowser = false
    @State private var showWebWorkbench = false

    public init(host: LocalAgentHost) {
        self.host = host
    }

    public var body: some View {
        NavigationStack {
            List {
                // Hero Section: Embedded DSH Web Workbench + Built-in Agent Browser
                Section {
                    Button {
                        showWebWorkbench = true
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
                                        .foregroundStyle(.primary)
                                    DSStatusBadge("Loopback", color: DSTheme.brand)
                                }
                                Text("内嵌官方 Web UI、会话 ZIP/Markdown 导出与社区 dsh-client-ui-* 插件")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 6)
                    }
                    .buttonStyle(.plain)

                    Button {
                        showAgentBrowser = true
                    } label: {
                        HStack(spacing: 14) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .fill(Color.cyan.gradient)
                                    .frame(width: 48, height: 48)
                                Image(systemName: "safari.fill")
                                    .font(.title3.weight(.semibold))
                                    .foregroundStyle(.white)
                            }
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 6) {
                                    Text("内置受控浏览器")
                                        .font(.headline)
                                        .foregroundStyle(.primary)
                                    DSStatusBadge("browser_*", color: .cyan)
                                }
                                Text("独立 WKWebView 沙盒，供智能体检索、填表、截图 OCR 与人工接管登录")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                            Spacer(minLength: 4)
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 6)
                    }
                    .buttonStyle(.plain)
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
                            title: "沙盒虚拟命令台",
                            subtitle: "在 /workspace 使用受限解释器运行 Node、Python 和目录命令；当前不是 Linux shell/PTY"
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

                Section("外部连接器生态") {
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
            .sheet(isPresented: $showAgentBrowser) {
                AgentBrowserSheet(workspace: host.workspace)
            }
            .fullScreenCover(isPresented: $showWebWorkbench) {
                DSHWebUIView(host: host)
            }
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

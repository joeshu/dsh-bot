import SwiftUI

public enum BotProfileTab: String, CaseIterable, Identifiable {
    case work = "work"
    case memory = "memory"
    case files = "files"
    case routines = "routines"
    case settings = "settings"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .work: return "概览"
        case .memory: return "记忆"
        case .files: return "文件"
        case .routines: return "定时"
        case .settings: return "设置"
        }
    }
}

/// Self-contained 5-Tab Bot Profile Sheet (概览 / 记忆 / 文件 / 定时 / 设置)
/// with persisted last-selected tab via `@AppStorage`. Works identically from
/// SessionsTabView, BotRosterTabView, and ChatView with zero dead closures.
public struct BotProfileSheet: View {
    let bot: BotProfile
    @ObservedObject var host: LocalAgentHost

    @AppStorage("dsbot.profile.selectedTab") private var selectedTabRaw: String = BotProfileTab.work.rawValue
    @State private var refreshStatus: String = ""
    @State private var showEditSettings = false
    @State private var showDiagnostics = false
    @Environment(\.dismiss) private var dismiss

    public init(bot: BotProfile, host: LocalAgentHost) {
        self.bot = bot
        self.host = host
    }

    private var selectedTab: Binding<BotProfileTab> {
        Binding(
            get: { BotProfileTab(rawValue: selectedTabRaw) ?? .work },
            set: { selectedTabRaw = $0.rawValue }
        )
    }

    private var liveBot: BotProfile {
        host.bots.first(where: { $0.id == bot.id }) ?? bot
    }

    private var recentActivities: [DSHToolActivity] {
        host.dshToolActivities.filter { $0.sessionId == liveBot.id }.suffix(12).reversed()
    }

    private var fileActivities: [DSHToolActivity] {
        host.dshToolActivities.filter { $0.sessionId == liveBot.id && $0.fileSummary != nil }.suffix(15).reversed()
    }

    public var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("档案分页", selection: selectedTab) {
                    ForEach(BotProfileTab.allCases) { tab in
                        Text(tab.title).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

                tabBody
            }
            .navigationTitle(liveBot.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
            .sheet(isPresented: $showEditSettings) {
                EditBotSheet(bot: liveBot, host: host)
            }
            .sheet(isPresented: $showDiagnostics) {
                SessionDiagnosticsSheet(host: host, bot: liveBot)
            }
        }
    }

    @ViewBuilder
    private var tabBody: some View {
        switch selectedTab.wrappedValue {
        case .work:
            workTab
        case .memory:
            memoryTab
        case .files:
            filesTab
        case .routines:
            routinesTab
        case .settings:
            settingsTab
        }
    }

    private var workTab: some View {
        List {
            Section("智能体信息") {
                LabeledContent("角色定位", value: liveBot.roleLabel)
                LabeledContent("默认模型", value: host.modelSelection(liveBot.model))
                LabeledContent("DSH 模式", value: host.agentPresetName(liveBot.agentPreset))
                LabeledContent("审批档位", value: liveBot.permissionModeLabel)
                LabeledContent("本地消息数", value: "\(host.messages(for: liveBot.id).count)")
            }
            Section("近期工具调用") {
                if recentActivities.isEmpty {
                    Text("当前会话尚未触发工具调用。").font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(recentActivities) { act in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(act.toolName).font(.subheadline.weight(.medium))
                                Spacer()
                                Text(act.phaseLabel).font(.caption2).foregroundStyle(.secondary)
                            }
                            if let summary = act.fileSummary {
                                Text(summary).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }
                }
            }
        }
    }

    private var memoryTab: some View {
        List {
            Section("记忆冻结语义（Prompt Cache 保护）") {
                Text("活跃会话的系统提示词与记忆快照在当前会话周期内自动冻结，确保 DeepSeek Prompt Cache 高命中率；新建或重置会话时自动刷新。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button {
                    Task {
                        let ok = await host.refreshSessionPersona(botId: liveBot.id)
                        refreshStatus = ok ? "已刷新本会话记忆快照（下轮生效）" : "当前会话尚未激活，下轮发送将自动加载最新记忆"
                    }
                } label: {
                    Label("立即刷新记忆快照（重置 Prompt Cache）", systemImage: "arrow.clockwise.circle")
                }
                if !refreshStatus.isEmpty {
                    Text(refreshStatus)
                        .font(.caption2)
                        .foregroundStyle(DSTheme.brand)
                }
                NavigationLink {
                    MemoryVaultView(host: host, botId: liveBot.id)
                } label: {
                    Label("管理本机记忆库与写前隐私闸门", systemImage: "brain.head.profile")
                }
            }
        }
    }

    private var filesTab: some View {
        List {
            Section {
                if fileActivities.isEmpty {
                    Text("本会话暂无文件读写记录。").font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(fileActivities) { act in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(act.fileSummary ?? act.toolName)
                                .font(.caption.monospaced())
                                .lineLimit(2)
                            Text("\(act.toolName) · \(act.phaseLabel)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("本会话关联文件（仅当前智能体轨迹）")
            }

            Section {
                if liveBot.isPrivate {
                    Label("私密会话不会自动写入共享目录；打开下方工作区将浏览全局共享 files/。", systemImage: "lock.shield")
                        .font(.caption)
                        .foregroundStyle(DSTheme.warning)
                }
                NavigationLink {
                    WorkspaceFilesView(host: host)
                } label: {
                    Label("打开全局共享工作区 (files/)", systemImage: "folder.fill")
                }
            } header: {
                Text("共享工作区全部文件（跨会话共享）")
            } footer: {
                Text("files/ 为全局沙盒共享目录，所有非私密智能体均可读写；与上方仅限本会话的变更轨迹作用域不同。")
            }
        }
    }

    private var routinesTab: some View {
        List {
            Section("定时任务与后台作业") {
                NavigationLink {
                    ScheduleManagerView(host: host, botId: liveBot.id)
                } label: {
                    Label("打开定时任务管理器", systemImage: "calendar.badge.clock")
                }
                NavigationLink {
                    JobsManagerView(host: host, botId: liveBot.id)
                } label: {
                    Label("查看后台计算任务 (Jobs)", systemImage: "hourglass")
                }
                Button {
                    showDiagnostics = true
                } label: {
                    Label("查看会话诊断与内存水位", systemImage: "stethoscope")
                }
            }
        }
    }

    private var settingsTab: some View {
        List {
            Section("模式与审批策略（支持热切换）") {
                Picker("DSH Agent 模式", selection: Binding(
                    get: { liveBot.agentPreset },
                    set: { host.setAgentPreset(sessionId: liveBot.id, presetId: $0) }
                )) {
                    ForEach(host.dshAgentPresets) { preset in
                        Text(preset.isAvailable ? preset.name : "\(preset.name)（不可用）")
                            .tag(preset.id)
                            .disabled(!preset.isAvailable)
                    }
                }
                .disabled(host.isStreaming)

                Picker("审批档位", selection: Binding(
                    get: { liveBot.permissionMode },
                    set: { host.setPermissionMode(sessionId: liveBot.id, mode: $0) }
                )) {
                    Text("只读保护").tag("readOnly")
                    Text("标准审批").tag("ask")
                    Text("沙盒免打扰").tag("autoReview")
                }
                .disabled(host.isStreaming)

                ModelSelectionView(
                    host: host,
                    model: Binding(
                        get: { host.modelSelection(liveBot.model) },
                        set: { host.setBotModel(sessionId: liveBot.id, model: $0) }
                    ),
                    allowsTyping: false
                )
                .disabled(host.isStreaming)
            }
            Section("档案与安全配置") {
                LabeledContent("私密空间", value: liveBot.isPrivate ? "已开启（Face ID）" : "未开启")
                LabeledContent("群聊协作", value: liveBot.isGroup ? "群聊（90s 租约保护）" : "单聊")
                LabeledContent("红队演练工具", value: liveBot.redteamToolsEnabled ? "已授权" : "关闭")
                Button {
                    showEditSettings = true
                } label: {
                    Label("编辑智能体人设与高级配置", systemImage: "slider.horizontal.3")
                }
            }
        }
    }
}

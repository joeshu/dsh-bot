import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

public enum ChatSessionViewMode: String, CaseIterable, Identifiable {
    case dialogue = "对话"
    case trajectory = "轨迹"
    public var id: String { rawValue }
}

/// Top sub-navigation bar directly below the session title:
/// `对话 | 轨迹 | [enabled plugin pills...] | •••`
/// Inspired by DSH Harness mobile web workbench.
struct ChatSessionSubTabBar: View {
    @Binding var mode: ChatSessionViewMode
    let stepCount: Int
    let isPrivate: Bool
    let enabledPlugins: [DSHInstalledPlugin]
    let thirdPartyTools: [RuntimePluginTool]
    let onOpenPlugins: () -> Void
    let onOpenWebWorkbench: () -> Void
    let onOpenBrowser: () -> Void
    let onInsertToolPrompt: (String) -> Void

    var body: some View {
        HStack(spacing: 12) {
            tabButton(.dialogue, badge: nil)
            tabButton(.trajectory, badge: stepCount > 0 ? "\(stepCount)" : nil)

            if !isPrivate {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        if enabledPlugins.isEmpty {
                            Button {
                                onOpenPlugins()
                            } label: {
                                Text("dsh-purge-safe")
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(DSTheme.surfaceSecondary)
                                    .clipShape(Capsule())
                                    .overlay(
                                        Capsule()
                                            .strokeBorder(Color.secondary.opacity(0.22), lineWidth: 0.75)
                                    )
                            }
                            .buttonStyle(.plain)
                        } else {
                            ForEach(enabledPlugins.prefix(4)) { plugin in
                                Button {
                                    onOpenPlugins()
                                } label: {
                                    Text(shortPluginLabel(plugin.name))
                                        .font(.caption.weight(.medium))
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 5)
                                        .background(DSTheme.surfaceSecondary)
                                        .clipShape(Capsule())
                                        .overlay(
                                            Capsule()
                                                .strokeBorder(DSTheme.brand.opacity(0.28), lineWidth: 0.75)
                                        )
                                }
                                .buttonStyle(.plain)
                            }
                        }

                        Menu {
                            Button {
                                onOpenPlugins()
                            } label: {
                                Label("浏览更多插件", systemImage: "puzzlepiece.extension")
                            }
                            if !thirdPartyTools.isEmpty {
                                Menu {
                                    ForEach(thirdPartyTools.prefix(20)) { tool in
                                        Button {
                                            onInsertToolPrompt("请使用插件工具 \(tool.name) 帮我 ")
                                        } label: {
                                            Label(tool.name, systemImage: "wrench.and.screwdriver")
                                        }
                                    }
                                } label: {
                                    Label("调用已挂载插件工具 (\(thirdPartyTools.count))", systemImage: "sparkles")
                                }
                            }
                            Divider()
                            Button {
                                onOpenBrowser()
                            } label: {
                                Label("打开 App 内置浏览器", systemImage: "safari")
                            }
                            Button {
                                onOpenWebWorkbench()
                            } label: {
                                Label("在 DSH Web 工作台使用", systemImage: "macwindow.on.rectangle")
                            }
                        } label: {
                            Image(systemName: "ellipsis")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .frame(width: 26, height: 26)
                                .background(DSTheme.surfaceSecondary)
                                .clipShape(Circle())
                        }
                    }
                    .padding(.vertical, 2)
                }
            } else {
                Spacer()
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 4)
        .padding(.bottom, 6)
        .background(DSTheme.surfacePrimary)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }

    private func tabButton(_ target: ChatSessionViewMode, badge: String?) -> some View {
        let active = mode == target
        return Button {
            withAnimation(.easeInOut(duration: 0.16)) {
                mode = target
            }
        } label: {
            VStack(spacing: 5) {
                HStack(spacing: 4) {
                    Text(target.rawValue)
                        .font(.subheadline.weight(active ? .semibold : .regular))
                        .foregroundStyle(active ? DSTheme.brand : .secondary)
                    if let badge {
                        Text(badge)
                            .font(.system(size: 10, weight: .semibold).monospacedDigit())
                            .foregroundStyle(active ? DSTheme.brand : .secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background((active ? DSTheme.brand : Color.secondary).opacity(0.14))
                            .clipShape(Capsule())
                    }
                }
                Rectangle()
                    .fill(active ? DSTheme.brand : Color.clear)
                    .frame(height: 2)
                    .clipShape(Capsule())
            }
            .fixedSize(horizontal: true, vertical: false)
        }
        .buttonStyle(.plain)
    }

    private func shortPluginLabel(_ raw: String) -> String {
        if let slash = raw.lastIndex(of: "/") {
            return String(raw[raw.index(after: slash)...])
        }
        return raw
    }
}

/// Dedicated Execution Trajectory (轨迹) timeline view for a session.
struct ChatTrajectoryView: View {
    enum Filter: String, CaseIterable, Identifiable {
        case all = "全部"
        case failed = "仅失败"
        case files = "含文件"
        case approvals = "审批记录"
        var id: String { rawValue }
    }

    let activities: [DSHToolActivity]
    let audits: [DSHApprovalAudit]
    let turnCount: Int
    @State private var filter: Filter = .all
    @State private var expandedIDs: Set<String> = []
    @State private var copiedID: String?

    private var filteredActivities: [DSHToolActivity] {
        switch filter {
        case .all: return activities
        case .failed: return activities.filter { $0.phase == "failed" }
        case .files: return activities.filter { !($0.fileSummary ?? "").isEmpty }
        case .approvals: return []
        }
    }

    private var totalDurationText: String {
        let ms = activities.compactMap(\.durationMs).reduce(0, +)
        guard ms > 0 else { return "—" }
        return ms < 1_000 ? "\(ms)ms" : String(format: "%.1fs", Double(ms) / 1000.0)
    }

    private var successCount: Int {
        activities.filter { $0.phase == "completed" }.count
    }

    var body: some View {
        VStack(spacing: 0) {
            // Compact summary strip
            HStack(spacing: 12) {
                Label("\(turnCount) 轮", systemImage: "bubble.left.and.bubble.right")
                Label("\(activities.count) 步", systemImage: "bolt.horizontal.fill")
                Label("\(successCount) 成功", systemImage: "checkmark.circle")
                Label(totalDurationText, systemImage: "clock")
                Spacer()
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(DSTheme.surfaceSecondary.opacity(0.6))

            // Filter pills
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Filter.allCases) { item in
                        let selected = filter == item
                        Button {
                            filter = item
                        } label: {
                            Text(item == .approvals && !audits.isEmpty ? "\(item.rawValue) (\(audits.count))" : item.rawValue)
                                .font(.caption.weight(selected ? .semibold : .regular))
                                .foregroundStyle(selected ? .white : .primary)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(selected ? DSTheme.brand : DSTheme.surfaceSecondary)
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
            }

            Divider()

            if filter == .approvals {
                if audits.isEmpty {
                    DSEmptyStateView(
                        icon: "checkmark.shield",
                        title: "暂无审批审计记录",
                        subtitle: "高风险或需要人工授权的工具调用将在此按时间留痕。"
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(audits) { audit in
                                HStack(spacing: 10) {
                                    Image(systemName: audit.outcome == "allowed-once" ? "checkmark.shield.fill" : "xmark.shield.fill")
                                        .foregroundStyle(audit.outcome == "allowed-once" ? DSTheme.success : DSTheme.danger)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(audit.toolName)
                                            .font(.subheadline.weight(.semibold))
                                        Text(audit.outcomeLabel)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Text(audit.timestamp, style: .time)
                                        .font(.caption2.monospacedDigit())
                                        .foregroundStyle(.tertiary)
                                }
                                .padding(12)
                                .background(DSTheme.surfaceSecondary)
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            }
                        }
                        .padding(14)
                    }
                }
            } else if filteredActivities.isEmpty {
                DSEmptyStateView(
                    icon: "point.topleft.down.curvedto.point.bottomright.up",
                    title: activities.isEmpty ? "暂无执行轨迹" : "当前筛选条件下无记录",
                    subtitle: activities.isEmpty
                        ? "发送任务后，Bot 的每次工具调用、网页操作与文件读写都会实时记录在此。"
                        : "切换上方筛选条件以查看完整执行步骤。"
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(Array(filteredActivities.enumerated()), id: \.element.id) { idx, item in
                            trajectoryRow(step: idx + 1, item: item)
                        }
                    }
                    .padding(14)
                }
            }
        }
        .background(DSTheme.surfacePrimary)
    }

    private func trajectoryRow(step: Int, item: DSHToolActivity) -> some View {
        let isExpanded = expandedIDs.contains(item.id)
        let statusColor: Color = item.phase == "failed" ? DSTheme.danger : (item.phase == "completed" ? DSTheme.success : DSTheme.brand)
        return VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.16)) {
                    if isExpanded { expandedIDs.remove(item.id) } else { expandedIDs.insert(item.id) }
                }
            } label: {
                HStack(spacing: 8) {
                    Text("#\(step)")
                        .font(.caption2.weight(.bold).monospacedDigit())
                        .foregroundStyle(statusColor)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(statusColor.opacity(0.14))
                        .clipShape(Capsule())
                    Text(item.displayLabel)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Spacer()
                    if let dur = item.formattedDuration {
                        Text(dur)
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Text(item.timestamp, style: .time)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)

            if let file = item.fileSummary, !file.isEmpty {
                Label(file, systemImage: "doc.text")
                    .font(.caption2)
                    .foregroundStyle(DSTheme.brand)
                    .lineLimit(1)
            }

            if isExpanded, !item.result.isEmpty {
                let summary = item.result
                Text(summary)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(item.phase == "failed" ? DSTheme.danger : .secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(DSTheme.surfacePrimary)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                HStack {
                    Spacer()
                    Button {
                        #if canImport(UIKit)
                        UIPasteboard.general.string = summary
                        #endif
                        copiedID = item.id
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            if copiedID == item.id { copiedID = nil }
                        }
                    } label: {
                        Label(copiedID == item.id ? "已复制" : "复制结果", systemImage: copiedID == item.id ? "checkmark" : "doc.on.doc")
                            .font(.caption2.weight(.medium))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                }
            }
        }
        .padding(12)
        .background(DSTheme.surfaceSecondary)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// Compact bottom session configuration sheet inspired by IMG_1006:
/// Model + Safety Permission Mode + Agent Teamwork toggle + Web Search / Tools.
struct ChatSessionConfigSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var host: LocalAgentHost
    let bot: BotProfile
    @Binding var selectedModel: String

    var body: some View {
        NavigationStack {
            List {
                Section("模型与权限") {
                    Picker("模型", selection: $selectedModel) {
                        let choices = host.models.isEmpty ? [selectedModel] : host.models
                        ForEach(choices, id: \.self) { model in
                            Text(model).tag(model)
                        }
                    }
                    Picker("推理等级", selection: Binding(
                        get: { bot.reasoningEffort },
                        set: { host.setReasoningEffort(sessionId: bot.id, effort: $0) }
                    )) {
                        Text("低（快速）").tag("low")
                        Text("中（均衡）").tag("medium")
                        Text("高（深度）").tag("high")
                    }
                    Picker("执行安全级别", selection: Binding(
                        get: { bot.permissionMode },
                        set: { host.setPermissionMode(sessionId: bot.id, mode: $0) }
                    )) {
                        Text("只读保护").tag("readOnly")
                        Text("标准确认").tag("ask")
                        Text("沙盒免打扰").tag("autoReview")
                    }
                }

                Section("智能体能力") {
                    Toggle(isOn: $host.subagentEnabled) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("启用智能体团队协作")
                            Text("允许主 Bot 派生子代理并行处理复杂任务")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Toggle(isOn: $host.webSearchEnabled) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("联网搜索增强")
                            Text("允许在回答前检索最新网页信息")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Toggle(isOn: $host.customTools) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("工作区与插件工具")
                            Text("允许读写工作区文件、内置浏览器及已挂载插件")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if !bot.isPrivate {
                    Section("本 Bot 逐工具白名单") {
                        let toggleableTools: [(id: String, title: String)] = [
                            ("web_fetch", "联网抓取网页 (web_fetch)"),
                            ("browser_open", "App 内置浏览器 (browser_*)"),
                            ("terminal_exec", "沙盒虚拟终端 (terminal_exec)"),
                            ("git_workspace", "工作区 Git 追踪 (git_workspace)"),
                            ("python_exec", "离线 Python 沙盒 (python_exec)"),
                            ("js_eval", "QuickJS 沙盒 (js_eval)"),
                        ]
                        ForEach(toggleableTools, id: \.id) { tool in
                            let isAllowed = !bot.disabledTools.contains(tool.id)
                            Toggle(tool.title, isOn: Binding(
                                get: { isAllowed },
                                set: { enabled in
                                    var next = Set(bot.disabledTools)
                                    if enabled {
                                        next.remove(tool.id)
                                        if tool.id == "browser_open" {
                                            for name in ["browser_open", "browser_snapshot", "browser_click", "browser_type", "browser_select", "browser_press_key", "browser_scroll", "browser_screenshot", "browser_back", "browser_wait", "browser_eval", "browser_handoff"] {
                                                next.remove(name)
                                            }
                                        }
                                    } else {
                                        next.insert(tool.id)
                                        if tool.id == "browser_open" {
                                            for name in ["browser_open", "browser_snapshot", "browser_click", "browser_type", "browser_select", "browser_press_key", "browser_scroll", "browser_screenshot", "browser_back", "browser_wait", "browser_eval", "browser_handoff"] {
                                                next.insert(name)
                                            }
                                        }
                                    }
                                    host.setDisabledTools(botId: bot.id, disabledTools: Array(next))
                                }
                            ))
                        }
                    }

                    Section("模板与备份") {
                        Button {
                            exportBotJSON()
                        } label: {
                            Label("导出本 Bot 配置（JSON，不含密钥）", systemImage: "square.and.arrow.up")
                        }
                    }
                }
            }
            .navigationTitle("会话配置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func exportBotJSON() {
        let payload = BotExportPayload(from: bot)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(payload) else { return }
        let safe = bot.name.replacingOccurrences(of: "/", with: "_")
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("\(safe)-bot-config.json")
        guard (try? data.write(to: dest, options: .atomic)) != nil else { return }
        #if canImport(UIKit)
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let root = scenes.first(where: { $0.activationState == .foregroundActive })?.windows.first(where: \.isKeyWindow)?.rootViewController
            ?? scenes.first?.windows.first?.rootViewController
        var presenter = root
        while let next = presenter?.presentedViewController { presenter = next }
        guard let presenter else {
            try? FileManager.default.removeItem(at: dest)
            return
        }
        let sheet = UIActivityViewController(activityItems: [dest], applicationActivities: nil)
        sheet.popoverPresentationController?.sourceView = presenter.view
        sheet.popoverPresentationController?.sourceRect = CGRect(x: presenter.view.bounds.midX, y: presenter.view.bounds.maxY - 60, width: 1, height: 1)
        sheet.completionWithItemsHandler = { _, _, _, _ in
            try? FileManager.default.removeItem(at: dest)
        }
        presenter.present(sheet, animated: true)
        #else
        try? FileManager.default.removeItem(at: dest)
        #endif
    }
}

/// Sleek single-line telemetry bar below the composer (`N 轮 M 步 · ~X tok · ○ Y%`)
/// with three interactive detail popovers matching DSH Web Workbench (IMG_1008 / IMG_1009 / IMG_1010).
struct ChatSessionTelemetryBar: View {
    enum PopoverKind: String, Identifiable {
        case stats
        case tokens
        case context
        var id: String { rawValue }
    }

    let turnCount: Int
    let stepCount: Int
    let toolDurationMs: Int
    let firstTokenMs: Int?
    let liveTelemetry: SessionLiveTelemetry?
    let systemPromptTokens: Int
    let toolSchemaTokens: Int
    let messageTokens: Int
    let outputTokens: Int
    let contextLimit: Int
    let enabledPluginCount: Int
    let onTapTrajectory: () -> Void
    let onTapCompact: () -> Void

    @State private var activePopover: PopoverKind?

    private var hasRealUsage: Bool {
        (liveTelemetry?.totalTokens ?? 0) > 0
    }

    private var totalContextTokens: Int {
        systemPromptTokens + toolSchemaTokens + messageTokens
    }

    private var contextPercent: Double {
        guard contextLimit > 0 else { return 0 }
        return min(100.0, (Double(totalContextTokens) / Double(contextLimit)) * 100.0)
    }

    private var totalSessionTokens: Int {
        if let real = liveTelemetry, real.totalTokens > 0 {
            return real.totalTokens
        }
        return max(totalContextTokens, messageTokens + outputTokens)
    }

    private func formatTok(_ value: Int) -> String {
        if value >= 1_000_000 {
            return String(format: "%.1fM", Double(value) / 1_000_000.0)
        }
        if value >= 1_000 {
            return String(format: "%.1fK", Double(value) / 1_000.0)
        }
        return "\(value)"
    }

    private func formatDuration(_ ms: Int) -> String {
        guard ms > 0 else { return "—" }
        let sec = Double(ms) / 1000.0
        if sec >= 60 {
            let m = Int(sec) / 60
            let s = Int(sec) % 60
            return "\(m)分\(s)秒"
        }
        return String(format: "%.1f秒", sec)
    }

    var body: some View {
        VStack(spacing: 0) {
            if let activePopover {
                detailCard(for: activePopover)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 6)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            HStack(spacing: 10) {
                Button {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        activePopover = activePopover == .stats ? nil : .stats
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "gauge.with.dots.needle.33percent")
                            .font(.system(size: 11))
                        Text("\(turnCount) 轮 \(stepCount) 步")
                            .lineLimit(1)
                    }
                    .foregroundStyle(activePopover == .stats ? DSTheme.brand : .secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(activePopover == .stats ? DSTheme.brand.opacity(0.12) : Color.clear)
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)

                Button {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        activePopover = activePopover == .tokens ? nil : .tokens
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "cylinder.split.1x2")
                            .font(.system(size: 11))
                        Text("\(formatTok(totalSessionTokens)) tok")
                            .lineLimit(1)
                        if enabledPluginCount > 0 {
                            Text("· \(enabledPluginCount) 插件")
                                .lineLimit(1)
                        }
                    }
                    .foregroundStyle(activePopover == .tokens ? DSTheme.brand : .secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(activePopover == .tokens ? DSTheme.brand.opacity(0.12) : Color.clear)
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)

                Spacer()

                Button {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        activePopover = activePopover == .context ? nil : .context
                    }
                } label: {
                    HStack(spacing: 5) {
                        ZStack {
                            Circle()
                                .stroke(Color.secondary.opacity(0.25), lineWidth: 2)
                            Circle()
                                .trim(from: 0, to: min(1.0, max(0.02, contextPercent / 100.0)))
                                .stroke(contextPercent >= 75 ? Color.orange : DSTheme.brand, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                                .rotationEffect(.degrees(-90))
                        }
                        .frame(width: 12, height: 12)
                        Text("\(Int(contextPercent.rounded()))%")
                            .monospacedDigit()
                            .foregroundStyle(contextPercent >= 75 ? .orange : (activePopover == .context ? DSTheme.brand : .secondary))
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(activePopover == .context ? DSTheme.brand.opacity(0.12) : Color.clear)
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            .font(.system(size: 11))
            .padding(.horizontal, 10)
            .padding(.top, 2)
            .padding(.bottom, 6)
        }
    }

    @ViewBuilder
    private func detailCard(for kind: PopoverKind) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            switch kind {
            case .stats:
                let effectiveTtft = liveTelemetry?.averageTtftMs ?? firstTokenMs
                let modelMs = liveTelemetry?.modelDurationMs ?? 0
                let tpsText: String = {
                    if let tps = liveTelemetry?.tokensPerSecond {
                        return "\(Int(tps.rounded())) tok/s"
                    }
                    return "—"
                }()
                HStack {
                    Label("会话统计", systemImage: "gauge.with.dots.needle.33percent")
                        .font(.caption.weight(.semibold))
                    Spacer()
                    Text("\(turnCount) 轮 \(stepCount) 步")
                        .font(.caption.weight(.semibold).monospacedDigit())
                }
                Divider()
                statRow("模型用时", formatDuration(modelMs))
                statRow("工具调用用时", formatDuration(toolDurationMs))
                statRow("首 token 平均 (TTFT)", effectiveTtft.map { formatDuration($0) } ?? "—")
                statRow("输出速度 (TPS)", tpsText)
                Button {
                    activePopover = nil
                    onTapTrajectory()
                } label: {
                    HStack {
                        Text("查看完整执行轨迹")
                        Spacer()
                        Image(systemName: "arrow.right")
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(DSTheme.brand)
                    .padding(.top, 2)
                }
                .buttonStyle(.plain)

            case .tokens:
                let real = liveTelemetry
                let cached = hasRealUsage ? (real?.cacheReadTokens ?? 0) : max(0, messageTokens - (messageTokens / 5))
                let uncached = hasRealUsage ? (real?.uncachedInputTokens ?? 0) : max(0, messageTokens - cached)
                let outTok = hasRealUsage ? (real?.outputTokens ?? 0) : outputTokens
                let hitRate = hasRealUsage
                    ? (real?.cacheHitPercent ?? 0)
                    : (messageTokens > 0 ? Int((Double(cached) / Double(messageTokens) * 100.0).rounded()) : 0)
                let prefix = hasRealUsage ? "" : "~"
                HStack {
                    Label(hasRealUsage ? "Token 用量" : "Token 用量（估算）", systemImage: "cylinder.split.1x2")
                        .font(.caption.weight(.semibold))
                    Spacer()
                    Text("\(prefix)\(formatTok(totalSessionTokens)) tok")
                        .font(.caption.weight(.semibold).monospacedDigit())
                }
                Divider()
                statRow("缓存命中", "\(hitRate)%")
                statRow("未缓存输入", "\(prefix)\(formatTok(uncached)) tok")
                statRow("缓存读取", "\(prefix)\(formatTok(cached)) tok")
                statRow("输出", "\(prefix)\(formatTok(outTok)) tok")

            case .context:
                HStack {
                    Text("上下文已用 \(Int(contextPercent.rounded()))%")
                        .font(.caption.weight(.semibold))
                    Spacer()
                    Text("~\(formatTok(totalContextTokens)) / \(formatTok(contextLimit))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                GeometryReader { geo in
                    let w = max(1, geo.size.width)
                    let limit = max(1.0, Double(contextLimit))
                    let sysW = w * min(1.0, Double(systemPromptTokens) / limit)
                    let toolW = w * min(1.0, Double(toolSchemaTokens) / limit)
                    let msgW = w * min(1.0, Double(messageTokens) / limit)
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.secondary.opacity(0.18))
                        HStack(spacing: 1) {
                            Rectangle().fill(Color.secondary).frame(width: max(2, sysW))
                            Rectangle().fill(Color.purple).frame(width: max(2, toolW))
                            Rectangle().fill(DSTheme.brand).frame(width: max(2, msgW))
                        }
                        .clipShape(Capsule())
                    }
                }
                .frame(height: 5)

                contextRow(color: .secondary, label: "系统提示词", value: "~\(formatTok(systemPromptTokens))")
                contextRow(color: .purple, label: "工具定义", value: "~\(formatTok(toolSchemaTokens))")
                contextRow(color: DSTheme.brand, label: "对话消息", value: "~\(formatTok(messageTokens))")

                Button {
                    activePopover = nil
                    onTapCompact()
                } label: {
                    Label("压缩以上对话内容 (/compact)", systemImage: "arrow.down.right.and.arrow.up.left")
                        .font(.caption.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .padding(.top, 2)
            }
        }
        .padding(12)
        .background(DSTheme.surfaceSecondary)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.18), lineWidth: 0.75)
        )
        .shadow(color: Color.black.opacity(0.08), radius: 8, y: 2)
    }

    private func statRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.primary)
        }
    }

    private func contextRow(color: Color, label: String, value: String) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(color)
                .frame(width: 8, height: 8)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.primary)
        }
    }
}

/// Shield quick-permission preset menu in the composer bar matching IMG_1011.
struct ChatPermissionQuickMenu: View {
    let currentMode: String
    let onSelect: (String) -> Void

    private var tintColor: Color {
        switch currentMode {
        case "readOnly": return .secondary
        case "autoReview": return .orange
        default: return DSTheme.brand
        }
    }

    private var iconName: String {
        switch currentMode {
        case "readOnly": return "checkmark.shield"
        case "autoReview": return "bolt.shield.fill"
        default: return "shield.lefthalf.filled"
        }
    }

    var body: some View {
        Menu {
            Button {
                onSelect("readOnly")
            } label: {
                Label(currentMode == "readOnly" ? "仅可查看 ✓" : "仅可查看", systemImage: "eye")
            }
            Button {
                onSelect("ask")
            } label: {
                Label(currentMode == "ask" ? "标准确认 ✓" : "标准确认", systemImage: "checkmark.shield")
            }
            Button {
                onSelect("autoReview")
            } label: {
                Label(currentMode == "autoReview" ? "沙盒免打扰 (EXP) ✓" : "沙盒免打扰 (EXP)", systemImage: "bolt.shield")
            }
        } label: {
            Image(systemName: iconName)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(tintColor)
        }
        .help("切换会话权限预设")
    }
}

/// Categorized `+` / `/` command palette matching IMG_1012 / IMG_1013 (`添加` + `指令` + `已挂载插件`).
struct ChatSlashCommandPalette: View {
    struct Entry: Identifiable {
        let id: String
        let group: String
        let icon: String
        let title: String
        let command: String
        let subtitle: String
        let badge: String?
        let action: () -> Void
    }

    let query: String
    let isPrivate: Bool
    let isGroup: Bool
    let isPlanMode: Bool
    let thirdPartyTools: [RuntimePluginTool]
    let onPickFile: () -> Void
    let onOpenGoal: () -> Void
    let onTogglePlanMode: () -> Void
    let onQuoteChat: () -> Void
    let onCompact: () -> Void
    let onOpenConfig: () -> Void
    let onOpenSchedules: () -> Void
    let onOpenSideChat: () -> Void
    let onOpenWorkspace: () -> Void
    let onExport: () -> Void
    let onPurge: () -> Void
    let onRewind: () -> Void
    let onOpenRules: () -> Void
    let onOpenSkills: () -> Void
    let onClear: () -> Void
    let onInsertText: (String) -> Void

    private var entries: [Entry] {
        var list: [Entry] = []
        if !isPrivate {
            list.append(Entry(id: "file", group: "添加", icon: "paperclip", title: "文件", command: "file", subtitle: "附加文档、图片或代码文件", badge: nil, action: onPickFile))
        }
        list.append(Entry(id: "goal", group: "添加", icon: "target", title: "目标", command: "goal", subtitle: "设置或查看长期任务目标", badge: nil, action: onOpenGoal))
        list.append(Entry(id: "plan", group: "添加", icon: "list.bullet.clipboard", title: "计划", command: "plan", subtitle: isPlanMode ? "退出计划模式" : "进入计划模式（先规划后执行）", badge: isPlanMode ? "已开启" : nil, action: onTogglePlanMode))
        if !isPrivate {
            list.append(Entry(id: "quote", group: "添加", icon: "quote.bubble", title: "引用对话", command: "quote", subtitle: "引用其他历史会话作为上下文", badge: nil, action: onQuoteChat))
        }

        list.append(Entry(id: "compact", group: "指令", icon: "circle.dotted", title: "压缩", command: "compact", subtitle: "压缩以上对话内容", badge: nil, action: onCompact))
        list.append(Entry(id: "permission", group: "指令", icon: "shield", title: "权限", command: "permission", subtitle: "切换权限预设（沙盒模式与审批策略）", badge: nil, action: onOpenConfig))
        list.append(Entry(id: "model", group: "指令", icon: "cylinder", title: "模型", command: "model", subtitle: "选择本会话使用的模型", badge: nil, action: onOpenConfig))
        if !isPrivate {
            list.append(Entry(id: "export", group: "指令", icon: "arrow.down.to.line", title: "下载日志", command: "export", subtitle: "将当前会话与轨迹导出为 Markdown", badge: nil, action: onExport))
            list.append(Entry(id: "purge", group: "指令", icon: "sparkles", title: "purge", command: "purge", subtitle: "dsh 指令权威性清洗 (status/apply/revert)", badge: nil, action: onPurge))
        }
        list.append(Entry(id: "rewind", group: "指令", icon: "arrow.uturn.backward", title: "rewind", command: "rewind", subtitle: "回退：回填上一轮消息重新编辑发送", badge: nil, action: onRewind))
        if !isPrivate {
            list.append(Entry(id: "rules", group: "指令", icon: "doc.badge.gearshape", title: "rules", command: "rules", subtitle: "规则集切换（写入 files/AGENTS.md）", badge: nil, action: onOpenRules))
            list.append(Entry(id: "skills", group: "指令", icon: "wand.and.stars", title: "skills", command: "skills", subtitle: "用户 Skill（skills/）：查看、创建与调用", badge: nil, action: onOpenSkills))
            list.append(Entry(id: "schedule", group: "指令", icon: "clock", title: "定时任务", command: "schedule", subtitle: "打开这个会话的定时任务", badge: nil, action: onOpenSchedules))
            list.append(Entry(id: "files", group: "指令", icon: "folder", title: "工作区", command: "files", subtitle: "浏览与编辑 files/ 工作区", badge: nil, action: onOpenWorkspace))
        }
        list.append(Entry(id: "side", group: "指令", icon: "bubble.left.and.bubble.right", title: "侧边对话", command: "side", subtitle: "不打断主线的临时提问", badge: nil, action: onOpenSideChat))
        list.append(Entry(id: "clear", group: "指令", icon: "trash", title: "清空", command: "clear", subtitle: "清空当前会话记录", badge: nil, action: onClear))

        if !isPrivate {
            for tool in thirdPartyTools.prefix(12) {
                list.append(Entry(
                    id: "plugin-\(tool.name)",
                    group: "已挂载插件",
                    icon: "puzzlepiece.extension",
                    title: tool.name,
                    command: tool.name,
                    subtitle: tool.description.isEmpty ? "调用已挂载插件工具" : tool.description,
                    badge: nil,
                    action: { onInsertText("请使用插件工具 \(tool.name) 帮我 ") }
                ))
            }
        }
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        let needle = trimmed.hasPrefix("/") ? String(trimmed.dropFirst()).lowercased() : ""
        if needle.isEmpty { return list }
        return list.filter {
            $0.command.lowercased().contains(needle)
            || $0.title.lowercased().contains(needle)
            || $0.subtitle.lowercased().contains(needle)
        }
    }

    var body: some View {
        let items = entries
        if !items.isEmpty {
            let groups = ["添加", "指令", "已挂载插件"].filter { g in items.contains(where: { $0.group == g }) }
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(groups, id: \.self) { group in
                        Text(group)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 12)
                            .padding(.top, 6)
                            .padding(.bottom, 2)
                        ForEach(items.filter { $0.group == group }) { item in
                            Button(action: item.action) {
                                HStack(spacing: 10) {
                                    Image(systemName: item.icon)
                                        .font(.caption)
                                        .foregroundStyle(item.badge != nil ? DSTheme.brand : .secondary)
                                        .frame(width: 18)
                                    Text(item.title)
                                        .font(.subheadline.weight(.medium))
                                        .foregroundStyle(.primary)
                                    if item.command != item.title {
                                        Text(item.command)
                                            .font(.caption)
                                            .foregroundStyle(.tertiary)
                                    }
                                    if let badge = item.badge {
                                        Text(badge)
                                            .font(.system(size: 10, weight: .semibold))
                                            .foregroundStyle(DSTheme.brand)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(DSTheme.brand.opacity(0.14))
                                            .clipShape(Capsule())
                                    }
                                    Spacer()
                                    Text(item.subtitle)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.vertical, 6)
            }
            .frame(maxHeight: 300)
            .background(DSTheme.surfaceSecondary)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.secondary.opacity(0.18), lineWidth: 0.75)
            )
            .shadow(color: Color.black.opacity(0.10), radius: 10, y: -2)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
    }
}

/// Real workspace `files/AGENTS.md` rule-set switcher & editor (`rules` command in IMG_1012/IMG_1013).
struct SessionRulesEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    let workspace: URL
    @State private var content: String = ""
    @State private var statusMessage: String = ""

    private static let presets: [(name: String, body: String)] = [
        ("中文严谨工程模式", "# AGENTS.md\n\n- 始终使用简体中文简洁回复。\n- 修改代码前先阅读上下文，保持改动最小且可验证。\n- 每次修改后运行语法校验与单元测试。\n"),
        ("极简直出模式", "# AGENTS.md\n\n- 直接给出结论、命令或代码，省略寒暄与铺垫。\n- 列表优先，重点加粗。\n"),
        ("深度研究分析模式", "# AGENTS.md\n\n- 回答前先拆解问题维度，对比多种方案的优缺点与风险。\n- 所有结论标注依据与来源。\n"),
        ("安全审计优先模式", "# AGENTS.md\n\n- 优先检查权限边界、注入风险、SSRF 与敏感数据泄露。\n- 严禁未经确认执行破坏性写操作。\n"),
    ]

    private var rulesURL: URL {
        workspace.appendingPathComponent("files/AGENTS.md")
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Self.presets, id: \.name) { preset in
                            Button(preset.name) {
                                content = preset.body
                                statusMessage = "已载入预设「\(preset.name)」，点击右上角保存生效。"
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                }
                Divider()
                TextEditor(text: $content)
                    .font(.system(.callout, design: .monospaced))
                    .padding(10)
                if !statusMessage.isEmpty {
                    Text(statusMessage)
                        .font(.caption)
                        .foregroundStyle(DSTheme.brand)
                        .padding(.horizontal, 14)
                        .padding(.bottom, 8)
                }
            }
            .navigationTitle("规则集 (files/AGENTS.md)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("保存") {
                        saveRules()
                    }
                    .fontWeight(.semibold)
                }
            }
            .onAppear {
                content = (try? String(contentsOf: rulesURL, encoding: .utf8)) ?? ""
            }
        }
    }

    private func saveRules() {
        do {
            try FileManager.default.createDirectory(at: rulesURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.write(to: rulesURL, atomically: true, encoding: .utf8)
            statusMessage = "已写入 files/AGENTS.md（\(content.utf8.count) 字节）"
            DSHaptics.notify(.success)
        } catch {
            statusMessage = "保存失败：\(error.localizedDescription)"
        }
    }
}

/// Real user Skills manager (`skills` command in IMG_1013) backed by `<workspace>/skills/`.
struct SessionSkillsSheet: View {
    struct SkillEntry: Identifiable {
        let id: String
        let name: String
        let url: URL
        let preview: String
        let isCustom: Bool
    }

    @Environment(\.dismiss) private var dismiss
    let workspace: URL
    let onUseSkill: (String, String) -> Void

    @State private var skills: [SkillEntry] = []
    @State private var showCreate = false
    @State private var newName = ""
    @State private var newBody = "# Skill 说明\n\n当用户调用本技能时，请按以下步骤执行：\n1. \n2. \n"
    @State private var statusMessage = ""

    var body: some View {
        NavigationStack {
            List {
                if !statusMessage.isEmpty {
                    Section {
                        Text(statusMessage)
                            .font(.caption)
                            .foregroundStyle(DSTheme.brand)
                    }
                }
                if skills.isEmpty {
                    Section {
                        DSEmptyStateView(
                            icon: "wand.and.stars",
                            title: "暂无本地 Skill",
                            subtitle: "点击右上角「新建」创建你的专属工作流 Skill，随时在任意会话中一键调用。"
                        )
                        .listRowBackground(Color.clear)
                    }
                } else {
                    Section("可用 Skill（\(skills.count)）") {
                        ForEach(skills) { skill in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text(skill.name)
                                        .font(.subheadline.weight(.semibold))
                                    Spacer()
                                    Button("在当前会话使用") {
                                        let body = (try? String(contentsOf: skill.url, encoding: .utf8)) ?? skill.preview
                                        dismiss()
                                        onUseSkill(skill.name, body)
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .controlSize(.mini)
                                }
                                Text(skill.preview)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                            .padding(.vertical, 2)
                            .swipeActions(edge: .trailing) {
                                if skill.isCustom {
                                    Button(role: .destructive) {
                                        try? FileManager.default.removeItem(at: skill.url.deletingLastPathComponent())
                                        reloadSkills()
                                    } label: {
                                        Label("删除", systemImage: "trash")
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("用户 Skills")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showCreate = true
                    } label: {
                        Label("新建", systemImage: "plus")
                    }
                }
            }
            .sheet(isPresented: $showCreate) {
                NavigationStack {
                    Form {
                        Section("Skill 名称") {
                            TextField("例如：code-review 或 daily-brief", text: $newName)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                        }
                        Section("Skill 指令内容 (SKILL.md)") {
                            TextEditor(text: $newBody)
                                .font(.system(.callout, design: .monospaced))
                                .frame(minHeight: 180)
                        }
                    }
                    .navigationTitle("新建用户 Skill")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button("取消") { showCreate = false }
                        }
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("创建") {
                                createSkill()
                            }
                            .disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                }
            }
            .onAppear { reloadSkills() }
        }
    }

    private func reloadSkills() {
        var found: [SkillEntry] = []
        var seenNames = Set<String>()
        let dirs: [(URL, Bool)] = [
            (workspace.appendingPathComponent("files/skills", isDirectory: true), true),
            (workspace.appendingPathComponent("skills", isDirectory: true), true),
            (workspace.appendingPathComponent("redteam/skills", isDirectory: true), false),
        ]
        for (dir, isCustom) in dirs {
            guard let items = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { continue }
            for item in items {
                let skillFile = item.hasDirectoryPath ? item.appendingPathComponent("SKILL.md") : item
                guard skillFile.pathExtension.lowercased() == "md",
                      let text = try? String(contentsOf: skillFile, encoding: .utf8) else { continue }
                let name = item.hasDirectoryPath ? item.lastPathComponent : item.deletingPathExtension().lastPathComponent
                guard seenNames.insert(name.lowercased()).inserted else { continue }
                let preview = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
                found.append(SkillEntry(id: skillFile.path, name: name, url: skillFile, preview: String(preview.prefix(120)), isCustom: isCustom))
            }
        }
        skills = found.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func createSkill() {
        let cleaned = newName.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: " ", with: "-")
        guard !cleaned.isEmpty else { return }
        let dir = workspace
            .appendingPathComponent("files", isDirectory: true)
            .appendingPathComponent("skills", isDirectory: true)
            .appendingPathComponent(cleaned, isDirectory: true)
        let file = dir.appendingPathComponent("SKILL.md")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try newBody.write(to: file, atomically: true, encoding: .utf8)
            showCreate = false
            newName = ""
            statusMessage = "已创建 Skill：files/skills/\(cleaned)/SKILL.md"
            reloadSkills()
        } catch {
            statusMessage = "创建失败：\(error.localizedDescription)"
        }
    }
}

/// Renders clickable workspace file artifact cards extracted from assistant messages
/// (similar to the file preview cards in IMG_1005).
struct MessageWorkspaceFileCards: View {
    let text: String
    let workspace: URL

    private struct ResolvedFile: Identifiable {
        let id: String
        let relativePath: String
        let fileName: String
        let url: URL
        let byteCount: Int64
    }

    private var resolvedFiles: [ResolvedFile] {
        guard let regex = try? NSRegularExpression(pattern: #"(?:files/[A-Za-z0-9._/\-]+)"#) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        var seen = Set<String>()
        var out: [ResolvedFile] = []
        for match in regex.matches(in: text, range: range) {
            guard let swiftRange = Range(match.range, in: text) else { continue }
            let raw = String(text[swiftRange]).trimmingCharacters(in: CharacterSet(charactersIn: ".,;:)]}>\"'`"))
            guard !raw.isEmpty, !raw.contains(".."), seen.insert(raw).inserted else { continue }
            let url = workspace.appendingPathComponent(raw).standardizedFileURL
            let filesRoot = workspace.appendingPathComponent("files", isDirectory: true).standardizedFileURL.path
            guard url.path.hasPrefix(filesRoot),
                  let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let size = attrs[.size] as? NSNumber else { continue }
            out.append(ResolvedFile(
                id: raw,
                relativePath: raw,
                fileName: url.lastPathComponent,
                url: url,
                byteCount: size.int64Value
            ))
            if out.count >= 4 { break }
        }
        return out
    }

    var body: some View {
        let files = resolvedFiles
        if !files.isEmpty {
            VStack(spacing: 6) {
                ForEach(files) { file in
                    Button {
                        shareFile(file.url)
                    } label: {
                        HStack(spacing: 10) {
                            fileBadge(for: file.fileName)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(file.fileName)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Text("\(file.relativePath) · \(ByteCountFormatter.string(fromByteCount: file.byteCount, countStyle: .file))")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Image(systemName: "square.and.arrow.up")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(DSTheme.surfaceSecondary)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(Color.secondary.opacity(0.16), lineWidth: 0.75)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 4)
        }
    }

    private func fileBadge(for name: String) -> some View {
        let ext = (name as NSString).pathExtension.uppercased()
        let badgeText = ext.isEmpty ? "FILE" : String(ext.prefix(4))
        let color: Color = {
            switch ext {
            case "MD", "TXT": return .blue
            case "PY", "JS", "TS", "SWIFT", "JSON": return .indigo
            case "JPG", "JPEG", "PNG", "WEBP": return .teal
            case "PDF": return .red
            case "ZIP", "IPA", "TGZ": return .orange
            default: return .secondary
            }
        }()
        return Text(badgeText)
            .font(.system(size: 9, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: 34, height: 34)
            .background(color.gradient)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func shareFile(_ url: URL) {
        #if canImport(UIKit)
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let root = scenes.first(where: { $0.activationState == .foregroundActive })?.windows.first(where: \.isKeyWindow)?.rootViewController
            ?? scenes.first?.windows.first?.rootViewController
        var presenter = root
        while let next = presenter?.presentedViewController { presenter = next }
        guard let presenter else { return }
        let sheet = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        sheet.popoverPresentationController?.sourceView = presenter.view
        sheet.popoverPresentationController?.sourceRect = CGRect(x: presenter.view.bounds.midX, y: presenter.view.bounds.maxY - 60, width: 1, height: 1)
        presenter.present(sheet, animated: true)
        #endif
    }
}

/// Compact 1-tap footer action bar below assistant messages matching IMG_1005 (`复制 | 分享 | 重答 | 时间`).
struct MessageFooterActionBar: View {
    let text: String
    let timestamp: Date
    let canRegenerate: Bool
    let onRegenerate: () -> Void
    @State private var copied = false

    var body: some View {
        HStack(spacing: 14) {
            Button {
                #if canImport(UIKit)
                UIPasteboard.general.string = text
                #endif
                DSHaptics.impact(.light)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    copied = false
                }
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.caption)
                    .foregroundStyle(copied ? DSTheme.success : .secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("复制回复")

            Button {
                shareText(text)
            } label: {
                Image(systemName: "square.and.arrow.up")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("分享回复")

            if canRegenerate {
                Button(action: onRegenerate) {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("重新生成")
            }

            Text(timestamp, style: .time)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
        }
        .padding(.top, 2)
        .padding(.leading, 4)
    }

    private func shareText(_ content: String) {
        #if canImport(UIKit)
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let root = scenes.first(where: { $0.activationState == .foregroundActive })?.windows.first(where: \.isKeyWindow)?.rootViewController
            ?? scenes.first?.windows.first?.rootViewController
        var presenter = root
        while let next = presenter?.presentedViewController { presenter = next }
        guard let presenter else { return }
        let sheet = UIActivityViewController(activityItems: [content], applicationActivities: nil)
        sheet.popoverPresentationController?.sourceView = presenter.view
        sheet.popoverPresentationController?.sourceRect = CGRect(x: presenter.view.bounds.midX, y: presenter.view.bounds.maxY - 60, width: 1, height: 1)
        presenter.present(sheet, animated: true)
        #endif
    }
}

/// Live `@` mention autocomplete palette for referencing workspace `files/` or other non-private chats.
struct ChatAtMentionPalette: View {
    let query: String
    let workspace: URL
    let bots: [BotProfile]
    let currentBotId: String
    let onSelectFile: (String) -> Void
    let onSelectBot: (BotProfile) -> Void

    private var matchingFiles: [String] {
        let root = workspace.appendingPathComponent("files", isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        let needle = query.lowercased()
        var found: [String] = []
        while let url = enumerator.nextObject() as? URL {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            let rel = url.path.replacingOccurrences(of: root.path + "/", with: "")
            if needle.isEmpty || rel.lowercased().contains(needle) {
                found.append("files/\(rel)")
                if found.count >= 8 { break }
            }
        }
        return found
    }

    private var matchingBots: [BotProfile] {
        let needle = query.lowercased()
        return bots.filter { bot in
            !bot.isPrivate && bot.id != currentBotId && (needle.isEmpty || bot.name.lowercased().contains(needle))
        }.prefix(6).map { $0 }
    }

    var body: some View {
        let files = matchingFiles
        let chats = matchingBots
        if !files.isEmpty || !chats.isEmpty {
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    if !files.isEmpty {
                        Text("工作区文件")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 10)
                            .padding(.top, 4)
                        ForEach(files, id: \.self) { rel in
                            Button {
                                onSelectFile(rel)
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: "doc.text")
                                        .font(.caption)
                                        .foregroundStyle(DSTheme.brand)
                                    Text(rel)
                                        .font(.subheadline)
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Spacer()
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    if !chats.isEmpty {
                        Text("引用对话 / 提及 Bot")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 10)
                            .padding(.top, 4)
                        ForEach(chats) { candidate in
                            Button {
                                onSelectBot(candidate)
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: "quote.bubble")
                                        .font(.caption)
                                        .foregroundStyle(.indigo)
                                    Text(candidate.name)
                                        .font(.subheadline)
                                        .foregroundStyle(.primary)
                                    Spacer()
                                    Text(candidate.isGroup ? "群聊" : "会话")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.vertical, 6)
            }
            .frame(maxHeight: 200)
            .background(DSTheme.surfaceSecondary)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.secondary.opacity(0.16), lineWidth: 0.75)
            )
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
    }
}

/// Multi-thread switcher & organizer sheet for a Bot (P1-1: 一 Bot 多会话 + 置顶/归档/重命名/删除).
struct BotThreadsSheet: View {
    @Environment(\.dismiss) private var dismiss
    let bot: BotProfile
    @ObservedObject var threadStore: BotThreadStore
    let onSelectThread: (BotThread) -> Void
    let onDeleteSession: (String) -> Void

    @State private var newTitle = ""
    @State private var showArchived = false

    var body: some View {
        NavigationStack {
            List {
                Section("新建独立话题") {
                    HStack {
                        TextField("话题名称（留空自动命名）", text: $newTitle)
                        Button("新建") {
                            let created = threadStore.createThread(for: bot.id, title: newTitle)
                            newTitle = ""
                            onSelectThread(created)
                            dismiss()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                }

                let active = threadStore.activeThread(for: bot.id)
                let threads = threadStore.threads(for: bot.id, includeArchived: showArchived)
                Section("「\(bot.name)」的话题列表（\(threads.count)）") {
                    ForEach(threads) { thread in
                        Button {
                            threadStore.selectThread(thread)
                            onSelectThread(thread)
                            dismiss()
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: thread.isPinned ? "pin.fill" : (thread.isDefault ? "bubble.left.and.bubble.right.fill" : "bubble.left"))
                                    .foregroundStyle(thread.id == active.id ? DSTheme.brand : .secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 6) {
                                        Text(thread.title)
                                            .font(.subheadline.weight(thread.id == active.id ? .semibold : .regular))
                                            .foregroundStyle(.primary)
                                        if thread.isArchived {
                                            Text("已归档")
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    Text(thread.createdAt, style: .date)
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                                Spacer()
                                if thread.id == active.id {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(DSTheme.brand)
                                }
                            }
                        }
                        .swipeActions(edge: .leading) {
                            Button {
                                threadStore.togglePin(botId: bot.id, threadId: thread.id)
                            } label: {
                                Label(thread.isPinned ? "取消置顶" : "置顶", systemImage: thread.isPinned ? "pin.slash" : "pin")
                            }
                            .tint(.orange)
                        }
                        .swipeActions(edge: .trailing) {
                            if !thread.isDefault {
                                Button(role: .destructive) {
                                    if let removedSessionId = threadStore.deleteThread(botId: bot.id, threadId: thread.id) {
                                        onDeleteSession(removedSessionId)
                                    }
                                } label: {
                                    Label("删除", systemImage: "trash")
                                }
                                Button {
                                    threadStore.toggleArchive(botId: bot.id, threadId: thread.id)
                                } label: {
                                    Label(thread.isArchived ? "取消归档" : "归档", systemImage: "archivebox")
                                }
                                .tint(.indigo)
                            }
                        }
                    }
                }

                Section {
                    Toggle("显示已归档话题", isOn: $showArchived)
                }
            }
            .navigationTitle("多话题切换")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}



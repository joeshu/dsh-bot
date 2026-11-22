import Foundation
import SwiftUI

// MARK: - 1. DSH Structured User Question Card (`ask_user_question`)

public struct DSHUserQuestionCard: View {
    let request: PendingDSHQuestion
    let onSubmit: ([[String: Any]]) -> Void
    @State private var selected: [String: Set<String>] = [:]
    @State private var customText: [String: String] = [:]

    public init(request: PendingDSHQuestion, onSubmit: @escaping ([[String: Any]]) -> Void) {
        self.request = request
        self.onSubmit = onSubmit
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("DSH 需要你的回答", systemImage: "questionmark.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(DSTheme.brand)
                Spacer()
                DSStatusBadge("\(request.questions.count) 项提问", color: DSTheme.brand)
            }

            ForEach(request.questions) { item in
                VStack(alignment: .leading, spacing: 8) {
                    if !item.header.isEmpty {
                        Text(item.header.uppercased())
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.secondary)
                    }
                    Text(item.question)
                        .font(.subheadline.weight(.semibold))
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
                            DSHaptics.impact(.light)
                        } label: {
                            HStack(alignment: .top, spacing: 10) {
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
                            .padding(8)
                            .background(isSelected ? DSTheme.brand.opacity(0.08) : DSTheme.surfacePrimary.opacity(0.6))
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
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
                .padding(10)
                .background(DSTheme.surfacePrimary.opacity(0.75))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }

            Button {
                let answers: [[String: Any]] = request.questions.map { item in
                    var answer: [String: Any] = [
                        "id": item.id,
                        "selected": item.options.filter { selected[item.id, default: []].contains($0.label) }.map(\.label),
                    ]
                    let custom = customText[item.id]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    if !custom.isEmpty { answer["custom"] = custom }
                    return answer
                }
                DSHaptics.impact(.medium)
                onSubmit(answers)
            } label: {
                Label("提交回答", systemImage: "paperplane.fill")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(14)
        .background(DSTheme.brand.opacity(0.10))
        .overlay(
            RoundedRectangle(cornerRadius: DSTheme.cornerCard, style: .continuous)
                .stroke(DSTheme.brand.opacity(0.24), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: DSTheme.cornerCard, style: .continuous))
    }
}

// MARK: - 2. Inline Tool Execution & PTC Dispatch Card

public struct DSHToolActivityCard: View {
    let activity: DSHToolActivity
    let onViewFull: () -> Void

    public init(activity: DSHToolActivity, onViewFull: @escaping () -> Void) {
        self.activity = activity
        self.onViewFull = onViewFull
    }

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
        case "completed": return DSTheme.success
        case "failed": return DSTheme.danger
        case "cancelled": return DSTheme.warning
        default: return .secondary
        }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: statusIcon)
                    .foregroundStyle(statusTint)
                Text(activity.toolName)
                    .font(.subheadline.weight(.semibold).monospaced())
                Spacer()
                DSStatusBadge(activity.phaseLabel, color: statusTint)
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
            DisclosureGroup("查看工具输入与结果预览") {
                VStack(alignment: .leading, spacing: 8) {
                    if !activity.arguments.isEmpty {
                        Text("输入").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                        Text(activity.arguments)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                            .background(.secondary.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    if !activity.result.isEmpty {
                        Text("结果").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                        Text(activity.result)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                            .background(.secondary.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
                .padding(.top, 4)
            }
            .font(.caption)
            if activity.callSequence != nil {
                Button {
                    onViewFull()
                } label: {
                    Label("查看完整工具记录（64 KiB 分页）", systemImage: "doc.text.magnifyingglass")
                        .font(.caption.weight(.medium))
                }
            }
        }
        .padding(12)
        .background(Color.secondary.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: DSTheme.cornerCard, style: .continuous))
    }
}

// MARK: - 2b. Collapsed Consecutive Tool Burst Card

public struct DSHToolBurstCard: View {
    let activities: [DSHToolActivity]
    let onViewFull: (DSHToolActivity) -> Void
    @State private var isExpanded = false

    public init(activities: [DSHToolActivity], onViewFull: @escaping (DSHToolActivity) -> Void) {
        self.activities = activities
        self.onViewFull = onViewFull
    }

    private var runningActivity: DSHToolActivity? {
        activities.last(where: { $0.phase == "started" })
    }

    private var completedCount: Int {
        activities.filter { $0.phase == "completed" }.count
    }

    private var failedCount: Int {
        activities.filter { $0.phase == "failed" || $0.phase == "cancelled" }.count
    }

    private var toolSummaryPills: [(name: String, count: Int)] {
        var counts: [String: Int] = [:]
        var order: [String] = []
        for item in activities {
            if counts[item.toolName] == nil { order.append(item.toolName) }
            counts[item.toolName, default: 0] += 1
        }
        return order.map { ($0, counts[$0] ?? 1) }
    }

    private var statusTint: Color {
        if runningActivity != nil { return DSTheme.brand }
        if failedCount > 0 && completedCount == 0 { return DSTheme.danger }
        if failedCount > 0 { return DSTheme.warning }
        return DSTheme.success
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            } label: {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        if runningActivity != nil {
                            ProgressView()
                                .scaleEffect(0.75)
                        } else {
                            Image(systemName: failedCount > 0 ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                                .foregroundStyle(statusTint)
                        }
                        if let running = runningActivity {
                            Text("正在执行 \(running.toolName)（第 \(activities.count) 步）…")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                        } else {
                            let detail = failedCount > 0
                                ? "\(completedCount) 成功 · \(failedCount) 失败"
                                : "全部成功"
                            Text("执行了 \(activities.count) 项工具调用 · \(detail)")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                        }
                        Spacer()
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(toolSummaryPills, id: \.name) { pill in
                                Text(pill.count > 1 ? "\(pill.name) ×\(pill.count)" : pill.name)
                                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 3)
                                    .background(DSTheme.surfacePrimary.opacity(0.85))
                                    .clipShape(Capsule())
                            }
                        }
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(activities) { activity in
                        DSHToolActivityCard(activity: activity) {
                            onViewFull(activity)
                        }
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(11)
        .background(Color.secondary.opacity(0.07))
        .overlay(
            RoundedRectangle(cornerRadius: DSTheme.cornerCard, style: .continuous)
                .stroke(statusTint.opacity(0.22), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: DSTheme.cornerCard, style: .continuous))
    }
}

// MARK: - 2c. Isolated High-Frequency Streaming Turn Row

public struct StreamingTurnRow: View {
    let botName: String
    @ObservedObject var liveStream: StreamingTurnState
    let collapseThinkingByDefault: Bool
    let onStreamGrowth: () -> Void

    @State private var expandReasoning: Bool
    @State private var userToggledReasoning = false

    public init(
        botName: String,
        liveStream: StreamingTurnState,
        collapseThinkingByDefault: Bool,
        onStreamGrowth: @escaping () -> Void
    ) {
        self.botName = botName
        self.liveStream = liveStream
        self.collapseThinkingByDefault = collapseThinkingByDefault
        self.onStreamGrowth = onStreamGrowth
        _expandReasoning = State(initialValue: !collapseThinkingByDefault)
    }

    private var splitContent: (stable: String, tail: String) {
        Self.splitMarkdownForStreaming(liveStream.content)
    }

    private var telemetryLine: String {
        var parts: [String] = ["\(botName) · \(liveStream.phase.label)"]
        if let ttft = liveStream.firstTokenMs {
            parts.append("首字 \(ttft)ms")
        }
        if liveStream.charsPerSecond > 0, !liveStream.content.isEmpty {
            parts.append("\(liveStream.charsPerSecond) 字/秒")
        }
        if !liveStream.content.isEmpty {
            parts.append("\(liveStream.content.count) 字")
        } else if !liveStream.reasoning.isEmpty {
            parts.append("思考 \(liveStream.reasoning.count) 字")
        }
        return parts.joined(separator: " · ")
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let steer = liveStream.recentSteerNote, !steer.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.triangle.turn.up.right.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Text("已插话引导：\(steer)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.orange.opacity(0.10))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }

            HStack(spacing: 6) {
                ProgressView()
                    .scaleEffect(0.72)
                Image(systemName: liveStream.phase.icon)
                    .font(.caption2)
                    .foregroundStyle(DSTheme.brand)
                Text(telemetryLine)
                    .font(.caption2.monospacedDigit())
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            if !liveStream.reasoning.isEmpty {
                let title = liveStream.content.isEmpty
                    ? "深度思考中…（\(liveStream.reasoning.count) 字）"
                    : "已完成思考（\(liveStream.reasoning.count) 字）"
                DisclosureGroup(
                    title,
                    isExpanded: Binding(
                        get: { expandReasoning },
                        set: { next in
                            userToggledReasoning = true
                            expandReasoning = next
                        }
                    )
                ) {
                    Text(liveStream.reasoning)
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

            if !liveStream.content.isEmpty {
                let parts = splitContent
                VStack(alignment: .leading, spacing: 6) {
                    if !parts.stable.isEmpty {
                        DSMarkdownText(parts.stable)
                    }
                    if !parts.tail.isEmpty {
                        Text(parts.tail + " ▍")
                            .font(.body)
                            .foregroundStyle(.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(12)
                .background(DSTheme.surfaceSecondary)
                .clipShape(RoundedRectangle(cornerRadius: DSTheme.cornerBubble, style: .continuous))
            }
        }
        .onChange(of: liveStream.content.isEmpty) { isEmpty in
            if !isEmpty && !userToggledReasoning && expandReasoning {
                withAnimation(.easeInOut(duration: 0.2)) {
                    expandReasoning = false
                }
            }
        }
        .onChange(of: liveStream.content.count) { _ in
            onStreamGrowth()
        }
        .onChange(of: liveStream.reasoning.count) { _ in
            onStreamGrowth()
        }
    }

    /// Splits streaming Markdown into stable completed paragraphs (safe for full Markdown rendering)
    /// and a live trailing paragraph (rendered as lightweight plain text) without splitting open code fences.
    static func splitMarkdownForStreaming(_ text: String) -> (stable: String, tail: String) {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count > 2 else { return ("", text) }
        var inFence = false
        var lastSafeSplitLine = -1
        for (idx, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                inFence.toggle()
            } else if !inFence && trimmed.isEmpty && idx < lines.count - 1 {
                lastSafeSplitLine = idx
            }
        }
        guard lastSafeSplitLine > 0 else { return ("", text) }
        let stable = lines[0..<lastSafeSplitLine].joined(separator: "\n")
        let tail = lines[(lastSafeSplitLine + 1)...].joined(separator: "\n")
        return (stable, tail)
    }
}

// MARK: - 3. Inline Approval Audit History Card

public struct DSHApprovalAuditCard: View {
    let audit: DSHApprovalAudit

    public init(audit: DSHApprovalAudit) {
        self.audit = audit
    }

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

    public var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: icon).foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("审批 · \(audit.toolName)")
                    .font(.caption.weight(.semibold))
                Text(audit.outcomeLabel)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(tint)
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

// MARK: - 4. Live Pending Approval Card

public struct DSHPendingApprovalCard: View {
    let approval: PendingApproval
    let onRespond: (Bool) -> Void
    let onApproveAndTrustSandbox: (() -> Void)?

    public init(
        approval: PendingApproval,
        onRespond: @escaping (Bool) -> Void,
        onApproveAndTrustSandbox: (() -> Void)? = nil
    ) {
        self.approval = approval
        self.onRespond = onRespond
        self.onApproveAndTrustSandbox = onApproveAndTrustSandbox
    }

    private var canUpgradeToSandboxAuto: Bool {
        let lower = approval.tool.lowercased()
        return lower == "write" || lower == "edit" || lower == "apply_patch" || lower == "patch"
            || lower == "workspace_write" || lower == "workspace_edit"
            || lower == "terminal_exec" || lower == "web_search" || lower == "memory_save"
            || lower.hasPrefix("redteam_")
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "hand.raised.fill")
                    .foregroundColor(DSTheme.warning)
                Text("需要审批：\(approval.tool)")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                DSStatusBadge(approval.isDSH ? "DSH Guard" : "iOS 沙盒", color: DSTheme.warning)
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
                Text(approval.summary)
                    .font(.caption.monospaced())
                    .foregroundColor(.secondary)
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(DSTheme.surfacePrimary.opacity(0.75))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            Text("工具结果会返回当前模型服务。")
                .font(.caption2)
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Button {
                    DSHaptics.impact(.medium)
                    onRespond(true)
                } label: {
                    Label("批准执行", systemImage: "checkmark.circle.fill")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                Button(role: .destructive) {
                    DSHaptics.impact(.light)
                    onRespond(false)
                } label: {
                    Label("拒绝", systemImage: "xmark.circle")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            if canUpgradeToSandboxAuto, let onApproveAndTrustSandbox {
                Button {
                    DSHaptics.notify(.success)
                    onApproveAndTrustSandbox()
                } label: {
                    Label("批准并将本 Bot 切至「沙盒免打扰」", systemImage: "bolt.shield.fill")
                        .font(.caption.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(DSTheme.success)
            }
        }
        .padding(14)
        .background(DSTheme.warning.opacity(0.12))
        .overlay(
            RoundedRectangle(cornerRadius: DSTheme.cornerCard, style: .continuous)
                .stroke(DSTheme.warning.opacity(0.32), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: DSTheme.cornerCard, style: .continuous))
    }
}

// MARK: - 5. Create Bot / Group Sheet

public enum CreateBotInitialKind: String, Identifiable {
    case standard
    case group
    case privateSpace

    public var id: String { rawValue }
}

public struct CreateBotSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var host: LocalAgentHost
    @State private var name = ""
    @State private var roleLabel = ""
    @State private var model = ModelProvider.defaultModel
    @State private var systemPrompt = ""
    @State private var isPrivate: Bool
    @State private var isGroup: Bool
    @State private var permissionMode = "ask"
    @State private var agentPreset = "standard"
    @State private var redteamToolsEnabled = false
    @State private var redteamWriteEnabled = false
    @State private var redteamSensitiveDataEnabled = false

    public init(host: LocalAgentHost, initialKind: CreateBotInitialKind = .standard) {
        self.host = host
        _isGroup = State(initialValue: initialKind == .group)
        _isPrivate = State(initialValue: initialKind == .privateSpace)
    }

    private static let presets: [(title: String, icon: String, role: String, model: String, prompt: String)] = [
        ("代码架构师", "cpu.fill", "架构设计与代码审查", ModelProvider.thinkingModel, "你是资深软件架构师，先给出清晰结论，再提供可验证的代码与边界风险分析。"),
        ("研报分析师", "doc.text.magnifyingglass", "资料提炼与结构化研报", ModelProvider.thinkingModel, "你擅长将长文档和网页信息提炼为结构化研报，区分事实、推断与待核查项。"),
        ("英文润色", "character.book.closed.fill", "地道学术与商务英文润色", ModelProvider.defaultModel, "你负责将中英文内容润色为自然地道的表达，并简要列出关键修改理由。"),
        ("红队评测", "shield.lefthalf.filled", "提示词安全与边界评测", ModelProvider.thinkingModel, "你负责评估系统提示词与安全策略的鲁棒性，输出客观复现步骤与修复建议。"),
        ("日常翻译", "globe.asia.australia.fill", "中英日精准互译", ModelProvider.defaultModel, "请准确自然地翻译用户输入，保留专业术语与排版格式。")
    ]

    private func redteamPresetAllowed(_ preset: DSHAgentPresetOption) -> Bool {
        preset.isAvailable && !isPrivate && host.redteamModeEnabled && redteamToolsEnabled
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section("快捷角色模板") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(Self.presets, id: \.title) { preset in
                                let isChosen = name == preset.title
                                Button {
                                    name = preset.title
                                    roleLabel = preset.role
                                    model = preset.model
                                    systemPrompt = preset.prompt
                                    DSHaptics.impact(.light)
                                } label: {
                                    VStack(alignment: .leading, spacing: 4) {
                                        HStack(spacing: 6) {
                                            Image(systemName: preset.icon)
                                                .foregroundStyle(isChosen ? .white : DSTheme.brand)
                                            Text(preset.title)
                                                .font(.caption.weight(.semibold))
                                                .foregroundStyle(isChosen ? .white : .primary)
                                        }
                                        Text(preset.role)
                                            .font(.caption2)
                                            .foregroundStyle(isChosen ? .white.opacity(0.85) : .secondary)
                                            .lineLimit(1)
                                    }
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                    .background(isChosen ? DSTheme.brand : DSTheme.surfaceSecondary)
                                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
                Section("身份与模型配置") {
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
                    if let currentPreset = host.dshAgentPresets.first(where: { $0.id == agentPreset }),
                       !currentPreset.description.isEmpty {
                        Text(currentPreset.description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Section("系统提示词（可选）") {
                    TextEditor(text: $systemPrompt)
                        .frame(minHeight: 72)
                }
                Section("权限预设与空间隔离") {
                    Picker("审批档位", selection: $permissionMode) {
                        Text("只读保护").tag("readOnly")
                        Text("标准审批").tag("ask")
                        Text("沙盒免打扰").tag("autoReview")
                    }
                    Toggle("创建群会话与共享待办", isOn: $isGroup)
                        .onChange(of: isGroup) { v in if v { isPrivate = false } }
                    Toggle("锁定私密会话（面容解锁，Web 隔离）", isOn: $isPrivate)
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
            .navigationTitle("新建智能体 / 群聊")
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

// MARK: - 6. Edit Bot Sheet

public struct EditBotSheet: View {
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
    public init(bot: BotProfile, host: LocalAgentHost) {
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
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section("智能体信息") {
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
                    .disabled(host.isStreaming)
                    Text("支持随时无损切换模式（保留全部聊天历史，下轮发送自动热切换 DSH 工具与引擎配置）。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section("审批档位（三档治理）") {
                    Picker("工具审批档位", selection: $permissionMode) {
                        Text("只读保护").tag("readOnly")
                        Text("标准审批").tag("ask")
                        Text("沙盒免打扰").tag("autoReview")
                    }
                    Text("• 只读保护：拦截全部写入、删除、终端变更与代码执行。\n• 标准审批：写入、删除、终端、Python、联网与红队工具逐次人工确认。\n• 沙盒免打扰：所有已授权沙盒工具（含读写删除、终端、Python 与已授权红队工具）全程自动放行并记录审计日志，无需人工弹窗确认。")
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

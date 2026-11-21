import SwiftUI
import UniformTypeIdentifiers

public struct ExperimentalFeaturesView: View {
    @ObservedObject var host: LocalAgentHost
    @State private var showImporter = false
    @State private var importStatus = ""

    public var body: some View {
        List {
            Section("iOS 可用实验能力") {
                NavigationLink {
                    AutoReviewDetailView(host: host)
                } label: {
                    featureRow(
                        icon: "checkmark.shield.fill",
                        color: .blue,
                        title: "自动授权审查",
                        subtitle: "每次工具调用前自动评估风险，低风险只读调用立即放行，高风险写入仍由你审批。",
                        badge: "实验性",
                        status: host.autoReviewEnabled ? "已启用" : "已停用"
                    )
                }

                NavigationLink {
                    DiagnosticsFeatureDetailView(host: host)
                } label: {
                    featureRow(
                        icon: "doc.text.magnifyingglass",
                        color: .indigo,
                        title: "会话数据诊断与统计",
                        subtitle: "在对话顶部开启诊断入口，查看消息分布、估算 Token、首字延迟与自动审查日志。",
                        badge: "实验性",
                        status: host.sessionDiagnosticsEnabled ? "已启用" : "已停用"
                    )
                }

                Button {
                    showImporter = true
                } label: {
                    featureRow(
                        icon: "square.and.arrow.down.fill",
                        color: .cyan,
                        title: "DeepSeek 会话导入",
                        subtitle: "导入外部 JSON 或 Markdown 对话记录，在本机生成新的可继续追问的会话。",
                        badge: nil,
                        status: "导入"
                    )
                }
                .buttonStyle(.plain)

                Toggle(isOn: $host.collapseThinkingByDefault) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text("思考过程默认折叠").font(.subheadline.weight(.semibold))
                            Text("实验性")
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color(.tertiarySystemFill))
                                .clipShape(Capsule())
                        }
                        Text("推理模型输出时默认收起深度思考块，减少长思考占屏。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if !importStatus.isEmpty {
                Section("导入结果") {
                    Text(importStatus).font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("桌面专属实验项（iOS 沙盒不适用）") {
                desktopUnavailableRow(
                    icon: "terminal.fill",
                    title: "持久终端 (PTY)",
                    reason: "iOS 沙盒禁止派生交互式子进程与伪终端，请使用工作区文件工具或 QuickJS 沙盒。"
                )
                desktopUnavailableRow(
                    icon: "arrow.triangle.branch",
                    title: "Git 工作树与 PR 追踪",
                    reason: "需要本机 git CLI 与桌面仓库文件系统；可通过 GitHub Remote MCP 连接器管理仓库与 PR。"
                )
                desktopUnavailableRow(
                    icon: "ladybug.fill",
                    title: "Chrome DevTools 后端调试",
                    reason: "iOS 安全构建已禁用 inspector 端口监听，可使用上方的原生「会话数据诊断」。"
                )
            }
        }
        .navigationTitle("实验性插件")
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.json, .plainText, .text],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                do {
                    let bot = try host.importConversation(from: url)
                    importStatus = "已导入会话「\(bot.name)」，可在「会话」或「Bot」页打开继续对话。"
                } catch {
                    importStatus = "导入失败：\(error.localizedDescription)"
                }
            case .failure(let error):
                importStatus = "选择文件失败：\(error.localizedDescription)"
            }
        }
    }

    private func featureRow(icon: String, color: Color, title: String, subtitle: String, badge: String?, status: String) -> some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(color.opacity(0.14))
                    .frame(width: 40, height: 40)
                Image(systemName: icon)
                    .foregroundStyle(color)
                    .font(.system(size: 18))
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(title).font(.subheadline.weight(.semibold))
                    if let badge {
                        Text(badge)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color(.tertiarySystemFill))
                            .clipShape(Capsule())
                    }
                }
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            Text(status)
                .font(.caption)
                .foregroundStyle(status == "已启用" ? DSTheme.success : .secondary)
        }
        .padding(.vertical, 4)
    }

    private func desktopUnavailableRow(icon: String, title: String, reason: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(.tertiarySystemFill))
                    .frame(width: 36, height: 36)
                Image(systemName: icon).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(title).font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                    Text("仅桌面端").font(.caption2).foregroundStyle(.secondary)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color(.tertiarySystemFill)).clipShape(Capsule())
                }
                Text(reason).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct AutoReviewDetailView: View {
    @ObservedObject var host: LocalAgentHost

    var body: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.blue.opacity(0.14))
                            .frame(width: 48, height: 48)
                        Image(systemName: "checkmark.shield.fill")
                            .font(.title2)
                            .foregroundStyle(.blue)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("自动授权审查").font(.headline)
                        HStack(spacing: 6) {
                            Text("v0.2.2-rc.5").font(.caption2).padding(.horizontal, 6).padding(.vertical, 2).background(Color(.tertiarySystemFill)).clipShape(Capsule())
                            Text("实验性").font(.caption2).padding(.horizontal, 6).padding(.vertical, 2).background(Color(.tertiarySystemFill)).clipShape(Capsule())
                        }
                    }
                    Spacer()
                    Toggle("", isOn: $host.autoReviewEnabled).labelsHidden()
                }
                Text("开启后，低风险只读工具（列出/读取/搜索工作区文件、读取设备状态）将自动放行并记录审计日志；写文件、修改记忆、联网抓取与外部 MCP 仍需要你手动审批。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("包含的组件") {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("自动授权审查策略引擎").font(.subheadline.weight(.semibold))
                        HStack(spacing: 4) {
                            Circle()
                                .fill(host.autoReviewEnabled ? DSTheme.success : Color.secondary)
                                .frame(width: 7, height: 7)
                            Text(host.autoReviewEnabled ? "运行中" : "已关闭")
                                .font(.caption)
                                .foregroundStyle(host.autoReviewEnabled ? DSTheme.success : .secondary)
                        }
                    }
                    Spacer()
                    Toggle("", isOn: $host.autoReviewEnabled).labelsHidden()
                }
            }

            if !host.autoReviewLog.isEmpty {
                Section("近期自动审查日志") {
                    ForEach(host.autoReviewLog, id: \.self) { entry in
                        Text(entry).font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                }
            }

            Section("高级") {
                LabeledContent("包名", value: "@dsbot/ios-auto-review")
                LabeledContent("代码来源", value: "内置")
                LabeledContent("当前版本", value: host.appVersion)
            }
        }
        .navigationTitle("自动授权审查")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct DiagnosticsFeatureDetailView: View {
    @ObservedObject var host: LocalAgentHost

    var body: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.indigo.opacity(0.14))
                            .frame(width: 48, height: 48)
                        Image(systemName: "doc.text.magnifyingglass")
                            .font(.title2)
                            .foregroundStyle(.indigo)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("会话数据诊断与统计").font(.headline)
                        HStack(spacing: 6) {
                            Text("v0.2.2-rc.5").font(.caption2).padding(.horizontal, 6).padding(.vertical, 2).background(Color(.tertiarySystemFill)).clipShape(Capsule())
                            Text("实验性").font(.caption2).padding(.horizontal, 6).padding(.vertical, 2).background(Color(.tertiarySystemFill)).clipShape(Capsule())
                        }
                    }
                    Spacer()
                    Toggle("", isOn: $host.sessionDiagnosticsEnabled).labelsHidden()
                }
                Text("开启后，在任意对话页右上角显示诊断图标，可随时查看当前会话的消息分布、上下文字符/Token 估算、首字延迟与数据库占用。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("高级") {
                LabeledContent("包名", value: "@dsbot/ios-session-diagnostics")
                LabeledContent("代码来源", value: "内置")
                LabeledContent("本地 SQLite", value: ByteCountFormatter.string(fromByteCount: host.sqliteDatabaseSizeBytes(), countStyle: .file))
            }
        }
        .navigationTitle("会话数据诊断")
        .navigationBarTitleDisplayMode(.inline)
    }
}

public struct SessionDiagnosticsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var host: LocalAgentHost
    let bot: BotProfile

    private var messages: [ChatMessageItem] {
        host.messages(for: bot.id)
    }

    private var userCount: Int {
        messages.filter { $0.role == "user" }.count
    }

    private var assistantCount: Int {
        messages.filter { $0.role == "assistant" }.count
    }

    private var totalChars: Int {
        messages.reduce(0) { $0 + $1.content.count + $1.reasoning.count }
    }

    private var estimatedTokens: Int {
        max(0, totalChars / 3)
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section("当前会话概览") {
                    LabeledContent("会话 ID", value: bot.id)
                    LabeledContent("模型", value: bot.model)
                    LabeledContent("权限模式", value: bot.permissionModeLabel)
                    LabeledContent("用户消息 / 回复", value: "\(userCount) / \(assistantCount)")
                    LabeledContent("上下文字符数", value: totalChars.formatted())
                    LabeledContent("估算上下文 Tokens", value: "~\(estimatedTokens.formatted())")
                    if let ttft = host.streamFirstTokenMs {
                        LabeledContent("最近首字延迟", value: "\(ttft) ms")
                    }
                }

                Section("运行时与存储") {
                    LabeledContent("内嵌引擎", value: host.embeddedRuntimeLabel ?? "NodeMobile 24.22.3")
                    LabeledContent("SQLite 大小", value: ByteCountFormatter.string(fromByteCount: host.sqliteDatabaseSizeBytes(), countStyle: .file))
                    LabeledContent("自动授权审查", value: host.autoReviewEnabled ? "已开启" : "关闭")
                }

                if !host.autoReviewLog.isEmpty {
                    Section("自动审查审计记录") {
                        ForEach(host.autoReviewLog.prefix(15), id: \.self) { line in
                            Text(line).font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("会话数据诊断")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}

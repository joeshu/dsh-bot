import SwiftUI
import UniformTypeIdentifiers
#if canImport(UIKit)
import UIKit
#endif

public struct ExperimentalFeaturesView: View {
    @ObservedObject var host: LocalAgentHost
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
                    #if canImport(UIKit)
                    NativeDocumentPicker.present(contentTypes: [.json, .plainText, .text], allowsMultipleSelection: false) { urls in
                        guard let url = urls.first else { return }
                        do {
                            let bot = try host.importConversation(from: url)
                            importStatus = "已导入会话「\(bot.name)」，可在「对话」页打开继续对话。"
                        } catch {
                            importStatus = "导入失败：\(error.localizedDescription)"
                        }
                    }
                    #endif
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

            Section("桌面级开发实验能力（iOS 沙盒引擎已适配）") {
                NavigationLink {
                    VirtualTerminalFeatureView(host: host)
                } label: {
                    featureRow(
                        icon: "terminal.fill",
                        color: .green,
                        title: "持久终端 (沙盒 PTY)",
                        subtitle: "iOS 进程内持久虚拟终端，保留 cwd 与环境变量，支持文件指令、Node VM、离线 Python 与 Git 状态。",
                        badge: "iOS 适配",
                        status: "打开终端"
                    )
                }

                NavigationLink {
                    GitWorktreeTrackerView(host: host)
                } label: {
                    featureRow(
                        icon: "arrow.triangle.branch",
                        color: .orange,
                        title: "Git 工作树与 PR 追踪",
                        subtitle: "追踪沙盒工作区文件新增/修改/删除与 Unified Diff，支持建立基线快照及关联 GitHub 仓库 PR。",
                        badge: "iOS 适配",
                        status: "查看工作树"
                    )
                }

                NavigationLink {
                    BackendDevToolsInspectorView(host: host)
                } label: {
                    featureRow(
                        icon: "ladybug.fill",
                        color: .purple,
                        title: "Chrome DevTools 后端调试",
                        subtitle: "通过私有 IPC 实时检视 Node.js 内存、Cordis 插件 Fiber 状态、已注册工具集与沙盒诊断表达式。",
                        badge: "iOS 适配",
                        status: "打开调试器"
                    )
                }
            }
        }
        .navigationTitle("实验性插件")
        .navigationBarTitleDisplayMode(.inline)
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
}

private struct TerminalLineEntry: Identifiable {
    let id = UUID()
    let isCommand: Bool
    let text: String
    let isError: Bool
}

public struct VirtualTerminalFeatureView: View {
    @ObservedObject var host: LocalAgentHost
    @State private var cwd: String = "/workspace"
    @State private var commandInput: String = ""
    @State private var lines: [TerminalLineEntry] = [
        TerminalLineEntry(
            isCommand: false,
            text: "DS Bot iOS Sandboxed Virtual PTY (Node + Pyodide 3.13 + Virtual Git)\n输入 help 查看支持命令，所有文件操作均限制在沙盒工作区 /workspace (files/) 内。",
            isError: false
        )
    ]
    @State private var isRunning = false

    private let quickCommands = ["help", "pwd", "ls -la", "git status", "git diff", "uname -a", "python -c \"import numpy as np; print(np.arange(6))\""]

    public var body: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    DSStatusBadge("cwd: \(cwd)", color: DSTheme.success)
                    ForEach(quickCommands, id: \.self) { cmd in
                        Button {
                            commandInput = cmd
                            Task { await runCommand(cmd) }
                        } label: {
                            Text(cmd)
                                .font(.caption2.monospaced())
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .background(Color(.secondarySystemFill))
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .disabled(isRunning)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .background(Color(.secondarySystemBackground))

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(lines) { item in
                            Text(item.text)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(item.isCommand ? Color.green : (item.isError ? Color.red : Color.white.opacity(0.92)))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(item.id)
                        }
                    }
                    .padding(12)
                }
                .background(Color(red: 0.07, green: 0.08, blue: 0.10))
                .onChange(of: lines.count) { _ in
                    if let last = lines.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }

            Divider()

            HStack(spacing: 8) {
                Text("$")
                    .font(.system(.body, design: .monospaced).weight(.bold))
                    .foregroundStyle(.green)
                TextField("输入命令（如 ls -la, git status, python -c ...）", text: $commandInput)
                    .font(.system(.subheadline, design: .monospaced))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.send)
                    .onSubmit {
                        let cmd = commandInput
                        Task { await runCommand(cmd) }
                    }
                Button {
                    let cmd = commandInput
                    Task { await runCommand(cmd) }
                } label: {
                    if isRunning {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title3)
                    }
                }
                .disabled(isRunning || commandInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color(.secondarySystemBackground))
        }
        .navigationTitle("持久终端 (沙盒 PTY)")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button("清屏") {
                    lines.removeAll()
                }
                Button("重置") {
                    Task { await resetTerminal() }
                }
            }
        }
        .task {
            await refreshState()
        }
    }

    private func refreshState() async {
        guard let rpc = host.rpc() else { return }
        if let res = try? await rpc.request("terminal.state", params: ["sessionId": "ios-ui"], timeoutSeconds: 10),
           let dir = res["cwd"] as? String {
            cwd = dir
        }
    }

    private func resetTerminal() async {
        guard let rpc = host.rpc() else { return }
        if let res = try? await rpc.request("terminal.reset", params: ["sessionId": "ios-ui"], timeoutSeconds: 10),
           let dir = res["cwd"] as? String {
            cwd = dir
        }
        lines = [TerminalLineEntry(isCommand: false, text: "已重置虚拟终端会话（cwd: \(cwd)）。", isError: false)]
    }

    private func runCommand(_ raw: String) async {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        commandInput = ""
        if trimmed == "clear" {
            lines.removeAll()
            return
        }
        lines.append(TerminalLineEntry(isCommand: true, text: "\(cwd) $ \(trimmed)", isError: false))
        guard let rpc = host.rpc() else {
            lines.append(TerminalLineEntry(isCommand: false, text: "DSH 运行时尚未就绪。", isError: true))
            return
        }
        isRunning = true
        defer { isRunning = false }
        do {
            let res = try await rpc.request("terminal.exec", params: ["sessionId": "ios-ui", "command": trimmed], timeoutSeconds: 60)
            if let dir = res["cwd"] as? String { cwd = dir }
            let exitCode = res["exitCode"] as? Int ?? 0
            let output = res["output"] as? String ?? ""
            if !output.isEmpty {
                lines.append(TerminalLineEntry(isCommand: false, text: output, isError: exitCode != 0))
            }
        } catch {
            lines.append(TerminalLineEntry(isCommand: false, text: "执行失败：\(error.localizedDescription)", isError: true))
        }
    }
}

public struct GitWorktreeTrackerView: View {
    @ObservedObject var host: LocalAgentHost
    @State private var branch: String = "main"
    @State private var repoInput: String = ""
    @State private var snapshotAt: String = ""
    @State private var totalWorkspaceFiles: Int = 0
    @State private var changes: [[String: Any]] = []
    @State private var commits: [[String: Any]] = []
    @State private var pullRequests: [[String: Any]] = []
    @State private var diffText: String = ""
    @State private var snapshotMessage: String = ""
    @State private var statusBanner: String = ""
    @State private var isLoading = false

    public var body: some View {
        Form {
            Section("沙盒工作树状态 (/workspace)") {
                LabeledContent("当前分支", value: branch)
                LabeledContent("工作区文件总数", value: "\(totalWorkspaceFiles)")
                LabeledContent("基线快照时间", value: snapshotAt.isEmpty ? "尚未建立快照" : snapshotAt)
                LabeledContent("未提交变更数", value: "\(changes.count)")

                HStack {
                    TextField("快照提交说明（可选）", text: $snapshotMessage)
                    Button("建立快照基线") {
                        Task { await createSnapshot() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isLoading)
                }
            }

            if !changes.isEmpty {
                Section("工作树变更列表 (\(changes.count))") {
                    ForEach(Array(changes.enumerated()), id: \.offset) { _, item in
                        let path = item["path"] as? String ?? ""
                        let status = item["status"] as? String ?? "M"
                        let label = item["label"] as? String ?? "修改"
                        HStack {
                            DSStatusBadge(
                                "\(status) · \(label)",
                                color: status == "A" ? DSTheme.success : (status == "D" ? DSTheme.danger : .orange)
                            )
                            Text(path)
                                .font(.caption.monospaced())
                            Spacer()
                            Button("Diff") {
                                Task { await loadDiff(path: path) }
                            }
                            .font(.caption)
                        }
                    }
                    Button("查看全部工作树 Unified Diff") {
                        Task { await loadDiff(path: nil) }
                    }
                }
            }

            if !diffText.isEmpty {
                Section("Unified Diff 预览") {
                    ScrollView(.horizontal, showsIndicators: true) {
                        Text(diffText)
                            .font(.system(.caption2, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(.vertical, 4)
                    }
                }
            }

            Section("GitHub 仓库与 Pull Requests 追踪") {
                TextField("owner/repo（例如 CallMeGuLab/dsh-purge-safe）", text: $repoInput)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button {
                    Task { await fetchPRs() }
                } label: {
                    Label("同步 GitHub Pull Requests 与提交", systemImage: "arrow.triangle.pull")
                }
                .disabled(isLoading || repoInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                if !statusBanner.isEmpty {
                    Text(statusBanner)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                ForEach(Array(pullRequests.enumerated()), id: \.offset) { _, pr in
                    let number = pr["number"] as? Int ?? 0
                    let title = pr["title"] as? String ?? ""
                    let state = pr["state"] as? String ?? "open"
                    let author = pr["author"] as? String ?? ""
                    let branchInfo = pr["branch"] as? String ?? ""
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("#\(number) \(title)")
                                .font(.subheadline.weight(.semibold))
                            Spacer()
                            DSStatusBadge(
                                state.uppercased(),
                                color: state == "open" ? DSTheme.success : (state == "merged" ? .purple : .secondary)
                            )
                        }
                        Text("\(author) · \(branchInfo)")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }
            }

            if !commits.isEmpty {
                Section("本地快照历史 (\(commits.count))") {
                    ForEach(Array(commits.enumerated()), id: \.offset) { _, commit in
                        let id = commit["id"] as? String ?? ""
                        let msg = commit["message"] as? String ?? ""
                        let ts = commit["timestamp"] as? String ?? ""
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(id).font(.caption.monospaced().weight(.bold)).foregroundStyle(DSTheme.brand)
                                Text(msg).font(.caption.weight(.medium))
                            }
                            Text(ts).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("Git 工作树与 PR 追踪")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await refreshGitStatus() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
            }
        }
        .task {
            await refreshGitStatus()
        }
    }

    private func refreshGitStatus() async {
        guard let rpc = host.rpc() else { return }
        isLoading = true
        defer { isLoading = false }
        if let res = try? await rpc.request("git.status", timeoutSeconds: 15) {
            applyStatusResponse(res)
        }
    }

    private func applyStatusResponse(_ res: [String: Any]) {
        branch = res["branch"] as? String ?? "main"
        let savedRepo = res["repo"] as? String ?? ""
        if repoInput.isEmpty && !savedRepo.isEmpty { repoInput = savedRepo }
        snapshotAt = res["snapshotAt"] as? String ?? ""
        totalWorkspaceFiles = res["totalWorkspaceFiles"] as? Int ?? 0
        changes = res["changes"] as? [[String: Any]] ?? []
        commits = res["commits"] as? [[String: Any]] ?? []
    }

    private func createSnapshot() async {
        guard let rpc = host.rpc() else { return }
        isLoading = true
        defer { isLoading = false }
        let msg = snapshotMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        if let res = try? await rpc.request("git.snapshot", params: ["message": msg.isEmpty ? "Workspace snapshot" : msg], timeoutSeconds: 15) {
            snapshotMessage = ""
            diffText = ""
            applyStatusResponse(res)
        }
    }

    private func loadDiff(path: String?) async {
        guard let rpc = host.rpc() else { return }
        var params: [String: Any] = [:]
        if let path { params["path"] = path }
        if let res = try? await rpc.request("git.diff", params: params, timeoutSeconds: 15) {
            diffText = res["diff"] as? String ?? ""
        }
    }

    private func fetchPRs() async {
        guard let rpc = host.rpc() else { return }
        isLoading = true
        statusBanner = "正在从 GitHub 同步 PR 列表…"
        defer { isLoading = false }
        do {
            let res = try await rpc.request("git.pullRequests", params: ["repo": repoInput], timeoutSeconds: 20)
            pullRequests = res["pullRequests"] as? [[String: Any]] ?? []
            statusBanner = "已同步 \(pullRequests.count) 条 Pull Request 记录。"
        } catch {
            statusBanner = "同步失败：\(error.localizedDescription)"
        }
    }
}

public struct BackendDevToolsInspectorView: View {
    @ObservedObject var host: LocalAgentHost
    @ObservedObject private var memoryGovernor = MemoryGovernor.shared
    @State private var nodeVersion: String = "-"
    @State private var dshVersion: String = "-"
    @State private var uptimeSeconds: Int = 0
    @State private var rssMB: Double = 0
    @State private var heapUsedMB: Double = 0
    @State private var heapTotalMB: Double = 0
    @State private var webPort: Int = 0
    @State private var cordisEntries: [[String: Any]] = []
    @State private var registeredTools: [[String: Any]] = []
    @State private var evalExpression: String = "({ memory: process.memoryUsage(), plugins: runtime.activePlugins.length, tools: tools.length })"
    @State private var evalOutput: String = ""

    public var body: some View {
        Form {
            Section("iOS 宿主机 Jetsam 与内存治理") {
                let snap = memoryGovernor.snapshot
                LabeledContent("物理内存占用 (phys_footprint)", value: String(format: "%.1f MB", snap.physFootprintMB))
                LabeledContent("Jetsam 可用余量", value: snap.availableMB > 0 ? String(format: "%.1f MB", snap.availableMB) : "模拟器/未知")
                LabeledContent("内存压力等级", value: snap.tier.displayName)
                LabeledContent("NodeMobile V8 堆上限", value: "\(snap.nodeHeapLimitMB) MB")
                LabeledContent("打开文件描述符 (FD)", value: "\(snap.openFDCount)")
                LabeledContent("MetricKit 遥测", value: snap.lastMetricSummary)
                Button("刷新内存快照") {
                    memoryGovernor.refreshSnapshot()
                }
                .font(.caption)
            }

            Section("NodeMobile 与 DSH 内核实时指标") {
                LabeledContent("Node.js 版本", value: nodeVersion)
                LabeledContent("DSH 核心版本", value: dshVersion)
                LabeledContent("进程运行时间", value: "\(uptimeSeconds) 秒")
                LabeledContent("内存占用 (RSS)", value: String(format: "%.1f MB", rssMB))
                LabeledContent("V8 堆内存 (Used / Total)", value: String(format: "%.1f / %.1f MB", heapUsedMB, heapTotalMB))
                LabeledContent("回环 Web 端口", value: webPort > 0 ? "127.0.0.1:\(webPort)" : "未启动")
            }

            Section("DevTools 沙盒诊断控制台 (REPL)") {
                TextField("输入诊断 JS 表达式（如 tools, runtime.activePlugins）", text: $evalExpression)
                    .font(.system(.caption, design: .monospaced))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button {
                    Task { await runEval() }
                } label: {
                    Label("执行后端诊断表达式", systemImage: "play.fill")
                }
                if !evalOutput.isEmpty {
                    ScrollView(.horizontal, showsIndicators: true) {
                        Text(evalOutput)
                            .font(.system(.caption2, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(.vertical, 4)
                    }
                }
            }

            Section("Cordis Loader 插件 Fiber 树 (\(cordisEntries.count))") {
                DisclosureGroup("展开查看全部 \(cordisEntries.count) 个 Cordis 实例") {
                    ForEach(Array(cordisEntries.enumerated()), id: \.offset) { _, entry in
                        let id = entry["id"] as? String ?? ""
                        let name = entry["name"] as? String ?? ""
                        let state = entry["state"] as? String ?? "inactive"
                        HStack {
                            Circle()
                                .fill(state == "active" ? DSTheme.success : .secondary)
                                .frame(width: 7, height: 7)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(id.isEmpty ? name : id)
                                    .font(.caption.monospaced().weight(.semibold))
                                Text(name)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(state)
                                .font(.caption2)
                                .foregroundStyle(state == "active" ? DSTheme.success : .secondary)
                        }
                    }
                }
            }

            Section("已注册 DSH 工具注册表 (\(registeredTools.count))") {
                DisclosureGroup("展开查看全部 \(registeredTools.count) 个工具定义") {
                    ForEach(Array(registeredTools.enumerated()), id: \.offset) { _, tool in
                        let name = tool["name"] as? String ?? ""
                        let desc = tool["description"] as? String ?? ""
                        VStack(alignment: .leading, spacing: 2) {
                            Text(name).font(.caption.monospaced().weight(.bold))
                            if !desc.isEmpty {
                                Text(desc).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
        .navigationTitle("DevTools 后端调试")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await refreshInspector() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
            }
        }
        .task {
            await refreshInspector()
        }
    }

    private func refreshInspector() async {
        memoryGovernor.refreshSnapshot()
        guard let rpc = host.rpc() else { return }
        if let res = try? await rpc.request("devtools.inspect", timeoutSeconds: 10) {
            nodeVersion = res["nodeVersion"] as? String ?? "-"
            dshVersion = res["dshVersion"] as? String ?? "-"
            uptimeSeconds = res["uptimeSeconds"] as? Int ?? 0
            webPort = res["webPort"] as? Int ?? 0
            if let mem = res["memory"] as? [String: Any] {
                rssMB = (mem["rssMB"] as? NSNumber)?.doubleValue ?? 0
                heapUsedMB = (mem["heapUsedMB"] as? NSNumber)?.doubleValue ?? 0
                heapTotalMB = (mem["heapTotalMB"] as? NSNumber)?.doubleValue ?? 0
            }
            cordisEntries = res["cordisEntries"] as? [[String: Any]] ?? []
            registeredTools = res["registeredTools"] as? [[String: Any]] ?? []
        }
    }

    private func runEval() async {
        guard let rpc = host.rpc() else { return }
        do {
            let res = try await rpc.request("devtools.eval", params: ["expression": evalExpression], timeoutSeconds: 10)
            let raw = res["output"] as? String ?? ""
            evalOutput = SecretRedactor.redactCommonTokens(raw)
        } catch {
            evalOutput = "错误：\(SecretRedactor.redactCommonTokens(error.localizedDescription))"
        }
    }
}

struct AutoReviewDetailView: View {
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

struct DiagnosticsFeatureDetailView: View {
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
                    let memSnap = MemoryGovernor.shared.snapshot
                    LabeledContent("内嵌引擎", value: host.embeddedRuntimeLabel ?? "NodeMobile 24.22.3")
                    LabeledContent("SQLite 大小", value: ByteCountFormatter.string(fromByteCount: host.sqliteDatabaseSizeBytes(), countStyle: .file))
                    LabeledContent("物理内存 / Jetsam 余量", value: String(format: "%.1f MB / %.1f MB", memSnap.physFootprintMB, memSnap.availableMB))
                    LabeledContent("压力等级 / 打开 FD", value: "\(memSnap.tier.displayName) · \(memSnap.openFDCount) FD")
                    LabeledContent("自动授权审查", value: host.autoReviewEnabled ? "已开启" : "关闭")
                    Button {
                        let mem = MemoryGovernor.shared.refreshSnapshot()
                        let rawReport = """
                        DS-Bot Session Diagnostics
                        sessionId: \(bot.id)
                        model: \(bot.model)
                        preset: \(bot.agentPreset)
                        messages: user=\(userCount), assistant=\(assistantCount)
                        physFootprintMB: \(String(format: "%.1f", mem.physFootprintMB))
                        availableMB: \(String(format: "%.1f", mem.availableMB))
                        pressureTier: \(mem.tier.rawValue)
                        openFD: \(mem.openFDCount)
                        nodeHeapCapMB: \(mem.nodeHeapLimitMB)
                        """
                        #if canImport(UIKit)
                        UIPasteboard.general.string = SecretRedactor.redactCommonTokens(rawReport)
                        #endif
                        DSHaptics.notify(.success)
                    } label: {
                        Label("复制脱敏诊断摘要", systemImage: "doc.on.doc")
                    }
                }

                if !host.autoReviewLog.isEmpty {
                    Section("自动审查审计记录") {
                        ForEach(host.autoReviewLog.prefix(15), id: \.self) { line in
                            Text(SecretRedactor.redactCommonTokens(line)).font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("会话数据诊断")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { MemoryGovernor.shared.refreshSnapshot() }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}

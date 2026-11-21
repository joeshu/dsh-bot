import SwiftUI

public struct JobsBotPickerView: View {
    @ObservedObject var host: LocalAgentHost

    private var eligibleBots: [BotProfile] {
        host.sortBySessionActivity(host.bots.filter {
            !$0.isPrivate && ($0.agentPreset == "standard" || $0.agentPreset == "cordis")
        })
    }

    public var body: some View {
        List {
            Section {
                Text("后台任务按 Bot 会话隔离。仅标准和创造模式可启动离线 Python/NumPy 任务；私密 Bot 不开放 Jobs。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("选择 Bot") {
                if eligibleBots.isEmpty {
                    DSEmptyStateView(
                        icon: "hourglass",
                        title: "没有可管理的智能体",
                        subtitle: "新建或编辑一个非私密智能体，并选择标准模式或创造模式。"
                    )
                    .listRowBackground(Color.clear)
                } else {
                    ForEach(eligibleBots) { bot in
                        NavigationLink {
                            JobsManagerView(host: host, botId: bot.id)
                        } label: {
                            HStack(spacing: 10) {
                                DSBotAvatar(initials: bot.name, color: DSTheme.botAvatarColor(bot),
                                            isPrivate: false, size: 36)
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack(spacing: 6) {
                                        Text(bot.name).font(.subheadline.weight(.semibold))
                                        DSPresetBadge(presetId: bot.agentPreset, label: bot.agentPresetLabel)
                                    }
                                    Text(bot.roleLabel)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("后台任务")
        .navigationBarTitleDisplayMode(.inline)
    }
}

public struct JobsManagerView: View {
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject var host: LocalAgentHost
    let botId: String

    @State private var jobs: [[String: Any]] = []
    @State private var isLoading = false
    @State private var errorMessage = ""
    @State private var selectedJob: JobOutputRoute?
    @State private var pendingKill: [String: Any]?

    public init(host: LocalAgentHost, botId: String) {
        self.host = host
        self.botId = botId
    }

    public var body: some View {
        List {
            Section {
                Text("标准和创造模式可让 Bot 启动经审批的离线 Python/NumPy 计算。任务与输出由 DSH Jobs 的进程内注册表管理，按 Bot 会话隔离；每个 Bot 最多登记一个任务，整个 App 同时只运行一个 Python Worker。App 切到后台时会尽量保留有 Jobs 记录的 Bot；iOS 可能挂起或终止 Host，因此后台执行不保证。完成通知会留在会话收件箱，并由下一次用户输入带入。打开页面时每 3 秒自动刷新任务状态和保留输出。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if isLoading && jobs.isEmpty {
                ProgressView("正在读取后台任务…")
            } else if jobs.isEmpty {
                DSEmptyStateView(
                    icon: "hourglass",
                    title: "暂无后台任务",
                    subtitle: "可以在标准或创造模式的对话中要求智能体将较长的离线 Python/NumPy 计算作为后台任务运行。"
                )
                .listRowBackground(Color.clear)
            }

            ForEach(jobs, id: \.jobID) { job in
                JobRow(job: job, onOutput: {
                    selectedJob = JobOutputRoute(job: job)
                }, onKill: {
                    pendingKill = job
                })
            }

            if !errorMessage.isEmpty {
                Section("状态") {
                    Text(errorMessage).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("后台任务")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await reload() }
                } label: {
                    if isLoading { ProgressView() } else { Image(systemName: "arrow.clockwise") }
                }
                .disabled(isLoading)
                .accessibilityLabel("刷新后台任务")
            }
        }
        .task(id: scenePhase == .active && selectedJob.map(\.id) == nil) {
            guard scenePhase == .active, selectedJob.map(\.id) == nil else { return }
            while !Task.isCancelled {
                await reload()
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
        .refreshable { await reload() }
        .sheet(item: $selectedJob) { route in
            NavigationStack {
                JobOutputView(host: host, botId: botId, job: route.job)
            }
        }
        .confirmationDialog(
            "取消“\(pendingKill?["label"] as? String ?? "后台任务")”？",
            isPresented: Binding(
                get: { pendingKill.map { _ in true } ?? false },
                set: { if !$0 { pendingKill = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("取消任务", role: .destructive) {
                guard let job = pendingKill else { return }
                pendingKill = nil
                Task { await kill(job) }
            }
            Button("返回", role: .cancel) { pendingKill = nil }
        } message: {
            Text("任务取消后会等待 Python Worker 停止，并在任务状态中记录结果。")
        }
    }

    private func reload() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            guard let rpc = host.rpc() else { throw IPCFrameError.channelClosed }
            let generation = host.runtimeGeneration
            let response = try await rpc.request("jobs.list", params: ["botId": botId], timeoutSeconds: 15)
            try Task.checkCancellation()
            guard generation == host.runtimeGeneration else { return }
            jobs = (response["jobs"] as? [[String: Any]] ?? []).sorted {
                (($0["startedAt"] as? NSNumber)?.doubleValue ?? 0)
                    > (($1["startedAt"] as? NSNumber)?.doubleValue ?? 0)
            }
            errorMessage = ""
        } catch is CancellationError {
            return
        } catch {
            errorMessage = "无法读取后台任务：\(error.localizedDescription)"
        }
    }

    private func kill(_ job: [String: Any]) async {
        guard let id = job["id"] as? String else { return }
        do {
            guard let rpc = host.rpc() else { throw IPCFrameError.channelClosed }
            let generation = host.runtimeGeneration
            let response = try await rpc.request("jobs.kill", params: [
                "botId": botId, "jobId": id, "reason": "Cancelled from the iOS Jobs manager",
            ], timeoutSeconds: 15)
            try Task.checkCancellation()
            guard generation == host.runtimeGeneration else { return }
            guard response["found"] as? Bool == true else {
                errorMessage = "任务已结束或不属于当前 Bot。请刷新任务列表。"
                await reload()
                return
            }
            errorMessage = ""
            await reload()
        } catch is CancellationError {
            return
        } catch {
            errorMessage = "取消任务失败：\(error.localizedDescription)"
        }
    }
}

private struct JobRow: View {
    let job: [String: Any]
    let onOutput: () -> Void
    let onKill: () -> Void

    private var status: String { job["status"] as? String ?? "unknown" }
    private var canCancel: Bool { status == "running" }
    private var label: String { job["label"] as? String ?? "未命名任务" }
    private var output: [String: Any] { job["output"] as? [String: Any] ?? [:] }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(label).font(.subheadline.weight(.semibold)).lineLimit(2)
                Spacer(minLength: 8)
                Text(statusLabel)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(statusColor)
            }
            if let progress = job["progress"] as? String, !progress.isEmpty {
                Label(progress, systemImage: "arrow.trianglehead.2.clockwise.rotate.90")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            HStack(spacing: 12) {
                Text(job["kind"] as? String ?? "job")
                if let startedAt = job["startedAt"] as? NSNumber {
                    Text(Date(timeIntervalSince1970: startedAt.doubleValue / 1000)
                        .formatted(date: .omitted, time: .shortened))
                }
                Text(ByteCountFormatter.string(fromByteCount: Int64(output["total"] as? Int ?? 0), countStyle: .memory))
                Spacer(minLength: 0)
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)

            HStack {
                Button("查看输出", action: onOutput)
                    .buttonStyle(.bordered)
                    .font(.caption)
                if canCancel {
                    Button("取消", role: .destructive, action: onKill)
                        .buttonStyle(.bordered)
                        .font(.caption)
                }
                Spacer()
            }
        }
        .padding(.vertical, 5)
    }

    private var statusLabel: String {
        switch status {
        case "running": return "运行中"
        case "stopping": return "正在取消"
        case "completed": return "已完成"
        case "killed": return "已取消"
        case "failed": return "失败"
        default: return status
        }
    }

    private var statusColor: Color {
        switch status {
        case "running", "stopping": return DSTheme.brand
        case "completed": return DSTheme.success
        case "failed", "killed": return DSTheme.warning
        default: return .secondary
        }
    }
}

private struct JobOutputRoute: Identifiable {
    let job: [String: Any]
    var id: String { job["id"] as? String ?? UUID().uuidString }
}

private struct JobOutputView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var host: LocalAgentHost
    let botId: String
    let job: [String: Any]

    @State private var currentJob: [String: Any]
    @State private var output = ""
    @State private var nextOutputOffset = 0
    @State private var lossy = false
    @State private var isLoading = false
    @State private var errorMessage = ""

    init(host: LocalAgentHost, botId: String, job: [String: Any]) {
        self.host = host
        self.botId = botId
        self.job = job
        _currentJob = State(initialValue: job)
    }

    private var jobId: String { job["id"] as? String ?? "" }

    var body: some View {
        List {
            Section("任务") {
                LabeledContent("状态", value: stateLabel)
                LabeledContent("类型", value: currentJob["kind"] as? String ?? "job")
                if let progress = currentJob["progress"] as? String, !progress.isEmpty {
                    LabeledContent("进度", value: progress)
                }
                if let detail = currentJob["detail"] as? String, !detail.isEmpty {
                    Text(detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            Section("输出 · \(outputByteCount)") {
                if lossy {
                    Text("保留窗口之前的部分输出已被滚动丢弃。")
                        .font(.caption)
                        .foregroundStyle(DSTheme.warning)
                }
                if output.isEmpty && !isLoading {
                    Text("暂无输出。任务仍在运行时可下拉刷新。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ScrollView(.vertical) {
                    Text(output)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 440)
            }
            if !errorMessage.isEmpty {
                Section("状态") {
                    Text(errorMessage).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("任务输出")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { Button("完成") { dismiss() } }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await reload() }
                } label: {
                    if isLoading { ProgressView() } else { Image(systemName: "arrow.clockwise") }
                }
                .disabled(isLoading)
                .accessibilityLabel("刷新任务输出")
            }
        }
        .task(id: scenePhase == .active) {
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                await reload()
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
        .refreshable { await reload() }
    }

    private var outputByteCount: String {
        ByteCountFormatter.string(fromByteCount: Int64(output.utf8.count), countStyle: .memory)
    }

    private var stateLabel: String {
        switch currentJob["status"] as? String ?? "unknown" {
        case "running": return "运行中"
        case "stopping": return "正在取消"
        case "completed": return "已完成"
        case "killed": return "已取消"
        case "failed": return "失败"
        default: return "未知"
        }
    }

    private func reload() async {
        guard !jobId.isEmpty, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            guard let rpc = host.rpc() else { throw IPCFrameError.channelClosed }
            let generation = host.runtimeGeneration
            let response = try await rpc.request("jobs.output", params: [
                "botId": botId, "jobId": jobId, "from": nextOutputOffset,
            ], timeoutSeconds: 20)
            try Task.checkCancellation()
            guard generation == host.runtimeGeneration else { return }
            guard response["found"] as? Bool == true else {
                errorMessage = "任务已结束或不属于当前 Bot。"
                return
            }
            if let updated = response["job"] as? [String: Any] { currentJob = updated }
            let chunks = response["chunks"] as? [[String: Any]] ?? []
            var delta = chunks.map { chunk in
                var text = chunk["text"] as? String ?? ""
                if chunk["gapBefore"] as? Bool == true { text = "\n…（此前输出已丢弃）…\n" + text }
                if chunk["channel"] as? String == "stderr" { text = "[stderr]\n" + text }
                return text
            }.joined()
            let didLoseOutput = response["lossy"] as? Bool == true
            if didLoseOutput {
                lossy = true
                if delta.isEmpty { delta = "\n…（此前输出已丢弃）…\n" }
            }
            output += delta
            if let next = response["next"] as? Int, next >= nextOutputOffset {
                nextOutputOffset = next
            }
            errorMessage = ""
        } catch is CancellationError {
            return
        } catch {
            errorMessage = "无法读取任务输出：\(error.localizedDescription)"
        }
    }
}

private extension Dictionary where Key == String, Value == Any {
    var jobID: String { self["id"] as? String ?? UUID().uuidString }
}

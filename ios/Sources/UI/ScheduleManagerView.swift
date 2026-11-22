import SwiftUI

public struct ScheduleBotPickerView: View {
    @ObservedObject var host: LocalAgentHost

    public var body: some View {
        List {
            Section {
                Text("定时任务按 Bot 隔离。私密 Bot 的任务仅能在解锁后的私密会话中查看和管理。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("选择 Bot") {
                ForEach(host.sortBySessionActivity(host.bots.filter { !$0.isPrivate })) { bot in
                    NavigationLink {
                        ScheduleManagerView(host: host, botId: bot.id)
                    } label: {
                        HStack(spacing: 10) {
                            DSBotAvatar(initials: bot.name, color: DSTheme.botAvatarColor(bot),
                                        isPrivate: false, size: 36)
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 6) {
                                    Text(bot.name).font(.subheadline.weight(.semibold))
                                    DSPresetBadge(presetId: bot.agentPreset, label: bot.agentPresetLabel)
                                }
                                Text(bot.roleLabel).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("定时任务")
        .navigationBarTitleDisplayMode(.inline)
    }
}

public struct ScheduleManagerView: View {
    @ObservedObject var host: LocalAgentHost
    let botId: String

    @State private var tasks: [[String: Any]] = []
    @State private var isLoading = false
    @State private var errorMessage = ""
    @State private var pendingDeletion: [String: Any]?
    @State private var presentation: SchedulePresentation?

    public init(host: LocalAgentHost, botId: String) {
        self.host = host
        self.botId = botId
    }

    public var body: some View {
        List {
            Section {
                Text("任务只投递到当前 Bot。iOS 挂起或关闭 App 时不保证准点执行；重复任务恢复后最多补投最近一次错过的发生。新建任务请在对话中明确说明时间和提醒内容。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if isLoading && tasks.isEmpty {
                ProgressView("正在读取定时任务…")
            } else if tasks.isEmpty {
                DSEmptyStateView(
                    icon: "calendar.badge.clock",
                    title: "暂无定时任务",
                    subtitle: "你可以在智能体对话中直接要求创建一个单次或周期性（RRULE）定时提醒。"
                )
                .listRowBackground(Color.clear)
            }

            ForEach(tasks, id: \.scheduleID) { task in
                ScheduleTaskRow(task: task, onEdit: {
                    presentation = SchedulePresentation(task: task, screen: .edit)
                }, onHistory: {
                    presentation = SchedulePresentation(task: task, screen: .history)
                }) {
                    Task { await change(task, action: task["status"] as? String == "active" ? "pause" : "resume") }
                } onDelete: {
                    pendingDeletion = task
                }
            }

            if !errorMessage.isEmpty {
                Section("状态") {
                    Text(errorMessage).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("定时任务")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await reload() }
                } label: {
                    if isLoading { ProgressView() } else { Image(systemName: "arrow.clockwise") }
                }
                .disabled(isLoading)
                .accessibilityLabel("刷新定时任务")
            }
        }
        .task { await reload() }
        .refreshable { await reload() }
        .sheet(item: $presentation) { route in
            NavigationStack {
                switch route.screen {
                case .edit:
                    ScheduleTaskEditorView(host: host, botId: botId, task: route.task) {
                        presentation = nil
                        await reload()
                    }
                case .history:
                    ScheduleDeliveryHistoryView(host: host, botId: botId, task: route.task)
                }
            }
        }
        .confirmationDialog(
            "删除“\(pendingDeletion?["title"] as? String ?? "定时任务")”？",
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("删除任务", role: .destructive) {
                guard let task = pendingDeletion else { return }
                pendingDeletion = nil
                Task { await change(task, action: "delete") }
            }
            Button("取消", role: .cancel) { pendingDeletion = nil }
        } message: {
            Text("删除后不会再投递该任务。")
        }
    }

    private func reload() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            guard let rpc = host.rpc() else { throw IPCFrameError.channelClosed }
            let generation = host.runtimeGeneration
            let response = try await rpc.request("schedule.list", params: ["botId": botId], timeoutSeconds: 30)
            try Task.checkCancellation()
            guard generation == host.runtimeGeneration else { return }
            tasks = (response["tasks"] as? [[String: Any]] ?? []).sorted {
                ($0["scheduledAt"] as? String ?? "") < ($1["scheduledAt"] as? String ?? "")
            }
            errorMessage = ""
        } catch is CancellationError {
            return
        } catch {
            errorMessage = "无法读取定时任务：\(error.localizedDescription)"
        }
    }

    private func change(_ task: [String: Any], action: String) async {
        guard let id = task["id"] as? String else { return }
        do {
            guard let rpc = host.rpc() else { throw IPCFrameError.channelClosed }
            let generation = host.runtimeGeneration
            var params: [String: Any] = ["botId": botId, "id": id, "action": action]
            if let updatedAt = task["updatedAt"] as? String { params["expectedUpdatedAt"] = updatedAt }
            let response = try await rpc.request("schedule.edit", params: params, timeoutSeconds: 30)
            try Task.checkCancellation()
            guard generation == host.runtimeGeneration else { return }
            guard response["found"] as? Bool == true else {
                errorMessage = "任务已变化，或不属于当前 Bot。请刷新后重试。"
                await reload()
                return
            }
            errorMessage = ""
            await reload()
        } catch is CancellationError {
            return
        } catch {
            errorMessage = "定时任务操作失败：\(error.localizedDescription)"
        }
    }
}

private struct ScheduleTaskRow: View {
    let task: [String: Any]
    let onEdit: () -> Void
    let onHistory: () -> Void
    let onToggle: () -> Void
    let onDelete: () -> Void

    private var status: String { task["status"] as? String ?? "ended" }
    private var isActive: Bool { status == "active" }
    private var title: String { task["title"] as? String ?? "未命名任务" }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.subheadline.weight(.semibold))
                Spacer()
                Text(status == "active" ? "运行中" : status == "paused" ? "已暂停" : "已结束")
                    .font(.caption.weight(.medium))
                    .foregroundColor(isActive ? DSTheme.success : Color.secondary)
            }
            if let scheduledAt = task["scheduledAt"] as? String, !scheduledAt.isEmpty {
                Label(scheduledAt, systemImage: "clock")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            if let prompt = task["prompt"] as? String, !prompt.isEmpty {
                Text(prompt)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .textSelection(.enabled)
            }
            HStack {
                Menu {
                    Button(action: onEdit) { Label("编辑任务", systemImage: "pencil") }
                    Button(action: onHistory) { Label("投递记录", systemImage: "clock.arrow.circlepath") }
                } label: {
                    Label("详情", systemImage: "ellipsis.circle")
                }
                if status != "ended" {
                    Button(isActive ? "暂停" : "恢复", action: onToggle)
                        .buttonStyle(.bordered)
                        .font(.caption)
                }
                Button("删除", role: .destructive, action: onDelete)
                    .buttonStyle(.bordered)
                    .font(.caption)
                Spacer()
            }
            .padding(.top, 2)
        }
        .padding(.vertical, 5)
    }
}

private struct SchedulePresentation: Identifiable {
    enum Screen: String { case edit, history }
    let task: [String: Any]
    let screen: Screen
    var id: String { "\(task["id"] as? String ?? "missing"):\(screen.rawValue)" }
}

private struct ScheduleTaskEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var host: LocalAgentHost
    let botId: String
    let task: [String: Any]
    let onSaved: () async -> Void

    @State private var title: String
    @State private var prompt: String
    @State private var rrule: String
    @State private var isSaving = false
    @State private var errorMessage = ""

    init(host: LocalAgentHost, botId: String, task: [String: Any], onSaved: @escaping () async -> Void) {
        self.host = host
        self.botId = botId
        self.task = task
        self.onSaved = onSaved
        _title = State(initialValue: task["title"] as? String ?? "")
        _prompt = State(initialValue: task["prompt"] as? String ?? "")
        _rrule = State(initialValue: task["rrule"] as? String ?? "")
    }

    private var taskID: String { task["id"] as? String ?? "" }
    private var isRRule: Bool { task["kind"] as? String == "rrule" }

    var body: some View {
        Form {
            Section("任务") {
                TextField("名称", text: $title)
                    .textInputAutocapitalization(.sentences)
                TextField("提醒内容", text: $prompt, axis: .vertical)
                    .lineLimit(3...8)
                    .textInputAutocapitalization(.sentences)
            }

            Section("计划规则") {
                if isRRule {
                    TextEditor(text: $rrule)
                        .frame(minHeight: 92)
                        .font(.system(.caption, design: .monospaced))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Text("保留 DTSTART 与 RRULE 两行；保存时由 DSH 校验规则并重新计算下一次时间。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("\(task["kind"] as? String ?? "schedule") · \(task["scheduledAt"] as? String ?? "时间未提供")")
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                    Text("此规则类型可修改名称和提醒内容；通过 DSH 校验的 RRULE 重建需要在对话中进行。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if !errorMessage.isEmpty {
                Section("状态") { Text(errorMessage).font(.caption).foregroundStyle(.secondary) }
            }
        }
        .navigationTitle("编辑定时任务")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    Task { await save() }
                } label: {
                    if isSaving { ProgressView() } else { Text("保存") }
                }
                .disabled(isSaving || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private func save() async {
        guard !taskID.isEmpty else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            guard let rpc = host.rpc() else { throw IPCFrameError.channelClosed }
            var params: [String: Any] = [
                "botId": botId, "id": taskID, "action": "update",
                "title": title, "prompt": prompt,
            ]
            if isRRule, rrule != (task["rrule"] as? String ?? "") { params["rrule"] = rrule }
            if let updatedAt = task["updatedAt"] as? String { params["expectedUpdatedAt"] = updatedAt }
            let response = try await rpc.request("schedule.edit", params: params, timeoutSeconds: 30)
            guard response["found"] as? Bool == true else {
                errorMessage = "任务已在其他位置更新，已保留本次编辑内容；请取消后刷新再编辑。"
                return
            }
            await onSaved()
            dismiss()
        } catch {
            errorMessage = "保存失败：\(error.localizedDescription)"
        }
    }
}

private struct ScheduleDeliveryHistoryView: View {
    @ObservedObject var host: LocalAgentHost
    let botId: String
    let task: [String: Any]

    @State private var records: [[String: Any]] = []
    @State private var nextBefore: String?
    @State private var isLoading = false
    @State private var errorMessage = ""
    @State private var unavailable = false
    @State private var pruned = false

    private var taskID: String { task["id"] as? String ?? "" }
    private var taskTitle: String { task["title"] as? String ?? "定时任务" }

    var body: some View {
        List {
            Section {
                Text("投递记录表示提醒已写入 Bot 会话收件箱；不代表模型已完成处理。记录按 DSH 保留策略保存，较早记录可能不可恢复。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if unavailable || pruned {
                    Text(pruned ? "部分较早记录已按保留上限清理。" : "更早投递记录未保存。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if records.isEmpty && !isLoading && errorMessage.isEmpty {
                ContentUnavailableScheduleHistory()
            }
            if records.isEmpty && isLoading {
                ProgressView("正在读取投递记录…")
            }
            ForEach(Array(records.enumerated()), id: \.offset) { _, record in
                VStack(alignment: .leading, spacing: 7) {
                    Label("已写入会话", systemImage: "checkmark.circle.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(DSTheme.success)
                    if let scheduledAt = record["scheduledAt"] as? String {
                        LabeledContent("计划时间", value: scheduledAt)
                    }
                    if let deliveredAt = record["deliveredAt"] as? String {
                        LabeledContent("投递时间", value: deliveredAt)
                    }
                    if let prompt = record["prompt"] as? String, !prompt.isEmpty {
                        Text(prompt).font(.caption).foregroundStyle(.secondary).lineLimit(4)
                    }
                }
                .padding(.vertical, 4)
            }
            if let nextBefore {
                Button {
                    Task { await load(before: nextBefore) }
                } label: {
                    HStack {
                        Spacer()
                        if isLoading { ProgressView() } else { Text("加载更早记录") }
                        Spacer()
                    }
                }
                .disabled(isLoading)
            }
            if !errorMessage.isEmpty {
                Section("状态") { Text(errorMessage).font(.caption).foregroundStyle(.secondary) }
            }
        }
        .navigationTitle(taskTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { Task { await load(before: nil) } } label: {
                    if isLoading { ProgressView() } else { Image(systemName: "arrow.clockwise") }
                }
                .disabled(isLoading)
                .accessibilityLabel("刷新投递记录")
            }
        }
        .task { await load(before: nil) }
    }

    private func load(before: String?) async {
        guard !taskID.isEmpty else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            guard let rpc = host.rpc() else { throw IPCFrameError.channelClosed }
            let generation = host.runtimeGeneration
            var params: [String: Any] = ["botId": botId, "id": taskID, "limit": 50]
            if let before { params["before"] = before }
            let response = try await rpc.request("schedule.history", params: params, timeoutSeconds: 30)
            try Task.checkCancellation()
            guard generation == host.runtimeGeneration else { return }
            guard response["found"] as? Bool == true,
                  let history = response["history"] as? [String: Any] else {
                errorMessage = "此任务或投递记录已不可用。"
                return
            }
            let page = history["records"] as? [[String: Any]] ?? []
            records = before == nil ? page : records + page
            nextBefore = history["nextBefore"] as? String
            unavailable = history["earlierRecordsUnavailable"] as? Bool ?? false
            pruned = history["earlierRecordsPruned"] as? Bool ?? false
            errorMessage = ""
        } catch {
            errorMessage = "无法读取投递记录：\(error.localizedDescription)"
        }
    }
}

private struct ContentUnavailableScheduleHistory: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray").font(.system(size: 26)).foregroundStyle(.secondary)
            Text("暂无投递记录").font(.headline)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .listRowBackground(Color.clear)
    }
}

private extension Dictionary where Key == String, Value == Any {
    var scheduleID: String { self["id"] as? String ?? UUID().uuidString }
}

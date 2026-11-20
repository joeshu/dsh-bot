import LocalAuthentication
import SwiftUI
import UniformTypeIdentifiers

// MARK: - 1. Long Reply Reading Pill (`2026-11-13-long-reply-reading.md`)

public struct MarkdownHeading: Identifiable, Equatable {
    public let id: String
    public let level: Int
    public let title: String
}

public enum MarkdownOutlineParser {
    public static func extractHeadings(from text: String) -> [MarkdownHeading] {
        text.split(separator: "\n", omittingEmptySubsequences: false).enumerated().compactMap { idx, rawLine in
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("### ") {
                return MarkdownHeading(id: "h_\(idx)", level: 3, title: String(line.dropFirst(4)))
            } else if line.hasPrefix("## ") {
                return MarkdownHeading(id: "h_\(idx)", level: 2, title: String(line.dropFirst(3)))
            } else if line.hasPrefix("# ") {
                return MarkdownHeading(id: "h_\(idx)", level: 1, title: String(line.dropFirst(2)))
            }
            return nil
        }
    }
}

/// Floating reading capsule shown at the top of long Bot replies on iPhone screens.
public struct LongReplyReadingPill: View {
    let currentSection: String
    let headings: [MarkdownHeading]
    let onJumpTop: () -> Void
    let onJumpHeading: (MarkdownHeading) -> Void
    @State private var showOutline = false

    public var body: some View {
        HStack(spacing: 8) {
            Button(action: onJumpTop) {
                Image(systemName: "arrow.up.to.line")
                    .font(.caption.weight(.semibold))
            }
            Divider().frame(height: 14)
            Button { showOutline = true } label: {
                HStack(spacing: 4) {
                    Text(currentSection.isEmpty ? "长回复大纲" : currentSection)
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.caption2)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial)
        .clipShape(Capsule())
        .shadow(radius: 2)
        .sheet(isPresented: $showOutline) {
            NavigationStack {
                List(headings) { h in
                    Button {
                        showOutline = false
                        onJumpHeading(h)
                    } label: {
                        Text(h.title)
                            .padding(.leading, CGFloat((h.level - 1) * 12))
                    }
                }
                .navigationTitle("章节跳转")
                .navigationBarTitleDisplayMode(.inline)
            }
            .presentationDetents([.medium])
        }
    }
}

// MARK: - 2. Side Chat (`/side` non-interrupting aside sheet)

public struct SideChatSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var host: LocalAgentHost
    let model: String
    let botId: String
    let botName: String
    let isPrivate: Bool
    @State private var status = ""
    @State private var sending = false
    @State private var request: Task<Void, Never>?
    @State private var sideId: String?
    @State private var question = ""
    @State private var includeRecentContext = false
    @State private var messages: [(role: String, text: String)] = []

    private var recentContext: [[String: String]] {
        guard includeRecentContext else { return [] }
        return host.messages(for: botId).suffix(8).compactMap { message in
            guard ["user", "assistant"].contains(message.role), message.incomplete != true,
                  !message.content.isEmpty else { return nil }
            return ["role": message.role, "content": String(message.content.prefix(2_000))]
        }
    }

    public var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("侧边对话不会打断主会话，也不会把侧边回复写回主会话。默认不附带聊天历史。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    if !host.messages(for: botId).isEmpty {
                        Toggle("附带最近 8 条可见消息", isOn: $includeRecentContext)
                            .font(.caption)
                        Text(includeRecentContext
                             ? "这次请求会把「\(botName)」的可见对话片段发送给当前模型服务。\(isPrivate ? "此会话为私密会话。" : "")"
                             : "不附带主会话内容；思考过程不会被引用。")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.secondarySystemBackground))

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            ForEach(Array(messages.enumerated()), id: \.offset) { idx, msg in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(msg.role).font(.caption2).foregroundColor(.secondary)
                                    DSMarkdownText(msg.text)
                                        .padding(10)
                                        .background(msg.role == "You" ? Color.accentColor.opacity(0.14) : Color(.secondarySystemBackground))
                                        .clipShape(RoundedRectangle(cornerRadius: 10))
                                }
                                .id(idx)
                            }
                        }
                        .padding()
                    }
                    .onChange(of: messages.count) { count in
                        if count > 0 {
                            withAnimation { proxy.scrollTo(count - 1, anchor: .bottom) }
                        }
                    }
                }

                if !status.isEmpty { Text(status).font(.caption).foregroundStyle(.secondary) }
                Divider()
                HStack(spacing: 8) {
                    TextField("顺手问一句...", text: $question)
                        .textFieldStyle(.roundedBorder)
                    Button("发送") {
                        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !q.isEmpty else { return }
                        messages.append((role: "You", text: q))
                        question = ""
                        status = ""
                        sending = true
                        let id = UUID().uuidString
                        let contextSnapshot = recentContext
                        sideId = id
                        request = Task {
                            defer {
                                sending = false
                                if sideId == id { sideId = nil }
                            }
                            do {
                                guard let rpc = host.rpc() else { throw IPCFrameError.channelClosed }
                                let response = try await rpc.request("side.ask", params: [
                                    "model": model, "question": q, "apiBaseURL": host.apiBaseURL,
                                    "sideId": id, "context": contextSnapshot
                                ], timeoutSeconds: 95)
                                guard let reply = response["reply"] as? String else { throw ModelProviderError.invalidResponse }
                                messages.append((role: "Side", text: reply))
                            } catch {
                                if !Task.isCancelled { status = error.localizedDescription }
                            }
                        }
                    }
                    .disabled(sending)
                    .buttonStyle(.borderedProminent)
                }
                .padding()
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("侧边对话")
            .onDisappear {
                request?.cancel()
                if let sideId { Task { _ = try? await host.rpc()?.request("side.cancel", params: ["sideId": sideId]) } }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if sending {
                        Button("停止") { cancelSideRequest() }
                    } else {
                        Button("关闭") { dismiss() }
                    }
                }
            }
        }
    }

    private func cancelSideRequest() {
        request?.cancel()
        guard let sideId else { return }
        self.sideId = nil
        status = "已停止侧边请求。"
        Task {
            guard let rpc = host.rpc() else { return }
            _ = try? await rpc.request("side.cancel", params: ["sideId": sideId], timeoutSeconds: 10)
        }
    }
}

// MARK: - 3. Group Goal, Task Board & Shared Todos Drawer

public struct GroupWorkspaceSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var host: LocalAgentHost
    let groupId: String
    @State private var newTodoText = ""
    @State private var todos: [(id: String, text: String, done: Bool)] = []
    @State private var goalTitle = "未设定群目标"
    @State private var newGoalInput = ""
    @State private var status = ""

    public var body: some View {
        NavigationStack {
            List {
                Section("群 Goal 进度") {
                    Text(goalTitle).font(.subheadline.weight(.medium))
                    HStack {
                        TextField("设定或更新群目标...", text: $newGoalInput)
                        Button("保存") {
                            let g = newGoalInput.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !g.isEmpty else { return }
                            newGoalInput = ""
                            Task {
                                do {
                                    guard let rpc = host.rpc() else { throw IPCFrameError.channelClosed }
                                    _ = try await rpc.request("group.goal.set", params: ["groupId": groupId, "title": g])
                                    status = ""
                                    await reload()
                                } catch { status = error.localizedDescription }
                            }
                        }
                        .disabled(newGoalInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }

                Section("共享待办") {
                    HStack {
                        TextField("添加群待办...", text: $newTodoText)
                        Button("添加") {
                            let t = newTodoText.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !t.isEmpty else { return }
                            newTodoText = ""
                            Task {
                                do {
                                    guard let rpc = host.rpc() else { throw IPCFrameError.channelClosed }
                                    _ = try await rpc.request("group.todo.add", params: ["groupId": groupId, "text": t])
                                    status = ""
                                    await reload()
                                } catch { status = error.localizedDescription }
                            }
                        }
                        .disabled(newTodoText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    ForEach(todos, id: \.id) { todo in
                        HStack {
                            Image(systemName: todo.done ? "checkmark.circle.fill" : "circle")
                                .foregroundColor(todo.done ? .green : .secondary)
                            Text(todo.text)
                                .strikethrough(todo.done)
                        }
                        .onTapGesture {
                            Task {
                                _ = try? await host.rpc()?.request("group.todo.toggle", params: ["groupId": groupId, "id": todo.id, "done": !todo.done])
                                await reload()
                            }
                        }
                    }
                    if todos.contains(where: { $0.done }) {
                        Button("清空已完成待办", role: .destructive) {
                            Task {
                                _ = try? await host.rpc()?.request("group.todo.clearCompleted", params: ["groupId": groupId])
                                DSHaptics.impact(.light)
                                await reload()
                            }
                        }
                    }
                }
                if !status.isEmpty {
                    Section { Text(status).font(.caption).foregroundStyle(.secondary) }
                }
            }
            .navigationTitle("群协作面板")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            .task { await reload() }
        }
    }

    private func reload() async {
        guard let res = try? await host.rpc()?.request("group.state", params: ["groupId": groupId]) else { return }
        if let goal = res["goal"] as? [String: Any], let title = goal["title"] as? String {
            goalTitle = title
        }
        let rawTodos = res["todos"] as? [[String: Any]] ?? []
        todos = rawTodos.compactMap { d in
            guard let id = d["id"] as? String, let text = d["text"] as? String else { return nil }
            return (id: id, text: text, done: d["done"] as? Bool ?? false)
        }
    }
}

// MARK: - 4. 4-Layer Memory & Reversible Journal View

public struct MemoryVaultView: View {
    @ObservedObject var host: LocalAgentHost
    let botId: String
    private struct Record: Identifiable {
        let id: String
        let title: String
        let content: String
        let layer: String

        init?(_ raw: [String: Any]) {
            guard let id = raw["journalId"] as? String else { return nil }
            self.id = id
            title = raw["title"] as? String ?? "未命名记忆"
            content = raw["content"] as? String ?? ""
            layer = raw["layer"] as? String ?? ""
        }
    }

    @State private var journal: [Record] = []
    @State private var legacy: [Record] = []
    @State private var showsLegacy = false
    @State private var status = ""
    @State private var showAddMemory = false
    @State private var newMemTitle = ""
    @State private var newMemContent = ""
    @State private var newMemLayer = "pinned"
    @Environment(\.scenePhase) private var phase

    public var body: some View {
        List {
            Section("当前 Bot") {
                if journal.isEmpty { Text("暂无记忆记录").foregroundStyle(.secondary) }
                ForEach(journal) { row in
                    HStack {
                        memoryRow(row)
                        Spacer()
                        Button("撤销", role: .destructive) {
                            Task { await mutate("memory.undo", id: row.id) }
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
            Section("升级前的记忆") {
                if !showsLegacy {
                    Button("验证设备身份并查看") {
                        Task {
                            let context = LAContext()
                            do {
                                guard try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "查看升级前的记忆") else { return }
                                showsLegacy = true
                                await reload()
                            } catch { status = "无法验证设备身份。" }
                        }
                    }
                } else {
                    Text("选择归属后，这条记忆将移到当前 Bot。常驻记忆会随请求发给模型服务。")
                        .font(.caption).foregroundStyle(.secondary)
                    if legacy.isEmpty { Text("暂无未归属记忆").foregroundStyle(.secondary) }
                    ForEach(legacy) { row in
                        HStack {
                            memoryRow(row)
                            Spacer()
                            Button("分配给当前 Bot") { Task { await mutate("memory.assign", id: row.id) } }
                                .buttonStyle(.bordered)
                        }
                    }
                }
            }
            if !status.isEmpty { Section("状态") { Text(status).font(.caption) } }
        }
        .refreshable { await reload() }
        .navigationTitle("记忆")
        .onChange(of: phase) { phase in
            if phase == .background { showsLegacy = false; legacy = [] }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showAddMemory = true } label: { Label("新增", systemImage: "plus") }
            }
        }
        .sheet(isPresented: $showAddMemory) {
            NavigationStack {
                Form {
                    TextField("记忆标题", text: $newMemTitle)
                    Picker("用途", selection: $newMemLayer) {
                        Text("常驻 · 随聊天发送给模型").tag("pinned")
                        Text("手动查阅 · 仅本机").tag("delta")
                    }
                    TextField("记忆内容", text: $newMemContent, axis: .vertical).lineLimit(3...6)
                    if !status.isEmpty { Text(status).font(.caption) }
                }
                .navigationTitle("新增记忆")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) { Button("取消") { showAddMemory = false } }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("保存") {
                            Task {
                                do {
                                    guard let rpc = host.rpc() else { throw IPCFrameError.channelClosed }
                                    _ = try await rpc.request("memory.add", params: [
                                        "botId": botId, "title": newMemTitle, "content": newMemContent, "layer": newMemLayer
                                    ])
                                    newMemTitle = ""
                                    newMemContent = ""
                                    showAddMemory = false
                                    status = ""
                                    await reload()
                                } catch { status = error.localizedDescription }
                            }
                        }
                        .disabled(
                            newMemTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || newMemContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        )
                    }
                }
            }
        }
        .task { await reload() }
    }

    private func memoryRow(_ row: Record) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(row.title)
            if row.layer == "pinned" { Text("常驻").font(.caption2).foregroundStyle(.secondary) }
            Text(row.content).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
        }
    }

    private func mutate(_ method: String, id: String) async {
        do {
            guard let rpc = host.rpc() else { throw IPCFrameError.channelClosed }
            let result = try await rpc.request(method, params: ["botId": botId, "journalId": id])
            status = (result["assigned"] as? Bool == true || result["undone"] as? Bool == true) ? "" : "这条记忆已变更。"
            await reload()
        } catch { status = error.localizedDescription }
    }

    private func reload() async {
        do {
            guard let rpc = host.rpc() else { throw IPCFrameError.channelClosed }
            let current = try await rpc.request("memory.journal", params: ["botId": botId])
            journal = (current["records"] as? [[String: Any]] ?? []).compactMap(Record.init)
            if showsLegacy {
                let previous = try await rpc.request("memory.legacy")
                if showsLegacy { legacy = (previous["records"] as? [[String: Any]] ?? []).compactMap(Record.init) }
            }
        } catch { status = error.localizedDescription }
    }
}

// MARK: - 5. Universal Connectors & Token Usage Dashboard

private struct DSHUsageTotals {
    let calls: Int
    let inputTokens: Int
    let cacheReadTokens: Int
    let cacheWriteTokens: Int
    let outputTokens: Int
    let totalTokens: Int

    init(_ raw: [String: Any] = [:]) {
        calls = max(0, raw["calls"] as? Int ?? 0)
        inputTokens = max(0, raw["inputTokens"] as? Int ?? 0)
        cacheReadTokens = max(0, raw["cacheReadTokens"] as? Int ?? 0)
        cacheWriteTokens = max(0, raw["cacheWriteTokens"] as? Int ?? 0)
        outputTokens = max(0, raw["outputTokens"] as? Int ?? 0)
        totalTokens = max(0, raw["totalTokens"] as? Int ?? 0)
    }
}

private struct DSHUsageRollup: Identifiable {
    let id: String
    let title: String
    let totals: DSHUsageTotals
}

public struct ConnectorsAndUsageView: View {
    @ObservedObject var host: LocalAgentHost
    @State private var usageTotals = DSHUsageTotals()
    @State private var botUsage: [DSHUsageRollup] = []
    @State private var modelUsage: [DSHUsageRollup] = []
    @State private var dailyUsage: [DSHUsageRollup] = []
    @State private var unreportedCalls = 0
    @State private var unreadUsageSessions = 0
    @State private var legacyTotalTokens = 0
    @State private var legacyCacheHitRate = 0.0
    @State private var connectorName = ""
    @State private var connectorEndpoint = ""
    @State private var connectorToken = ""
    @State private var connectors: [(id: String, type: String, name: String, endpoint: String)] = []
    @State private var mcpStatus = ""

    private func recentDayWindows() -> [[String: Any]] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        return (0...6).compactMap { daysAgo in
            guard let day = calendar.date(byAdding: .day, value: -daysAgo, to: today),
                  let nextDay = calendar.date(byAdding: .day, value: 1, to: day) else { return nil }
            let components = calendar.dateComponents([.year, .month, .day], from: day)
            let id = String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
            return [
                "id": id,
                "title": day.formatted(date: .abbreviated, time: .omitted),
                "start": Int64(day.timeIntervalSince1970 * 1_000),
                "end": Int64(nextDay.timeIntervalSince1970 * 1_000),
            ]
        }
    }

    private func decodeUsageRollups(_ value: Any?, title: (String) -> String = { $0 }) -> [DSHUsageRollup] {
        (value as? [[String: Any]] ?? []).compactMap { raw in
            guard let id = raw["id"] as? String else { return nil }
            return DSHUsageRollup(
                id: id,
                title: title(raw["title"] as? String ?? id),
                totals: DSHUsageTotals(raw)
            )
        }
    }

    public var body: some View {
        Form {
            Section("真实用量（DSH 持久事件）") {
                LabeledContent("已报告用量的模型调用", value: usageTotals.calls.formatted())
                LabeledContent("输入 Tokens（未缓存）", value: usageTotals.inputTokens.formatted())
                LabeledContent("缓存读取 Tokens", value: usageTotals.cacheReadTokens.formatted())
                LabeledContent("缓存写入 Tokens", value: usageTotals.cacheWriteTokens.formatted())
                LabeledContent("输出 Tokens", value: usageTotals.outputTokens.formatted())
                LabeledContent("合计 Tokens", value: usageTotals.totalTokens.formatted())
                if unreportedCalls > 0 {
                    Text("另有 \(unreportedCalls.formatted()) 次模型尝试没有报告用量，因此未计入 Token 总数。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if unreadUsageSessions > 0 {
                    Text("另有 \(unreadUsageSessions.formatted()) 个会话日志无法读取，统计可能不完整。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("原生兼容请求（独立累计）") {
                LabeledContent("累计 Tokens", value: legacyTotalTokens.formatted())
                LabeledContent("Prompt 缓存命中率", value: String(format: "%.1f%%", legacyCacheHitRate * 100))
                Text("包含 Swift 兼容路径的历史请求，不与 DSH 明细合并，也无法按 Bot、模型或日期拆分。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !botUsage.isEmpty {
                Section("按 Bot") {
                    ForEach(botUsage) { item in
                        LabeledContent(item.title, value: "\(item.totals.totalTokens.formatted()) Tokens · \(item.totals.calls.formatted()) 次")
                    }
                }
            }

            if !modelUsage.isEmpty {
                Section("按模型") {
                    ForEach(modelUsage) { item in
                        LabeledContent(item.title, value: "\(item.totals.totalTokens.formatted()) Tokens · \(item.totals.calls.formatted()) 次")
                    }
                }
            }

            if !dailyUsage.isEmpty {
                Section("最近 7 天") {
                    ForEach(dailyUsage) { item in
                        LabeledContent(item.title, value: "\(item.totals.totalTokens.formatted()) Tokens · \(item.totals.calls.formatted()) 次")
                    }
                }
            }

            Section("添加 Remote MCP 连接器") {
                TextField("名称（如 Office MCP）", text: $connectorName)
                TextField("Endpoint / URL", text: $connectorEndpoint)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("Bearer Token（可选，存 Keychain）", text: $connectorToken)
                Button("保存连接器") {
                    let trimmedName = connectorName.trimmingCharacters(in: .whitespacesAndNewlines)
                    let trimmedEndpoint = connectorEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmedName.isEmpty, !trimmedEndpoint.isEmpty else { return }
                    Task {
                        do {
                            guard let rpc = host.rpc() else { throw IPCFrameError.channelClosed }
                            _ = try await rpc.request("connectors.upsert", params: [
                                "name": trimmedName, "endpoint": trimmedEndpoint,
                                "token": connectorToken.trimmingCharacters(in: .whitespacesAndNewlines)
                            ])
                            connectorName = ""
                            connectorEndpoint = ""
                            connectorToken = ""
                            mcpStatus = "已保存连接器：\(trimmedName)"
                            await reload()
                        } catch { mcpStatus = error.localizedDescription }
                    }
                }
                .disabled(
                    connectorName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || connectorEndpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
            }

            if !connectors.isEmpty {
                Section("已配置连接器") {
                    ForEach(connectors, id: \.id) { c in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(c.name) (\(c.type))").font(.subheadline.weight(.medium))
                                Text(c.endpoint).font(.caption2).foregroundColor(.secondary)
                            }
                            Spacer()
                            if c.type == "remote-mcp" {
                                Button("发现工具") {
                                    Task {
                                        do {
                                            guard let rpc = host.rpc() else { throw IPCFrameError.channelClosed }
                                            let result = try await rpc.request("mcp.listTools", params: ["connectorId": c.id], timeoutSeconds: 180)
                                            let tools = result["tools"] as? [[String: Any]] ?? []
                                            mcpStatus = "\(c.name)：已发现 \(tools.count) 个远程工具"
                                        } catch { mcpStatus = error.localizedDescription }
                                    }
                                }
                                .buttonStyle(.bordered)
                                .font(.caption)
                            }
                        }
                        .swipeActions(edge: .trailing) {
                            Button("删除", role: .destructive) {
                                Task {
                                    do {
                                        guard let rpc = host.rpc() else { throw IPCFrameError.channelClosed }
                                        _ = try await rpc.request("connectors.delete", params: ["id": c.id])
                                        await reload()
                                    } catch { mcpStatus = error.localizedDescription }
                                }
                            }
                        }
                    }
                }
            }
            if !mcpStatus.isEmpty {
                Section("MCP 探测结果") {
                    Text(mcpStatus).font(.caption).foregroundColor(.secondary)
                }
            }
        }
        .refreshable { await reload() }
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle("连接器与用量")
        .task { await reload() }
    }

    private func reload() async {
        if let usage = try? await host.rpc()?.request("usage.summary", params: ["dayWindows": recentDayWindows()], timeoutSeconds: 120) {
            usageTotals = DSHUsageTotals(usage["totals"] as? [String: Any] ?? [:])
            botUsage = decodeUsageRollups(usage["byBot"]) { botId in
                host.bots.first(where: { $0.id == botId })?.name ?? botId
            }
            modelUsage = decodeUsageRollups(usage["byModel"])
            dailyUsage = decodeUsageRollups(usage["byDay"])
            unreportedCalls = max(0, usage["unreportedCalls"] as? Int ?? 0)
            unreadUsageSessions = max(0, usage["unreadSessions"] as? Int ?? 0)
        }
        if let legacy = try? await host.rpc()?.request("usage.legacySummary") {
            legacyTotalTokens = max(0, legacy["totalTokens"] as? Int ?? 0)
            legacyCacheHitRate = min(1, max(0, legacy["cacheHitRate"] as? Double ?? 0))
        }
        if let c = try? await host.rpc()?.request("connectors.list") {
            let raw = c["connectors"] as? [[String: Any]] ?? []
            connectors = raw.compactMap { d in
                guard let id = d["id"] as? String else { return nil }
                return (
                    id: id,
                    type: d["type"] as? String ?? "",
                    name: d["name"] as? String ?? "",
                    endpoint: d["endpoint"] as? String ?? ""
                )
            }
        }
    }
}


// MARK: - 6. Native Widget Blueprint Renderer (`2026-10-20-widget-views.md`)

public struct WidgetMetricItem: Identifiable, Equatable {
    public let id = UUID()
    public let label: String
    public let value: String
    public init(label: String, value: String) {
        self.label = label
        self.value = value
    }
}

public struct WidgetBlueprintCardView: View {
    let title: String
    let metrics: [WidgetMetricItem]

    public init(title: String, metrics: [WidgetMetricItem]) {
        self.title = title
        self.metrics = metrics
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                ForEach(metrics) { item in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.label)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Text(item.value)
                            .font(.headline.monospacedDigit())
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(DSTheme.surfaceSecondary)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }
        }
        .padding(14)
        .background(DSTheme.surfacePrimary)
        .clipShape(RoundedRectangle(cornerRadius: DSTheme.cornerCard, style: .continuous))
        .shadow(color: .black.opacity(0.04), radius: 6, y: 2)
    }
}


// MARK: - 7. On-Device QuickJS Sandbox Playground

public struct JSSandboxPlaygroundView: View {
    @ObservedObject var host: LocalAgentHost
    @State private var script = "const items = [12, 28, 45];\nconsole.log('count:', items.length);\n({ sum: items.reduce((a,b)=>a+b, 0) })"
    @State private var output = ""
    @State private var deviceInfo = ""
    @State private var isRunning = false

    public var body: some View {
        Form {
            Section("QuickJS 离线沙盒（免 JIT / 零体积增量）") {
                TextEditor(text: $script)
                    .font(.caption.monospaced())
                    .frame(minHeight: 110)
                HStack {
                    Button(isRunning ? "运行中…" : "在 iOS 沙盒中运行") {
                        isRunning = true
                        Task {
                            defer { isRunning = false }
                            if let res = try? await host.rpc()?.request("tools.jsEval", params: ["script": script]) {
                                let ok = res["ok"] as? Bool ?? false
                                let val = res["value"] as? String ?? ""
                                let logs = (res["logs"] as? [String] ?? []).joined(separator: "\n")
                                let err = res["error"] as? String ?? ""
                                output = ok ? [logs, val].filter { !$0.isEmpty }.joined(separator: "\n") : "错误：\(err)"
                                DSHaptics.notify(ok ? .success : .error)
                            }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isRunning || script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    if !output.isEmpty {
                        Button("清空输出") { output = "" }
                            .buttonStyle(.bordered)
                    }
                }
            }

            if !output.isEmpty {
                Section("执行输出") {
                    Text(output).font(.caption.monospaced()).textSelection(.enabled)
                }
            }

            Section("本机设备状态探针") {
                Button("读取电量与温控状态") {
                    Task {
                        if let st = try? await host.rpc()?.request("device.status"),
                           let d = try? JSONSerialization.data(withJSONObject: st, options: [.prettyPrinted, .sortedKeys]),
                           let s = String(data: d, encoding: .utf8) {
                            deviceInfo = s
                        }
                    }
                }
                if !deviceInfo.isEmpty {
                    Text(deviceInfo).font(.caption2.monospaced()).textSelection(.enabled)
                }
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle("端侧 JS 沙盒")
    }
}

// MARK: - 8. Sandboxed Workspace Files Browser (`Documents/dsh-home/files/`)

public struct WorkspaceFilesView: View {
    @ObservedObject var host: LocalAgentHost
    private struct FileEntry: Identifiable {
        let id: String
        let url: URL
        let name: String
        let byteCount: Int
    }

    @State private var entries: [FileEntry] = []
    @State private var selectedPreview: (name: String, content: String)?
    @State private var showImporter = false
    @State private var status = ""

    private var filesRoot: URL {
        let dir = LocalAgentTransport.defaultWorkspace.appendingPathComponent("files", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    public var body: some View {
        List {
            Section {
                Text("此目录供智能体通过 workspace_list / workspace_read / workspace_search / workspace_write / workspace_edit 安全读写（写入与编辑均需原生审批）。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("工作区文件（files/）") {
                if entries.isEmpty {
                    Text("暂无文件，可点击右上角导入文档或图片。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(entries) { entry in
                        Button {
                            preview(entry)
                        } label: {
                            HStack {
                                Image(systemName: "doc.text")
                                    .foregroundStyle(DSTheme.brand)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.name).font(.subheadline)
                                    Text(ByteCountFormatter.string(fromByteCount: Int64(entry.byteCount), countStyle: .file))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .swipeActions(edge: .trailing) {
                            Button("删除", role: .destructive) {
                                try? FileManager.default.removeItem(at: entry.url)
                                reload()
                            }
                        }
                    }
                }
            }
            if !status.isEmpty {
                Section { Text(status).font(.caption).foregroundStyle(.secondary) }
            }
        }
        .navigationTitle("工作区文件")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showImporter = true } label: { Label("导入", systemImage: "plus") }
            }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.item]) { result in
            switch result {
            case .success(let url):
                do {
                    let imported = try host.importFileToWorkspace(from: url)
                    status = "已导入：files/\(imported.relativePath)"
                    reload()
                } catch { status = "导入失败：\(error.localizedDescription)" }
            case .failure(let error):
                status = "导入失败：\(error.localizedDescription)"
            }
        }
        .sheet(isPresented: Binding(
            get: { selectedPreview != nil },
            set: { if !$0 { selectedPreview = nil } }
        )) {
            if let preview = selectedPreview {
                NavigationStack {
                    ScrollView {
                        Text(preview.content)
                            .font(.caption.monospaced())
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                            .textSelection(.enabled)
                    }
                    .navigationTitle(preview.name)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("完成") { selectedPreview = nil }
                        }
                    }
                }
            }
        }
        .onAppear { reload() }
    }

    private func reload() {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(
            at: filesRoot,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            entries = []
            return
        }
        entries = urls.compactMap { url in
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values?.isSymbolicLink != true, values?.isRegularFile == true else { return nil }
            return FileEntry(id: url.lastPathComponent, url: url, name: url.lastPathComponent, byteCount: values?.fileSize ?? 0)
        }.sorted { $0.name < $1.name }
    }

    private func preview(_ entry: FileEntry) {
        guard let data = try? Data(contentsOf: entry.url) else {
            status = "无法读取文件。"
            return
        }
        let slice = data.prefix(65_536)
        if let text = String(data: slice, encoding: .utf8) {
            selectedPreview = (entry.name, data.count > 65_536 ? text + "\n…(已截断)" : text)
        } else {
            selectedPreview = (entry.name, "二进制文件（\(data.count) 字节），暂不支持文本预览。")
        }
    }
}

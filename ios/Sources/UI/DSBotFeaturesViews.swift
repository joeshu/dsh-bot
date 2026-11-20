import SwiftUI

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
    @ObservedObject var host: BareWorkletHost
    let parentSessionId: String
    @State private var question = ""
    @State private var messages: [(role: String, text: String)] = []

    public var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Text("侧边对话不会打断当前 Bot 工作，也不会写入主对话上下文。")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(8)
                    .frame(maxWidth: .infinity)
                    .background(Color(.secondarySystemBackground))

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(messages.enumerated()), id: \.offset) { _, msg in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(msg.role).font(.caption2).foregroundColor(.secondary)
                                Text(msg.text)
                                    .padding(10)
                                    .background(msg.role == "You" ? Color.accentColor.opacity(0.14) : Color(.secondarySystemBackground))
                                    .clipShape(RoundedRectangle(cornerRadius: 10))
                            }
                        }
                    }
                    .padding()
                }

                Divider()
                HStack(spacing: 8) {
                    TextField("顺手问一句...", text: $question)
                        .textFieldStyle(.roundedBorder)
                    Button("发送") {
                        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !q.isEmpty else { return }
                        messages.append((role: "You", text: q))
                        question = ""
                        Task {
                            if let res = try? await host.rpc()?.request("side.ask", params: ["parentSessionId": parentSessionId, "question": q, "apiBaseURL": host.apiBaseURL]),
                               let reply = res["reply"] as? String {
                                messages.append((role: "Side", text: reply))
                            }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding()
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Side Chat (/side)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { dismiss() }
                }
            }
        }
    }
}

// MARK: - 3. Group Goal, Task Board & Shared Todos Drawer

public struct GroupWorkspaceSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var host: BareWorkletHost
    let groupId: String
    @State private var newTodoText = ""
    @State private var todos: [(id: String, text: String, done: Bool)] = []
    @State private var goalTitle = "未设定群目标"
    @State private var newGoalInput = ""

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
                                _ = try? await host.rpc()?.request("group.goal.set", params: ["groupId": groupId, "title": g])
                                await reload()
                            }
                        }
                    }
                }

                Section("共享待办 (上限 100 条)") {
                    HStack {
                        TextField("添加群待办...", text: $newTodoText)
                        Button("添加") {
                            let t = newTodoText.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !t.isEmpty else { return }
                            newTodoText = ""
                            Task {
                                _ = try? await host.rpc()?.request("group.todo.add", params: ["groupId": groupId, "text": t])
                                await reload()
                            }
                        }
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
    @ObservedObject var host: BareWorkletHost
    let botId: String
    @State private var journal: [(id: String, op: String, entryId: String, title: String, content: String, layer: String, at: String)] = []
    @State private var status = ""
    @State private var showAddMemory = false
    @State private var newMemTitle = ""
    @State private var newMemContent = ""
    @State private var newMemLayer = "pinned"

    public var body: some View {
        List {
            Section("四层记忆说明") {
                Text("支持常驻（Pinned）、增量（Delta）、自动召回（Recall）与按需（On-Demand）四层读取，所有变更均写入可逆账本。")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Section("更改记录（支持单条撤销）") {
                if journal.isEmpty {
                    Text("暂无记忆变更记录").font(.caption).foregroundColor(.secondary)
                } else {
                    ForEach(journal, id: \.id) { row in
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 6) {
                                    Text(row.title.isEmpty ? "\(row.op.uppercased()) · \(row.entryId)" : row.title)
                                        .font(.subheadline.weight(.medium))
                                    if !row.layer.isEmpty {
                                        DSStatusBadge(row.layer, color: row.layer == "pinned" ? DSTheme.brand : .secondary)
                                    }
                                }
                                if !row.content.isEmpty {
                                    Text(row.content).font(.caption).foregroundColor(.secondary).lineLimit(2)
                                }
                                Text("\(row.op.uppercased()) · \(row.at)").font(.caption2).foregroundColor(.secondary)
                            }
                            Spacer()
                            if row.op != "undo" {
                                Button("撤销") {
                                    Task {
                                        _ = try? await host.rpc()?.request("memory.undo", params: ["botId": botId, "journalId": row.id])
                                        status = "已撤销记录 \(row.id)"
                                        await reload()
                                    }
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                    }
                }
            }
            if !status.isEmpty {
                Section("状态") { Text(status).font(.caption).foregroundColor(.secondary) }
            }
        }
        .refreshable { await reload() }
        .navigationTitle("四层记忆与撤销")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showAddMemory = true } label: { Image(systemName: "plus") }
            }
        }
        .sheet(isPresented: $showAddMemory) {
            NavigationStack {
                Form {
                    TextField("记忆标题", text: $newMemTitle)
                    Picker("记忆层级", selection: $newMemLayer) {
                        Text("常驻 (Pinned)").tag("pinned")
                        Text("增量 (Delta)").tag("delta")
                        Text("自动召回 (Recall)").tag("recall")
                        Text("按需 (On-Demand)").tag("on_demand")
                    }
                    TextField("记忆内容", text: $newMemContent, axis: .vertical)
                        .lineLimit(3...6)
                }
                .navigationTitle("新增记忆")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) { Button("取消") { showAddMemory = false } }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("保存") {
                            Task {
                                _ = try? await host.rpc()?.request("memory.add", params: [
                                    "botId": botId,
                                    "title": newMemTitle,
                                    "content": newMemContent,
                                    "layer": newMemLayer
                                ])
                                newMemTitle = ""
                                newMemContent = ""
                                showAddMemory = false
                                await reload()
                            }
                        }
                        .disabled(newMemTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
        }
        .task { await reload() }
    }

    private func reload() async {
        guard let res = try? await host.rpc()?.request("memory.journal", params: ["botId": botId]) else { return }
        let raw = res["records"] as? [[String: Any]] ?? []
        journal = raw.compactMap { d in
            guard let id = d["journalId"] as? String, let op = d["op"] as? String else { return nil }
            return (
                id: id,
                op: op,
                entryId: d["entryId"] as? String ?? "",
                title: d["title"] as? String ?? "",
                content: d["content"] as? String ?? "",
                layer: d["layer"] as? String ?? "",
                at: d["at"] as? String ?? ""
            )
        }
    }
}

// MARK: - 5. Universal Connectors & Token Usage Dashboard

public struct ConnectorsAndUsageView: View {
    @ObservedObject var host: BareWorkletHost
    @State private var totalTokens = 0
    @State private var cacheHitRate = 0.0
    @State private var connectorName = ""
    @State private var connectorEndpoint = ""
    @State private var connectorToken = ""
    @State private var connectorType = "remote-mcp"
    @State private var connectors: [(id: String, type: String, name: String, endpoint: String)] = []
    @State private var mcpStatus = ""

    public var body: some View {
        Form {
            Section("Token 用量与缓存命中") {
                LabeledContent("累计 Tokens", value: "\(totalTokens)")
                LabeledContent("Prompt 缓存命中率", value: String(format: "%.1f%%", cacheHitRate * 100))
            }

            Section("添加通用连接器（凭据仅存 Keychain）") {
                Picker("类型", selection: $connectorType) {
                    Text("Remote MCP").tag("remote-mcp")
                    Text("GitHub").tag("github")
                    Text("邮箱 (IMAP/SMTP)").tag("mail")
                }
                TextField("名称（如 Office MCP）", text: $connectorName)
                TextField("Endpoint / URL", text: $connectorEndpoint)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("Bearer Token（可选，存 Keychain）", text: $connectorToken)
                Button("保存连接器") {
                    guard !connectorName.isEmpty else { return }
                    Task {
                        if let res = try? await host.rpc()?.request("connectors.upsert", params: [
                            "type": connectorType,
                            "name": connectorName,
                            "endpoint": connectorEndpoint
                        ]), let conn = res["connector"] as? [String: Any], let cid = conn["id"] as? String {
                            let tok = connectorToken.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !tok.isEmpty {
                                _ = try? KeychainBridge().setSecret(account: "connector:\(cid)", value: tok)
                            }
                        }
                        connectorName = ""
                        connectorEndpoint = ""
                        connectorToken = ""
                        await reload()
                    }
                }
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
                                        if let res = try? await host.rpc()?.request("mcp.listTools", params: ["endpoint": c.endpoint, "keychainAccount": "connector:\(c.id)"]) {
                                            let tools = res["tools"] as? [[String: Any]] ?? []
                                            mcpStatus = (res["ok"] as? Bool == true)
                                                ? "\(c.name)：已发现 \(tools.count) 个远程工具"
                                                : "连接失败：\(res["error"] as? String ?? "未知错误")"
                                        }
                                    }
                                }
                                .buttonStyle(.bordered)
                                .font(.caption)
                            }
                        }
                        .swipeActions(edge: .trailing) {
                            Button("删除", role: .destructive) {
                                Task {
                                    _ = try? await host.rpc()?.request("connectors.delete", params: ["id": c.id])
                                    _ = try? KeychainBridge().deleteSecret(account: "connector:\(c.id)")
                                    await reload()
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
        if let u = try? await host.rpc()?.request("usage.summary") {
            totalTokens = u["totalTokens"] as? Int ?? 0
            cacheHitRate = u["cacheHitRate"] as? Double ?? 0.0
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


// MARK: - 7. On-Device JavaScriptCore Sandbox Playground

public struct JSSandboxPlaygroundView: View {
    @ObservedObject var host: BareWorkletHost
    @State private var script = "const items = [12, 28, 45];\nconsole.log('count:', items.length);\n({ sum: items.reduce((a,b)=>a+b, 0) })"
    @State private var output = ""
    @State private var deviceInfo = ""

    public var body: some View {
        Form {
            Section("JavaScriptCore 离线沙盒（免 JIT / 零体积增量）") {
                TextEditor(text: $script)
                    .font(.caption.monospaced())
                    .frame(minHeight: 110)
                Button("在 iOS 沙盒中运行") {
                    Task {
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
                    Text(deviceInfo).font(.caption2.monospaced())
                }
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle("端侧 JS 沙盒")
    }
}

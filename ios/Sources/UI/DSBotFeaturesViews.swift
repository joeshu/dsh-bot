import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

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

    public init(currentSection: String, headings: [MarkdownHeading], onJumpTop: @escaping () -> Void, onJumpHeading: @escaping (MarkdownHeading) -> Void) {
        self.currentSection = currentSection
        self.headings = headings
        self.onJumpTop = onJumpTop
        self.onJumpHeading = onJumpHeading
    }

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
        .background(DSTheme.surfacePrimary)
        .overlay(Capsule().stroke(Color.secondary.opacity(0.18), lineWidth: 1))
        .clipShape(Capsule())
        .shadow(color: .black.opacity(0.08), radius: 3, y: 1)
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
    let sessionId: String
    let apiBaseURL: String?
    let botName: String
    let isPrivate: Bool
    @State private var status = ""
    @State private var sending = false
    @State private var request: Task<Void, Never>?
    @State private var sideId: String?
    @State private var question = ""
    @State private var includeRecentContext = false
    @State private var messages: [(role: String, text: String)] = []

    public init(host: LocalAgentHost, model: String, botId: String, botName: String, isPrivate: Bool, sessionId: String? = nil, apiBaseURL: String? = nil) {
        self.host = host
        self.model = model
        self.botId = botId
        self.sessionId = sessionId ?? botId
        self.apiBaseURL = apiBaseURL
        self.botName = botName
        self.isPrivate = isPrivate
    }

    private var recentContext: [[String: String]] {
        guard includeRecentContext else { return [] }
        return host.messages(for: sessionId).suffix(8).compactMap { message in
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
                    if !host.messages(for: sessionId).isEmpty {
                        Toggle("附带最近 8 条可见消息", isOn: $includeRecentContext)
                            .font(.caption)
                        Text(includeRecentContext
                             ? "这次请求会把「\(botName)」的可见对话片段发送给当前模型服务。\(isPrivate ? "此会话为私密会话。" : "")"
                             : "不附带主会话内容；思考过程不会被引用。")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.secondarySystemBackground))

                ScrollViewReader { proxy in
                    ScrollView {
                        if messages.isEmpty {
                            DSEmptyStateView(
                                icon: "bubble.left.and.exclamationmark.bubble.right",
                                title: "开启旁白追问",
                                subtitle: "在不污染当前主线上下文的前提下，随时查询概念、验证代码或做快速推演。"
                            )
                            .padding(.top, 28)
                        } else {
                            LazyVStack(alignment: .leading, spacing: 10) {
                                ForEach(Array(messages.enumerated()), id: \.offset) { idx, msg in
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(msg.role == "You" ? "你" : "侧边助手")
                                            .font(.caption2.weight(.semibold))
                                            .foregroundColor(.secondary)
                                        DSMarkdownText(msg.text)
                                            .padding(10)
                                            .background(msg.role == "You" ? DSTheme.brand.opacity(0.14) : Color(.secondarySystemBackground))
                                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                            .contextMenu {
                                                Button {
                                                    #if canImport(UIKit)
                                                    UIPasteboard.general.string = msg.text
                                                    #endif
                                                    DSHaptics.notify(.success)
                                                } label: {
                                                    Label("复制内容", systemImage: "doc.on.doc")
                                                }
                                            }
                                    }
                                    .id(idx)
                                }
                            }
                            .padding()
                        }
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .onChange(of: messages.count) { count in
                        if count > 0 {
                            withAnimation { proxy.scrollTo(count - 1, anchor: .bottom) }
                        }
                    }
                }

                if !status.isEmpty {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 4)
                }
                Divider()
                HStack(spacing: 8) {
                    TextField("顺手问一句…", text: $question)
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
                        let endpoint = apiBaseURL ?? host.apiBaseURL
                        sideId = id
                        request = Task {
                            defer {
                                sending = false
                                if sideId == id { sideId = nil }
                            }
                            do {
                                guard let rpc = host.rpc() else { throw IPCFrameError.channelClosed }
                                let response = try await rpc.request("side.ask", params: [
                                    "model": model, "question": q, "apiBaseURL": endpoint,
                                    "sideId": id, "context": contextSnapshot
                                ], timeoutSeconds: 95)
                                guard let reply = response["reply"] as? String else { throw ModelProviderError.invalidResponse }
                                messages.append((role: "Side", text: reply))
                            } catch {
                                if !Task.isCancelled { status = error.localizedDescription }
                            }
                        }
                    }
                    .disabled(sending || question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .buttonStyle(.borderedProminent)
                }
                .padding()
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("侧边对话 (/side)")
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

    public init(host: LocalAgentHost, groupId: String) {
        self.host = host
        self.groupId = groupId
    }

    public var body: some View {
        NavigationStack {
            List {
                Section("当前群 Goal 目标") {
                    HStack(spacing: 10) {
                        Image(systemName: "target")
                            .foregroundStyle(DSTheme.brand)
                            .font(.title3)
                        Text(goalTitle)
                            .font(.subheadline.weight(.semibold))
                    }
                    .padding(.vertical, 4)

                    HStack {
                        TextField("设定或更新群目标…", text: $newGoalInput)
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
                        .buttonStyle(.borderedProminent)
                        .font(.caption.weight(.semibold))
                        .disabled(newGoalInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }

                Section("共享待办清单 (\(todos.filter { !$0.done }.count) 待完成 / 共 \(todos.count))") {
                    HStack {
                        TextField("添加群待办事项…", text: $newTodoText)
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
                        .buttonStyle(.bordered)
                        .font(.caption.weight(.semibold))
                        .disabled(newTodoText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    if todos.isEmpty {
                        Text("暂无群待办，可在上方添加或在群对话中使用工具创建。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(todos, id: \.id) { todo in
                        HStack(spacing: 10) {
                            Image(systemName: todo.done ? "checkmark.circle.fill" : "circle")
                                .foregroundColor(todo.done ? DSTheme.success : .secondary)
                            Text(todo.text)
                                .strikethrough(todo.done)
                                .foregroundStyle(todo.done ? .secondary : .primary)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            Task {
                                _ = try? await host.rpc()?.request("group.todo.toggle", params: ["groupId": groupId, "id": todo.id, "done": !todo.done])
                                DSHaptics.impact(.light)
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
            .navigationTitle("群协作面板 (/goal)")
            .navigationBarTitleDisplayMode(.inline)
            .scrollDismissesKeyboard(.interactively)
            .refreshable { await reload() }
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
            HStack {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Image(systemName: "waveform.path.ecg")
                    .font(.caption)
                    .foregroundStyle(DSTheme.brand)
            }
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

    public init(host: LocalAgentHost) {
        self.host = host
    }

    public var body: some View {
        Form {
            Section("QuickJS 离线沙盒（免 JIT · 2 秒超时 · 16 MiB 上限）") {
                TextEditor(text: $script)
                    .font(.caption.monospaced())
                    .frame(minHeight: 120)
                HStack {
                    Button(isRunning ? "运行中…" : "在 iOS 沙盒中运行") {
                        isRunning = true
                        Task {
                            defer { isRunning = false }
                            do {
                                guard let rpc = host.rpc() else { throw IPCFrameError.channelClosed }
                                let res = try await rpc.request("tools.jsEval", params: ["script": script])
                                let ok = res["ok"] as? Bool ?? false
                                let val = res["value"] as? String ?? ""
                                let logs = (res["logs"] as? [String] ?? []).joined(separator: "\n")
                                let err = res["error"] as? String ?? ""
                                output = ok ? [logs, val].filter { !$0.isEmpty }.joined(separator: "\n") : "错误：\(err)"
                                DSHaptics.notify(ok ? .success : .error)
                            } catch {
                                output = "执行失败：\(error.localizedDescription)"
                                DSHaptics.notify(.error)
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
                    Text(output)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
            }

            Section("本机设备状态探针 (device.status)") {
                Button {
                    Task {
                        do {
                            guard let rpc = host.rpc() else { throw IPCFrameError.channelClosed }
                            let st = try await rpc.request("device.status")
                            let d = try JSONSerialization.data(withJSONObject: st, options: [.prettyPrinted, .sortedKeys])
                            deviceInfo = String(decoding: d, as: UTF8.self)
                            DSHaptics.impact(.light)
                        } catch {
                            deviceInfo = "读取失败：\(error.localizedDescription)"
                        }
                    }
                } label: {
                    Label("读取本机电量与温控状态", systemImage: "battery.100.bolt")
                }
                if !deviceInfo.isEmpty {
                    Text(deviceInfo)
                        .font(.caption2.monospaced())
                        .textSelection(.enabled)
                }
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle("端侧 JS 沙盒")
        .navigationBarTitleDisplayMode(.inline)
    }
}


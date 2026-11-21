import SwiftUI

enum SessionHistoryPresentation: Identifiable {
    case export
    case message(ChatMessageItem)
    case tool(DSHToolActivity)

    var id: String {
        switch self {
        case .export: return "export"
        case .message(let message): return "message-" + message.id
        case .tool(let activity): return "tool-" + activity.id
        }
    }
}

struct SessionHistoryDetailView: View {
    let host: LocalAgentHost
    let bot: BotProfile
    let presentation: SessionHistoryPresentation

    @Environment(\.dismiss) private var dismiss
    @State private var content: String?
    @State private var reasoning = ""
    @State private var toolName = ""
    @State private var toolArguments = ""
    @State private var toolResult = ""
    @State private var toolPhase = ""
    @State private var toolArgumentsNext = 0
    @State private var toolArgumentsTotalBytes = 0
    @State private var toolResultNext = 0
    @State private var toolResultTotalBytes = 0
    @State private var isLoadingMoreToolRecord = false
    @State private var failure: String?
    @State private var retry = 0

    var body: some View {
        NavigationStack {
            Group {
                if let failure {
                    VStack(spacing: 12) {
                        Text(failure)
                        Button("重试") { retry += 1 }
                    }
                    .padding()
                } else if let content {
                    switch presentation {
                    case .export:
                        VStack(spacing: 12) {
                            Text("已生成 Markdown · 不含思考过程")
                                .foregroundStyle(.secondary)
                            ShareLink(item: content) {
                                Label("分享 Markdown", systemImage: "square.and.arrow.up")
                            }
                        }
                        .padding()
                    case .message:
                        ScrollView {
                            VStack(alignment: .leading, spacing: 12) {
                                if !reasoning.isEmpty {
                                    DisclosureGroup("深度思考过程") {
                                        Text(reasoning).textSelection(.enabled)
                                    }
                                }
                                DSMarkdownText(content).textSelection(.enabled)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                        }
                    case .tool:
                        ScrollView {
                            VStack(alignment: .leading, spacing: 12) {
                                Label(toolName, systemImage: "wrench.and.screwdriver")
                                    .font(.headline)
                                Text("执行状态：\(toolPhase)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text("完整输入 · \(byteCount(toolArgumentsNext)) / \(byteCount(toolArgumentsTotalBytes))")
                                    .font(.subheadline.weight(.semibold))
                                Text(toolArguments)
                                    .font(.caption.monospaced())
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Text("完整结果 · \(byteCount(toolResultNext)) / \(byteCount(toolResultTotalBytes))")
                                    .font(.subheadline.weight(.semibold))
                                Text(toolResult)
                                    .font(.caption.monospaced())
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                if hasMoreToolRecord {
                                    Button {
                                        Task { await loadMoreToolRecord() }
                                    } label: {
                                        if isLoadingMoreToolRecord {
                                            ProgressView("正在读取下一段…")
                                        } else {
                                            Label("继续读取下一段", systemImage: "text.append")
                                        }
                                    }
                                    .disabled(isLoadingMoreToolRecord)
                                }
                            }
                            .padding()
                        }
                    }
                } else {
                    ProgressView("正在读取记录…")
                }
            }
            .navigationTitle(title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
        }
        .task(id: retry) { await load() }
    }

    private var title: String {
        switch presentation {
        case .export: return "导出会话"
        case .message: return "完整消息"
        case .tool: return "完整工具记录"
        }
    }

    private func load() async {
        failure = nil
        do {
            switch presentation {
            case .export:
                let markdown = try await host.exportSessionMarkdown(sessionId: bot.id, botName: bot.name)
                try Task.checkCancellation()
                content = markdown
            case .message(let message):
                let full = try await host.loadFullHistoryMessage(message)
                try Task.checkCancellation()
                content = full.content
                reasoning = full.reasoning
            case .tool(let activity):
                let page = try await host.loadHistoryToolActivityPage(activity)
                try Task.checkCancellation()
                toolName = activity.toolName
                toolArguments = page.arguments
                toolArgumentsNext = page.argumentsNext
                toolArgumentsTotalBytes = page.argumentsTotalBytes
                toolResult = page.result
                toolResultNext = page.resultNext
                toolResultTotalBytes = page.resultTotalBytes
                toolPhase = page.phase == "completed" ? "已完成"
                    : page.phase == "failed" ? "失败" : "结果未知"
                content = ""
            }
        } catch {
            if !Task.isCancelled { failure = error.localizedDescription }
        }
    }

    private var hasMoreToolRecord: Bool {
        toolArgumentsNext < toolArgumentsTotalBytes || toolResultNext < toolResultTotalBytes
    }

    private func byteCount(_ value: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .memory)
    }

    private func loadMoreToolRecord() async {
        guard case .tool(let activity) = presentation, hasMoreToolRecord else { return }
        isLoadingMoreToolRecord = true
        defer { isLoadingMoreToolRecord = false }
        do {
            let page = try await host.loadHistoryToolActivityPage(
                activity, argumentsFrom: toolArgumentsNext, resultFrom: toolResultNext
            )
            try Task.checkCancellation()
            toolArguments += page.arguments
            toolArgumentsNext = page.argumentsNext
            toolArgumentsTotalBytes = page.argumentsTotalBytes
            toolResult += page.result
            toolResultNext = page.resultNext
            toolResultTotalBytes = page.resultTotalBytes
            toolPhase = page.phase == "completed" ? "已完成"
                : page.phase == "failed" ? "失败" : "结果未知"
        } catch {
            if !Task.isCancelled { failure = error.localizedDescription }
        }
    }
}

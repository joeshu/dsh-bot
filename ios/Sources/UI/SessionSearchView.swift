import SwiftUI

private struct SessionSearchHit: Identifiable {
    let sessionKey: String
    let rootBotId: String
    let sequence: Int
    let snippet: String

    var id: String { sessionKey }
}

struct SessionSearchResults: View {
    @ObservedObject var host: LocalAgentHost
    let query: String

    @State private var results: [SessionSearchHit] = []
    @State private var cursor: String?
    @State private var loading = true
    @State private var failed = false
    @State private var requestNumber = 0
    @State private var appendPage = false

    private var publicBotIDs: Set<String> {
        Set(host.bots.lazy.filter { !$0.isPrivate }.map(\.id))
    }

    var body: some View {
        Section("历史消息") {
            ForEach(results) { hit in
                if let bot = host.bots.first(where: { $0.id == hit.rootBotId && !$0.isPrivate }) {
                    NavigationLink {
                        SessionSearchContextView(host: host, bot: bot, sessionKey: hit.sessionKey, sequence: hit.sequence)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                Text(bot.name).font(.headline)
                                if hit.sessionKey.contains(":") {
                                    Text("子话题")
                                        .font(.caption2)
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 1)
                                        .background(Color.secondary.opacity(0.15))
                                        .clipShape(Capsule())
                                }
                            }
                            Text(hit.snippet).font(.subheadline).foregroundStyle(.secondary).lineLimit(3)
                        }
                    }
                }
            }
            if loading {
                ProgressView("正在查询历史…")
            } else if failed {
                Button("重新搜索历史") {
                    appendPage = false
                    requestNumber += 1
                }
            } else if cursor != nil {
                Button("更多历史结果") {
                    appendPage = true
                    requestNumber += 1
                }
            } else if results.isEmpty {
                Text("未找到匹配的历史消息").foregroundStyle(.secondary)
            }
        }
        .task(id: requestNumber) { await search(append: appendPage) }
        .onChange(of: query) { _ in
            cursor = nil
            appendPage = false
            requestNumber += 1
        }
        .onChange(of: publicBotIDs) { allowedIDs in
            results.removeAll { !allowedIDs.contains($0.rootBotId) }
            cursor = nil
            appendPage = false
            requestNumber += 1
        }
    }

    private func search(append: Bool) async {
        loading = true
        failed = false
        defer { if !Task.isCancelled { loading = false } }
        do {
            if !append { try await Task.sleep(nanoseconds: 300_000_000) }
            guard let rpc = host.rpc() else { throw IPCFrameError.channelClosed }
            let generation = host.runtimeGeneration
            let publicIDs = Array(publicBotIDs)
            // Truncate at Unicode scalar boundaries so a search ending in an emoji
            // cannot become an invalid UTF-16 string during request construction.
            let searchQuery = String(String.UnicodeScalarView(query.unicodeScalars.prefix(160)))
            var params: [String: Any] = ["query": searchQuery, "botIds": publicIDs]
            if append { params["cursor"] = cursor }
            let response = try await rpc.request("session.search", params: params, timeoutSeconds: 30)
            try Task.checkCancellation()
            guard host.runtimeGeneration == generation else { throw IPCFrameError.channelClosed }
            let rows = response["results"] as? [[String: Any]] ?? []
            var seen = Set(append ? results.map(\.id) : [])
            let hits = rows.compactMap { row -> SessionSearchHit? in
                guard let sessionKey = row["botId"] as? String, let sequence = row["sequence"] as? Int,
                      let snippet = row["snippet"] as? String else { return nil }
                let rootId = sessionKey.split(separator: ":", maxSplits: 1).first.map(String.init) ?? sessionKey
                guard host.bots.contains(where: { $0.id == rootId && !$0.isPrivate }),
                      seen.insert(sessionKey).inserted else { return nil }
                return SessionSearchHit(sessionKey: sessionKey, rootBotId: rootId, sequence: sequence, snippet: snippet)
            }
            if !append { results = [] }
            results.append(contentsOf: hits)
            cursor = response["nextCursor"] as? String
        } catch {
            if !Task.isCancelled { failed = true }
        }
    }
}

private struct SessionSearchContextView: View {
    @ObservedObject var host: LocalAgentHost
    let bot: BotProfile
    let sessionKey: String
    let sequence: Int

    @State private var messages: [ChatMessageItem] = []
    @State private var failed = false
    @State private var retry = 0
    @State private var presentation: SessionHistoryPresentation?

    private var visible: Bool {
        host.bots.contains { $0.id == bot.id && !$0.isPrivate }
    }

    private var targetMessageID: String {
        messages.first(where: { $0.sequence == sequence })?.id ?? "dsh-ios:\(sessionKey)-\(sequence)"
    }

    var body: some View {
        ScrollViewReader { proxy in
            List {
                if !visible {
                    Text("此会话已不可访问")
                } else if failed {
                    Button("重新读取消息上下文") { retry += 1 }
                } else if messages.isEmpty {
                    ProgressView("正在定位消息…")
                } else {
                    ForEach(messages) { message in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(message.sequence == sequence ? "匹配消息" : (message.role == "user" ? "你" : bot.name))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            DSMarkdownText(message.content)
                            if message.historyPreview == true {
                                Button("查看完整消息") { presentation = .message(message) }
                            }
                        }
                        .id(message.sequence ?? -1)
                    }
                }
            }
            .task(id: retry) {
                guard visible else { return }
                failed = false
                do {
                    messages = try await host.searchSessionContext(botId: sessionKey, sequence: sequence)
                    await Task.yield()
                    if visible && !Task.isCancelled { proxy.scrollTo(sequence, anchor: .center) }
                } catch {
                    if !Task.isCancelled { failed = true }
                }
            }
        }
        .navigationTitle("历史上下文")
        .toolbar {
            if visible {
                NavigationLink("打开会话") {
                    ChatView(
                        bot: bot,
                        host: host,
                        targetMessageID: targetMessageID,
                        initialAddress: host.resolveAddress(sessionKey)
                    )
                }
            }
        }
        .sheet(item: $presentation) { item in
            if visible { SessionHistoryDetailView(host: host, bot: bot, presentation: item, sessionId: sessionKey) }
        }
        .onChange(of: visible) { allowed in
            if !allowed {
                messages = []
                presentation = nil
            }
        }
    }
}

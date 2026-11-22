import LocalAuthentication
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

// MARK: - 4. 4-Layer Memory & Reversible Journal View (with optional Public Bot Switcher)

public struct MemoryVaultView: View {
    @ObservedObject var host: LocalAgentHost
    let initialBotId: String
    let allowsSwitchingBot: Bool
    @State private var activeBotId: String

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
    @State private var searchText = ""
    @State private var layerFilter = "all"
    @Environment(\.scenePhase) private var phase

    public init(host: LocalAgentHost, botId: String, allowsSwitchingBot: Bool = false) {
        self.host = host
        self.initialBotId = botId
        self.allowsSwitchingBot = allowsSwitchingBot
        _activeBotId = State(initialValue: botId)
    }

    private var publicBots: [BotProfile] {
        host.bots.filter { !$0.isPrivate }
    }

    private var activeBotName: String {
        host.bots.first(where: { $0.id == activeBotId })?.name ?? activeBotId
    }

    private var filteredJournal: [Record] {
        journal.filter { row in
            let matchesLayer = layerFilter == "all" || row.layer == layerFilter
            let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let matchesSearch = q.isEmpty || row.title.lowercased().contains(q) || row.content.lowercased().contains(q)
            return matchesLayer && matchesSearch
        }
    }

    public var body: some View {
        List {
            if allowsSwitchingBot && publicBots.count > 1 {
                Section("选择智能体记忆空间") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(publicBots) { bot in
                                let selected = bot.id == activeBotId
                                Button {
                                    activeBotId = bot.id
                                    DSHaptics.impact(.light)
                                    Task { await reload() }
                                } label: {
                                    HStack(spacing: 6) {
                                        Circle()
                                            .fill(selected ? .white : DSTheme.botAvatarColor(bot))
                                            .frame(width: 8, height: 8)
                                        Text(bot.name)
                                            .font(.caption.weight(selected ? .semibold : .medium))
                                    }
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 7)
                                    .background(selected ? DSTheme.brand : DSTheme.surfaceSecondary)
                                    .foregroundStyle(selected ? .white : .primary)
                                    .clipShape(Capsule())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    Text("私密智能体的记忆受独立硬件锁保护，请直接从私密会话右上角工作抽屉查看。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Picker("筛选", selection: $layerFilter) {
                    Text("全部 (\(journal.count))").tag("all")
                    Text("常驻 (随对话发送)").tag("pinned")
                    Text("仅本机 (Delta)").tag("delta")
                }
                .pickerStyle(.segmented)
            }

            Section("「\(activeBotName)」的记忆 (\(filteredJournal.count))") {
                if filteredJournal.isEmpty {
                    DSEmptyStateView(
                        icon: "brain.head.profile",
                        title: journal.isEmpty ? "暂无记忆记录" : "无匹配记忆",
                        subtitle: journal.isEmpty ? "你可以点击右上角手动新增常驻或本机记忆，或在长对话中将助手回复一键存入。" : "尝试切换上方分类筛选或清空搜索词。"
                    )
                    .listRowBackground(Color.clear)
                } else {
                    ForEach(filteredJournal) { row in
                        HStack(alignment: .top, spacing: 10) {
                            memoryRow(row)
                            Spacer()
                            Button("撤销", role: .destructive) {
                                Task { await mutate("memory.undo", id: row.id) }
                            }
                            .buttonStyle(.bordered)
                            .font(.caption)
                        }
                        .padding(.vertical, 3)
                    }
                }
            }

            Section("升级前的未归属记忆") {
                if !showsLegacy {
                    Button {
                        Task {
                            let context = LAContext()
                            do {
                                guard try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "查看升级前的记忆") else { return }
                                showsLegacy = true
                                await reload()
                            } catch { status = "无法验证设备身份。" }
                        }
                    } label: {
                        Label("验证设备身份并查看旧记忆", systemImage: "faceid")
                    }
                } else {
                    Text("选择归属后，这条记忆将移到「\(activeBotName)」。常驻记忆会随请求发给模型服务。")
                        .font(.caption).foregroundStyle(.secondary)
                    if legacy.isEmpty {
                        Text("暂无未归属记忆").font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(legacy) { row in
                        HStack {
                            memoryRow(row)
                            Spacer()
                            Button("分配给当前 Bot") { Task { await mutate("memory.assign", id: row.id) } }
                                .buttonStyle(.bordered)
                                .font(.caption)
                        }
                    }
                }
            }
            if !status.isEmpty { Section("状态") { Text(status).font(.caption) } }
        }
        .searchable(text: $searchText, prompt: "搜索记忆标题或内容")
        .refreshable { await reload() }
        .navigationTitle("记忆中心")
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
                    Section("归属智能体：\(activeBotName)") {
                        TextField("记忆标题", text: $newMemTitle)
                        Picker("记忆层级", selection: $newMemLayer) {
                            Text("常驻 · 随聊天自动发送给模型").tag("pinned")
                            Text("手动查阅 · 仅保存在本机").tag("delta")
                        }
                        TextField("记忆内容", text: $newMemContent, axis: .vertical).lineLimit(3...6)
                    }
                    if !status.isEmpty { Text(status).font(.caption) }
                }
                .navigationTitle("新增记忆")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) { Button("取消") { showAddMemory = false } }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("保存") {
                            let decision = PrivacyGate.evaluateMemoryWrite(title: newMemTitle, content: newMemContent)
                            if case .hardBlock(let reason) = decision {
                                status = "隐私闸门拦截：\(reason)"
                                DSHaptics.notify(.error)
                                return
                            }
                            Task {
                                do {
                                    guard let rpc = host.rpc() else { throw IPCFrameError.channelClosed }
                                    _ = try await rpc.request("memory.add", params: [
                                        "botId": activeBotId, "title": newMemTitle, "content": newMemContent, "layer": newMemLayer
                                    ])
                                    newMemTitle = ""
                                    newMemContent = ""
                                    showAddMemory = false
                                    if case .softWarn(let reason) = decision {
                                        status = "已保存（隐私提示：\(reason)）"
                                    } else {
                                        status = ""
                                    }
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
        .task(id: activeBotId) { await reload() }
    }

    private func memoryRow(_ row: Record) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(row.title).font(.subheadline.weight(.semibold))
                DSStatusBadge(
                    row.layer == "pinned" ? "常驻" : "本机",
                    color: row.layer == "pinned" ? DSTheme.brand : .secondary
                )
            }
            Text(row.content)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }

    private func mutate(_ method: String, id: String) async {
        do {
            guard let rpc = host.rpc() else { throw IPCFrameError.channelClosed }
            let result = try await rpc.request(method, params: ["botId": activeBotId, "journalId": id])
            status = (result["assigned"] as? Bool == true || result["undone"] as? Bool == true) ? "" : "这条记忆已变更。"
            await reload()
        } catch { status = error.localizedDescription }
    }

    private func reload() async {
        do {
            guard let rpc = host.rpc() else { throw IPCFrameError.channelClosed }
            let current = try await rpc.request("memory.journal", params: ["botId": activeBotId])
            journal = (current["records"] as? [[String: Any]] ?? []).compactMap(Record.init)
            if showsLegacy {
                let previous = try await rpc.request("memory.legacy")
                if showsLegacy { legacy = (previous["records"] as? [[String: Any]] ?? []).compactMap(Record.init) }
            }
        } catch { status = error.localizedDescription }
    }
}


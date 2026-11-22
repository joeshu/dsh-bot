import SwiftUI

struct SessionInboxView: View {
    @ObservedObject var host: LocalAgentHost
    @ObservedObject private var threadStore = BotThreadStore.shared

    private var approvalItems: [PendingInboxItem] {
        host.unifiedPendingInbox.filter { $0.kind == .approval }
    }

    private var questionItems: [PendingInboxItem] {
        host.unifiedPendingInbox.filter { $0.kind == .question }
    }

    var body: some View {
        List {
            if host.unifiedPendingInbox.isEmpty {
                DSEmptyStateView(
                    icon: "tray",
                    title: "收件箱已清空",
                    subtitle: "当前没有任何待审批的工具操作或待回答的 DSH 提问。"
                )
                .listRowBackground(Color.clear)
            }

            if !approvalItems.isEmpty {
                Section("待审批工具调用 (\(approvalItems.count))") {
                    ForEach(approvalItems) { item in
                        if let bot = host.bot(for: item.address) {
                            let isHandling = host.inFlightRequestIDs.contains(item.id)
                            let threadLabel = bot.isPrivate ? nil : threadStore.threadTitle(for: item.address)
                            VStack(alignment: .leading, spacing: 8) {
                                NavigationLink {
                                    ChatView(bot: bot, host: host, initialAddress: item.address)
                                } label: {
                                    HStack(spacing: 12) {
                                        DSBotAvatar(
                                            initials: bot.name,
                                            color: DSTheme.botAvatarColor(bot),
                                            isPrivate: bot.isPrivate,
                                            size: 38
                                        )
                                        VStack(alignment: .leading, spacing: 3) {
                                            HStack(spacing: 6) {
                                                Text(bot.isPrivate ? "私密会话" : bot.name)
                                                    .font(.subheadline.weight(.semibold))
                                                if let threadLabel {
                                                    Text("· \(threadLabel)")
                                                        .font(.caption)
                                                        .foregroundStyle(.secondary)
                                                        .lineLimit(1)
                                                }
                                                DSStatusBadge(isHandling ? "处理中" : "待审批", color: DSTheme.warning, icon: "hand.raised.fill")
                                            }
                                            Text(bot.isPrivate ? "需解锁私密会话后查看并确认工具审批" : "工具：\(item.toolName ?? item.title) · \(item.detail)")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(2)
                                        }
                                    }
                                    .padding(.vertical, 2)
                                }
                                if !bot.isPrivate {
                                    HStack(spacing: 10) {
                                        Button {
                                            Task { await host.respondToApproval(id: item.id, approved: true) }
                                        } label: {
                                            Label(isHandling ? "处理中…" : "批准执行", systemImage: "checkmark.circle.fill")
                                                .font(.caption.weight(.semibold))
                                        }
                                        .buttonStyle(.borderedProminent)
                                        .controlSize(.small)
                                        .disabled(isHandling)

                                        Button(role: .destructive) {
                                            Task { await host.respondToApproval(id: item.id, approved: false) }
                                        } label: {
                                            Label("拒绝", systemImage: "xmark.circle")
                                                .font(.caption.weight(.semibold))
                                        }
                                        .buttonStyle(.bordered)
                                        .controlSize(.small)
                                        .disabled(isHandling)
                                    }
                                    .padding(.leading, 50)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
            }

            if !questionItems.isEmpty {
                Section("待回答智能体提问 (\(questionItems.count))") {
                    ForEach(questionItems) { item in
                        if let bot = host.bot(for: item.address) {
                            let threadLabel = bot.isPrivate ? nil : threadStore.threadTitle(for: item.address)
                            NavigationLink {
                                ChatView(bot: bot, host: host, initialAddress: item.address)
                            } label: {
                                HStack(spacing: 12) {
                                    DSBotAvatar(
                                        initials: bot.name,
                                        color: DSTheme.botAvatarColor(bot),
                                        isPrivate: bot.isPrivate,
                                        size: 38
                                    )
                                    VStack(alignment: .leading, spacing: 3) {
                                        HStack(spacing: 6) {
                                            Text(bot.isPrivate ? "私密会话" : bot.name)
                                                .font(.subheadline.weight(.semibold))
                                            if let threadLabel {
                                                Text("· \(threadLabel)")
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                                    .lineLimit(1)
                                            }
                                            DSStatusBadge(item.title, color: DSTheme.brand, icon: "questionmark.circle.fill")
                                        }
                                        Text(bot.isPrivate ? "需解锁私密会话后回答问题" : item.detail)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(2)
                                    }
                                }
                                .padding(.vertical, 2)
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("待处理收件箱")
        .navigationBarTitleDisplayMode(.inline)
    }
}

import SwiftUI

struct SessionInboxView: View {
    @ObservedObject var host: LocalAgentHost

    var body: some View {
        List {
            if host.pendingApprovals.isEmpty && host.pendingDSHQuestions.isEmpty {
                DSEmptyStateView(
                    icon: "tray",
                    title: "收件箱已清空",
                    subtitle: "当前没有任何待审批的工具操作或待回答的 DSH 提问。"
                )
                .listRowBackground(Color.clear)
            }

            if !host.pendingApprovals.isEmpty {
                Section("待审批工具调用 (\(host.pendingApprovals.count))") {
                    ForEach(host.pendingApprovals) { approval in
                        if let bot = host.bots.first(where: { $0.id == approval.sessionId }) {
                            NavigationLink {
                                ChatView(bot: bot, host: host)
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
                                            DSStatusBadge("待审批", color: DSTheme.warning, icon: "hand.raised.fill")
                                        }
                                        Text(bot.isPrivate ? "需解锁私密会话后查看并确认工具审批" : "工具：\(approval.tool) · \(approval.summary)")
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

            if !host.pendingDSHQuestions.isEmpty {
                Section("待回答智能体提问 (\(host.pendingDSHQuestions.count))") {
                    ForEach(host.pendingDSHQuestions) { request in
                        if let bot = host.bots.first(where: { $0.id == request.sessionId }) {
                            NavigationLink {
                                ChatView(bot: bot, host: host)
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
                                            DSStatusBadge("\(request.questions.count) 项提问", color: DSTheme.brand, icon: "questionmark.circle.fill")
                                        }
                                        Text(bot.isPrivate ? "需解锁私密会话后回答问题" : (request.questions.first?.question ?? "智能体正在等待你的补充确认"))
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

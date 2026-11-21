import SwiftUI

struct SessionInboxView: View {
    @ObservedObject var host: LocalAgentHost

    var body: some View {
        List {
            if host.pendingApprovals.isEmpty && host.pendingDSHQuestions.isEmpty {
                Text("没有待处理的审批或提问").foregroundStyle(.secondary)
            }
            ForEach(host.pendingApprovals) { approval in
                if let bot = host.bots.first(where: { $0.id == approval.sessionId }) {
                    NavigationLink {
                        ChatView(bot: bot, host: host)
                    } label: {
                        Label(bot.isPrivate ? "私密会话有待审批操作" : "\(bot.name) · 工具审批", systemImage: "checkmark.shield")
                    }
                }
            }
            ForEach(host.pendingDSHQuestions) { request in
                if let bot = host.bots.first(where: { $0.id == request.sessionId }) {
                    NavigationLink {
                        ChatView(bot: bot, host: host)
                    } label: {
                        Label(bot.isPrivate ? "私密会话有待回答问题" : "\(bot.name) · 待回答问题", systemImage: "questionmark.bubble")
                    }
                }
            }
        }
        .navigationTitle("待处理")
    }
}

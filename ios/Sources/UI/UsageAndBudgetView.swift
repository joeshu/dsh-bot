import Charts
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

// MARK: - 5. Multi-dimensional Token Usage & Cache Dashboard

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
    @ObservedObject private var costGovernor = CostBudgetGovernor.shared
    @State private var usageTotals = DSHUsageTotals()
    @State private var botUsage: [DSHUsageRollup] = []
    @State private var modelUsage: [DSHUsageRollup] = []
    @State private var dailyUsage: [DSHUsageRollup] = []
    @State private var unreportedCalls = 0
    @State private var unreadUsageSessions = 0
    @State private var legacyTotalTokens = 0
    @State private var legacyCacheHitRate = 0.0
    @State private var usageDimension = "day"

    public init(host: LocalAgentHost) {
        self.host = host
    }

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

    private var activeRollups: [DSHUsageRollup] {
        switch usageDimension {
        case "bot": return botUsage
        case "model": return modelUsage
        default: return dailyUsage
        }
    }

    public var body: some View {
        Form {
            Section("真实用量概览（DSH 持久事件）") {
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

            Section("成本估算与预算守卫（3 态显示）") {
                let primaryModel = modelUsage.first?.id ?? ModelProvider.defaultModel
                let costState = CostBudgetGovernor.estimateCost(
                    model: primaryModel,
                    inputTokens: usageTotals.inputTokens,
                    cacheReadTokens: usageTotals.cacheReadTokens,
                    outputTokens: usageTotals.outputTokens
                )
                let cacheRatio = CostBudgetGovernor.cacheHitRatio(
                    inputTokens: usageTotals.inputTokens,
                    cacheReadTokens: usageTotals.cacheReadTokens
                )
                LabeledContent("预估费用（\(primaryModel)）", value: costState.formattedLabel)
                LabeledContent("今日累计预估", value: String(format: "$%.4f", costGovernor.todayEstimatedSpendUSD))
                LabeledContent("Prompt Cache 命中率", value: String(format: "%.1f%%", cacheRatio * 100))
                if let warning = costGovernor.activeBudgetWarning {
                    Text(warning)
                        .font(.caption)
                        .foregroundStyle(DSTheme.warning)
                }
                Stepper(
                    value: $costGovernor.dailyBudgetUSD,
                    in: 0...100,
                    step: 0.5
                ) {
                    LabeledContent(
                        "每日预算上限",
                        value: costGovernor.dailyBudgetUSD > 0
                            ? String(format: "$%.2f / 天", costGovernor.dailyBudgetUSD)
                            : "不限制"
                    )
                }
                if costGovernor.dailyBudgetUSD > 0 {
                    Picker("超额策略", selection: $costGovernor.budgetAction) {
                        ForEach(BudgetGuardAction.allCases) { action in
                            Text(action.displayName).tag(action)
                        }
                    }
                    .pickerStyle(.segmented)
                }
            }

            Section("多维用量分析") {
                Picker("统计维度", selection: $usageDimension) {
                    Text("最近 7 天").tag("day")
                    Text("按智能体").tag("bot")
                    Text("按模型").tag("model")
                }
                .pickerStyle(.segmented)

                let items = usageDimension == "day" ? Array(activeRollups.reversed()) : activeRollups
                if items.contains(where: { $0.totals.totalTokens > 0 }) {
                    Chart(items.prefix(8)) { item in
                        BarMark(
                            x: .value("维度", item.title),
                            y: .value("Tokens", item.totals.totalTokens)
                        )
                        .foregroundStyle(DSTheme.brand.gradient)
                        .cornerRadius(4)
                    }
                    .frame(height: 165)
                    .padding(.vertical, 6)
                }
                if activeRollups.isEmpty {
                    Text("当前维度暂无用量数据。").font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(activeRollups) { item in
                        LabeledContent(item.title, value: "\(item.totals.totalTokens.formatted()) Tokens · \(item.totals.calls.formatted()) 次")
                    }
                }
            }

            Section("原生兼容请求（历史累计）") {
                LabeledContent("累计 Tokens", value: legacyTotalTokens.formatted())
                LabeledContent("Prompt 缓存命中率", value: String(format: "%.1f%%", legacyCacheHitRate * 100))
                Text("包含 Swift 兼容路径的历史请求，不与 DSH 明细合并，也无法按 Bot、模型或日期拆分。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Remote MCP 连接器") {
                NavigationLink {
                    ConnectorMarketplaceView(host: host)
                } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("前往 Remote MCP 连接器市场")
                                .font(.subheadline.weight(.semibold))
                            Text("管理已配置连接器或浏览 38 个官方 MCP 服务目录")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "puzzlepiece.extension.fill")
                            .foregroundStyle(.indigo)
                    }
                }
            }
        }
        .refreshable { await reload() }
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle("Token 用量与缓存")
        .navigationBarTitleDisplayMode(.inline)
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
    }
}


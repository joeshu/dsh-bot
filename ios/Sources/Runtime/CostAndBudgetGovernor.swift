import Foundation

/// Three-state cost representation to avoid misleading `$0.00` for unpriced custom models.
public enum CostDisplayState: Equatable, Sendable {
    case exact(Double)
    case free
    case unknown

    public var formattedLabel: String {
        switch self {
        case .exact(let usd):
            if usd < 0.0001 && usd > 0 {
                return "<$0.0001"
            }
            return String(format: "$%.4f", usd)
        case .free:
            return "免费"
        case .unknown:
            return "未知（自定义模型）"
        }
    }
}

public enum BudgetGuardAction: String, CaseIterable, Identifiable, Sendable {
    case warn
    case stop

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .warn: return "超额提醒"
        case .stop: return "超额拦截"
        }
    }
}

public enum BudgetEvaluation: Equatable, Sendable {
    case allow
    case warn(String)
    case block(String)
}

/// Estimates DeepSeek API cost (with Prompt Cache savings) and enforces optional daily budget limits.
@MainActor
public final class CostBudgetGovernor: ObservableObject {
    public static let shared = CostBudgetGovernor()

    private let budgetKey = "dsbot.cost.dailyBudgetUSD"
    private let actionKey = "dsbot.cost.budgetAction"
    private let spendDayKey = "dsbot.cost.spendDay"
    private let spendAmountKey = "dsbot.cost.todaySpendUSD"

    @Published public var dailyBudgetUSD: Double {
        didSet { UserDefaults.standard.set(dailyBudgetUSD, forKey: budgetKey) }
    }

    @Published public var budgetAction: BudgetGuardAction {
        didSet { UserDefaults.standard.set(budgetAction.rawValue, forKey: actionKey) }
    }

    @Published public private(set) var todayEstimatedSpendUSD: Double = 0
    @Published public var activeBudgetWarning: String?

    private init() {
        self.dailyBudgetUSD = UserDefaults.standard.double(forKey: budgetKey)
        let savedAction = UserDefaults.standard.string(forKey: actionKey) ?? BudgetGuardAction.warn.rawValue
        self.budgetAction = BudgetGuardAction(rawValue: savedAction) ?? .warn
        self.todayEstimatedSpendUSD = Self.loadTodaySpend(dayKey: spendDayKey, amountKey: spendAmountKey)
    }

    private static func currentDayString() -> String {
        let components = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }

    private static func loadTodaySpend(dayKey: String, amountKey: String) -> Double {
        let today = currentDayString()
        guard UserDefaults.standard.string(forKey: dayKey) == today else {
            UserDefaults.standard.set(today, forKey: dayKey)
            UserDefaults.standard.set(0.0, forKey: amountKey)
            return 0
        }
        return max(0, UserDefaults.standard.double(forKey: amountKey))
    }

    public func syncTodaySpend(usd: Double) {
        let today = Self.currentDayString()
        let clamped = max(0, usd)
        UserDefaults.standard.set(today, forKey: spendDayKey)
        UserDefaults.standard.set(clamped, forKey: spendAmountKey)
        todayEstimatedSpendUSD = clamped
    }

    public func recordUsage(model: String, inputTokens: Int, cacheReadTokens: Int, outputTokens: Int) {
        let current = Self.loadTodaySpend(dayKey: spendDayKey, amountKey: spendAmountKey)
        if case .exact(let delta) = Self.estimateCost(
            model: model,
            inputTokens: inputTokens,
            cacheReadTokens: cacheReadTokens,
            outputTokens: outputTokens
        ) {
            syncTodaySpend(usd: current + delta)
        }
    }

    public func evaluateCurrentDailySpend() -> BudgetEvaluation {
        let current = Self.loadTodaySpend(dayKey: spendDayKey, amountKey: spendAmountKey)
        todayEstimatedSpendUSD = current
        return evaluate(todaySpentUSD: current)
    }

    /// DeepSeek official pricing (USD per 1M tokens).
    /// Returns `.unknown` for unrecognized third-party/custom models, `.free` for explicit free models.
    nonisolated public static func estimateCost(
        model: String,
        inputTokens: Int,
        cacheReadTokens: Int,
        outputTokens: Int
    ) -> CostDisplayState {
        let lower = model.lowercased()
        if lower.contains(":free") || lower.hasSuffix("-free") {
            return .free
        }

        let inputRatePerM: Double
        let cacheReadRatePerM: Double
        let outputRatePerM: Double

        if lower.contains("deepseek-reasoner") || lower.contains("deepseek-r1")
            || lower.contains("deepseek-v4-pro") || lower.contains("deepseek-flash-thinking") {
            inputRatePerM = 0.55
            cacheReadRatePerM = 0.14
            outputRatePerM = 2.19
        } else if lower.contains("deepseek") {
            // deepseek-chat / deepseek-v3 / deepseek-flash
            inputRatePerM = 0.27
            cacheReadRatePerM = 0.07
            outputRatePerM = 1.10
        } else {
            return .unknown
        }

        let cost = (Double(max(0, inputTokens)) / 1_000_000.0) * inputRatePerM
            + (Double(max(0, cacheReadTokens)) / 1_000_000.0) * cacheReadRatePerM
            + (Double(max(0, outputTokens)) / 1_000_000.0) * outputRatePerM
        return .exact(cost)
    }

    /// Aggregates estimated cost per model so mixed-model usage is priced accurately.
    nonisolated public static func estimateTotalCost(
        models: [(model: String, inputTokens: Int, cacheReadTokens: Int, outputTokens: Int)]
    ) -> CostDisplayState {
        guard !models.isEmpty else { return .exact(0) }
        var totalUSD = 0.0
        var hasKnownPaid = false
        var hasFree = false
        var hasUnknown = false
        for item in models {
            switch estimateCost(
                model: item.model,
                inputTokens: item.inputTokens,
                cacheReadTokens: item.cacheReadTokens,
                outputTokens: item.outputTokens
            ) {
            case .exact(let usd):
                totalUSD += usd
                hasKnownPaid = true
            case .free:
                hasFree = true
            case .unknown:
                hasUnknown = true
            }
        }
        if hasKnownPaid { return .exact(totalUSD) }
        if hasFree && !hasUnknown { return .free }
        return hasUnknown ? .unknown : .exact(0)
    }

    /// Computes Prompt Cache hit ratio across uncached input and cached read tokens.
    nonisolated public static func cacheHitRatio(inputTokens: Int, cacheReadTokens: Int) -> Double {
        let total = inputTokens + cacheReadTokens
        guard total > 0 else { return 0 }
        return Double(cacheReadTokens) / Double(total)
    }

    public func evaluate(todaySpentUSD: Double) -> BudgetEvaluation {
        guard dailyBudgetUSD > 0 else { return .allow }
        guard todaySpentUSD >= dailyBudgetUSD else { return .allow }
        let formattedSpent = String(format: "$%.4f", todaySpentUSD)
        let formattedCap = String(format: "$%.2f", dailyBudgetUSD)
        let message = "今日预估费用 \(formattedSpent) 已达到每日预算上限 \(formattedCap)。"
        switch budgetAction {
        case .warn: return .warn(message)
        case .stop: return .block(message)
        }
    }
}

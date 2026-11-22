import Foundation
import SwiftUI

/// Secondary conversation thread belonging to a Bot (P1-1: Multi-Thread per Bot).
/// The default thread uses `sessionId == botId` (`ios:<botId>`) for full backward compatibility;
/// additional threads use `sessionId == "\(botId):\(threadId)"` (`ios:<botId>:<threadId>`),
/// which automatically inherits the parent Bot's privacy isolation in `private-session-access.mjs`.
public struct BotThread: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let botId: String
    public var title: String
    public let createdAt: Date
    public var isPinned: Bool
    public var isArchived: Bool
    public var tags: [String]
    public let isDefault: Bool

    public var sessionId: String {
        isDefault ? botId : "\(botId):\(id)"
    }

    public init(
        id: String = "t-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(4).lowercased())",
        botId: String,
        title: String,
        createdAt: Date = Date(),
        isPinned: Bool = false,
        isArchived: Bool = false,
        tags: [String] = [],
        isDefault: Bool = false
    ) {
        self.id = id
        self.botId = botId
        self.title = title
        self.createdAt = createdAt
        self.isPinned = isPinned
        self.isArchived = isArchived
        self.tags = tags
        self.isDefault = isDefault
    }
}

@MainActor
public final class BotThreadStore: ObservableObject {
    public static let shared = BotThreadStore()

    @Published public private(set) var threadsByBot: [String: [BotThread]] = [:]
    @Published public var activeThreadIdByBot: [String: String] = [:]

    private init() {
        load()
    }

    public func threads(for botId: String, includeArchived: Bool = false) -> [BotThread] {
        var list = threadsByBot[botId] ?? []
        if !list.contains(where: \.isDefault) {
            let def = BotThread(id: "default", botId: botId, title: "主会话", isDefault: true)
            list.insert(def, at: 0)
        }
        let filtered = includeArchived ? list : list.filter { !$0.isArchived }
        return filtered.sorted { lhs, rhs in
            if lhs.isPinned != rhs.isPinned { return lhs.isPinned }
            if lhs.isDefault != rhs.isDefault { return lhs.isDefault }
            return lhs.createdAt > rhs.createdAt
        }
    }

    public func activeThread(for botId: String) -> BotThread {
        let list = threads(for: botId, includeArchived: true)
        if let activeId = activeThreadIdByBot[botId],
           let found = list.first(where: { $0.id == activeId }) {
            return found
        }
        return list.first(where: \.isDefault) ?? BotThread(id: "default", botId: botId, title: "主会话", isDefault: true)
    }

    public func activeSessionId(for botId: String) -> String {
        activeThread(for: botId).sessionId
    }

    @discardableResult
    public func createThread(for botId: String, title: String = "") -> BotThread {
        var list = threadsByBot[botId] ?? [BotThread(id: "default", botId: botId, title: "主会话", isDefault: true)]
        let resolvedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "新话题 \(list.count)"
            : title.trimmingCharacters(in: .whitespacesAndNewlines)
        let thread = BotThread(botId: botId, title: resolvedTitle, isDefault: false)
        list.append(thread)
        threadsByBot[botId] = list
        activeThreadIdByBot[botId] = thread.id
        save()
        return thread
    }

    public func selectThread(_ thread: BotThread) {
        activeThreadIdByBot[thread.botId] = thread.id
    }

    public func selectAddress(_ address: SessionAddress) {
        activeThreadIdByBot[address.botID] = address.threadID ?? "default"
    }

    public func threadTitle(for address: SessionAddress) -> String? {
        guard let threadID = address.threadID else { return nil }
        return threads(for: address.botID, includeArchived: true).first(where: { $0.id == threadID })?.title
    }

    public func renameThread(botId: String, threadId: String, title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var list = threads(for: botId, includeArchived: true)
        guard let idx = list.firstIndex(where: { $0.id == threadId }) else { return }
        list[idx].title = trimmed
        threadsByBot[botId] = list
        save()
    }

    public func togglePin(botId: String, threadId: String) {
        var list = threads(for: botId, includeArchived: true)
        guard let idx = list.firstIndex(where: { $0.id == threadId }) else { return }
        list[idx].isPinned.toggle()
        threadsByBot[botId] = list
        save()
    }

    public func toggleArchive(botId: String, threadId: String) {
        var list = threads(for: botId, includeArchived: true)
        guard let idx = list.firstIndex(where: { $0.id == threadId }), !list[idx].isDefault else { return }
        list[idx].isArchived.toggle()
        threadsByBot[botId] = list
        if list[idx].isArchived && activeThreadIdByBot[botId] == threadId {
            activeThreadIdByBot[botId] = "default"
        }
        save()
    }

    public func deleteThread(botId: String, threadId: String) -> String? {
        var list = threads(for: botId, includeArchived: true)
        guard let idx = list.firstIndex(where: { $0.id == threadId }), !list[idx].isDefault else { return nil }
        let removedSessionId = list[idx].sessionId
        list.remove(at: idx)
        threadsByBot[botId] = list
        if activeThreadIdByBot[botId] == threadId {
            activeThreadIdByBot[botId] = "default"
        }
        save()
        return removedSessionId
    }

    private func load() {
        let raw = AppSettings.string(.botThreadsJSON)
        guard !raw.isEmpty,
              let data = raw.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([String: [BotThread]].self, from: data) else { return }
        threadsByBot = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(threadsByBot),
              let str = String(data: data, encoding: .utf8) else { return }
        AppSettings.set(str, for: .botThreadsJSON)
    }
}

/// Curated Bot role templates & safe key-free JSON export/import payload (P1-16).
public struct BotTemplate: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let roleLabel: String
    public let icon: String
    public let agentPreset: String
    public let permissionMode: String
    public let reasoningEffort: String
    public let systemPrompt: String

    public static let builtIn: [BotTemplate] = [
        BotTemplate(
            id: "fullstack",
            name: "全栈工程师",
            roleLabel: "代码架构与调试",
            icon: "chevron.left.forwardslash.chevron.right",
            agentPreset: "standard",
            permissionMode: "ask",
            reasoningEffort: "high",
            systemPrompt: "你是一位资深全栈工程师。修改前先阅读相关文件，优先给出最小、可验证的改动，并在完成后给出验证步骤。"
        ),
        BotTemplate(
            id: "researcher",
            name: "深度研究分析师",
            roleLabel: "多维调研与对比",
            icon: "doc.text.magnifyingglass",
            agentPreset: "standard",
            permissionMode: "readOnly",
            reasoningEffort: "high",
            systemPrompt: "你是资深行业与技术研究分析师。回答前先拆解维度，使用表格对比利弊与风险，并给出明确结论与依据。"
        ),
        BotTemplate(
            id: "browser-agent",
            name: "网页自动化助手",
            roleLabel: "内置浏览器交互",
            icon: "safari",
            agentPreset: "standard",
            permissionMode: "ask",
            reasoningEffort: "medium",
            systemPrompt: "你擅长使用 App 内置浏览器（browser_*）浏览、检索、填表与提取信息。遇到登录、2FA 或验证码时立即调用 browser_handoff 请用户手动接管。"
        ),
        BotTemplate(
            id: "translator",
            name: "双语润色专家",
            roleLabel: "信达雅中英互译",
            icon: "character.book.closed",
            agentPreset: "minimal",
            permissionMode: "readOnly",
            reasoningEffort: "low",
            systemPrompt: "你是专业双语编辑。直出自然地道、术语准确的译文或润色版本，保持原意并标注关键表达取舍。"
        ),
    ]
}

public struct BotExportPayload: Codable {
    public let schemaVersion: Int
    public let name: String
    public let roleLabel: String
    public let model: String
    public let systemPrompt: String
    public let permissionMode: String
    public let agentPreset: String
    public let reasoningEffort: String
    public let disabledTools: [String]

    public init(from bot: BotProfile) {
        self.schemaVersion = 1
        self.name = bot.name
        self.roleLabel = bot.roleLabel
        self.model = bot.model
        self.systemPrompt = bot.systemPrompt
        self.permissionMode = bot.permissionMode
        self.agentPreset = bot.agentPreset
        self.reasoningEffort = bot.reasoningEffort
        self.disabledTools = bot.disabledTools
    }
}

/// Multi-endpoint provider profile registry (P2-13, stores zero API keys — keys remain in Keychain).
public struct ProviderProfile: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public var name: String
    public var apiBaseURL: String
    public var defaultModel: String
    public var protocolKind: String // "anthropic" | "openai-compat"

    public init(
        id: String = UUID().uuidString,
        name: String,
        apiBaseURL: String,
        defaultModel: String,
        protocolKind: String = "anthropic"
    ) {
        self.id = id
        self.name = name
        self.apiBaseURL = apiBaseURL
        self.defaultModel = defaultModel
        self.protocolKind = protocolKind
    }
}

@MainActor
public final class ProviderProfileStore: ObservableObject {
    public static let shared = ProviderProfileStore()

    @Published public private(set) var profiles: [ProviderProfile] = []

    private init() {
        load()
        if profiles.isEmpty {
            profiles = [
                ProviderProfile(id: "deepseek-official", name: "DeepSeek 官方", apiBaseURL: ModelProvider.defaultAddress, defaultModel: ModelProvider.defaultModel, protocolKind: "anthropic")
            ]
        }
    }

    public func upsert(_ profile: ProviderProfile) {
        if let idx = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[idx] = profile
        } else {
            profiles.append(profile)
        }
        save()
    }

    public func delete(id: String) {
        guard profiles.count > 1 else { return }
        profiles.removeAll { $0.id == id }
        save()
    }

    private func load() {
        let raw = AppSettings.string(.providerProfilesJSON)
        guard !raw.isEmpty,
              let data = raw.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([ProviderProfile].self, from: data) else { return }
        profiles = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(profiles),
              let str = String(data: data, encoding: .utf8) else { return }
        AppSettings.set(str, for: .providerProfilesJSON)
    }
}

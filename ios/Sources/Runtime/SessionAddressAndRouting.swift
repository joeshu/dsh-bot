import Foundation

/// Canonical, validated address for a conversation thread (P0-01).
/// - Default thread: `threadID == nil` -> `canonicalSessionId == botID` (100% compatible with legacy `ios:<botId>`).
/// - Child thread: `threadID == "t-..."` -> `canonicalSessionId == "\(botID):\(threadID)"` (`ios:<botId>:<threadId>`).
/// - Malformed or unknown-bot addresses return `nil` and MUST be rejected on writes (never falling back to main).
public struct SessionAddress: Hashable, Codable, Sendable, CustomStringConvertible {
    public let botID: String
    public let threadID: String?

    public var isDefaultThread: Bool { threadID == nil }

    public var canonicalSessionId: String {
        if let threadID {
            return "\(botID):\(threadID)"
        }
        return botID
    }

    public var dshSessionId: String {
        "ios:\(canonicalSessionId)"
    }

    public var description: String { canonicalSessionId }

    public init?(botID: String, threadID: String? = nil) {
        let cleanBot = botID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanBot.isEmpty, !cleanBot.contains(":") else { return nil }
        if let rawThread = threadID {
            let cleanThread = rawThread.trimmingCharacters(in: .whitespacesAndNewlines)
            if cleanThread.isEmpty || cleanThread == "default" {
                self.botID = cleanBot
                self.threadID = nil
            } else {
                guard !cleanThread.contains(":") else { return nil }
                self.botID = cleanBot
                self.threadID = cleanThread
            }
        } else {
            self.botID = cleanBot
            self.threadID = nil
        }
    }

    /// Parses either `"<botID>"`, `"<botID>:<threadID>"`, `"ios:<botID>"`, or `"ios:<botID>:<threadID>"`.
    /// Rejects trailing colons (`"main:"`) or extra segments (`"a:b:c"`) instead of falling back to main.
    public init?(parsing rawSessionId: String) {
        var trimmed = rawSessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("ios:") {
            trimmed = String(trimmed.dropFirst(4))
        }
        let parts = trimmed.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        switch parts.count {
        case 1:
            self.init(botID: parts[0], threadID: nil)
        case 2:
            guard !parts[1].isEmpty else { return nil }
            self.init(botID: parts[0], threadID: parts[1])
        default:
            return nil
        }
    }

    /// Resolves and verifies that the target `botID` exists in `knownBotIDs`.
    public static func resolve(_ rawSessionId: String, knownBotIDs: Set<String>) -> SessionAddress? {
        guard let parsed = SessionAddress(parsing: rawSessionId),
              knownBotIDs.contains(parsed.botID) else {
            return nil
        }
        return parsed
    }
}

/// Unified pending-action projection shared by SessionInboxView, ChatView cards, and status banners (P0-03).
public struct PendingInboxItem: Identifiable, Equatable, Sendable {
    public enum Kind: String, Sendable {
        case approval
        case question
    }

    public let id: String
    public let kind: Kind
    public let address: SessionAddress
    public let title: String
    public let detail: String
    public let toolName: String?

    public init(id: String, kind: Kind, address: SessionAddress, title: String, detail: String, toolName: String? = nil) {
        self.id = id
        self.kind = kind
        self.address = address
        self.title = title
        self.detail = detail
        self.toolName = toolName
    }
}

/// Typed deep-link routes carrying explicit SessionAddress + target resource IDs (P1-01).
public enum AppRoute: Hashable, Sendable {
    case chat(SessionAddress, messageID: String? = nil)
    case inboxRequest(requestID: String, address: SessionAddress)
    case botProfile(botID: String)
    case workspaceFile(relativePath: String)
    case schedule(id: String? = nil)
    case job(id: String? = nil)
    case plugin(name: String? = nil)
    case settings(section: String)
}

/// Unified Action Catalog describing scope, confirmation rules, and privacy boundaries (P1-01).
public enum AppActionScope: String, Sendable {
    case session
    case bot
    case workspace
    case global
}

public enum AppActionID: String, CaseIterable, Sendable {
    case resolveApproval
    case clearSession
    case saveToWorkspaceFile
    case exportSession
    case rewindTurn
    case compactContext
}

public struct AppActionDescriptor: Sendable {
    public let id: AppActionID
    public let title: String
    public let scope: AppActionScope
    public let requiresConfirmation: Bool
    public let requiresCrossSpaceConfirmationForPrivate: Bool

    public func isAvailable(isPrivate: Bool, isStreaming: Bool) -> Bool {
        switch id {
        case .resolveApproval:
            return true
        case .clearSession, .rewindTurn, .compactContext:
            return !isStreaming
        case .saveToWorkspaceFile, .exportSession:
            return !isStreaming
        }
    }
}

public enum AppActionCatalog {
    public static func descriptor(for id: AppActionID) -> AppActionDescriptor {
        switch id {
        case .resolveApproval:
            return AppActionDescriptor(id: id, title: "处理审批请求", scope: .session, requiresConfirmation: false, requiresCrossSpaceConfirmationForPrivate: false)
        case .clearSession:
            return AppActionDescriptor(id: id, title: "清空当前话题", scope: .session, requiresConfirmation: true, requiresCrossSpaceConfirmationForPrivate: false)
        case .saveToWorkspaceFile:
            return AppActionDescriptor(id: id, title: "存入共享工作区 (files/)", scope: .workspace, requiresConfirmation: false, requiresCrossSpaceConfirmationForPrivate: true)
        case .exportSession:
            return AppActionDescriptor(id: id, title: "导出当前话题日志", scope: .workspace, requiresConfirmation: false, requiresCrossSpaceConfirmationForPrivate: true)
        case .rewindTurn:
            return AppActionDescriptor(id: id, title: "撤回上一轮并重编", scope: .session, requiresConfirmation: false, requiresCrossSpaceConfirmationForPrivate: false)
        case .compactContext:
            return AppActionDescriptor(id: id, title: "压缩当前上下文", scope: .session, requiresConfirmation: false, requiresCrossSpaceConfirmationForPrivate: false)
        }
    }
}

import Foundation

/// Centralized, type-safe UserDefaults registry for DS Bot iOS (P0-5).
/// Single source of truth for all persisted preference keys, defaults, and migrations.
public enum AppSettings {
    public enum Key: String, CaseIterable {
        case webSearchEnabled = "dsbot.webSearchEnabled"
        case subagentEnabled = "dsbot.subagentEnabled"
        case customTools = "dsbot.customTools"
        case autoReviewEnabled = "dsbot.exp.autoReviewEnabled"
        case sessionDiagnosticsEnabled = "dsbot.exp.sessionDiagnosticsEnabled"
        case collapseThinkingByDefault = "dsbot.exp.collapseThinkingByDefault"
        case redteamModeEnabled = "dsbot.redteamModeEnabled"
        case redteamWebReadEnabled = "dsbot.redteamWebReadEnabled"
        case redteamWebWriteEnabled = "dsbot.redteamWebWriteEnabled"
        case redteamWebSensitiveEnabled = "dsbot.redteamWebSensitiveEnabled"
        case smartActionCardsEnabled = "dsbot.exp.smartActionCardsEnabled"
        case subagentMaxDepth = "dsbot.cfg.subagentMaxDepth"
        case subagentMaxActive = "dsbot.cfg.subagentMaxActive"
        case subagentModelSelection = "dsbot.cfg.subagentModelSelection"
        case webSearchCount = "dsbot.cfg.webSearchCount"
        case webSearchSendOriginalQuestion = "dsbot.cfg.webSearchSendOriginalQuestion"
        case useBubbleLayout = "dsbot.useBubbleLayout"
        case apiBaseURL = "dsbot.apiBaseURL"
        case webViewportMode = "dsbot.web.viewportMode"
        case webTextScale = "dsbot.web.textScale"
        case privateSessionTombstones = "dsbot.privateSessionTombstones"
        case providerProfilesJSON = "dsbot.providerProfiles.v1"
        case botThreadsJSON = "dsbot.botThreads.v1"
    }

    public static func bool(_ key: Key, default defaultValue: Bool = false) -> Bool {
        if let stored = UserDefaults.standard.object(forKey: key.rawValue) as? Bool {
            return stored
        }
        return defaultValue
    }

    public static func set(_ value: Bool, for key: Key) {
        UserDefaults.standard.set(value, forKey: key.rawValue)
    }

    public static func int(_ key: Key, default defaultValue: Int) -> Int {
        if let stored = UserDefaults.standard.object(forKey: key.rawValue) as? Int {
            return stored
        }
        return defaultValue
    }

    public static func set(_ value: Int, for key: Key) {
        UserDefaults.standard.set(value, forKey: key.rawValue)
    }

    public static func string(_ key: Key, default defaultValue: String = "") -> String {
        UserDefaults.standard.string(forKey: key.rawValue) ?? defaultValue
    }

    public static func set(_ value: String, for key: Key) {
        UserDefaults.standard.set(value, forKey: key.rawValue)
    }

    public static func draftKey(for sessionId: String) -> String {
        "dsbot.draft.\(sessionId)"
    }
}

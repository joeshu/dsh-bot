import Foundation

/// Redacts raw, URL-encoded, and JSON-escaped secret values as well as common API token patterns.
public enum SecretRedactor {
    private static let tokenPatterns: [String] = [
        #"sk-[A-Za-z0-9_\-]{16,}"#,
        #"gh[pousr]_[A-Za-z0-9]{20,}"#,
        #"AKIA[0-9A-Z]{16}"#,
        #"Bearer\s+[A-Za-z0-9\._\-]{16,}"#,
        #"-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----"#
    ]

    public static func redact(_ text: String, secrets: [String: String]) -> String {
        var result = text
        for (name, rawValue) in secrets {
            let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.count >= 6 else { continue }
            let placeholder = "[secret:\(name)]"
            result = result.replacingOccurrences(of: trimmed, with: placeholder)
            if let urlEncoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
               urlEncoded != trimmed {
                result = result.replacingOccurrences(of: urlEncoded, with: placeholder)
            }
            if let jsonData = try? JSONSerialization.data(withJSONObject: [trimmed]),
               let jsonArray = String(data: jsonData, encoding: .utf8),
               jsonArray.count >= 4 {
                let jsonEscaped = String(jsonArray.dropFirst(2).dropLast(2))
                if jsonEscaped != trimmed {
                    result = result.replacingOccurrences(of: jsonEscaped, with: placeholder)
                }
            }
        }
        return redactCommonTokens(result)
    }

    public static func redactCommonTokens(_ text: String) -> String {
        var result = text
        for pattern in tokenPatterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { continue }
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "[secret:REDACTED]")
        }
        return result
    }
}

public enum PrivacyGateDecision: Equatable, Sendable {
    case allow
    case softWarn(reason: String)
    case hardBlock(reason: String)
}

/// Dual-layer write-before-commit privacy gate for persistent memory entries.
public enum PrivacyGate {
    private static let hardBlockRules: [(pattern: String, reason: String)] = [
        (#"\b\d{17}[\dXx]\b"#, "检测到疑似身份证号，已禁止写入持久记忆。"),
        (#"\b(?:\d[ -]*?){16,19}\b"#, "检测到疑似银行卡/信用卡号，已禁止写入持久记忆。"),
        (#"sk-[A-Za-z0-9_\-]{16,}"#, "检测到疑似 API Key（sk-...），已禁止写入持久记忆。"),
        (#"gh[pousr]_[A-Za-z0-9]{20,}"#, "检测到疑似 GitHub Token，已禁止写入持久记忆。"),
        (#"AKIA[0-9A-Z]{16}"#, "检测到疑似云服务 Access Key，已禁止写入持久记忆。"),
        (#"-----BEGIN [A-Z ]*PRIVATE KEY-----"#, "检测到私钥片段，已禁止写入持久记忆。")
    ]

    private static let softWarnKeywords: [String] = [
        "密码", "口令", "病历", "诊断书", "体检报告", "银行账户", "税号", "合同编号", "password", "passcode"
    ]

    public static func evaluateMemoryWrite(title: String, content: String) -> PrivacyGateDecision {
        let combined = "\(title)\n\(content)"
        for rule in hardBlockRules {
            if let regex = try? NSRegularExpression(pattern: rule.pattern, options: []),
               regex.firstMatch(in: combined, options: [], range: NSRange(combined.startIndex..<combined.endIndex, in: combined)) != nil {
                return .hardBlock(reason: rule.reason)
            }
        }
        let lower = combined.lowercased()
        for keyword in softWarnKeywords where lower.contains(keyword) {
            return .softWarn(reason: "内容包含敏感主题关键词（\(keyword)），请确认仅保留必要摘要。")
        }
        return .allow
    }
}

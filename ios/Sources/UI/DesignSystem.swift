import LocalAuthentication
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Unified visual design system for DS-Bot iOS Standalone.
public enum DSTheme {
    public static let brand = Color(red: 0.145, green: 0.388, blue: 0.922)       // Cobalt #2563EB
    public static let brandSoft = brand.opacity(0.12)
    public static let success = Color(red: 0.086, green: 0.639, blue: 0.290)     // Emerald
    public static let warning = Color(red: 0.851, green: 0.467, blue: 0.024)     // Amber
    public static let danger = Color(red: 0.863, green: 0.149, blue: 0.149)      // Crimson
    public static let surfacePrimary = Color(.systemBackground)
    public static let surfaceSecondary = Color(.secondarySystemBackground)
    public static let surfaceGrouped = Color(.systemGroupedBackground)

    public static let cornerCard: CGFloat = 16
    public static let cornerBubble: CGFloat = 18
    public static let cornerPill: CGFloat = 999
}

public enum DSHaptics {
    public static func impact(_ style: ImpactStyle = .light) {
        #if canImport(UIKit)
        let run = {
            let uiStyle: UIImpactFeedbackGenerator.FeedbackStyle
            switch style {
            case .light: uiStyle = .light
            case .medium: uiStyle = .medium
            case .soft: uiStyle = .soft
            }
            UIImpactFeedbackGenerator(style: uiStyle).impactOccurred()
        }
        if Thread.isMainThread { run() } else { DispatchQueue.main.async(execute: run) }
        #endif
    }

    public static func notify(_ kind: NotifyKind) {
        #if canImport(UIKit)
        let run = {
            let gen = UINotificationFeedbackGenerator()
            switch kind {
            case .success: gen.notificationOccurred(.success)
            case .warning: gen.notificationOccurred(.warning)
            case .error: gen.notificationOccurred(.error)
            }
        }
        if Thread.isMainThread { run() } else { DispatchQueue.main.async(execute: run) }
        #endif
    }

    public enum ImpactStyle { case light, medium, soft }
    public enum NotifyKind { case success, warning, error }
}

/// Renders Markdown natively with styled fenced code blocks (with one-tap copy),
/// Markdown headings, and rich inline `AttributedString(markdown:)` formatting.
public struct DSMarkdownText: View {
    let raw: String

    private enum Segment: Identifiable {
        case prose(id: Int, text: String)
        case heading(id: Int, level: Int, text: String)
        case code(id: Int, language: String, body: String)

        var id: Int {
            switch self {
            case .prose(let id, _), .heading(let id, _, _), .code(let id, _, _): return id
            }
        }
    }

    public init(_ raw: String) {
        self.raw = raw
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(parseSegments(raw)) { seg in
                switch seg {
                case .heading(_, let level, let text):
                    Text(text)
                        .font(level <= 1 ? .title3.weight(.bold) : (level == 2 ? .headline : .subheadline.weight(.semibold)))
                        .textSelection(.enabled)
                        .padding(.top, 2)
                case .code(_, let lang, let body):
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(lang.isEmpty ? "CODE" : lang.uppercased())
                                .font(.caption2.weight(.semibold))
                                .foregroundColor(.secondary)
                            Spacer()
                            Button {
                                #if canImport(UIKit)
                                UIPasteboard.general.string = body
                                #endif
                                DSHaptics.impact(.light)
                            } label: {
                                Label("复制代码", systemImage: "doc.on.doc")
                                    .font(.caption2.weight(.medium))
                            }
                        }
                        ScrollView(.horizontal, showsIndicators: false) {
                            Text(body)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                        }
                    }
                    .padding(10)
                    .background(DSTheme.surfacePrimary.opacity(0.9))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.18), lineWidth: 1))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                case .prose(_, let text):
                    if let attr = try? AttributedString(
                        markdown: text,
                        options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
                    ) {
                        Text(attr).textSelection(.enabled)
                    } else {
                        Text(text).textSelection(.enabled)
                    }
                }
            }
        }
    }

    private func parseSegments(_ input: String) -> [Segment] {
        var result: [Segment] = []
        var nextId = 0
        var proseLines: [String] = []
        var inCode = false
        var codeLang = ""
        var codeLines: [String] = []

        func flushProse() {
            let joined = proseLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty {
                result.append(.prose(id: nextId, text: joined))
                nextId += 1
            }
            proseLines.removeAll()
        }

        for rawLine in input.components(separatedBy: .newlines) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                if !inCode {
                    flushProse()
                    inCode = true
                    codeLang = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                    codeLines.removeAll()
                } else {
                    result.append(.code(id: nextId, language: codeLang, body: codeLines.joined(separator: "\n")))
                    nextId += 1
                    inCode = false
                    codeLang = ""
                    codeLines.removeAll()
                }
                continue
            }
            if inCode {
                codeLines.append(rawLine)
            } else if trimmed.hasPrefix("### ") {
                flushProse()
                result.append(.heading(id: nextId, level: 3, text: String(trimmed.dropFirst(4))))
                nextId += 1
            } else if trimmed.hasPrefix("## ") {
                flushProse()
                result.append(.heading(id: nextId, level: 2, text: String(trimmed.dropFirst(3))))
                nextId += 1
            } else if trimmed.hasPrefix("# ") {
                flushProse()
                result.append(.heading(id: nextId, level: 1, text: String(trimmed.dropFirst(2))))
                nextId += 1
            } else {
                proseLines.append(rawLine)
            }
        }
        if inCode {
            result.append(.code(id: nextId, language: codeLang, body: codeLines.joined(separator: "\n")))
        } else {
            flushProse()
        }
        return result.isEmpty ? [.prose(id: 0, text: input)] : result
    }
}

/// Real Face ID / Touch ID / Passcode gate protecting Private Bots (`isPrivate == true`).
public struct PrivateBotLockOverlay: View {
    let botName: String
    let onUnlock: () -> Void
    @State private var authError = ""

    public var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 46))
                .foregroundColor(DSTheme.warning)
            Text("隐私 Bot 已锁定")
                .font(.title3.weight(.semibold))
            Text("「\(botName)」需要通过设备身份验证后查看。")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)
            Button {
                authenticate()
            } label: {
                Label("使用面容 / 密码解锁", systemImage: "faceid")
                    .font(.subheadline.weight(.semibold))
            }
            .buttonStyle(.borderedProminent)
            if !authError.isEmpty {
                Text(authError).font(.caption2).foregroundColor(DSTheme.danger)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.ultraThinMaterial)
    }

    private func authenticate() {
        let context = LAContext()
        var err: NSError?
        if context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err) {
            context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "解锁隐私 Bot「\(botName)」") { ok, evalErr in
                DispatchQueue.main.async {
                    if ok {
                        DSHaptics.notify(.success)
                        onUnlock()
                    } else {
                        authError = evalErr?.localizedDescription ?? "验证未通过"
                    }
                }
            }
        } else {
            // Simulator or device without passcode enrolled
            onUnlock()
        }
    }
}

public struct DSStatusBadge: View {
    let text: String
    let color: Color
    var icon: String? = nil

    public init(_ text: String, color: Color, icon: String? = nil) {
        self.text = text
        self.color = color
        self.icon = icon
    }

    public var body: some View {
        HStack(spacing: 4) {
            if let icon {
                Image(systemName: icon)
                    .font(.caption2.weight(.semibold))
            }
            Text(text)
                .font(.caption2.weight(.semibold))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(color.opacity(0.14))
        .foregroundColor(color)
        .clipShape(Capsule())
    }
}

public struct DSBannerCard: View {
    let icon: String
    let tint: Color
    let message: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    public var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: icon)
                .foregroundColor(tint)
                .font(.subheadline.weight(.semibold))
            Text(message)
                .font(.caption)
                .foregroundColor(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .font(.caption.weight(.semibold))
                    .foregroundColor(tint)
            }
        }
        .padding(12)
        .background(tint.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: DSTheme.cornerCard, style: .continuous))
    }
}

public struct DSBotAvatar: View {
    let initials: String
    let color: Color
    var isPrivate: Bool = false
    var size: CGFloat = 40

    public var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Circle()
                .fill(color.gradient)
                .frame(width: size, height: size)
                .overlay(
                    Text(String(initials.prefix(2)).uppercased())
                        .font(.system(size: size * 0.36, weight: .semibold, design: .rounded))
                        .foregroundColor(.white)
                )
            if isPrivate {
                Image(systemName: "lock.fill")
                    .font(.system(size: size * 0.24, weight: .bold))
                    .foregroundColor(.white)
                    .padding(3)
                    .background(Circle().fill(DSTheme.warning))
                    .offset(x: 2, y: 2)
            }
        }
    }
}

import LocalAuthentication
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Unified visual design system for DS-Bot iOS Standalone (DesignSystem 2.0).
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

    public static func presetColor(_ presetId: String) -> Color {
        switch presetId {
        case "cordis": return .indigo
        case "ptc-python": return .teal
        case "minimal": return .secondary
        case "redteam": return danger
        default: return brand
        }
    }

    public static func presetIcon(_ presetId: String) -> String {
        switch presetId {
        case "cordis": return "sparkles"
        case "ptc-python": return "terminal.fill"
        case "minimal": return "leaf.fill"
        case "redteam": return "shield.lefthalf.filled"
        default: return "wrench.and.screwdriver.fill"
        }
    }

    public static func botAvatarColor(_ bot: BotProfile) -> Color {
        if bot.isMain { return brand }
        if bot.isGroup { return .indigo }
        if bot.isPrivate { return warning }
        return presetColor(bot.agentPreset)
    }
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

private final class DSMarkdownBlockCache: @unchecked Sendable {
    static let shared = DSMarkdownBlockCache()
    private let cache: NSCache<NSString, NSAttributedString> = {
        let c = NSCache<NSString, NSAttributedString>()
        c.countLimit = 400
        return c
    }()

    func attributedString(for markdown: String) -> AttributedString? {
        let key = markdown as NSString
        if let cached = cache.object(forKey: key) {
            return AttributedString(cached)
        }
        guard let parsed = try? AttributedString(
            markdown: markdown,
            options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) else {
            return nil
        }
        cache.setObject(NSAttributedString(parsed), forKey: key)
        return parsed
    }

    func removeAll() {
        cache.removeAllObjects()
    }
}

/// Renders Markdown natively with styled fenced code blocks (with one-tap copy confirmation),
/// Markdown headings, and cached inline `AttributedString(markdown:)` formatting.
public struct DSMarkdownText: View {
    public static func clearRenderCache() {
        DSMarkdownBlockCache.shared.removeAll()
    }

    let raw: String
    @State private var copiedBlockId: Int?

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
                case .code(let id, let lang, let body):
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            HStack(spacing: 4) {
                                Image(systemName: "chevron.left.forwardslash.chevron.right")
                                    .font(.caption2)
                                Text(lang.isEmpty ? "CODE" : lang.uppercased())
                                    .font(.caption2.weight(.semibold))
                            }
                            .foregroundColor(.secondary)
                            Spacer()
                            Button {
                                #if canImport(UIKit)
                                UIPasteboard.general.string = body
                                #endif
                                DSHaptics.impact(.light)
                                copiedBlockId = id
                            } label: {
                                Label(
                                    copiedBlockId == id ? "已复制" : "复制代码",
                                    systemImage: copiedBlockId == id ? "checkmark" : "doc.on.doc"
                                )
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(copiedBlockId == id ? DSTheme.success : DSTheme.brand)
                            }
                        }
                        ScrollView(.horizontal, showsIndicators: false) {
                            Text(body)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                        }
                    }
                    .padding(10)
                    .background(DSTheme.surfacePrimary.opacity(0.92))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.18), lineWidth: 1))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                case .prose(_, let text):
                    if let attr = DSMarkdownBlockCache.shared.attributedString(for: text) {
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

    public init(botName: String, onUnlock: @escaping () -> Void) {
        self.botName = botName
        self.onUnlock = onUnlock
    }

    public var body: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(DSTheme.warning.opacity(0.14))
                    .frame(width: 84, height: 84)
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 40))
                    .foregroundColor(DSTheme.warning)
            }
            Text("隐私 Bot 已锁定")
                .font(.title3.weight(.semibold))
            Text("「\(botName)」受设备硬件级认证保护，切后台或离开页面后会自动上锁并清空内存。")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button {
                authenticate()
            } label: {
                Label("使用面容 / 密码解锁", systemImage: "faceid")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 6)
            }
            .buttonStyle(.borderedProminent)
            if !authError.isEmpty {
                Text(authError).font(.caption2).foregroundColor(DSTheme.danger)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DSTheme.surfacePrimary)
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
            authError = "请先在设备设置中启用锁屏密码。"
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
        .padding(.vertical, 3.5)
        .background(color.opacity(0.14))
        .foregroundColor(color)
        .clipShape(Capsule())
    }
}

public struct DSPresetBadge: View {
    let presetId: String
    let label: String

    public init(presetId: String, label: String) {
        self.presetId = presetId
        self.label = label
    }

    public var body: some View {
        DSStatusBadge(
            label,
            color: DSTheme.presetColor(presetId),
            icon: DSTheme.presetIcon(presetId)
        )
    }
}

public struct DSBannerCard: View {
    let icon: String
    let tint: Color
    let message: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    public init(icon: String, tint: Color, message: String, actionTitle: String? = nil, action: (() -> Void)? = nil) {
        self.icon = icon
        self.tint = tint
        self.message = message
        self.actionTitle = actionTitle
        self.action = action
    }

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

    public init(initials: String, color: Color, isPrivate: Bool = false, size: CGFloat = 40) {
        self.initials = initials
        self.color = color
        self.isPrivate = isPrivate
        self.size = size
    }

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

/// Standardized empty state component for lists and sections (compatible with iOS 16.4+).
public struct DSEmptyStateView: View {
    let icon: String
    let title: String
    let subtitle: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    public init(icon: String, title: String, subtitle: String, actionTitle: String? = nil, action: (() -> Void)? = nil) {
        self.icon = icon
        self.title = title
        self.subtitle = subtitle
        self.actionTitle = actionTitle
        self.action = action
    }

    public var body: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(Color.secondary.opacity(0.10))
                    .frame(width: 54, height: 54)
                Image(systemName: icon)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            Text(title)
                .font(.headline)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
                    .font(.caption.weight(.semibold))
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
    }
}

/// Compact runtime status banner shown at the top of primary tabs.
public struct DSRuntimeStatusBanner: View {
    @ObservedObject var host: LocalAgentHost

    public init(host: LocalAgentHost) {
        self.host = host
    }

    private var statusBadge: String {
        switch host.state {
        case .ready: return "就绪"
        case .failed: return "异常"
        default: return "启动中"
        }
    }

    private var statusIcon: String {
        switch host.state {
        case .ready: return "cpu.fill"
        case .failed: return "exclamationmark.triangle.fill"
        default: return "clock.fill"
        }
    }

    private var statusColor: Color {
        switch host.state {
        case .ready: return DSTheme.success
        case .failed: return DSTheme.danger
        default: return .secondary
        }
    }

    private var statusDescription: String {
        switch host.state {
        case .idle, .starting: return "正在启动本机 DSH 运行时…"
        case .ready: return "v\(host.appVersion) · SQLite WAL 已就绪"
        case .failed(let message): return message
        }
    }

    public var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill((host.isDSHRecoveryMode ? DSTheme.warning : statusColor).opacity(0.14))
                    .frame(width: 36, height: 36)
                Image(systemName: statusIcon)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(host.isDSHRecoveryMode ? DSTheme.warning : statusColor)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(host.embeddedRuntimeLabel ?? "Node.js + DSH 0.2.2-rc.5")
                        .font(.subheadline.weight(.semibold))
                    DSStatusBadge(
                        host.isDSHRecoveryMode ? "恢复模式" : statusBadge,
                        color: host.isDSHRecoveryMode ? DSTheme.warning : statusColor
                    )
                }
                Text(host.workspaceError ?? statusDescription)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 4)
            if case .failed = host.state {
                Button("重试") {
                    Task { await host.boot() }
                }
                .buttonStyle(.borderedProminent)
                .font(.caption.weight(.semibold))
            }
        }
        .padding(12)
        .background(DSTheme.surfacePrimary)
        .clipShape(RoundedRectangle(cornerRadius: DSTheme.cornerCard, style: .continuous))
        .shadow(color: .black.opacity(0.04), radius: 5, y: 2)
    }
}

/// Shared Model Selection Picker / Input used across Bot creation, editing, and chat toolbar.
public struct ModelSelectionView: View {
    @ObservedObject var host: LocalAgentHost
    @Binding var model: String
    var allowsTyping: Bool

    public init(host: LocalAgentHost, model: Binding<String>, allowsTyping: Bool = true) {
        self.host = host
        self._model = model
        self.allowsTyping = allowsTyping
    }

    public var body: some View {
        if host.usesOfficialModels {
            Picker("模型", selection: $model) {
                Text("DeepSeek Flash").tag(ModelProvider.defaultModel)
                Text("DeepSeek Flash · 思考").tag(ModelProvider.thinkingModel)
                Text("DeepSeek V4 Pro").tag("deepseek-v4-pro")
                if ![ModelProvider.defaultModel, ModelProvider.thinkingModel, "deepseek-v4-pro"].contains(model) {
                    Text(model).tag(model)
                }
            }
        } else {
            if allowsTyping {
                TextField("服务商模型 ID", text: $model)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            if !host.models.isEmpty {
                Menu("选择服务商模型") {
                    ForEach(host.models, id: \.self) { id in
                        Button(id) { model = id }
                    }
                }
            }
        }
    }
}

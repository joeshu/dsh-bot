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
private final class DSMarkdownSegmentCache {
    private final class Box {
        let segments: [DSMarkdownSegment]
        init(_ segments: [DSMarkdownSegment]) { self.segments = segments }
    }
    static let shared = DSMarkdownSegmentCache()
    private let cache: NSCache<NSString, Box> = {
        let c = NSCache<NSString, Box>()
        c.countLimit = 256
        return c
    }()

    func segments(for key: String, build: () -> [DSMarkdownSegment]) -> [DSMarkdownSegment] {
        let nsKey = key as NSString
        if let hit = cache.object(forKey: nsKey) {
            return hit.segments
        }
        let built = build()
        cache.setObject(Box(built), forKey: nsKey)
        return built
    }

    func removeAll() {
        cache.removeAllObjects()
    }
}

enum DSMarkdownSegment: Identifiable {
    case prose(id: Int, text: String)
    case heading(id: Int, level: Int, text: String)
    case quote(id: Int, text: String)
    case list(id: Int, items: [(indent: Int, marker: String, checked: Bool?, text: String)])
    case table(id: Int, headers: [String], rows: [[String]])
    case divider(id: Int)
    case code(id: Int, language: String, body: String)

    var id: Int {
        switch self {
        case .prose(let id, _), .heading(let id, _, _), .quote(let id, _),
             .list(let id, _), .table(let id, _, _), .divider(let id), .code(let id, _, _):
            return id
        }
    }
}

public struct DSMarkdownText: View, Equatable {
    public static func == (lhs: DSMarkdownText, rhs: DSMarkdownText) -> Bool {
        lhs.raw == rhs.raw
    }

    public static func clearRenderCache() {
        DSMarkdownBlockCache.shared.removeAll()
        DSMarkdownSegmentCache.shared.removeAll()
    }

    let raw: String
    @State private var copiedBlockId: Int?
    @State private var savedBlockId: Int?
    @State private var expandedCodeIds: Set<Int> = []

    public init(_ raw: String) {
        self.raw = raw
    }

    public var body: some View {
        let segments = DSMarkdownSegmentCache.shared.segments(for: raw) {
            Self.parseSegments(raw)
        }
        VStack(alignment: .leading, spacing: 8) {
            ForEach(segments) { seg in
                switch seg {
                case .heading(_, let level, let text):
                    Text(text)
                        .font(level <= 1 ? .title3.weight(.bold) : (level == 2 ? .headline : .subheadline.weight(.semibold)))
                        .textSelection(.enabled)
                        .padding(.top, 2)
                case .divider:
                    Divider().padding(.vertical, 2)
                case .quote(_, let text):
                    HStack(alignment: .top, spacing: 8) {
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(DSTheme.brand.opacity(0.75))
                            .frame(width: 3)
                        inlineMarkdownText(text)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(DSTheme.surfaceSecondary.opacity(0.65))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                case .list(_, let items):
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                if let checked = item.checked {
                                    Image(systemName: checked ? "checkmark.square.fill" : "square")
                                        .font(.caption)
                                        .foregroundStyle(checked ? DSTheme.success : .secondary)
                                } else {
                                    Text(item.marker)
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(DSTheme.brand)
                                }
                                inlineMarkdownText(item.text)
                            }
                            .padding(.leading, CGFloat(min(item.indent, 4) * 12))
                        }
                    }
                case .table(_, let headers, let rows):
                    ScrollView(.horizontal, showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 0) {
                            HStack(spacing: 0) {
                                ForEach(Array(headers.enumerated()), id: \.offset) { idx, cell in
                                    Text(cell)
                                        .font(.caption.weight(.semibold))
                                        .frame(minWidth: 88, alignment: .leading)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 6)
                                    if idx < headers.count - 1 { Divider() }
                                }
                            }
                            .background(DSTheme.surfaceSecondary)
                            Divider()
                            ForEach(Array(rows.enumerated()), id: \.offset) { rIdx, row in
                                HStack(spacing: 0) {
                                    ForEach(0..<headers.count, id: \.self) { cIdx in
                                        let val = cIdx < row.count ? row[cIdx] : ""
                                        inlineMarkdownText(val)
                                            .font(.caption)
                                            .frame(minWidth: 88, alignment: .leading)
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 5)
                                        if cIdx < headers.count - 1 { Divider() }
                                    }
                                }
                                if rIdx < rows.count - 1 { Divider() }
                            }
                        }
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.22), lineWidth: 0.75))
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                case .code(let id, let lang, let body):
                    codeBlockView(id: id, lang: lang, body: body)
                case .prose(_, let text):
                    inlineMarkdownText(text)
                }
            }
        }
    }

    @ViewBuilder
    private func inlineMarkdownText(_ text: String) -> some View {
        if let attr = DSMarkdownBlockCache.shared.attributedString(for: text) {
            Text(attr).textSelection(.enabled)
        } else {
            Text(text).textSelection(.enabled)
        }
    }

    private func codeBlockView(id: Int, lang: String, body: String) -> some View {
        let lines = body.components(separatedBy: .newlines)
        let isLong = lines.count > 24
        let isExpanded = expandedCodeIds.contains(id)
        let displayedLines = (isLong && !isExpanded) ? Array(lines.prefix(18)) : lines

        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left.forwardslash.chevron.right")
                        .font(.caption2)
                    Text(lang.isEmpty ? "CODE" : lang.uppercased())
                        .font(.caption2.weight(.semibold))
                    Text("· \(lines.count) 行")
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
                .foregroundColor(.secondary)
                Spacer()
                Button {
                    saveCodeSnippetToWorkspace(lang: lang, body: body, blockId: id)
                } label: {
                    Label(savedBlockId == id ? "已存入" : "存工作区", systemImage: savedBlockId == id ? "checkmark.circle.fill" : "folder.badge.plus")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(savedBlockId == id ? DSTheme.success : .secondary)
                }
                .buttonStyle(.plain)
                Button {
                    #if canImport(UIKit)
                    UIPasteboard.general.string = body
                    #endif
                    DSHaptics.impact(.light)
                    copiedBlockId = id
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 2_000_000_000)
                        if copiedBlockId == id { copiedBlockId = nil }
                    }
                } label: {
                    Label(
                        copiedBlockId == id ? "已复制" : "复制",
                        systemImage: copiedBlockId == id ? "checkmark" : "doc.on.doc"
                    )
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(copiedBlockId == id ? DSTheme.success : DSTheme.brand)
                }
                .buttonStyle(.plain)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(displayedLines.enumerated()), id: \.offset) { idx, line in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("\(idx + 1)")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.tertiary)
                                .frame(minWidth: 22, alignment: .trailing)
                            Text(Self.highlightCodeLine(line, lang: lang))
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                        }
                    }
                }
            }
            if isLong {
                Button {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        if isExpanded { expandedCodeIds.remove(id) } else { expandedCodeIds.insert(id) }
                    }
                } label: {
                    Text(isExpanded ? "收起代码" : "展开全部 \(lines.count) 行")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(DSTheme.brand)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 2)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(10)
        .background(DSTheme.surfacePrimary.opacity(0.92))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.18), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func saveCodeSnippetToWorkspace(lang: String, body: String, blockId: Int) {
        let ext: String = {
            switch lang.lowercased() {
            case "swift": return "swift"
            case "python", "py": return "py"
            case "javascript", "js", "mjs": return "mjs"
            case "typescript", "ts": return "ts"
            case "json": return "json"
            case "html": return "html"
            case "css": return "css"
            case "sh", "bash", "zsh": return "sh"
            case "md", "markdown": return "md"
            default: return "txt"
            }
        }()
        let dir = LocalAgentTransport.defaultWorkspace.appendingPathComponent("files", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent("code-\(Int(Date().timeIntervalSince1970)).\(ext)")
        if (try? body.write(to: dest, atomically: true, encoding: .utf8)) != nil {
            DSHaptics.notify(.success)
            savedBlockId = blockId
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if savedBlockId == blockId { savedBlockId = nil }
            }
        }
    }

    private static func highlightCodeLine(_ line: String, lang: String) -> AttributedString {
        var attr = AttributedString(line)
        let lowerLang = lang.lowercased()
        if lowerLang == "diff" || lowerLang == "patch" {
            if line.hasPrefix("+") && !line.hasPrefix("+++") {
                attr.foregroundColor = .green
                return attr
            }
            if line.hasPrefix("-") && !line.hasPrefix("---") {
                attr.foregroundColor = .red
                return attr
            }
            if line.hasPrefix("@@") {
                attr.foregroundColor = .blue
                return attr
            }
        }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("//") || trimmed.hasPrefix("#") || trimmed.hasPrefix("--") {
            attr.foregroundColor = .secondary
            return attr
        }
        let keywords = ["func", "struct", "class", "enum", "let", "var", "if", "else", "guard", "return", "async", "await", "try", "catch", "import", "public", "private", "const", "function", "def", "for", "while", "switch", "case", "export", "default", "true", "false", "nil", "null"]
        for kw in keywords {
            let pattern = "\\b\(kw)\\b"
            if let regex = try? NSRegularExpression(pattern: pattern) {
                let ns = line as NSString
                for match in regex.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
                    if let r = Range(match.range, in: line),
                       let ar = Range(r, in: attr) {
                        attr[ar].foregroundColor = .indigo
                    }
                }
            }
        }
        return attr
    }

    private static func splitTableRow(_ line: String) -> [String] {
        var trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("|") { trimmed.removeFirst() }
        if trimmed.hasSuffix("|") { trimmed.removeLast() }
        return trimmed.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func isTableSeparator(_ line: String) -> Bool {
        let cells = splitTableRow(line)
        guard !cells.isEmpty else { return false }
        return cells.allSatisfy { cell in
            let stripped = cell.replacingOccurrences(of: ":", with: "").replacingOccurrences(of: "-", with: "").trimmingCharacters(in: .whitespaces)
            return stripped.isEmpty && cell.contains("-")
        }
    }

    private static func parseSegments(_ input: String) -> [DSMarkdownSegment] {
        var result: [DSMarkdownSegment] = []
        var nextId = 0
        var proseLines: [String] = []
        var quoteLines: [String] = []
        var listItems: [(indent: Int, marker: String, checked: Bool?, text: String)] = []
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
        func flushQuote() {
            let joined = quoteLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty {
                result.append(.quote(id: nextId, text: joined))
                nextId += 1
            }
            quoteLines.removeAll()
        }
        func flushList() {
            if !listItems.isEmpty {
                result.append(.list(id: nextId, items: listItems))
                nextId += 1
                listItems.removeAll()
            }
        }
        func flushAllNonCode() {
            flushProse()
            flushQuote()
            flushList()
        }

        let allLines = input.components(separatedBy: .newlines)
        var i = 0
        while i < allLines.count {
            let rawLine = allLines[i]
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") {
                if !inCode {
                    flushAllNonCode()
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
                i += 1
                continue
            }
            if inCode {
                codeLines.append(rawLine)
                i += 1
                continue
            }

            // Markdown table detection
            if trimmed.contains("|"), i + 1 < allLines.count, isTableSeparator(allLines[i + 1]) {
                flushAllNonCode()
                let headers = splitTableRow(trimmed)
                i += 2
                var rows: [[String]] = []
                while i < allLines.count {
                    let rowTrim = allLines[i].trimmingCharacters(in: .whitespaces)
                    if rowTrim.isEmpty || !rowTrim.contains("|") { break }
                    rows.append(splitTableRow(rowTrim))
                    i += 1
                }
                result.append(.table(id: nextId, headers: headers, rows: rows))
                nextId += 1
                continue
            }

            // Horizontal rule
            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                flushAllNonCode()
                result.append(.divider(id: nextId))
                nextId += 1
                i += 1
                continue
            }

            // Blockquote
            if trimmed.hasPrefix(">") {
                flushProse()
                flushList()
                let content = trimmed.dropFirst().trimmingCharacters(in: .whitespaces)
                quoteLines.append(content)
                i += 1
                continue
            } else if !quoteLines.isEmpty {
                flushQuote()
            }

            // Lists (task, bullet, ordered)
            let leadingSpaces = rawLine.prefix(while: { $0 == " " || $0 == "\t" }).count
            let indent = leadingSpaces / 2
            if trimmed.hasPrefix("- [x] ") || trimmed.hasPrefix("- [X] ") {
                flushProse()
                listItems.append((indent: indent, marker: "", checked: true, text: String(trimmed.dropFirst(6))))
                i += 1
                continue
            } else if trimmed.hasPrefix("- [ ] ") {
                flushProse()
                listItems.append((indent: indent, marker: "", checked: false, text: String(trimmed.dropFirst(6))))
                i += 1
                continue
            } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("• ") {
                flushProse()
                listItems.append((indent: indent, marker: "•", checked: nil, text: String(trimmed.dropFirst(2))))
                i += 1
                continue
            } else if let dotRange = trimmed.range(of: #"^\d+\.\s+"#, options: .regularExpression) {
                flushProse()
                let marker = String(trimmed[..<dotRange.upperBound]).trimmingCharacters(in: .whitespaces)
                let body = String(trimmed[dotRange.upperBound...])
                listItems.append((indent: indent, marker: marker, checked: nil, text: body))
                i += 1
                continue
            } else if !listItems.isEmpty {
                flushList()
            }

            // Headings
            if trimmed.hasPrefix("#### ") {
                flushProse()
                result.append(.heading(id: nextId, level: 4, text: String(trimmed.dropFirst(5))))
                nextId += 1
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
            i += 1
        }
        if inCode {
            result.append(.code(id: nextId, language: codeLang, body: codeLines.joined(separator: "\n")))
        } else {
            flushAllNonCode()
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
    @State private var showPickerSheet = false

    public init(host: LocalAgentHost, model: Binding<String>, allowsTyping: Bool = true) {
        self.host = host
        self._model = model
        self.allowsTyping = allowsTyping
    }

    private func displayName(for id: String) -> String {
        let base: String
        switch id {
        case ModelProvider.defaultModel: base = host.usesOfficialModels ? "DeepSeek Flash" : id
        case ModelProvider.thinkingModel: base = host.usesOfficialModels ? "DeepSeek Flash · 思考" : id
        case "deepseek-v4-pro": base = host.usesOfficialModels ? "DeepSeek V4 Pro" : id
        default: base = id
        }
        return host.isFavoriteModel(id) ? "★ \(base)" : base
    }

    public var body: some View {
        let options = host.orderedAvailableModels
        if !options.isEmpty {
            Picker("模型：\(model.isEmpty ? "未选择" : displayName(for: model))", selection: $model) {
                if !model.isEmpty && !options.contains(model) {
                    Text("\(model)（当前）").tag(model)
                }
                ForEach(options, id: \.self) { id in
                    Text(displayName(for: id)).tag(id)
                }
            }
        } else if !allowsTyping {
            Text("当前模型：\(model.isEmpty ? "未设置" : model)（可在设置中拉取列表）")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        if allowsTyping {
            HStack(spacing: 8) {
                TextField("手动输入或搜索模型 ID", text: $model)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button {
                    showPickerSheet = true
                } label: {
                    Label(options.isEmpty ? "拉取" : "浏览(\(options.count))", systemImage: "magnifyingglass")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .sheet(isPresented: $showPickerSheet) {
                ModelPickerSheet(host: host, model: $model)
            }
        }
    }
}

/// Searchable full-list model picker with favorite pinning, live refresh, and manual ID entry.
public struct ModelPickerSheet: View {
    @ObservedObject var host: LocalAgentHost
    @Binding var model: String
    var title: String
    var onApplyAll: ((String) -> Void)?
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    @State private var isRefreshing = false
    @State private var refreshMessage = ""

    public init(
        host: LocalAgentHost,
        model: Binding<String>,
        title: String = "选择模型",
        onApplyAll: ((String) -> Void)? = nil
    ) {
        self.host = host
        self._model = model
        self.title = title
        self.onApplyAll = onApplyAll
    }

    private var filteredModels: [String] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let all = host.orderedAvailableModels
        guard !query.isEmpty else { return all }
        return all.filter { $0.localizedCaseInsensitiveContains(query) }
    }

    public var body: some View {
        NavigationStack {
            List {
                if !refreshMessage.isEmpty {
                    Section {
                        Text(refreshMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                let trimmedQuery = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmedQuery.isEmpty && !host.orderedAvailableModels.contains(trimmedQuery) {
                    Section("使用自定义模型 ID") {
                        Button {
                            model = trimmedQuery
                            DSHaptics.notify(.success)
                            dismiss()
                        } label: {
                            Label("使用「\(trimmedQuery)」", systemImage: "plus.circle.fill")
                                .font(.subheadline.monospaced())
                        }
                    }
                }

                Section {
                    if filteredModels.isEmpty {
                        Text(host.orderedAvailableModels.isEmpty
                             ? "当前端点尚未拉取模型列表，点击右上角刷新或直接在搜索框输入模型 ID。"
                             : "未找到匹配「\(searchText)」的模型。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(filteredModels, id: \.self) { id in
                            let selected = model == id
                            let fav = host.isFavoriteModel(id)
                            HStack(spacing: 10) {
                                Button {
                                    host.toggleFavoriteModel(id)
                                    DSHaptics.impact(.light)
                                } label: {
                                    Image(systemName: fav ? "star.fill" : "star")
                                        .foregroundStyle(fav ? .orange : .secondary.opacity(0.6))
                                }
                                .buttonStyle(.plain)

                                Button {
                                    model = id
                                    DSHaptics.notify(.success)
                                    dismiss()
                                } label: {
                                    HStack {
                                        Text(id)
                                            .font(.subheadline.monospaced())
                                            .foregroundStyle(.primary)
                                            .lineLimit(2)
                                        Spacer()
                                        if selected {
                                            Image(systemName: "checkmark.circle.fill")
                                                .foregroundStyle(DSTheme.brand)
                                        }
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                            .swipeActions(edge: .trailing) {
                                if let onApplyAll {
                                    Button("应用全部") {
                                        model = id
                                        onApplyAll(id)
                                        DSHaptics.notify(.success)
                                        dismiss()
                                    }
                                    .tint(DSTheme.brand)
                                }
                            }
                        }
                    }
                } header: {
                    Text("可用模型（\(filteredModels.count) 个 · 星标置顶）")
                }
            }
            .searchable(text: $searchText, prompt: "搜索或输入模型 ID")
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        guard !isRefreshing else { return }
                        isRefreshing = true
                        refreshMessage = "正在拉取当前端点模型列表…"
                        Task {
                            defer { isRefreshing = false }
                            do {
                                let res = try await host.refreshModels()
                                refreshMessage = "已刷新：共 \(res.count) 个模型（\(res.latency) ms），并已同步至 Web 工作台。"
                                DSHaptics.notify(.success)
                            } catch {
                                refreshMessage = "拉取失败：\(error.localizedDescription)"
                                DSHaptics.notify(.warning)
                            }
                        }
                    } label: {
                        if isRefreshing {
                            ProgressView()
                        } else {
                            Label("刷新", systemImage: "arrow.clockwise")
                        }
                    }
                }
            }
        }
    }
}

import Foundation
import Combine

public enum LocalAgentState: Equatable {
    case idle
    case starting
    case ready
    case failed(String)
}

public struct PendingApproval: Identifiable, Equatable {
    public let id: String
    public let sessionId: String
    public let turnId: String
    public let tool: String
    public let summary: String
    public let isDSH: Bool
}

public struct DSHQuestionOption: Identifiable, Equatable {
    public let label: String
    public let description: String
    public var id: String { label }
}

public struct DSHQuestionItem: Identifiable, Equatable {
    public let id: String
    public let question: String
    public let detail: String
    public let header: String
    public let multiSelect: Bool
    public let options: [DSHQuestionOption]
}

public struct PendingDSHQuestion: Identifiable, Equatable {
    public let id: String
    public let sessionId: String
    public let turnId: String
    public let questions: [DSHQuestionItem]
}

public struct DSHAgentPresetOption: Identifiable, Equatable {
    public let id: String
    public let name: String
    public let description: String
    public let broken: String?

    public var isAvailable: Bool { broken == nil }
}

public struct DSHToolActivity: Identifiable, Equatable {
    public let id: String
    public let callId: String
    public let sessionId: String
    public let turnId: String
    public let toolName: String
    public var phase: String
    public var arguments: String
    public var result: String
    public var fileSummary: String? = nil
    public var timestamp: Date
    public var sequence: Int?
    public var callSequence: Int?
    public var durationMs: Int? = nil

    public var formattedDuration: String? {
        guard let ms = durationMs, ms >= 0 else { return nil }
        if ms < 1_000 { return "\(ms)ms" }
        let seconds = Double(ms) / 1_000.0
        return String(format: "%.1fs", seconds)
    }

    public var displayLabel: String {
        switch toolName {
        case "web_search": return "联网搜索"
        case "web_fetch": return "网页抓取"
        case "terminal_exec": return "终端命令"
        case "python_exec", "run_code": return "Python 执行"
        case "python_job_start": return "Python 后台任务"
        case "js_eval": return "JS 沙盒"
        case "read", "workspace_read": return "读取文件"
        case "write", "workspace_write": return "写入文件"
        case "edit", "workspace_edit", "apply_patch", "patch": return "编辑文件"
        case "glob", "grep", "workspace_list", "workspace_search": return "搜索工作区"
        case "memory_save": return "保存记忆"
        case "remote_mcp_list", "remote_mcp_call": return "远程 MCP"
        case "subagent": return "子智能体"
        case "git_workspace": return "工作区 Git"
        case "browser_open": return "内置浏览器 · 打开网页"
        case "browser_snapshot": return "内置浏览器 · 读取页面"
        case "browser_click": return "内置浏览器 · 点击元素"
        case "browser_type": return "内置浏览器 · 填写表单"
        case "browser_select": return "内置浏览器 · 选择下拉项"
        case "browser_press_key": return "内置浏览器 · 发送按键"
        case "browser_scroll": return "内置浏览器 · 滚动页面"
        case "browser_screenshot": return "内置浏览器 · 页面截图与 OCR"
        case "browser_back": return "内置浏览器 · 返回上页"
        case "browser_wait": return "内置浏览器 · 等待加载"
        case "browser_eval": return "内置浏览器 · 提取数据"
        case "browser_handoff": return "内置浏览器 · 请求人工接管"
        default:
            if toolName.hasPrefix("redteam_") { return "红队工具" }
            return "插件/扩展工具"
        }
    }

    public var phaseLabel: String {
        switch phase {
        case "started": return "运行中"
        case "completed": return "已完成"
        case "failed": return "失败"
        case "cancelled": return "已取消"
        case "unknown": return "结果未知"
        default: return phase
        }
    }
}

public struct DSHToolActivityHistoryPage: Equatable {
    public let arguments: String
    public let argumentsNext: Int
    public let argumentsTotalBytes: Int
    public let result: String
    public let resultNext: Int
    public let resultTotalBytes: Int
    public let phase: String
}

public struct DSHApprovalAudit: Identifiable, Equatable {
    public let id: String
    public let sessionId: String
    public var toolName: String
    public var outcome: String
    public var timestamp: Date
    public var sequence: Int?

    public var outcomeLabel: String {
        switch outcome {
        case "allowed-once": return "已批准"
        case "rejected": return "已拒绝"
        case "cancelled": return "已取消"
        case "unavailable": return "审批不可用，已拒绝"
        default: return "结果未知"
        }
    }
}

public struct SessionLiveTelemetry: Equatable, Sendable {
    public var inputTokens: Int = 0
    public var cacheReadTokens: Int = 0
    public var outputTokens: Int = 0
    public var modelDurationMs: Int = 0
    public var ttftSumMs: Int = 0
    public var ttftSamples: Int = 0

    public var totalTokens: Int { inputTokens + outputTokens }
    public var uncachedInputTokens: Int { max(0, inputTokens - cacheReadTokens) }
    public var cacheHitPercent: Int {
        guard inputTokens > 0 else { return 0 }
        return min(100, Int((Double(cacheReadTokens) / Double(inputTokens) * 100.0).rounded()))
    }
    public var averageTtftMs: Int? {
        guard ttftSamples > 0 else { return nil }
        return ttftSumMs / ttftSamples
    }
    public var tokensPerSecond: Double? {
        guard outputTokens > 0, modelDurationMs >= 200 else { return nil }
        return Double(outputTokens) / (Double(modelDurationMs) / 1000.0)
    }
}

public struct DSHPluginSource: Identifiable, Decodable, Equatable {
    public let id: String
    public let name: String
    public let url: String
    public let enabled: Bool
    public let builtIn: Bool
}

public struct DSHPluginCatalogItem: Identifiable, Decodable, Equatable {
    public let name: String
    public let title: String
    public let description: String
    public let version: String
    public let homepage: String
    public let repositoryURL: String
    public let category: String
    public let sourceId: String
    public let sourceName: String
    public let installable: Bool
    public let installSource: String

    public var id: String { "\(sourceId):\(name)" }
}

public struct RedteamPluginStatus: Equatable {
    public var installed: Bool = false
    public var pluginActive: Bool = false
    public var storeReady: Bool = false
    public var redteamModeActive: Bool = false
    public var toolCount: Int = 0
    public var tools: [String] = []
    public var skillCount: Int = 0
    public var rootPatchDisabled: Bool = true
    public var hostEnabled: Bool = false
    public var webWorkbenchSupported: Bool = false
    public var compatibilityWarning: String = ""
    public var webReadAllowed: Bool = false
    public var webWriteAllowed: Bool = false
    public var webSensitiveAllowed: Bool = false

    public init() {}

    init(_ dict: [String: Any]) {
        installed = dict["installed"] as? Bool ?? false
        pluginActive = dict["pluginActive"] as? Bool ?? false
        storeReady = dict["storeReady"] as? Bool ?? false
        redteamModeActive = dict["redteamModeActive"] as? Bool ?? false
        toolCount = dict["toolCount"] as? Int ?? 0
        tools = dict["tools"] as? [String] ?? []
        skillCount = dict["skillCount"] as? Int ?? 0
        rootPatchDisabled = dict["rootPatchDisabled"] as? Bool ?? true
        hostEnabled = dict["hostEnabled"] as? Bool ?? false
        webWorkbenchSupported = dict["webWorkbenchSupported"] as? Bool ?? false
        compatibilityWarning = dict["compatibilityWarning"] as? String ?? ""
        let webPermissions = dict["webPermissions"] as? [String: Any] ?? [:]
        webReadAllowed = webPermissions["read"] as? Bool ?? false
        webWriteAllowed = webPermissions["write"] as? Bool ?? false
        webSensitiveAllowed = webPermissions["sensitive"] as? Bool ?? false
    }
}

public struct DSHPluginComponent: Identifiable, Decodable, Equatable {
    public let id: String
    public let name: String
    public let description: String
    public let active: Bool

    enum CodingKeys: String, CodingKey { case id, name, description, active }

    public init(id: String, name: String, description: String = "", active: Bool = false) {
        self.id = id
        self.name = name
        self.description = description
        self.active = active
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? id
        description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        active = try c.decodeIfPresent(Bool.self, forKey: .active) ?? false
    }
}

public struct DSHInstalledPlugin: Identifiable, Decodable, Equatable {
    public let name: String
    public let version: String
    public let enabled: Bool
    public let desiredEnabled: Bool
    public let compatibility: String
    public let description: String
    public let sourceLabel: String
    public let components: [DSHPluginComponent]
    public var id: String { name }

    enum CodingKeys: String, CodingKey {
        case name, version, enabled, desiredEnabled, compatibility, description, sourceLabel, components
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        version = try c.decodeIfPresent(String.self, forKey: .version) ?? "0.0.0"
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        desiredEnabled = try c.decodeIfPresent(Bool.self, forKey: .desiredEnabled) ?? enabled
        compatibility = try c.decodeIfPresent(String.self, forKey: .compatibility) ?? "unverified"
        description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        sourceLabel = try c.decodeIfPresent(String.self, forKey: .sourceLabel) ?? "npm"
        components = try c.decodeIfPresent([DSHPluginComponent].self, forKey: .components) ?? []
    }

    var compatibilityLabel: String {
        switch compatibility {
        case "web-ui": return "Web UI 插件"
        case "host-only": return "仅 Host 功能"
        case "verified": return "已验证"
        default: return "待验证"
        }
    }
}

public struct ChatMessageItem: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let sessionId: String
    public let role: String // "user" | "assistant"
    public let content: String
    public let reasoning: String
    public let timestamp: Date
    public var sequence: Int?
    var historyPreview: Bool?
    var transcript: [ProviderMessage]?
    var providerProfile: String?
    var incomplete: Bool?

    public init(id: String = UUID().uuidString, sessionId: String, role: String, content: String, reasoning: String = "", timestamp: Date = Date(), sequence: Int? = nil) {
        self.id = id
        self.sessionId = sessionId
        self.role = role
        self.content = content
        self.reasoning = reasoning
        self.timestamp = timestamp
        self.sequence = sequence
    }
}

public struct BotProfile: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public var name: String
    public var roleLabel: String
    public var model: String
    public var systemPrompt: String
    public var isMain: Bool
    public var isPrivate: Bool
    public var isGroup: Bool
    public var section: String
    public var permissionMode: String // "ask" | "autoReview" | "readOnly"
    public var agentPreset: String // "standard" | "cordis" | "ptc-python" | "minimal" | "redteam"
    public var reasoningEffort: String // "low" | "medium" | "high"
    public var disabledTools: [String]
    public var redteamToolsEnabled: Bool
    public var redteamWriteEnabled: Bool
    public var redteamSensitiveDataEnabled: Bool
    public var providerProfileId: String?

    enum CodingKeys: String, CodingKey {
        case id, name, roleLabel, model, systemPrompt, isMain, isPrivate, isGroup, section, permissionMode, agentPreset, reasoningEffort, disabledTools
        case redteamToolsEnabled, redteamWriteEnabled, redteamSensitiveDataEnabled, providerProfileId
    }

    public init(id: String, name: String, roleLabel: String, model: String = "deepseek-flash", systemPrompt: String = "", isMain: Bool = false, isPrivate: Bool = false, isGroup: Bool = false, section: String = "默认团队", permissionMode: String = "ask", agentPreset: String = "standard", reasoningEffort: String = "medium", disabledTools: [String] = [], redteamToolsEnabled: Bool = false, redteamWriteEnabled: Bool = false, redteamSensitiveDataEnabled: Bool = false, providerProfileId: String? = nil) {
        self.id = id
        self.name = name
        self.roleLabel = roleLabel
        self.model = model
        self.systemPrompt = systemPrompt
        self.isMain = isMain
        self.isPrivate = isPrivate
        self.isGroup = isGroup
        self.section = section
        self.permissionMode = permissionMode
        self.agentPreset = agentPreset
        self.reasoningEffort = ["low", "medium", "high"].contains(reasoningEffort) ? reasoningEffort : "medium"
        self.disabledTools = disabledTools
        self.redteamToolsEnabled = !isPrivate && redteamToolsEnabled
        self.redteamWriteEnabled = !isPrivate && redteamToolsEnabled && redteamWriteEnabled
        self.redteamSensitiveDataEnabled = !isPrivate && redteamToolsEnabled && redteamSensitiveDataEnabled
        self.providerProfileId = providerProfileId
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        roleLabel = try c.decode(String.self, forKey: .roleLabel)
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? ModelProvider.defaultModel
        systemPrompt = try c.decodeIfPresent(String.self, forKey: .systemPrompt) ?? ""
        isMain = try c.decodeIfPresent(Bool.self, forKey: .isMain) ?? false
        isPrivate = try c.decodeIfPresent(Bool.self, forKey: .isPrivate) ?? false
        isGroup = try c.decodeIfPresent(Bool.self, forKey: .isGroup) ?? false
        section = try c.decodeIfPresent(String.self, forKey: .section) ?? "默认团队"
        permissionMode = try c.decodeIfPresent(String.self, forKey: .permissionMode) ?? "ask"
        agentPreset = try c.decodeIfPresent(String.self, forKey: .agentPreset) ?? "standard"
        let storedEffort = try c.decodeIfPresent(String.self, forKey: .reasoningEffort) ?? "medium"
        reasoningEffort = ["low", "medium", "high"].contains(storedEffort) ? storedEffort : "medium"
        disabledTools = try c.decodeIfPresent([String].self, forKey: .disabledTools) ?? []
        let storedRedteamToolsEnabled = try c.decodeIfPresent(Bool.self, forKey: .redteamToolsEnabled) ?? false
        let storedRedteamWriteEnabled = try c.decodeIfPresent(Bool.self, forKey: .redteamWriteEnabled) ?? false
        let storedRedteamSensitiveDataEnabled = try c.decodeIfPresent(Bool.self, forKey: .redteamSensitiveDataEnabled) ?? false
        redteamToolsEnabled = !isPrivate && storedRedteamToolsEnabled
        redteamWriteEnabled = !isPrivate && redteamToolsEnabled && storedRedteamWriteEnabled
        redteamSensitiveDataEnabled = !isPrivate && redteamToolsEnabled && storedRedteamSensitiveDataEnabled
        providerProfileId = try c.decodeIfPresent(String.self, forKey: .providerProfileId)
    }

    public var reasoningEffortLabel: String {
        switch reasoningEffort {
        case "low": return "低（快速）"
        case "high": return "高（深度）"
        default: return "中（均衡）"
        }
    }

    public var permissionModeLabel: String {
        switch permissionMode {
        case "autoReview": return "沙盒免打扰"
        case "readOnly": return "只读保护"
        default: return "标准审批"
        }
    }

    public var agentPresetLabel: String {
        switch agentPreset {
        case "cordis": return "创造模式"
        case "ptc-python": return "PTC 开发模式"
        case "minimal": return "轻量模式"
        case "redteam": return "红队演练"
        case "standard": return "标准模式"
        default: return agentPreset
        }
    }
}

public enum StreamTurnPhase: Equatable, Sendable {
    case connecting
    case thinking
    case toolRunning(String)
    case awaitingApproval(String)
    case generating
    case cancelling

    public var label: String {
        switch self {
        case .connecting: return "正在连接模型…"
        case .thinking: return "深度思考中…"
        case .toolRunning(let name): return "正在调用工具 \(name)…"
        case .awaitingApproval(let tool): return "等待审批 \(tool)"
        case .generating: return "正在生成"
        case .cancelling: return "正在安全停止…"
        }
    }

    public var icon: String {
        switch self {
        case .connecting: return "antenna.radiowaves.left.and.right"
        case .thinking: return "brain"
        case .toolRunning: return "gearshape.2.fill"
        case .awaitingApproval: return "checkmark.shield"
        case .generating: return "sparkles"
        case .cancelling: return "stop.circle"
        }
    }
}

/// Isolated high-frequency observable for the active streaming turn so 30fps token
/// flushes only re-render `StreamingTurnRow` and never invalidate the entire chat history.
@MainActor
public final class StreamingTurnState: ObservableObject {
    @Published public var sessionId: String?
    @Published public var content: String = ""
    @Published public var stableBlocks: [String] = []
    @Published public var liveTail: String = ""
    @Published public var reasoning: String = ""
    @Published public var phase: StreamTurnPhase = .connecting
    @Published public var firstTokenMs: Int?
    @Published public var charsPerSecond: Int = 0
    @Published public var elapsedSeconds: Int = 0
    @Published public var startedAt: Date?
    @Published public var recentSteerNote: String?

    private var inCodeFence = false
    private var tailBuffer = ""

    public init() {}

    public func begin(sessionId: String, steerNote: String? = nil) {
        self.sessionId = sessionId
        self.content = ""
        self.stableBlocks = []
        self.liveTail = ""
        self.reasoning = ""
        self.phase = .connecting
        self.firstTokenMs = nil
        self.charsPerSecond = 0
        self.elapsedSeconds = 0
        self.startedAt = Date()
        self.recentSteerNote = steerNote
        self.inCodeFence = false
        self.tailBuffer = ""
    }

    /// Incrementally appends streaming content in O(delta) time, sealing completed paragraphs
    /// outside open fenced code blocks into `stableBlocks` so completed Markdown blocks are never re-parsed.
    public func appendContent(_ delta: String) {
        guard !delta.isEmpty else { return }
        content += delta
        tailBuffer += delta

        // Fast path: only scan for paragraph boundaries when a newline was added
        guard delta.contains("\n") else {
            liveTail = tailBuffer
            return
        }

        // Process complete lines in tailBuffer while keeping the trailing partial line
        var lines = tailBuffer.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let trailingPartial = lines.popLast() ?? ""
        var currentBlockLines: [String] = []
        var sealedAny = false
        var localInFence = inCodeFence

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                localInFence.toggle()
                currentBlockLines.append(line)
            } else if !localInFence && trimmed.isEmpty {
                let candidate = currentBlockLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                if !candidate.isEmpty {
                    stableBlocks.append(candidate)
                    sealedAny = true
                }
                currentBlockLines.removeAll(keepingCapacity: true)
            } else {
                currentBlockLines.append(line)
            }
        }

        if sealedAny {
            inCodeFence = localInFence
            if !trailingPartial.isEmpty || !currentBlockLines.isEmpty {
                currentBlockLines.append(trailingPartial)
                tailBuffer = currentBlockLines.joined(separator: "\n")
            } else {
                tailBuffer = ""
            }
        }
        liveTail = tailBuffer
    }

    public func reset() {
        sessionId = nil
        content = ""
        stableBlocks = []
        liveTail = ""
        reasoning = ""
        phase = .connecting
        firstTokenMs = nil
        charsPerSecond = 0
        elapsedSeconds = 0
        startedAt = nil
        recentSteerNote = nil
        inCodeFence = false
        tailBuffer = ""
    }
}

struct StreamingDraftRecord: Codable, Sendable {
    let sessionId: String
    let content: String
    let reasoning: String
    let updatedAt: Date
}

public struct RuntimePluginTool: Identifiable, Codable, Equatable, Sendable {
    public var id: String { name }
    public let name: String
    public let description: String
}

public struct WebSessionSummary: Identifiable, Equatable, Sendable {
    public let sessionId: String
    public let lastActivityAt: Date
    public let lastMessagePreview: String
    public let eventCount: Int
    public var id: String { sessionId }

    public init(sessionId: String, lastActivityAt: Date, lastMessagePreview: String, eventCount: Int) {
        self.sessionId = sessionId
        self.lastActivityAt = lastActivityAt
        self.lastMessagePreview = lastMessagePreview
        self.eventCount = eventCount
    }
}


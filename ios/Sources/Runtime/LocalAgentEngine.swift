import Foundation

typealias LocalPythonRunHandler = @Sendable (String, String, String) async throws -> String
typealias LocalPythonCancelHandler = @Sendable (String, String) async -> Void

/// Disk-persisted native tool state.
actor LocalAgentStore {
    struct PersistedState: Codable {
        var memoryJournal: [[String: String]] = []
        var groupTodos: [String: [TodoItem]] = [:]
        var groupGoals: [String: String] = [:]
        var connectors: [ConnectorItem] = []
        var totalTokens: Int = 0
        var cachedInputTokens: Int = 0
        var totalInputTokens: Int = 0
    }

    struct TodoItem: Codable { let id: String; let text: String; var done: Bool }
    struct ConnectorItem: Codable { let id: String; let type: String; let name: String; let endpoint: String }

    private let stateURL: URL
    private var state: PersistedState
    private var lastSavedState: PersistedState?
    private(set) var loadError: Error?

    init(root: URL) {
        let url = root.appendingPathComponent("local-state.json")
        self.stateURL = url
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: url.path) {
                state = try JSONDecoder().decode(PersistedState.self, from: Data(contentsOf: url))
            } else {
                state = PersistedState()
            }
        } catch {
            state = PersistedState()
            loadError = error
        }
        lastSavedState = state
    }

    private func save() throws {
        do {
            try JSONEncoder().encode(state).write(to: stateURL, options: .atomic)
            lastSavedState = state
        } catch {
            if let lastSavedState { state = lastSavedState }
            throw error
        }
    }

    func recordUsage(input: Int, cached: Int, output: Int) throws {
        func adding(_ value: Int, _ increment: Int) -> Int {
            let (total, overflow) = max(0, value).addingReportingOverflow(max(0, increment))
            return overflow ? Int.max : total
        }
        state.totalInputTokens = adding(state.totalInputTokens, input)
        state.cachedInputTokens = adding(state.cachedInputTokens, min(input, cached))
        state.totalTokens = adding(adding(state.totalTokens, input), output)
        try save()
    }

    func usageSummary() -> [String: Any] {
        let rate = state.totalInputTokens > 0 ? Double(state.cachedInputTokens) / Double(state.totalInputTokens) : 0.0
        return ["totalTokens": state.totalTokens, "cacheHitRate": rate]
    }

    func addMemory(botId: String, title: String, content: String, layer: String) throws -> [String: Any] {
        let jId = "jrn_\(UUID().uuidString.prefix(8))"
        let eId = "mem_\(UUID().uuidString.prefix(8))"
        state.memoryJournal.insert([
            "botId": botId,
            "journalId": jId,
            "op": "add",
            "entryId": eId,
            "title": title,
            "content": content,
            "layer": layer,
            "at": ISO8601DateFormatter().string(from: Date())
        ], at: 0)
        try save()
        return ["journalId": jId, "entryId": eId]
    }

    func pinnedMemoriesSummary(botId: String) -> String {
        let pinned = state.memoryJournal.filter { $0["layer"] == "pinned" && $0["botId"] == botId }
        guard !pinned.isEmpty else { return "" }
        return pinned.prefix(8).compactMap { rec in
            guard let t = rec["title"], let c = rec["content"], !c.isEmpty else { return nil }
            return "- \(t): \(c)"
        }.joined(separator: "\n")
    }

    func memoryJournal(botId: String?) -> [[String: String]] {
        state.memoryJournal.filter { $0["botId"] == botId }
    }

    func assignMemory(journalId: String, botId: String) throws -> Bool {
        guard let index = state.memoryJournal.firstIndex(where: { $0["journalId"] == journalId && $0["botId"] == nil }) else { return false }
        state.memoryJournal[index]["botId"] = botId
        try save()
        return true
    }

    func undoMemory(botId: String, journalId: String) throws -> Bool {
        guard let index = state.memoryJournal.firstIndex(where: { $0["journalId"] == journalId && $0["botId"] == botId }) else { return false }
        state.memoryJournal.remove(at: index)
        try save()
        return true
    }

    func groupState(groupId: String) -> [String: Any] {
        let todos = (state.groupTodos[groupId] ?? []).map { ["id": $0.id, "text": $0.text, "done": $0.done] as [String: Any] }
        return ["goal": ["title": state.groupGoals[groupId] ?? "未设定群目标"], "todos": todos]
    }

    func setGroupGoal(groupId: String, title: String) throws -> [String: Any] {
        state.groupGoals[groupId] = title
        try save()
        return ["goal": ["title": title, "status": "active"]]
    }

    func addGroupTodo(groupId: String, text: String) throws -> [String: Any] {
        let item = TodoItem(id: "todo_\(UUID().uuidString.prefix(6))", text: text, done: false)
        state.groupTodos[groupId, default: []].append(item)
        try save()
        return ["todo": ["id": item.id, "text": item.text, "done": item.done]]
    }

    func toggleGroupTodo(groupId: String, id: String, done: Bool) throws {
        if var list = state.groupTodos[groupId], let idx = list.firstIndex(where: { $0.id == id }) {
            list[idx].done = done
            state.groupTodos[groupId] = list
            try save()
        }
    }

    func clearCompletedTodos(groupId: String) throws -> Int {
        guard let list = state.groupTodos[groupId] else { return 0 }
        let kept = list.filter { !$0.done }
        let removed = list.count - kept.count
        if removed > 0 {
            state.groupTodos[groupId] = kept
            try save()
        }
        return removed
    }

    func listConnectors() -> [[String: Any]] {
        state.connectors.map { ["id": $0.id, "type": $0.type, "name": $0.name, "endpoint": $0.endpoint] }
    }

    func upsertConnector(id: String?, type: String, name: String, endpoint: String) throws -> [String: Any] {
        let cid = id ?? "conn_\(UUID().uuidString.prefix(6))"
        state.connectors.removeAll { $0.id == cid }
        let entry = ConnectorItem(id: cid, type: type, name: name, endpoint: endpoint)
        state.connectors.append(entry)
        try save()
        return ["id": cid, "type": type, "name": name, "endpoint": endpoint]
    }

    func connector(id: String) -> ConnectorItem? { state.connectors.first { $0.id == id } }

    func deleteConnector(id: String) throws {
        state.connectors.removeAll { $0.id == id }
        try save()
    }

}

actor ToolApprovals {
    private struct Pending {
        let turnId: String
        let sessionId: String
        let continuation: CheckedContinuation<Bool, Never>
        let timeout: Task<Void, Never>
    }

    private var pending: [String: Pending] = [:]

    func wait(id: String, turnId: String, sessionId: String, announce: () -> Void) async -> Bool {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(returning: false); return }
                let timeout = Task { [weak self] in
                    do { try await Task.sleep(nanoseconds: 60_000_000_000) } catch { return }
                    await self?.finish(id, approved: false)
                }
                pending[id] = Pending(turnId: turnId, sessionId: sessionId, continuation: continuation, timeout: timeout)
                announce()
            }
        } onCancel: {
            Task { await self.finish(id, approved: false) }
        }
    }

    func respond(id: String, turnId: String, sessionId: String, approved: Bool) -> Bool {
        guard let item = pending[id], item.sessionId == sessionId, item.turnId == turnId else { return false }
        finish(id, approved: approved)
        return true
    }

    func cancel(sessionId: String, turnId: String) {
        let matching = pending.compactMap { id, item in
            item.sessionId == sessionId && item.turnId == turnId ? id : nil
        }
        matching.forEach { finish($0, approved: false) }
    }

    private func finish(_ id: String, approved: Bool) {
        guard let item = pending.removeValue(forKey: id) else { return }
        item.timeout.cancel()
        item.continuation.resume(returning: approved)
    }
}

public final class LocalAgentTransport: IPCByteTransport, @unchecked Sendable {
    static let defaultWorkspace = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("dsh-home", isDirectory: true)

    private let workspaceRoot: URL
    private let keychain: KeychainBridge
    private let modelKey: (ModelProvider) async throws -> String
    private let session: URLSession
    private let store: LocalAgentStore
    private let js = LocalJavaScript()
    private let device = DeviceCapabilitiesBridge()
    private let mcp: RemoteMCPClient
    private let approvals = ToolApprovals()

    private let io = DispatchQueue(label: "io.github.dsbot.localagent.ipc")
    private let decoder = IPCFrameDecoder()
    private var receiver: ((Data) -> Void)?
    private var nativeNotificationHandler: ((String, [String: Any]) -> Void)?
    private var turnTasks: [String: Task<Void, Never>] = [:]
    private var requestTasks: [Int: Task<Void, Never>] = [:]
    private var sideRequests: [String: Int] = [:]
    private var workspaceSideTasks: [String: Task<[String: Any], Error>] = [:]
    private var suspended = false
    private var closed = false

    init(root: URL = LocalAgentTransport.defaultWorkspace, keychain: KeychainBridge = KeychainBridge(),
         migrateOfficialKey: Bool = false, session: URLSession? = nil, mcp: RemoteMCPClient? = nil,
         modelKey: ((ModelProvider) async throws -> String)? = nil) {
        self.workspaceRoot = root
        self.keychain = keychain
        self.modelKey = modelKey ?? { provider in
            try await keychain.modelKey(provider: provider, migrateOfficialKey: migrateOfficialKey)
        }
        self.session = session ?? isolatedHTTPSession(timeout: 45)
        self.store = LocalAgentStore(root: root)
        self.mcp = mcp ?? RemoteMCPClient(keychain: keychain)
    }

    public func setReceiveHandler(_ handler: @escaping (Data) -> Void) {
        io.async { if !self.closed { self.receiver = handler } }
    }

    func setNativeNotificationHandler(_ handler: @escaping (String, [String: Any]) -> Void) {
        io.async { self.nativeNotificationHandler = handler }
    }

    /// Exposes only the pre-existing native workspace RPC allowlist. Chat and
    /// agent lifecycle calls remain exclusively owned by the embedded DSH runtime.
    func nativeWorkspaceRequest(method: String, params: [String: Any]) async throws -> [String: Any] {
        if method == "side.cancel" {
            let sideId = params["sideId"] as? String ?? ""
            let task = io.sync { workspaceSideTasks.removeValue(forKey: sideId) }
            task?.cancel()
            return ["cancelled": task != nil]
        }
        let allowed: Set<String> = [
            "models.test", "memory.add", "memory.journal", "memory.legacy", "memory.assign", "memory.undo",
            "group.state", "group.goal.set", "group.todo.add", "group.todo.toggle", "group.todo.clearCompleted",
            "connectors.list", "connectors.upsert", "connectors.delete", "usage.legacySummary", "tools.jsEval",
            "device.status", "device.speak", "device.stopSpeaking", "mcp.listTools", "mcp.callTool", "side.ask",
            "approval.respond"
        ]
        guard allowed.contains(method) else {
            throw IPCFrameError.remoteError(code: -32601, message: "Unsupported native workspace method: \(method)")
        }
        if method == "side.ask" {
            let sideId = params["sideId"] as? String ?? ""
            guard !sideId.isEmpty, sideId.utf8.count <= 128 else {
                throw IPCFrameError.remoteError(code: -32602, message: "无效的侧边请求编号。")
            }
            let task = Task { try await self.handle(method: method, params: params) }
            let inserted = io.sync { () -> Bool in
                guard workspaceSideTasks[sideId] == nil else { return false }
                workspaceSideTasks[sideId] = task
                return true
            }
            guard inserted else {
                task.cancel()
                throw IPCFrameError.remoteError(code: -32602, message: "侧边请求编号重复。")
            }
            defer {
                _ = io.sync { workspaceSideTasks.removeValue(forKey: sideId) }
                task.cancel()
            }
            return try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
        }
        return try await handle(method: method, params: params)
    }

    func executeNativeTool(name: String, arguments: [String: Any], botId: String, turnId: String, isGroup: Bool,
                           pythonRunner: LocalPythonRunHandler? = nil) async throws -> [String: Any] {
        guard ["js_eval", "python_exec", "device_status", "memory_save", "group_todo_add", "web_fetch", "web_search", "remote_mcp_list", "remote_mcp_call",
               "workspace_list", "workspace_read", "workspace_write", "workspace_search", "workspace_edit"].contains(name) else {
            throw IPCFrameError.remoteError(code: -32601, message: "Unsupported DSH native tool: \(name)")
        }
        guard let data = try? JSONSerialization.data(withJSONObject: arguments),
              let encoded = String(data: data, encoding: .utf8) else {
            throw IPCFrameError.invalidJSON
        }
        var call = ProviderMessage.ToolCall()
        call.id = "dsh_\(UUID().uuidString)"
        call.function.name = name
        call.function.arguments = encoded
        let output = try await execute(call, sessionId: botId, turnId: turnId, isGroup: isGroup,
                                       structuredWeb: name == "web_fetch", pythonRunner: pythonRunner)
        return ["output": output]
    }

    func cancelNativeTool(botId: String, turnId: String, pythonCanceller: LocalPythonCancelHandler? = nil) async {
        await approvals.cancel(sessionId: botId, turnId: turnId)
        await pythonCanceller?(botId, turnId)
    }

    public func write(_ data: Data) {
        io.async {
            guard !self.closed, let messages = try? self.decoder.push(data) else { return }
            for message in messages {
                guard let id = message["id"] as? Int, let method = message["method"] as? String else { continue }
                self.route(id: id, method: method, params: message["params"] as? [String: Any] ?? [:])
            }
        }
    }

    public func close() {
        io.async {
            self.closed = true
            self.receiver = nil
            self.cancelWork()
            self.session.invalidateAndCancel()
        }
    }

    private func cancelWork() {
        for task in turnTasks.values { task.cancel() }
        for task in requestTasks.values { task.cancel() }
        for task in workspaceSideTasks.values { task.cancel() }
        workspaceSideTasks.removeAll()
    }

    private func route(id: Int, method: String, params: [String: Any]) {
        switch method {
        case "chat.send":
            guard !suspended, let turnId = params["turnId"] as? String, !turnId.isEmpty, turnTasks.isEmpty else {
                fail(id, code: -32602, "当前无法启动新回合。")
                return
            }
            turnTasks[turnId] = Task { [weak self] in
                guard let self else { return }
                await self.chat(turnId: turnId, params: params)
            }
            reply(id, ["turnId": turnId, "status": "accepted"])
        case "chat.abort":
            let task = turnTasks[params["turnId"] as? String ?? ""]
            task?.cancel()
            reply(id, ["aborted": task != nil])
        case "side.cancel":
            let sideId = params["sideId"] as? String ?? ""
            if let request = sideRequests[sideId] { requestTasks[request]?.cancel() }
            reply(id, ["cancelled": true])
        case "agent.suspend":
            suspended = true
            cancelWork()
            Task { await device.stopSpeaking() }
            reply(id, ["suspended": true])
        case "agent.resume":
            suspended = false
            reply(id, ["suspended": false])
        default:
            guard !suspended else { fail(id, "应用在后台。"); return }
            let sideId = method == "side.ask" ? params["sideId"] as? String : nil
            if let sideId { sideRequests[sideId] = id }
            requestTasks[id] = Task { [weak self] in
                guard let self else { return }
                defer {
                    self.io.async {
                        self.requestTasks.removeValue(forKey: id)
                        if let sideId { self.sideRequests.removeValue(forKey: sideId) }
                    }
                }
                do {
                    let result = try await self.handle(method: method, params: params)
                    self.reply(id, result)
                } catch let error as IPCFrameError {
                    if case .remoteError(let code, let message) = error { self.fail(id, code: code, message) }
                    else { self.fail(id, error.localizedDescription) }
                } catch {
                    self.fail(id, error.localizedDescription)
                }
            }
        }
    }

    private func handle(method: String, params: [String: Any]) async throws -> [String: Any] {
        if await store.loadError != nil { throw IPCFrameError.remoteError(code: -32000, message: "无法读取本机工作区。原有数据已保留。") }
        let botId = params["botId"] as? String ?? "main"
        let groupId = params["groupId"] as? String ?? "default"
        switch method {
        case "agent.info":
            return [
                "engine": "native-workspace-bridge",
                "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
                "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "",
                "ipcProtocolVersion": IPCFrameCodec.protocolVersion,
                "tools": Self.tools.compactMap { ($0["function"] as? [String: Any])?["name"] as? String }
            ]
        case "side.ask": return try await sideChat(params)
        case "models.test": return try await listModels(params)
        case "memory.add":
            return try await store.addMemory(botId: botId, title: params["title"] as? String ?? "",
                                             content: params["content"] as? String ?? "", layer: params["layer"] as? String ?? "delta")
        case "memory.journal":
            return ["records": await store.memoryJournal(botId: botId)]
        case "memory.legacy":
            return ["records": await store.memoryJournal(botId: nil)]
        case "memory.assign":
            return ["assigned": try await store.assignMemory(journalId: params["journalId"] as? String ?? "", botId: botId)]
        case "memory.undo":
            return ["undone": try await store.undoMemory(botId: botId, journalId: params["journalId"] as? String ?? "")]
        case "group.state": return await store.groupState(groupId: groupId)
        case "group.goal.set": return try await store.setGroupGoal(groupId: groupId, title: params["title"] as? String ?? "")
        case "group.todo.add": return try await store.addGroupTodo(groupId: groupId, text: params["text"] as? String ?? "")
        case "group.todo.toggle":
            try await store.toggleGroupTodo(groupId: groupId, id: params["id"] as? String ?? "", done: params["done"] as? Bool ?? false)
            return ["found": true]
        case "group.todo.clearCompleted": return ["removed": try await store.clearCompletedTodos(groupId: groupId)]
        case "connectors.list": return ["connectors": await store.listConnectors()]
        case "connectors.upsert":
            let endpoint = try RemoteMCPClient.endpointURL(params["endpoint"] as? String ?? "").absoluteString
            let name = (params["name"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { throw IPCFrameError.remoteError(code: -32602, message: "请输入连接器名称。") }
            let requestedID = params["id"] as? String
            var existing: LocalAgentStore.ConnectorItem?
            if let requestedID { existing = await store.connector(id: requestedID) }
            let id: String
            if let existing, existing.type == "remote-mcp" { id = existing.id }
            else { id = "conn_" + UUID().uuidString }
            let isExistingConnector = existing?.type == "remote-mcp"
            let account = "connector:\(id)"
            let token = params["token"] as? String ?? ""
            if !token.isEmpty { _ = try keychain.setSecret(account: account, value: token) }
            do {
                return ["connector": try await store.upsertConnector(id: id, type: "remote-mcp", name: name, endpoint: endpoint)]
            } catch {
                if !isExistingConnector, !token.isEmpty { _ = try? keychain.deleteSecret(account: account) }
                throw error
            }
        case "connectors.delete":
            let id = params["id"] as? String ?? ""
            try await store.deleteConnector(id: id)
            _ = try keychain.deleteSecret(account: "connector:\(id)")
            return ["removed": true]
        case "usage.legacySummary": return await store.usageSummary()
        case "approval.respond":
            return ["found": await approvals.respond(
                id: params["approvalId"] as? String ?? "", turnId: params["turnId"] as? String ?? "",
                sessionId: params["sessionId"] as? String ?? "", approved: params["approved"] as? Bool ?? false)]
        case "tools.jsEval":
            let result = await js.evaluate(params["script"] as? String ?? "")
            return ["ok": result.ok, "value": result.value, "logs": result.logs, "error": result.error ?? ""]
        case "device.status": return await device.deviceStatus()
        case "device.speak":
            let text = params["text"] as? String ?? ""
            guard !text.isEmpty else { throw IPCFrameError.remoteError(code: -32602, message: "没有可朗读的内容。") }
            await device.speak(text)
            return ["ok": true]
        case "device.stopSpeaking":
            await device.stopSpeaking()
            return ["ok": true]
        case "mcp.listTools":
            guard let connector = await store.connector(id: params["connectorId"] as? String ?? ""), connector.type == "remote-mcp" else {
                throw IPCFrameError.remoteError(code: -32602, message: "连接器已移除。")
            }
            let tools = try await mcp.listTools(endpoint: connector.endpoint, keychainAccount: "connector:\(connector.id)")
            return ["ok": true, "tools": tools.map { ["name": $0.name, "description": $0.description] }]
        default: throw IPCFrameError.remoteError(code: -32601, message: "不支持的方法 \(method)。")
        }
    }

    private static let tools: [[String: Any]] = [
        tool("js_eval", "Evaluate JavaScript locally for calculations and data transforms.", ["script": "string"], ["script"]),
        tool("python_exec", "Run offline Python 3.13 with NumPy in a fresh, resource-limited local WebAssembly worker. State resets after each call; print results or leave a final expression. No app files, network, process, or MCP bindings are exposed; use workspace tools for files. Each call shows the full code and requires approval.", ["code": "string"], ["code"]),
        tool("memory_save", "Save memory for the current bot.", ["title": "string", "content": "string", "layer": "string"], ["title", "content"]),
        tool("group_todo_add", "Add a todo to the current group.", ["text": "string"], ["text"]),
        tool("device_status", "Read iOS device power and thermal status.", [:], []),
        tool("remote_mcp_call", "Call a user-configured MCP connector.", ["connectorName": "string", "toolName": "string", "arguments": "object"], ["connectorName", "toolName"]),
        tool("web_fetch", "Read an HTTPS URL after the user approves the exact address.", ["url": "string"], ["url"])
    ]

    private static func tool(_ name: String, _ summary: String, _ fields: [String: String], _ required: [String]) -> [String: Any] {
        ["type": "function", "function": ["name": name, "description": summary,
          "parameters": ["type": "object", "properties": fields.mapValues { ["type": $0] }, "required": required]]]
    }

    private func chat(turnId: String, params: [String: Any]) async {
        let sessionId = params["sessionId"] as? String ?? "main"
        var terminal: [String: Any] = ["sessionId": sessionId, "turnId": turnId]
        var status = "error"
        defer {
            terminal["status"] = status
            let frame = (try? IPCFrameCodec.encode(["jsonrpc": "2.0", "method": "chat.done", "params": terminal]))
                ?? (try? IPCFrameCodec.encode([
                    "jsonrpc": "2.0", "method": "chat.done",
                    "params": ["turnId": turnId, "sessionId": sessionId, "status": "incomplete",
                               "error": "回复超出本机保存上限。"]
                ]))
            io.async {
                self.turnTasks.removeValue(forKey: turnId)
                if let frame { self.receiver?(frame) }
            }
        }
        do {
            try Task.checkCancellation()
            if await store.loadError != nil {
                throw IPCFrameError.remoteError(code: -32000, message: "无法读取本机工作区。")
            }

            let provider = try ModelProvider(params["apiBaseURL"] as? String ?? "")
            let key = try await modelKey(provider)
            let selectedModel = params["model"] as? String ?? ""
            var fields = try provider.modelFields(selectedModel)
            let toolsEnabled = provider.isDeepSeek || params["customTools"] as? Bool == true
            let isGroup = params["isGroup"] as? Bool == true
            if toolsEnabled {
                fields["tools"] = isGroup ? Self.tools : Self.tools.filter {
                    ($0["function"] as? [String: Any])?["name"] as? String != "group_todo_add"
                }
            }
            fields["stream"] = true
            if provider.isDeepSeek { fields["stream_options"] = ["include_usage": true] }
            var prompt = "You are DS Bot on iOS. Reply concisely in the user's language."
            if let custom = params["systemPrompt"] as? String, !custom.isEmpty { prompt += "\n\n" + custom }
            let pinned = await store.pinnedMemoriesSummary(botId: sessionId)
            if !pinned.isEmpty { prompt += "\n\nPinned user memory:\n" + pinned }
            let historical = ((params["history"] as? [[String: Any]]) ?? []).map { message -> [String: Any] in
                var message = message
                if !provider.isDeepSeek || !toolsEnabled { message.removeValue(forKey: "reasoning_content") }
                return message
            }
            var messages = [["role": "system", "content": prompt] as [String: Any]] + historical
            var transcript: [ProviderMessage] = []
            var usedIDs = Set<String>()

            for roundIndex in 0...6 {
                try Task.checkCancellation()
                fields["messages"] = messages
                let round = try await completion(provider: provider, key: key, fields: fields, sessionId: sessionId, turnId: turnId)
                if ["length", "content_filter"].contains(round.finishReason ?? "") {
                    status = "incomplete"
                    terminal["error"] = "模型在生成结束前停止了回复。"
                    return
                }

                let calls = round.toolCalls
                let assistant = ProviderMessage(role: "assistant", content: round.content.isEmpty ? nil : round.content,
                    reasoning_content: round.reasoning.isEmpty ? nil : round.reasoning, tool_calls: calls.isEmpty ? nil : calls)
                transcript.append(assistant)
                guard !calls.isEmpty else {
                    guard round.finishReason != "tool_calls", !round.content.isEmpty else { throw ModelProviderError.invalidResponse }
                    status = "completed"
                    terminal["transcript"] = transcript.map(\.payload)
                    terminal["profile"] = provider.historyProfile(model: selectedModel, tools: toolsEnabled)
                    return
                }
                guard toolsEnabled, round.finishReason == "tool_calls" else { throw ModelProviderError.invalidToolCall }
                guard roundIndex < 6 else { throw ModelProviderError.toolLimit }
                // Validate the entire batch before any side effects.
                for call in calls {
                    guard !call.id.isEmpty, !call.function.name.isEmpty, usedIDs.insert(call.id).inserted,
                          (try? JSONSerialization.jsonObject(with: Data(call.function.arguments.utf8))) is [String: Any] else {
                        throw ModelProviderError.invalidToolCall
                    }
                }
                var assistantPayload = assistant.payload
                if !provider.isDeepSeek { assistantPayload.removeValue(forKey: "reasoning_content") }
                messages.append(assistantPayload)
                for call in calls {
                    try Task.checkCancellation()
                    let result = try await execute(call, sessionId: sessionId, turnId: turnId, isGroup: isGroup)
                    let response = ProviderMessage(role: "tool", content: String(result.prefix(16_384)), tool_call_id: call.id)
                    transcript.append(response)
                    messages.append(response.payload)
                }
            }
        } catch {
            if Task.isCancelled || (error as? URLError)?.code == .cancelled { status = "aborted" }
            else { terminal["error"] = error.localizedDescription }
        }
    }

    private func completion(provider: ModelProvider, key: String, fields: [String: Any],
                            sessionId: String, turnId: String) async throws -> CompletionRound {
        let request = try makeRequest(provider.endpoint("chat/completions"), key: key, fields: fields)
        for attempt in 0...2 {
            try Task.checkCancellation()
            let response: (URLSession.AsyncBytes, URLResponse)
            do {
                response = try await session.bytes(for: request)
            } catch let error as URLError where attempt < 2 &&
                [.notConnectedToInternet, .networkConnectionLost, .timedOut].contains(error.code) {
                try await Task.sleep(nanoseconds: UInt64(attempt + 1) * 1_000_000_000)
                continue
            }

            guard let http = response.1 as? HTTPURLResponse else { throw ModelProviderError.invalidResponse }
            if attempt < 2, [429, 502, 503, 504].contains(http.statusCode) {
                response.0.task.cancel()
                try await Task.sleep(nanoseconds: UInt64(attempt + 1) * 1_000_000_000)
                continue
            }
            defer { response.0.task.cancel() }
            try checkHTTP(http)
            guard http.mimeType == "text/event-stream" else { throw ModelProviderError.invalidResponse }

            var events = ServerSentEvents()
            var round = CompletionRound()
            for try await byte in response.0 {
                try Task.checkCancellation()
                guard let event = try events.append(byte: byte) else { continue }
                let delta = try round.consume(event)
                if !delta.content.isEmpty || !delta.reasoning.isEmpty {
                    emit("chat.delta", ["sessionId": sessionId, "turnId": turnId, "content": delta.content, "reasoning": delta.reasoning])
                }
                if let usage = delta.usage { await recordUsage(usage) }
                if round.done { break }
            }
            try Task.checkCancellation()
            guard round.done || (!provider.isDeepSeek && round.finishReason != nil) else { throw ModelProviderError.interrupted }
            guard let reason = round.finishReason, ["stop", "tool_calls", "length", "content_filter"].contains(reason) else {
                throw ModelProviderError.invalidResponse
            }
            return round
        }
        throw ModelProviderError.interrupted
    }

    private func execute(_ call: ProviderMessage.ToolCall, sessionId: String, turnId: String, isGroup: Bool,
                         structuredWeb: Bool = false, pythonRunner: LocalPythonRunHandler? = nil) async throws -> String {
        let name = call.function.name
        guard let args = try JSONSerialization.jsonObject(with: Data(call.function.arguments.utf8)) as? [String: Any] else {
            return "Invalid tool arguments."
        }
        func text(_ field: String) -> String {
            (args[field] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }

        var summary = call.function.arguments
        var connector: LocalAgentStore.ConnectorItem?
        var address: URL?
        switch name {
        case "js_eval":
            let result = await js.evaluate(text("script"))
            return result.error ?? (result.value.isEmpty ? result.logs.joined(separator: "\n") : result.value)
        case "python_exec":
            guard pythonRunner != nil else { return "本机 Python 运行时尚未连接。请重启 DSH 运行时后重试。" }
            let code = args["code"] as? String ?? ""
            guard !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  code.count <= 16_000, !code.unicodeScalars.contains(where: { $0.value == 0 }) else {
                return "Python 代码不能为空、不能包含 NUL，且最多 16,000 个字符。"
            }
            summary = "本机离线 Python 3.13 + NumPy（需批准；代码留在本机）\n每次在全新 WebAssembly Worker 中运行，45 秒上限、256 MiB Python 内存上限、32,000 字符输出上限。无宿主文件、网络、进程或 MCP 绑定。\n完整代码（\(code.count) 字符）：\n\(code)"
        case "memory_save":
            guard !text("title").isEmpty, !text("content").isEmpty else { return "Memory title and content are required." }
        case "group_todo_add":
            guard isGroup, !text("text").isEmpty else { return "This tool requires a group and a todo." }
        case "device_status": break
        case "remote_mcp_list":
            let targetName = text("connectorName")
            if targetName.isEmpty {
                let items = await store.listConnectors().map { c -> [String: Any] in
                    ["name": c["name"] as? String ?? "", "endpoint": c["endpoint"] as? String ?? "", "type": c["type"] as? String ?? ""]
                }
                if items.isEmpty { return "No Remote MCP connectors are configured yet. Ask the user to add one in Explore → Connector Marketplace." }
                return String(decoding: (try? JSONSerialization.data(withJSONObject: items, options: [.sortedKeys])) ?? Data(), as: UTF8.self)
            }
            let matches = await store.listConnectors().filter { ($0["name"] as? String)?.caseInsensitiveCompare(targetName) == .orderedSame }
            if matches.count == 1, let id = matches[0]["id"] as? String { connector = await store.connector(id: id) }
            guard let connector, connector.type == "remote-mcp" else { return "Connector '\(targetName)' not found. Call remote_mcp_list without arguments to see configured names." }
            summary = "发现远程 MCP 工具列表：\(connector.name)\n\(connector.endpoint)"
        case "remote_mcp_call":
            let matches = await store.listConnectors().filter { ($0["name"] as? String)?.caseInsensitiveCompare(text("connectorName")) == .orderedSame }
            if matches.count == 1, let id = matches[0]["id"] as? String { connector = await store.connector(id: id) }
            guard let connector, connector.type == "remote-mcp", !text("toolName").isEmpty else { return "Choose a configured MCP connector and tool." }
            summary = connector.endpoint + "\n" + summary
        case "web_search":
            let query = text("query")
            guard !query.isEmpty, query.unicodeScalars.count <= 300,
                  !query.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else {
                return "搜索关键词须为单行，且不能超过 300 个字符。"
            }
            summary = "发送到 api.deepseek.com 的搜索关键词：\n" + query
            let originalQuestion = args["originalQuestion"] as? String ?? ""
            if !originalQuestion.isEmpty {
                guard originalQuestion.unicodeScalars.count <= 128,
                      !originalQuestion.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else {
                    return "原始问题上下文格式无效，已阻止网页搜索。"
                }
                summary += "\n\n发送的原始问题上下文（空白已压缩，最多 128 个 Unicode 字符）：\n「" + originalQuestion + "」"
            }
        case "web_fetch":
            address = try? ModelProvider.httpsComponents(text("url")).url
            guard let address else { return "A valid HTTPS URL is required." }
            summary = address.absoluteString
        case "workspace_list":
            return listWorkspaceFiles(relativePath: text("path"))
        case "workspace_read":
            return readWorkspaceFile(relativePath: text("path"))
        case "workspace_write":
            let relPath = text("path")
            let content = args["content"] as? String ?? ""
            guard !relPath.isEmpty, sandboxedWorkspaceFileURL(relativePath: relPath, allowEmpty: false) != nil else {
                return "Invalid workspace file path. Use a relative path inside files/ without '..'."
            }
            let byteCount = content.utf8.count
            guard byteCount <= 262_144 else { return "Workspace file write exceeds 256 KB limit." }
            let preview = String(content.prefix(240))
            summary = "写入工作区文件：files/\(relPath)（\(byteCount) 字节）\n\(preview)"
        case "workspace_search":
            return searchWorkspaceFiles(query: text("query"), relativePath: text("path"))
        case "workspace_edit":
            let relPath = text("path")
            let oldText = args["old_text"] as? String ?? ""
            let newText = args["new_text"] as? String ?? ""
            guard !relPath.isEmpty, !oldText.isEmpty, sandboxedWorkspaceFileURL(relativePath: relPath, allowEmpty: false) != nil else {
                return "Invalid workspace_edit arguments. Provide a valid relative path inside files/ and non-empty old_text."
            }
            guard newText.utf8.count <= 262_144 else { return "Replacement text exceeds 256 KB limit." }
            summary = "编辑工作区文件：files/\(relPath)\n替换片段（\(oldText.count) 字符 → \(newText.count) 字符）"
        default: return "Unsupported tool."
        }

        let approvalId = UUID().uuidString
        let approved = await approvals.wait(id: approvalId, turnId: turnId, sessionId: sessionId) {
            emit("approval.request", ["approvalId": approvalId, "sessionId": sessionId, "turnId": turnId, "tool": name, "summary": summary])
        }
        emit("approval.closed", ["approvalId": approvalId])
        try Task.checkCancellation()
        guard approved else { return "The user did not approve this tool call." }

        do {
            switch name {
            case "memory_save":
                let requested = text("layer")
                let layer = ["pinned", "delta"].contains(requested) ? requested : "delta"
                _ = try await store.addMemory(botId: sessionId, title: text("title"), content: text("content"), layer: layer)
                return "Memory saved."
            case "group_todo_add":
                _ = try await store.addGroupTodo(groupId: sessionId, text: text("text"))
                return "Todo added."
            case "device_status":
                let status = await device.deviceStatus()
                return String(decoding: try JSONSerialization.data(withJSONObject: status), as: UTF8.self)
            case "remote_mcp_list":
                guard let connector, await store.connector(id: connector.id)?.endpoint == connector.endpoint else { return "Connector changed." }
                let tools = try await mcp.listTools(endpoint: connector.endpoint, keychainAccount: "connector:\(connector.id)")
                let payload = tools.prefix(60).map { t -> [String: Any] in
                    ["name": t.name, "description": String(t.description.prefix(240)), "inputSchema": String(t.inputSchemaJSON.prefix(800))]
                }
                return String(decoding: try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]), as: UTF8.self)
            case "remote_mcp_call":
                guard let connector, await store.connector(id: connector.id)?.endpoint == connector.endpoint else { return "Connector changed." }
                return try await mcp.callTool(endpoint: connector.endpoint, name: text("toolName"),
                    arguments: args["arguments"] as? [String: Any] ?? [:], keychainAccount: "connector:\(connector.id)")
            case "python_exec":
                guard let pythonRunner else { return "本机 Python 运行时尚未连接。请重启 DSH 运行时后重试。" }
                return try await pythonRunner(args["code"] as? String ?? "", sessionId, turnId)
            case "web_search": return "approved"
            case "web_fetch":
                guard let address else { return "Invalid URL." }
                let (bytes, response) = try await session.bytes(from: address)
                defer { bytes.task.cancel() }
                guard let http = response as? HTTPURLResponse else { throw ModelProviderError.invalidResponse }
                if !structuredWeb { try checkHTTP(http) }
                guard ["text/plain", "text/html"].contains(response.mimeType ?? "") else { return "Unsupported web content type." }
                var data = Data()
                for try await byte in bytes {
                    try Task.checkCancellation()
                    guard data.count < 1_500_000 else { throw ModelProviderError.responseTooLarge }
                    data.append(byte)
                }
                let plain = String(decoding: data, as: UTF8.self)
                    .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
                    .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                let content = String(plain.prefix(12_000))
                if !structuredWeb { return content }
                let result: [String: Any] = [
                    "url": http.url?.absoluteString ?? address.absoluteString, "statusCode": http.statusCode,
                    "body": ["kind": "text", "content": content], "truncated": plain.count > content.count
                ]
                return String(decoding: try JSONSerialization.data(withJSONObject: result), as: UTF8.self)
            case "workspace_write":
                return try writeWorkspaceFile(relativePath: text("path"), content: args["content"] as? String ?? "")
            case "workspace_edit":
                return try editWorkspaceFile(
                    relativePath: text("path"),
                    oldText: args["old_text"] as? String ?? "",
                    newText: args["new_text"] as? String ?? ""
                )
            default: return "Unsupported tool."
            }
        } catch {
            try Task.checkCancellation()
            return "Tool failed: \(error.localizedDescription)"
        }
    }

    private func workspaceFilesRoot() -> URL {
        let dir = workspaceRoot.appendingPathComponent("files", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func sandboxedWorkspaceFileURL(relativePath: String, allowEmpty: Bool) -> URL? {
        let normalized = relativePath.replacingOccurrences(of: "\\", with: "/").trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.isEmpty { return allowEmpty ? workspaceFilesRoot() : nil }
        if normalized.hasPrefix("/") || normalized.contains("\0") { return nil }
        let parts = normalized.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !parts.isEmpty, !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else { return nil }
        let base = workspaceFilesRoot().standardizedFileURL
        var target = base
        let fm = FileManager.default
        for part in parts {
            target = target.appendingPathComponent(part, isDirectory: false)
            if fm.fileExists(atPath: target.path),
               let attrs = try? fm.attributesOfItem(atPath: target.path),
               (attrs[.type] as? FileAttributeType) == .typeSymbolicLink {
                return nil
            }
        }
        let resolvedBase = base.resolvingSymlinksInPath().path
        let resolvedTarget = target.resolvingSymlinksInPath().path
        guard resolvedTarget == resolvedBase || resolvedTarget.hasPrefix(resolvedBase + "/") else { return nil }
        return target
    }

    private func listWorkspaceFiles(relativePath: String) -> String {
        guard let dir = sandboxedWorkspaceFileURL(relativePath: relativePath, allowEmpty: true) else {
            return "Invalid workspace path."
        }
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else {
            return "Workspace folder not found."
        }
        guard let entries = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey], options: [.skipsHiddenFiles]) else {
            return "Unable to read workspace folder."
        }
        let lines = entries.sorted { $0.lastPathComponent < $1.lastPathComponent }.prefix(200).compactMap { url -> String? in
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey])
            if values?.isSymbolicLink == true { return nil }
            if values?.isDirectory == true { return "[DIR] \(url.lastPathComponent)/" }
            let size = values?.fileSize ?? 0
            return "[FILE] \(url.lastPathComponent) (\(size) bytes)"
        }
        return lines.isEmpty ? "(files/ is empty)" : lines.joined(separator: "\n")
    }

    private func readWorkspaceFile(relativePath: String) -> String {
        guard let url = sandboxedWorkspaceFileURL(relativePath: relativePath, allowEmpty: false) else {
            return "Invalid workspace file path."
        }
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else {
            return "Workspace file not found."
        }
        guard let data = try? Data(contentsOf: url) else { return "Unable to read workspace file." }
        let maxRead = 65_536
        let slice = data.count > maxRead ? data.prefix(maxRead) : data
        guard let text = String(data: slice, encoding: .utf8) else {
            return "Workspace file is not UTF-8 text (\(data.count) bytes)."
        }
        return data.count > maxRead ? text + "\n…(truncated at 64 KB)" : text
    }

    private func writeWorkspaceFile(relativePath: String, content: String) throws -> String {
        guard let url = sandboxedWorkspaceFileURL(relativePath: relativePath, allowEmpty: false) else {
            return "Invalid workspace file path."
        }
        let data = Data(content.utf8)
        guard data.count <= 262_144 else { return "Workspace file write exceeds 256 KB limit." }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        return "Saved files/\(relativePath) (\(data.count) bytes)."
    }

    private func searchWorkspaceFiles(query: String, relativePath: String) -> String {
        guard !query.isEmpty, query.count <= 200 else { return "Provide a non-empty search query (up to 200 chars)." }
        guard let dir = sandboxedWorkspaceFileURL(relativePath: relativePath, allowEmpty: true) else {
            return "Invalid workspace path."
        }
        let fm = FileManager.default
        let basePath = workspaceFilesRoot().standardizedFileURL.path
        guard let enumerator = fm.enumerator(
            at: dir,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return "Unable to search workspace folder."
        }
        var matches: [String] = []
        var scannedFiles = 0
        for case let fileURL as URL in enumerator {
            guard scannedFiles < 300, matches.count < 50 else { break }
            let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            if values?.isSymbolicLink == true || values?.isRegularFile != true { continue }
            if (values?.fileSize ?? 0) > 262_144 { continue }
            scannedFiles += 1
            guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }
            let rel = fileURL.standardizedFileURL.path.replacingOccurrences(of: basePath + "/", with: "")
            for (idx, line) in content.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                if line.range(of: query, options: .caseInsensitive) != nil {
                    matches.append("\(rel):\(idx + 1): \(String(line.prefix(160)))")
                    if matches.count >= 50 { break }
                }
            }
        }
        return matches.isEmpty ? "No matches found in files/." : matches.joined(separator: "\n")
    }

    private func editWorkspaceFile(relativePath: String, oldText: String, newText: String) throws -> String {
        guard let url = sandboxedWorkspaceFileURL(relativePath: relativePath, allowEmpty: false) else {
            return "Invalid workspace file path."
        }
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else {
            return "Workspace file not found."
        }
        let existingData = try Data(contentsOf: url)
        guard existingData.count <= 262_144, let existing = String(data: existingData, encoding: .utf8) else {
            return "Workspace file is not an editable UTF-8 file (max 256 KB)."
        }
        guard let range = existing.range(of: oldText) else {
            return "Target old_text was not found in files/\(relativePath)."
        }
        var updated = existing
        updated.replaceSubrange(range, with: newText)
        let outData = Data(updated.utf8)
        guard outData.count <= 262_144 else { return "Edited file exceeds 256 KB limit." }
        try outData.write(to: url, options: .atomic)
        return "Updated files/\(relativePath) (\(outData.count) bytes)."
    }

    private func recordUsage(_ usage: [String: Any]) async {
        try? await store.recordUsage(input: usage["prompt_tokens"] as? Int ?? 0,
            cached: usage["prompt_cache_hit_tokens"] as? Int ?? 0, output: usage["completion_tokens"] as? Int ?? 0)
    }

    private func sideChat(_ params: [String: Any]) async throws -> [String: Any] {
        let provider = try ModelProvider(params["apiBaseURL"] as? String ?? "")
        try Task.checkCancellation()
        let key = try await modelKey(provider)
        try Task.checkCancellation()
        var body = try provider.modelFields(params["model"] as? String ?? "")
        body["stream"] = false
        let question = (params["question"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, question.utf8.count <= 65_536 else {
            throw IPCFrameError.remoteError(code: -32602, message: "侧边问题不能为空或超过 64 KB。")
        }
        let snapshot = params["context"] as? [[String: Any]] ?? []
        var contextMessages: [[String: Any]] = []
        for item in snapshot.suffix(8) {
            guard let role = item["role"] as? String, ["user", "assistant"].contains(role),
                  let content = item["content"] as? String, !content.isEmpty else { continue }
            contextMessages.append(["role": role, "content": String(content.prefix(2_000))])
        }
        body["messages"] = contextMessages + [["role": "user", "content": question]]
        let (data, response) = try await session.data(for: makeRequest(provider.endpoint("chat/completions"), key: key, fields: body))
        try Task.checkCancellation()
        try checkHTTP(response)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choice = (json["choices"] as? [[String: Any]])?.first,
              let reply = (choice["message"] as? [String: Any])?["content"] as? String, !reply.isEmpty else {
            throw ModelProviderError.invalidResponse
        }
        if let usage = json["usage"] as? [String: Any] { await recordUsage(usage) }
        return ["reply": reply]
    }

    private func listModels(_ params: [String: Any]) async throws -> [String: Any] {
        let provider = try ModelProvider(params["apiBaseURL"] as? String ?? "")
        let key = try await modelKey(provider)
        let start = Date()
        let (data, response) = try await session.data(for: makeRequest(provider.endpoint("models"), key: key))
        try checkHTTP(response)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["data"] as? [[String: Any]] else { throw ModelProviderError.invalidResponse }
        let ids = models.compactMap { $0["id"] as? String }
        return ["ok": true, "models": ids, "modelCount": ids.count, "latencyMs": Int(Date().timeIntervalSince(start) * 1000)]
    }

    private func checkHTTP(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw ModelProviderError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw ModelProviderError.http(http.statusCode) }
    }

    private func makeRequest(_ url: URL, key: String, fields: [String: Any]? = nil) throws -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        if let fields {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: fields)
        }
        return request
    }

    private func reply(_ id: Int, _ result: [String: Any]) {
        send(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private func fail(_ id: Int, code: Int = -32000, _ message: String) {
        send(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]])
    }

    private func emit(_ method: String, _ params: [String: Any]) {
        io.async {
            if let handler = self.nativeNotificationHandler {
                handler(method, params)
            } else {
                self.send(["jsonrpc": "2.0", "method": method, "params": params])
            }
        }
    }

    private func send(_ frame: [String: Any]) {
        guard let data = try? IPCFrameCodec.encode(frame) else { return }
        io.async { self.receiver?(data) }
    }
}

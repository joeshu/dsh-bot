import Foundation

/// Actor-isolated, disk-persisted on-device state for `LocalAgentTransport`.
/// Eliminates all Swift concurrency data races and persists memories, group goals/todos,
/// connectors, plugin index sources, experimental flags, and token usage across app launches.
private actor LocalAgentStore {
    struct PersistedState: Codable {
        var memoryJournal: [[String: String]] = []
        var groupTodos: [String: [TodoItem]] = [:]
        var groupGoals: [String: String] = [:]
        var connectors: [ConnectorItem] = []
        var activeIndexSourceId: String? = nil
        var registryUrl: String = "https://registry.npmmirror.com"
        var customIndexSources: [CustomIndexSource] = []
        var experimentalFlags: [String: Bool] = [:]
        var installedPlugins: [InstalledPluginItem] = []
        var totalTokens: Int = 0
        var cachedInputTokens: Int = 0
        var totalInputTokens: Int = 0
    }

    struct TodoItem: Codable { let id: String; let text: String; var done: Bool }
    struct ConnectorItem: Codable { let id: String; let type: String; let name: String; let endpoint: String }
    struct CustomIndexSource: Codable { let id: String; let name: String; let host: String; let url: String }
    struct InstalledPluginItem: Codable { let name: String; let version: String; let description: String; var enabled: Bool }

    private let stateURL: URL
    private var state: PersistedState
    private var activeStreamTasks: [String: Task<Void, Never>] = [:]

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let root = docs.appendingPathComponent("dsh-home", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        self.stateURL = root.appendingPathComponent("local-state.json")
        if let data = try? Data(contentsOf: stateURL),
           let decoded = try? JSONDecoder().decode(PersistedState.self, from: data) {
            self.state = decoded
        } else {
            self.state = PersistedState()
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(state) {
            try? data.write(to: stateURL, options: .atomic)
        }
    }

    func registerStream(turnId: String, task: Task<Void, Never>) {
        activeStreamTasks[turnId] = task
    }

    func removeStream(turnId: String) {
        activeStreamTasks.removeValue(forKey: turnId)
    }

    func abortStream(turnId: String) -> Bool {
        guard let task = activeStreamTasks.removeValue(forKey: turnId) else { return false }
        task.cancel()
        return true
    }

    func cancelAllStreams() {
        for (_, task) in activeStreamTasks { task.cancel() }
        activeStreamTasks.removeAll()
    }

    func recordUsage(input: Int, cached: Int, output: Int) {
        state.totalInputTokens += input
        state.cachedInputTokens += cached
        state.totalTokens += input + output
        save()
    }

    func usageSummary() -> [String: Any] {
        let rate = state.totalInputTokens > 0 ? Double(state.cachedInputTokens) / Double(state.totalInputTokens) : 0.0
        return ["totalTokens": state.totalTokens, "cacheHitRate": rate]
    }

    func diagnostics(dshVersion: String) -> [String: Any] {
        [
            "dshVersion": dshVersion,
            "ipcProtocolVersion": IPCFrameCodec.protocolVersion,
            "totalTokens": state.totalTokens,
            "connectorCount": state.connectors.count,
            "memoryJournalCount": state.memoryJournal.count,
            "installedPluginCount": state.installedPlugins.count
        ]
    }

    func addMemory(title: String, content: String, layer: String) -> [String: Any] {
        let jId = "jrn_\(UUID().uuidString.prefix(8))"
        let eId = "mem_\(UUID().uuidString.prefix(8))"
        state.memoryJournal.insert([
            "journalId": jId,
            "op": "add",
            "entryId": eId,
            "title": title,
            "content": content,
            "layer": layer,
            "at": ISO8601DateFormatter().string(from: Date())
        ], at: 0)
        save()
        return ["journalId": jId, "entryId": eId]
    }

    func pinnedMemoriesSummary() -> String {
        let pinned = state.memoryJournal.filter { $0["layer"] == "pinned" }
        guard !pinned.isEmpty else { return "" }
        return pinned.prefix(8).compactMap { rec in
            guard let t = rec["title"], let c = rec["content"], !c.isEmpty else { return nil }
            return "- \(t): \(c)"
        }.joined(separator: "\n")
    }

    func memoryJournal() -> [[String: String]] { state.memoryJournal }

    func undoMemory(journalId: String) {
        state.memoryJournal.removeAll { $0["journalId"] == journalId }
        save()
    }

    func groupState(groupId: String) -> [String: Any] {
        let todos = (state.groupTodos[groupId] ?? []).map { ["id": $0.id, "text": $0.text, "done": $0.done] as [String: Any] }
        return ["goal": ["title": state.groupGoals[groupId] ?? "未设定群目标"], "todos": todos]
    }

    func setGroupGoal(groupId: String, title: String) -> [String: Any] {
        state.groupGoals[groupId] = title
        save()
        return ["goal": ["title": title, "status": "active"]]
    }

    func addGroupTodo(groupId: String, text: String) -> [String: Any] {
        let item = TodoItem(id: "todo_\(UUID().uuidString.prefix(6))", text: text, done: false)
        state.groupTodos[groupId, default: []].append(item)
        save()
        return ["todo": ["id": item.id, "text": item.text, "done": item.done]]
    }

    func toggleGroupTodo(groupId: String, id: String, done: Bool) {
        if var list = state.groupTodos[groupId], let idx = list.firstIndex(where: { $0.id == id }) {
            list[idx].done = done
            state.groupTodos[groupId] = list
            save()
        }
    }

    func clearCompletedTodos(groupId: String) -> Int {
        guard let list = state.groupTodos[groupId] else { return 0 }
        let kept = list.filter { !$0.done }
        let removed = list.count - kept.count
        if removed > 0 {
            state.groupTodos[groupId] = kept
            save()
        }
        return removed
    }

    func currentRegistryUrl() -> String {
        state.registryUrl
    }

    func listConnectors() -> [[String: Any]] {
        state.connectors.map { ["id": $0.id, "type": $0.type, "name": $0.name, "endpoint": $0.endpoint] }
    }

    func upsertConnector(id: String?, type: String, name: String, endpoint: String) -> [String: Any] {
        let cid = id ?? "conn_\(UUID().uuidString.prefix(6))"
        state.connectors.removeAll { $0.id == cid }
        let entry = ConnectorItem(id: cid, type: type, name: name, endpoint: endpoint)
        state.connectors.append(entry)
        save()
        return ["id": cid, "type": type, "name": name, "endpoint": endpoint]
    }

    func deleteConnector(id: String) {
        state.connectors.removeAll { $0.id == id }
        save()
    }

    // --- Plugin Store & Community Index Sources ---
    func pluginsOverview() -> [String: Any] {
        let installed = state.installedPlugins.map {
            ["name": $0.name, "version": $0.version, "description": $0.description, "enabled": $0.enabled] as [String: Any]
        }
        let customSources = state.customIndexSources.map {
            ["id": $0.id, "name": $0.name, "host": $0.host, "url": $0.url] as [String: Any]
        }
        return [
            "installed": installed,
            "activeIndexSourceId": state.activeIndexSourceId ?? "",
            "customIndexSources": customSources,
            "experimentalFlags": state.experimentalFlags,
            "registryUrl": state.registryUrl
        ]
    }

    func setActiveIndexSource(_ sourceId: String?) {
        let trimmed = (sourceId ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        state.activeIndexSourceId = trimmed.isEmpty ? nil : trimmed
        save()
    }

    func addCustomIndexSource(url: String) {
        guard let parsed = URL(string: url), parsed.scheme == "https", let host = parsed.host else { return }
        let id = "custom-\(host)"
        state.customIndexSources.removeAll { $0.url == url }
        state.customIndexSources.append(CustomIndexSource(id: id, name: host, host: host, url: url))
        state.activeIndexSourceId = id
        save()
    }

    func activeIndexSourceURL() -> URL? {
        guard let id = state.activeIndexSourceId else { return nil }
        if id == "dsh-market" { return URL(string: "https://cdn.jsdelivr.net/gh/dsh-market/index@main/index.json") }
        if id == "dshfind" { return URL(string: "https://api.dshfind.com/v1/index.json") }
        if let custom = state.customIndexSources.first(where: { $0.id == id }) {
            return URL(string: custom.url)
        }
        return nil
    }

    func setRegistryUrl(_ url: String) {
        state.registryUrl = url
        save()
    }

    func setExperimental(id: String, enabled: Bool) {
        state.experimentalFlags[id] = enabled
        save()
    }

    func installPluginRecord(name: String, version: String, description: String) -> [String: Any] {
        state.installedPlugins.removeAll { $0.name == name }
        state.installedPlugins.append(InstalledPluginItem(name: name, version: version, description: description, enabled: true))
        save()
        return ["name": name, "version": version, "description": description, "enabled": true]
    }

    func togglePlugin(name: String, enabled: Bool) {
        if let idx = state.installedPlugins.firstIndex(where: { $0.name == name }) {
            state.installedPlugins[idx].enabled = enabled
            save()
        }
    }

    func uninstallPlugin(name: String) {
        state.installedPlugins.removeAll { $0.name == name }
        save()
    }
}

/// Race-free, disk-persisted on-device transport implementing the DS-Bot JSON-RPC 2.0 contract.
/// Supports real multi-turn DeepSeek / OpenAI-compatible HTTPS SSE streaming and live community plugin index discovery.
public final class LocalAgentTransport: IPCByteTransport {
    private var receiveHandler: ((Data) -> Void)?
    private let dshVersion: String
    private let keychain: KeychainBridge
    private let session: URLSession
    private let store = LocalAgentStore()
    private let jsc = JSCEmbeddedRuntime()
    private let deviceBridge = DeviceCapabilitiesBridge()
    private let mcpClient = RemoteMCPClient()
    private let decoder = IPCFrameDecoder()
    private let decoderQueue = DispatchQueue(label: "io.github.dsbot.localagent.ipc")
    private let emitQueue = DispatchQueue(label: "io.github.dsbot.localagent.emit")

    public init(dshVersion: String = KernelManager.baselineVersion, keychain: KeychainBridge = KeychainBridge()) {
        self.dshVersion = dshVersion
        self.keychain = keychain
        let cfg = URLSessionConfiguration.default
        cfg.waitsForConnectivity = true
        cfg.timeoutIntervalForRequest = 90
        self.session = URLSession(configuration: cfg)
    }

    public func setReceiveHandler(_ handler: @escaping (Data) -> Void) {
        self.receiveHandler = handler
        emitQueue.asyncAfter(deadline: .now() + 0.04) { [weak self] in
            guard let self else { return }
            self.emitNotification("kernel.ready", params: [
                "dshVersion": self.dshVersion,
                "ipcProtocolVersion": IPCFrameCodec.protocolVersion,
                "activeServices": ["sessionController", "sessionQuery", "sessionPersistence", "workspaceRegistry"]
            ])
        }
    }

    public func write(_ data: Data) {
        decoderQueue.async { [weak self] in
            guard let self, let messages = try? self.decoder.push(data) else { return }
            for msg in messages {
                guard let id = msg["id"] as? Int, let method = msg["method"] as? String else { continue }
                let params = msg["params"] as? [String: Any] ?? [:]
                Task { [weak self] in
                    await self?.handleRPC(id: id, method: method, params: params)
                }
            }
        }
    }

    public func close() {
        Task { await store.cancelAllStreams() }
        receiveHandler = nil
    }

    private func handleRPC(id: Int, method: String, params: [String: Any]) async {
        switch method {
        case "kernel.ping":
            reply(id: id, result: ["pong": true, "dshVersion": dshVersion, "ipcProtocolVersion": IPCFrameCodec.protocolVersion])
        case "kernel.diagnostics":
            reply(id: id, result: await store.diagnostics(dshVersion: dshVersion))
        case "chat.send":
            await handleChatSend(id: id, params: params)
        case "chat.abort":
            let aborted = await store.abortStream(turnId: params["turnId"] as? String ?? "")
            reply(id: id, result: ["found": aborted, "aborted": aborted])
        case "side.ask":
            await handleSideAsk(id: id, params: params)
        case "memory.add":
            let res = await store.addMemory(
                title: params["title"] as? String ?? "",
                content: params["content"] as? String ?? "",
                layer: params["layer"] as? String ?? "delta"
            )
            reply(id: id, result: res)
        case "memory.journal":
            reply(id: id, result: ["records": await store.memoryJournal()])
        case "memory.undo":
            await store.undoMemory(journalId: params["journalId"] as? String ?? "")
            reply(id: id, result: ["undone": true])
        case "group.state":
            reply(id: id, result: await store.groupState(groupId: params["groupId"] as? String ?? "default"))
        case "group.goal.set":
            reply(id: id, result: await store.setGroupGoal(groupId: params["groupId"] as? String ?? "default", title: params["title"] as? String ?? ""))
        case "group.todo.add":
            reply(id: id, result: await store.addGroupTodo(groupId: params["groupId"] as? String ?? "default", text: params["text"] as? String ?? ""))
        case "group.todo.toggle":
            await store.toggleGroupTodo(groupId: params["groupId"] as? String ?? "default", id: params["id"] as? String ?? "", done: params["done"] as? Bool ?? false)
            reply(id: id, result: ["found": true])
        case "group.todo.clearCompleted":
            let removed = await store.clearCompletedTodos(groupId: params["groupId"] as? String ?? "default")
            reply(id: id, result: ["removed": removed])
        case "connectors.list":
            reply(id: id, result: ["connectors": await store.listConnectors()])
        case "connectors.upsert":
            let c = await store.upsertConnector(
                id: params["id"] as? String,
                type: params["type"] as? String ?? "remote-mcp",
                name: params["name"] as? String ?? "Connector",
                endpoint: params["endpoint"] as? String ?? ""
            )
            reply(id: id, result: ["connector": c])
        case "connectors.delete":
            await store.deleteConnector(id: params["id"] as? String ?? "")
            reply(id: id, result: ["removed": true])
        case "usage.summary":
            reply(id: id, result: await store.usageSummary())
        case "plugins.overview":
            reply(id: id, result: await store.pluginsOverview())
        case "plugins.index.setActive":
            await store.setActiveIndexSource(params["sourceId"] as? String)
            reply(id: id, result: ["ok": true])
        case "plugins.index.addCustom":
            await store.addCustomIndexSource(url: params["url"] as? String ?? "")
            reply(id: id, result: ["ok": true])
        case "plugins.discover":
            await handlePluginsDiscover(id: id)
        case "plugins.experimental.toggle":
            await store.setExperimental(id: params["id"] as? String ?? "", enabled: params["enabled"] as? Bool ?? false)
            reply(id: id, result: ["ok": true])
        case "plugins.install":
            await handlePluginInstall(id: id, params: params)
        case "plugins.installLocal":
            let path = params["folderPath"] as? String ?? ""
            let name = URL(fileURLWithPath: path).lastPathComponent
            let rec = await store.installPluginRecord(name: name, version: "local", description: "Installed from local folder")
            reply(id: id, result: ["plugin": rec])
        case "plugins.toggle":
            await store.togglePlugin(name: params["name"] as? String ?? "", enabled: params["enabled"] as? Bool ?? true)
            reply(id: id, result: ["ok": true])
        case "plugins.uninstall":
            await store.uninstallPlugin(name: params["name"] as? String ?? "")
            reply(id: id, result: ["removed": true])
        case "plugins.setRegistry":
            let url = params["url"] as? String ?? "https://registry.npmmirror.com"
            await store.setRegistryUrl(url)
            reply(id: id, result: ["registryUrl": url])
        case "approval.respond":
            reply(id: id, result: ["found": true, "approved": params["approved"] as? Bool ?? false])
        case "kernel.suspend":
            await store.cancelAllStreams()
            reply(id: id, result: ["suspended": true])
        case "kernel.resume":
            reply(id: id, result: ["suspended": false])
        case "tools.jsEval":
            let code = params["script"] as? String ?? ""
            let res = jsc.evaluate(script: code)
            reply(id: id, result: ["ok": res.ok, "value": res.value, "logs": res.logs, "error": res.error ?? ""])
        case "device.status":
            reply(id: id, result: deviceBridge.deviceStatus())
        case "device.speak":
            deviceBridge.speak(text: params["text"] as? String ?? "", language: params["language"] as? String ?? "zh-CN")
            reply(id: id, result: ["ok": true])
        case "device.notify":
            let ok = await deviceBridge.scheduleLocalNotification(
                title: params["title"] as? String ?? "DS Bot",
                body: params["body"] as? String ?? "",
                delaySeconds: params["delaySeconds"] as? Double ?? 5
            )
            reply(id: id, result: ["scheduled": ok])
        case "mcp.listTools":
            let endpoint = params["endpoint"] as? String ?? ""
            let account = params["keychainAccount"] as? String
            do {
                let tools = try await mcpClient.listTools(endpoint: endpoint, keychainAccount: account)
                let serialized = tools.map { ["name": $0.name, "description": $0.description] }
                reply(id: id, result: ["ok": true, "tools": serialized])
            } catch {
                reply(id: id, result: ["ok": false, "tools": [], "error": error.localizedDescription])
            }
        case "mcp.callTool":
            let endpoint = params["endpoint"] as? String ?? ""
            let name = params["name"] as? String ?? ""
            let args = params["arguments"] as? [String: Any] ?? [:]
            let account = params["keychainAccount"] as? String
            do {
                let output = try await mcpClient.callTool(endpoint: endpoint, name: name, arguments: args, keychainAccount: account)
                reply(id: id, result: ["ok": true, "output": output])
            } catch {
                reply(id: id, result: ["ok": false, "error": error.localizedDescription])
            }
        case "models.test":
            await handleModelsTest(id: id, params: params)
        case "kernel.shutdown":
            await store.cancelAllStreams()
            reply(id: id, result: ["shutdown": true])
        default:
            reply(id: id, result: ["ok": true])
        }
    }

    private func handlePluginsDiscover(id: Int) async {
        guard let url = await store.activeIndexSourceURL() else {
            reply(id: id, result: ["items": []])
            return
        }
        do {
            let (data, _) = try await session.data(from: url)
            let json = try JSONSerialization.jsonObject(with: data)
            let list: [[String: Any]]
            if let arr = json as? [[String: Any]] {
                list = arr
            } else if let dict = json as? [String: Any] {
                list = (dict["plugins"] as? [[String: Any]])
                    ?? (dict["packages"] as? [[String: Any]])
                    ?? (dict["items"] as? [[String: Any]])
                    ?? []
            } else {
                list = []
            }
            reply(id: id, result: ["items": list])
        } catch {
            reply(id: id, result: ["items": [], "error": error.localizedDescription])
        }
    }

    private func handleChatSend(id: Int, params: [String: Any]) async {
        let sessionId = params["sessionId"] as? String ?? "main"
        let text = params["text"] as? String ?? ""
        let model = params["model"] as? String ?? "deepseek-chat"
        let baseURLRaw = (params["apiBaseURL"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseURL = (baseURLRaw?.isEmpty == false ? baseURLRaw! : "https://api.deepseek.com").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let history = params["history"] as? [[String: String]] ?? []
        let requestedTurn = (params["turnId"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let turnId = (requestedTurn?.isEmpty == false) ? requestedTurn! : "turn_\(UUID().uuidString.prefix(8))"

        let keyObj = try? await keychain.getSecret(account: "deepseek_api_key", requireBiometrics: false)
        let apiKey = (keyObj?["value"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if apiKey.isEmpty {
            emitNotification("chat.delta", params: [
                "sessionId": sessionId,
                "turnId": turnId,
                "reasoning": "检测到 iOS Keychain 尚未配置 API Key，进入快速引导。",
                "content": "## 配置 API Key 后即可独立流式对话\n请前往底部 **设置 → DeepSeek API Key** 保存 `sk-...`（加密存储于 iOS Keychain），也支持自定义 OpenAI 兼容 Base URL。\n\n### 当前内置能力\n- 内置锁定 **DSH \(dshVersion)** 可热换内核\n- 支持四层记忆撤销、群 Goal/待办、`/side` 侧边对话与社区插件索引源"
            ])
            emitNotification("chat.done", params: ["sessionId": sessionId, "turnId": turnId, "status": "completed"])
            reply(id: id, result: ["turnId": turnId, "status": "completed"])
            return
        }

        let pinnedMem = await store.pinnedMemoriesSummary()
        let customPrompt = (params["systemPrompt"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        var sysPrompt = "You are DS Bot running standalone on iOS with embedded DSH \(dshVersion). Reply concisely in the user's language."
        if !customPrompt.isEmpty {
            sysPrompt += "\n\nBot Persona & Instructions:\n\(customPrompt)"
        }
        if !pinnedMem.isEmpty {
            sysPrompt += "\n\nPinned User Memory:\n\(pinnedMem)"
        }

        var apiMessages: [[String: Any]] = [["role": "system", "content": sysPrompt]]
        for item in history.suffix(16) {
            if let r = item["role"], let c = item["content"], !c.isEmpty {
                apiMessages.append(["role": r, "content": c])
            }
        }
        if (apiMessages.last?["content"] as? String) != text {
            apiMessages.append(["role": "user", "content": text])
        }

        let builtInTools: [[String: Any]] = [
            [
                "type": "function",
                "function": [
                    "name": "js_eval",
                    "description": "Execute JavaScript in the isolated on-device JavaScriptCore sandbox for math, JSON/CSV processing, or data transforms.",
                    "parameters": ["type": "object", "properties": ["script": ["type": "string"]], "required": ["script"]]
                ]
            ],
            [
                "type": "function",
                "function": [
                    "name": "memory_save",
                    "description": "Persist an important user preference or fact into the 4-layer on-device memory store.",
                    "parameters": ["type": "object", "properties": ["title": ["type": "string"], "content": ["type": "string"], "layer": ["type": "string"]], "required": ["title", "content"]]
                ]
            ],
            [
                "type": "function",
                "function": [
                    "name": "group_todo_add",
                    "description": "Add a concrete action item to the current session/group shared todo list.",
                    "parameters": ["type": "object", "properties": ["text": ["type": "string"]], "required": ["text"]]
                ]
            ],
            [
                "type": "function",
                "function": [
                    "name": "device_status",
                    "description": "Read current iOS device battery level, thermal state, low power mode, and OS version.",
                    "parameters": ["type": "object", "properties": [:]]
                ]
            ],
            [
                "type": "function",
                "function": [
                    "name": "remote_mcp_call",
                    "description": "Invoke a tool on a configured Remote MCP connector by connectorName, toolName, and arguments.",
                    "parameters": ["type": "object", "properties": ["connectorName": ["type": "string"], "toolName": ["type": "string"], "arguments": ["type": "object"]], "required": ["connectorName", "toolName"]]
                ]
            ],
            [
                "type": "function",
                "function": [
                    "name": "web_fetch",
                    "description": "Fetch a public HTTPS URL and extract plain readable text (up to 12 KB).",
                    "parameters": ["type": "object", "properties": ["url": ["type": "string"]], "required": ["url"]]
                ]
            ]
        ]

        let task = Task { [weak self] in
            guard let self else { return }
            defer { Task { await self.store.removeStream(turnId: turnId) } }
            do {
                guard let endpoint = URL(string: "\(baseURL)/chat/completions") else {
                    throw NetworkBridgeError.invalidURL(baseURL)
                }

                // Autonomous multi-step Agent Tool-Calling Loop (max 6 rounds per turn)
                for _ in 0..<6 {
                    if Task.isCancelled { break }
                    var req = URLRequest(url: endpoint)
                    req.httpMethod = "POST"
                    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                    var body: [String: Any] = [
                        "model": model,
                        "stream": true,
                        "stream_options": ["include_usage": true],
                        "messages": apiMessages
                    ]
                    body["tools"] = builtInTools
                    req.httpBody = try JSONSerialization.data(withJSONObject: body)

                    var roundContent = ""
                    var roundReasoning = ""
                    var toolCallsByIndex: [Int: (id: String, name: String, args: String)] = [:]

                    // Bounded pre-first-token retry (max 2 retries: 1s -> 2s) for transient 429/502/503/504 or cellular drops
                    var bytesResult: (URLSession.AsyncBytes, URLResponse)?
                    let retryableStatuses: Set<Int> = [429, 502, 503, 504]
                    for attempt in 0..<3 {
                        if Task.isCancelled { break }
                        do {
                            let (b, resp) = try await self.session.bytes(for: req)
                            if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                                if retryableStatuses.contains(http.statusCode) && attempt < 2 {
                                    let waitSec = attempt + 1
                                    self.emitNotification("chat.delta", params: [
                                        "sessionId": sessionId,
                                        "turnId": turnId,
                                        "reasoning": "[网络重试] 服务端返回 HTTP \(http.statusCode)，\(waitSec) 秒后自动重试 (\(attempt + 1)/2)…\n"
                                    ])
                                    try await Task.sleep(nanoseconds: UInt64(waitSec) * 1_000_000_000)
                                    continue
                                }
                                var errSnippet = ""
                                for try await errLine in b.lines {
                                    errSnippet += errLine
                                    if errSnippet.count > 600 { break }
                                }
                                let hint: String
                                switch http.statusCode {
                                case 401: hint = "HTTP 401：API Key 无效或已失效，请在「设置」检查 Keychain 密钥。"
                                case 402: hint = "HTTP 402：模型服务商账户余额不足。"
                                case 429: hint = "HTTP 429：请求过于频繁，请稍后重试。"
                                default: hint = "HTTP \(http.statusCode)：\(errSnippet.prefix(240))"
                                }
                                throw IPCFrameError.remoteError(code: http.statusCode, message: hint)
                            }
                            bytesResult = (b, resp)
                            break
                        } catch let urlErr as URLError where attempt < 2 && (urlErr.code == .networkConnectionLost || urlErr.code == .timedOut || urlErr.code == .notConnectedToInternet) {
                            let waitSec = attempt + 1
                            self.emitNotification("chat.delta", params: [
                                "sessionId": sessionId,
                                "turnId": turnId,
                                "reasoning": "[网络重试] 连接波动（\(urlErr.localizedDescription)），\(waitSec) 秒后自动重试 (\(attempt + 1)/2)…\n"
                            ])
                            try await Task.sleep(nanoseconds: UInt64(waitSec) * 1_000_000_000)
                        }
                    }
                    guard let (bytes, _) = bytesResult else { break }
                    for try await line in bytes.lines {
                        if Task.isCancelled { break }
                        guard line.hasPrefix("data:") else { continue }
                        let payload = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" { break }
                        guard let jsonData = payload.data(using: .utf8),
                              let obj = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else { continue }
                        if let usage = obj["usage"] as? [String: Any] {
                            await self.store.recordUsage(
                                input: usage["prompt_tokens"] as? Int ?? 0,
                                cached: usage["prompt_cache_hit_tokens"] as? Int ?? 0,
                                output: usage["completion_tokens"] as? Int ?? 0
                            )
                        }
                        if let choices = obj["choices"] as? [[String: Any]],
                           let delta = choices.first?["delta"] as? [String: Any] {
                            var outDelta: [String: Any] = ["sessionId": sessionId, "turnId": turnId]
                            if let r = delta["reasoning_content"] as? String, !r.isEmpty {
                                roundReasoning += r
                                outDelta["reasoning"] = r
                            }
                            if let c = delta["content"] as? String, !c.isEmpty {
                                roundContent += c
                                outDelta["content"] = c
                            }
                            if outDelta.count > 2 {
                                self.emitNotification("chat.delta", params: outDelta)
                            }
                            if let tcDeltas = delta["tool_calls"] as? [[String: Any]] {
                                for tc in tcDeltas {
                                    let idx = tc["index"] as? Int ?? 0
                                    var cur = toolCallsByIndex[idx] ?? (id: "", name: "", args: "")
                                    if let cid = tc["id"] as? String, !cid.isEmpty { cur.id = cid }
                                    if let fn = tc["function"] as? [String: Any] {
                                        if let n = fn["name"] as? String { cur.name += n }
                                        if let a = fn["arguments"] as? String { cur.args += a }
                                    }
                                    toolCallsByIndex[idx] = cur
                                }
                            }
                        }
                    }

                    if toolCallsByIndex.isEmpty || Task.isCancelled { break }

                    let orderedCalls = toolCallsByIndex.keys.sorted().compactMap { toolCallsByIndex[$0] }
                    let serializedCalls: [[String: Any]] = orderedCalls.map { tc in
                        [
                            "id": tc.id.isEmpty ? "call_\(UUID().uuidString.prefix(6))" : tc.id,
                            "type": "function",
                            "function": ["name": tc.name, "arguments": tc.args]
                        ]
                    }
                    var assistantMsg: [String: Any] = ["role": "assistant", "content": roundContent, "tool_calls": serializedCalls]
                    if !roundReasoning.isEmpty {
                        assistantMsg["reasoning_content"] = roundReasoning
                    }
                    apiMessages.append(assistantMsg)

                    for (i, tc) in orderedCalls.enumerated() {
                        let callId = (serializedCalls[i]["id"] as? String) ?? "call_\(i)"
                        self.emitNotification("chat.delta", params: [
                            "sessionId": sessionId,
                            "turnId": turnId,
                            "reasoning": "\n[Tool] \(tc.name)(\(tc.args.prefix(120)))\n"
                        ])
                        let toolOutput = await self.executeBuiltInTool(name: tc.name, argsJSON: tc.args, sessionId: sessionId)
                        self.emitNotification("chat.delta", params: [
                            "sessionId": sessionId,
                            "turnId": turnId,
                            "reasoning": "[Result] \(toolOutput.prefix(160))\n"
                        ])
                        apiMessages.append(["role": "tool", "tool_call_id": callId, "content": toolOutput])
                    }
                }

                self.emitNotification("chat.done", params: ["sessionId": sessionId, "turnId": turnId, "status": Task.isCancelled ? "aborted" : "completed"])
                self.reply(id: id, result: ["turnId": turnId, "status": Task.isCancelled ? "aborted" : "completed"])
            } catch {
                let isCancel = Task.isCancelled || (error as? URLError)?.code == .cancelled
                if isCancel {
                    self.emitNotification("chat.done", params: ["sessionId": sessionId, "turnId": turnId, "status": "aborted"])
                    self.reply(id: id, result: ["turnId": turnId, "status": "aborted"])
                } else {
                    self.emitNotification("chat.delta", params: ["sessionId": sessionId, "turnId": turnId, "content": "\n[请求失败：\(error.localizedDescription)]"])
                    self.emitNotification("chat.done", params: ["sessionId": sessionId, "turnId": turnId, "status": "error", "error": error.localizedDescription])
                    self.reply(id: id, result: ["turnId": turnId, "status": "error"])
                }
            }
        }
        await store.registerStream(turnId: turnId, task: task)
    }

    private func executeBuiltInTool(name: String, argsJSON: String, sessionId: String) async -> String {
        let args = (argsJSON.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }) ?? [:]
        switch name {
        case "js_eval":
            let res = jsc.evaluate(script: args["script"] as? String ?? "")
            return res.ok ? (res.value.isEmpty ? res.logs.joined(separator: "\n") : res.value) : "Error: \(res.error ?? "failed")"
        case "memory_save":
            let r = await store.addMemory(
                title: args["title"] as? String ?? "Note",
                content: args["content"] as? String ?? "",
                layer: args["layer"] as? String ?? "pinned"
            )
            return "Saved memory: \(r["entryId"] ?? "")"
        case "group_todo_add":
            let r = await store.addGroupTodo(groupId: sessionId, text: args["text"] as? String ?? "")
            return "Added todo: \(r)"
        case "device_status":
            let st = deviceBridge.deviceStatus()
            if let d = try? JSONSerialization.data(withJSONObject: st), let s = String(data: d, encoding: .utf8) { return s }
            return "{}"
        case "remote_mcp_call":
            let cname = args["connectorName"] as? String ?? ""
            let tname = args["toolName"] as? String ?? ""
            let targs = args["arguments"] as? [String: Any] ?? [:]
            let conns = await store.listConnectors()
            guard let target = conns.first(where: { ($0["name"] as? String)?.caseInsensitiveCompare(cname) == .orderedSame }),
                  let ep = target["endpoint"] as? String,
                  let cid = target["id"] as? String else {
                return "Error: Remote MCP connector '\(cname)' not found."
            }
            do {
                return try await mcpClient.callTool(endpoint: ep, name: tname, arguments: targs, keychainAccount: "connector:\(cid)")
            } catch {
                return "MCP call failed: \(error.localizedDescription)"
            }
        case "web_fetch":
            guard let raw = args["url"] as? String, let url = URL(string: raw), url.scheme == "https",
                  let host = url.host?.lowercased(),
                  host != "localhost", !host.hasPrefix("127."), !host.hasPrefix("169.254.") else {
                return "Error: web_fetch requires a public https:// URL."
            }
            do {
                let (data, _) = try await session.data(from: url)
                guard data.count <= 1_500_000 else { return "Error: response exceeds 1.5 MB limit." }
                let html = String(data: data, encoding: .utf8) ?? ""
                let stripped = html.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
                    .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return String(stripped.prefix(12_000))
            } catch {
                return "Error fetching URL: \(error.localizedDescription)"
            }
        default:
            return "Unsupported tool: \(name)"
        }
    }

    private func handleSideAsk(id: Int, params: [String: Any]) async {
        let q = (params["question"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let baseURLRaw = (params["apiBaseURL"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseURL = (baseURLRaw?.isEmpty == false ? baseURLRaw! : "https://api.deepseek.com").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let keyObj = try? await keychain.getSecret(account: "deepseek_api_key", requireBiometrics: false)
        let apiKey = (keyObj?["value"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if apiKey.isEmpty {
            reply(id: id, result: ["reply": "【Side Chat · 无工具模式】请先在「设置 → DeepSeek API Key」保存密钥后即可独立问答（不中断主回合）。"])
            return
        }

        guard let endpoint = URL(string: "\(baseURL)/chat/completions") else {
            reply(id: id, result: ["reply": "Side Chat 请求失败：Base URL 格式无效。"])
            return
        }
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let body: [String: Any] = [
            "model": "deepseek-chat",
            "stream": false,
            "messages": [
                ["role": "system", "content": "You are DS Bot Side Chat (tool-free mode). Answer briefly without invoking any tools."],
                ["role": "user", "content": q]
            ]
        ]
        do {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, response) = try await session.data(for: req)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                reply(id: id, result: ["reply": "Side Chat 请求失败（HTTP \(http.statusCode)）。"])
                return
            }
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let choices = obj["choices"] as? [[String: Any]],
               let msg = choices.first?["message"] as? [String: Any],
               let content = msg["content"] as? String {
                if let usage = obj["usage"] as? [String: Any] {
                    await store.recordUsage(
                        input: usage["prompt_tokens"] as? Int ?? 0,
                        cached: usage["prompt_cache_hit_tokens"] as? Int ?? 0,
                        output: usage["completion_tokens"] as? Int ?? 0
                    )
                }
                reply(id: id, result: ["reply": content])
                return
            }
            reply(id: id, result: ["reply": "Side Chat 未收到有效响应内容。"])
        } catch {
            reply(id: id, result: ["reply": "Side Chat 网络错误：\(error.localizedDescription)"])
        }
    }

    private func handlePluginInstall(id: Int, params: [String: Any]) async {
        let spec = (params["name"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !spec.isEmpty else {
            replyError(id: id, code: -32602, message: "插件包名或 GitHub 地址不能为空。")
            return
        }

        let coreBuiltins: Set<String> = [
            "@deepseek-ai/dsh", "@deepseek-ai/dsh-app-boot", "@deepseek-ai/dsh-base",
            "@deepseek-ai/dsh-session-query-sqlite"
        ]
        let desktopOnly: Set<String> = [
            "@deepseek-ai/dsh-web-app", "@deepseek-ai/dsh-bash-local", "@deepseek-ai/dsh-computer-use",
            "@deepseek-ai/dsh-cua", "@deepseek-ai/dsh-experimental-cua-macos", "@deepseek-ai/dsh-skill-office",
            "@deepseek-ai/libreoffice-kit", "playwright-core", "node-pty", "sharp", "koffi", "pnpm"
        ]

        // GitHub URL install path
        if spec.hasPrefix("https://github.com/") || spec.hasPrefix("github:") {
            let cleanName = spec.split(separator: "/").last.map(String.init)?.replacingOccurrences(of: ".git", with: "") ?? spec
            let rec = await store.installPluginRecord(name: cleanName, version: "github", description: "Installed from GitHub: \(spec)")
            reply(id: id, result: ["plugin": rec])
            return
        }

        if coreBuiltins.contains(spec) {
            replyError(id: id, code: -32010, message: "「\(spec)」已内置于锁定内核 DSH \(dshVersion)，禁止覆盖安装（#13730）。")
            return
        }
        if desktopOnly.contains(spec) {
            replyError(id: id, code: -32011, message: "「\(spec)」为桌面端专用模块，iOS 沙盒不支持本地进程或原生扩展。")
            return
        }

        // Fetch real npm metadata from active registry (npmmirror / npmjs) and validate DSH 0.2.2-rc.5 compatibility
        let registry = await store.currentRegistryUrl().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let encoded = spec.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? spec
        var resolvedVersion = "latest"
        var resolvedDesc = "DSH Plugin"

        if let metaURL = URL(string: "\(registry)/\(encoded)/latest") {
            do {
                let (data, resp) = try await session.data(from: metaURL)
                if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    replyError(id: id, code: -32012, message: "无法从镜像源获取「\(spec)」（HTTP \(http.statusCode)）。")
                    return
                }
                if let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    resolvedVersion = manifest["version"] as? String ?? "latest"
                    resolvedDesc = manifest["description"] as? String ?? "DSH Plugin"

                    // Guard #13792: broken experimental session-search on 0.2.2-rc.5
                    if spec == "@deepseek-ai/dsh-experimental-session-search" && dshVersion == "0.2.2-rc.5" && resolvedVersion.hasPrefix("0.2.1-") {
                        replyError(id: id, code: -32013, message: "已拦截：「\(spec)@\(resolvedVersion)」在 DSH 0.2.2-rc.5 上会导致工作区选择器异常（#13792）。")
                        return
                    }
                    if (manifest["gypfile"] as? Bool) == true {
                        replyError(id: id, code: -32011, message: "已拦截：「\(spec)」需要 node-gyp 原生编译，不兼容 iOS 沙盒。")
                        return
                    }
                    if let engines = manifest["engines"] as? [String: Any],
                       let dshRange = engines["dsh"] as? String, !dshRange.trimmingCharacters(in: .whitespaces).isEmpty {
                        let branches = dshRange.components(separatedBy: "||").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                        let exactPattern = try? NSRegularExpression(pattern: "^\\d+\\.\\d+\\.\\d+(?:-[0-9A-Za-z.-]+)?$")
                        let allExact = !branches.isEmpty && branches.allSatisfy { b in
                            exactPattern?.firstMatch(in: b, range: NSRange(b.startIndex..., in: b)) != nil
                        }
                        if allExact && !branches.contains(dshVersion) {
                            replyError(id: id, code: -32014, message: "版本不兼容：「\(spec)」声明 engines.dsh=\"\(dshRange)\"，不包含当前内核 DSH \(dshVersion)。")
                            return
                        }
                    }
                    if let peers = manifest["peerDependencies"] as? [String: Any] {
                        for (peerName, rawRange) in peers where peerName.hasPrefix("@deepseek-ai/dsh") {
                            if let range = rawRange as? String {
                                let trimmed = range.trimmingCharacters(in: .whitespaces)
                                let exactPattern = try? NSRegularExpression(pattern: "^\\d+\\.\\d+\\.\\d+(?:-[0-9A-Za-z.-]+)?$")
                                let isExact = exactPattern?.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)) != nil
                                if isExact && trimmed != dshVersion {
                                    replyError(id: id, code: -32014, message: "版本不兼容：「\(spec)」强锁定 \(peerName)@\(trimmed)，与当前内核 DSH \(dshVersion) 冲突（#13798）。")
                                    return
                                }
                            }
                        }
                    }
                }
            } catch {
                replyError(id: id, code: -32015, message: "插件元数据拉取失败：\(error.localizedDescription)")
                return
            }
        }

        let rec = await store.installPluginRecord(name: spec, version: resolvedVersion, description: resolvedDesc)
        reply(id: id, result: ["plugin": rec])
    }

    private func handleModelsTest(id: Int, params: [String: Any]) async {
        let baseURLRaw = (params["apiBaseURL"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseURL = (baseURLRaw?.isEmpty == false ? baseURLRaw! : "https://api.deepseek.com").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let keyObj = try? await keychain.getSecret(account: "deepseek_api_key", requireBiometrics: false)
        let apiKey = (keyObj?["value"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !apiKey.isEmpty else {
            reply(id: id, result: ["ok": false, "error": "尚未在 Keychain 保存 API Key。"])
            return
        }
        guard let url = URL(string: "\(baseURL)/models") else {
            reply(id: id, result: ["ok": false, "error": "Base URL 格式无效。"])
            return
        }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let t0 = Date()
        do {
            let (data, resp) = try await session.data(for: req)
            let latencyMs = Int(Date().timeIntervalSince(t0) * 1000)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status) else {
                reply(id: id, result: ["ok": false, "statusCode": status, "latencyMs": latencyMs, "error": "HTTP \(status)"])
                return
            }
            var modelCount = 0
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let list = obj["data"] as? [[String: Any]] {
                modelCount = list.count
            }
            reply(id: id, result: ["ok": true, "statusCode": status, "latencyMs": latencyMs, "modelCount": modelCount])
        } catch {
            reply(id: id, result: ["ok": false, "error": error.localizedDescription])
        }
    }

    private func replyError(id: Int, code: Int, message: String) {
        guard let frame = try? IPCFrameCodec.encode(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]]) else { return }
        emitQueue.async { [weak self] in self?.receiveHandler?(frame) }
    }

    private func reply(id: Int, result: [String: Any]) {
        guard let frame = try? IPCFrameCodec.encode(["jsonrpc": "2.0", "id": id, "result": result]) else { return }
        emitQueue.async { [weak self] in self?.receiveHandler?(frame) }
    }

    private func emitNotification(_ method: String, params: [String: Any]) {
        guard let frame = try? IPCFrameCodec.encode(["jsonrpc": "2.0", "method": method, "params": params]) else { return }
        emitQueue.async { [weak self] in self?.receiveHandler?(frame) }
    }
}

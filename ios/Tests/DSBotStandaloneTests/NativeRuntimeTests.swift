import XCTest
@testable import DSBotStandalone

final class NativeRuntimeTests: XCTestCase {
    func testIPCDecoderHandlesFragmentedAndAlignedFrames() throws {
        let frames = try ["agent.info", "usage.summary"].map {
            try IPCFrameCodec.encode(["jsonrpc": "2.0", "id": 1, "method": $0])
        }
        let data = frames.reduce(into: Data()) { $0.append($1) }
        let decoder = IPCFrameDecoder()
        var methods: [String] = []
        for offset in stride(from: 0, to: data.count, by: 5) {
            methods += try decoder.push(data.subdata(in: offset..<min(offset + 5, data.count))).compactMap { $0["method"] as? String }
        }
        XCTAssertEqual(methods, ["agent.info", "usage.summary"])
        XCTAssertEqual(decoder.pendingBytes, 0)
    }

    func testModelSelectionAndEndpointBinding() throws {
        let official = try ModelProvider("https://API.DeepSeek.COM:443/v1/")
        let custom = try ModelProvider("https://example.test/gateway/v1/")
        XCTAssertEqual(official.endpoint("chat/completions").absoluteString, "https://api.deepseek.com/chat/completions")
        XCTAssertEqual(try official.modelFields("deepseek-chat")["model"] as? String, "deepseek-flash")
        XCTAssertEqual(try official.modelFields("deepseek-reasoner")["thinking"] as? [String: String], ["type": "enabled"])
        XCTAssertEqual(try custom.modelFields("deepseek-reasoner")["model"] as? String, "deepseek-reasoner")
        XCTAssertEqual(custom.endpoint("models").absoluteString, "https://example.test/gateway/v1/models")
        XCTAssertThrowsError(try ModelProvider("https://user:pass@example.test"))
        XCTAssertThrowsError(try ModelProvider("http://example.test/v1"))
    }

    func testParserHandlesMultilineSSEAndKeepAlives() throws {
        var events = ServerSentEvents()
        XCTAssertNil(try events.append(": keep alive"))
        XCTAssertNil(try events.append(#"data: {"choices":[{"delta":{"reasoning_content":"思考","#))
        XCTAssertNil(try events.append(#"data: "content":"回答"},"finish_reason":"stop"}]}"#))
        let event = try XCTUnwrap(events.append(""))
        var round = CompletionRound()
        let delta = try round.consume(event)
        XCTAssertEqual(delta.content, "回答")
        XCTAssertEqual(delta.reasoning, "思考")
        XCTAssertEqual(round.finishReason, "stop")
        XCTAssertFalse(round.done)
        _ = try round.consume("[DONE]")
        XCTAssertTrue(round.done)
        XCTAssertThrowsError(try round.consume(#"{"error":{"message":"upstream failure"}}"#))
    }

    func testNativeReadinessAndBotMemoryIsolation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = LocalAgentTransport(root: root)
        let channel = IPCChannel(transport: transport)
        defer { Task { await channel.close() } }
        let info = try await channel.request("agent.info")
        XCTAssertEqual(info["engine"] as? String, "swift")
        XCTAssertNil(info["dshVersion"])
        let added = try await channel.request("memory.add", params: [
            "botId": "private", "title": "Preference", "content": "Concise", "layer": "pinned"
        ])
        let id = try XCTUnwrap(added["journalId"] as? String)
        let other = try await channel.request("memory.journal", params: ["botId": "main"])
        XCTAssertEqual((other["records"] as? [[String: Any]])?.count, 0)
        let denied = try await channel.request("memory.undo", params: ["journalId": id, "botId": "main"])
        XCTAssertEqual(denied["undone"] as? Bool, false)
        let removed = try await channel.request("memory.undo", params: ["journalId": id, "botId": "private"])
        XCTAssertEqual(removed["undone"] as? Bool, true)
        do {
            _ = try await channel.request("plugins.install")
            XCTFail("Unavailable methods must return an error")
        } catch let error as IPCFrameError {
            guard case .remoteError(-32601, _) = error else { return XCTFail("\(error)") }
        }
    }

    func testLegacyMemoryIsLocalUntilAssigned() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let legacy = LocalAgentStore.PersistedState(memoryJournal: [
            ["journalId": "old", "layer": "pinned", "title": "Old preference", "content": "private"]
        ])
        try JSONEncoder().encode(legacy).write(to: root.appendingPathComponent("local-state.json"))
        let store = LocalAgentStore(root: root)
        let before = await store.pinnedMemoriesSummary(botId: "main")
        XCTAssertTrue(before.isEmpty)
        let assigned = try await store.assignMemory(journalId: "old", botId: "private")
        XCTAssertTrue(assigned)
        let after = await store.pinnedMemoriesSummary(botId: "private")
        XCTAssertEqual(after, "- Old preference: private")
    }

    func testApprovalRequiresMatchingTurnAndSession() async {
        let approvals = ToolApprovals()
        let wait = expectation(description: "pending approval")
        let approval = Task {
            await approvals.wait(id: "a", turnId: "t", sessionId: "s") { wait.fulfill() }
        }
        await fulfillment(of: [wait], timeout: 3)
        let mismatched = await approvals.respond(id: "a", turnId: "another", sessionId: "s", approved: true)
        XCTAssertFalse(mismatched)
        let denied = await approvals.respond(id: "a", turnId: "t", sessionId: "s", approved: false)
        XCTAssertTrue(denied)
        let result = await approval.value
        XCTAssertFalse(result)

        let pending = expectation(description: "pending cancellation")
        let cancelled = Task {
            await approvals.wait(id: "another", turnId: "t", sessionId: "s") { pending.fulfill() }
        }
        await fulfillment(of: [pending], timeout: 3)
        cancelled.cancel()
        let approvedAfterCancel = await cancelled.value
        XCTAssertFalse(approvedAfterCancel)
    }

    func testJavaScriptStopsLoopsAndLimitsMemory() async {
        let runtime = LocalJavaScript()
        let result = await runtime.evaluate("console.log('hello'); ({total: 21 * 2})")
        XCTAssertTrue(result.ok)
        XCTAssertEqual(result.logs, ["hello"])
        XCTAssertEqual(result.value, #"{"total":42}"#)
        let timedOut = await runtime.evaluate("while (true) {}", timeoutMilliseconds: 50)
        XCTAssertFalse(timedOut.ok)
        XCTAssertTrue(timedOut.error?.contains("超时") == true)
        let memory = await runtime.evaluate("let chunks = []; for (;;) chunks.push(new Array(100000).fill(1))")
        XCTAssertFalse(memory.ok)
        let isolated = await runtime.evaluate("typeof fetch + ',' + typeof require + ',' + typeof process")
        XCTAssertEqual(isolated.value, "undefined,undefined,undefined")
    }

    @MainActor
    func testProviderTranscriptReplaysReasoningAndToolResultsOnlyInOriginalProfile() throws {
        let provider = try ModelProvider("")
        let profile = provider.historyProfile(model: ModelProvider.thinkingModel, tools: true)
        var assistant = ChatMessageItem(sessionId: "main", role: "assistant", content: "42")
        assistant.providerProfile = profile
        assistant.transcript = [
            ProviderMessage(role: "assistant", content: nil, reasoning_content: "Calculate", tool_calls: [
                .init(id: "call_one", function: .init(name: "js_eval", arguments: #"{"script":"6*7"}"#))
            ]),
            ProviderMessage(role: "tool", content: "42", tool_call_id: "call_one"),
            ProviderMessage(role: "assistant", content: "42", reasoning_content: "Answer")
        ]
        let history = [
            ChatMessageItem(sessionId: "main", role: "user", content: "6×7"),
            assistant,
            ChatMessageItem(sessionId: "main", role: "user", content: "Thanks")
        ]
        let replay = LocalAgentHost.providerHistory(history, provider: provider, model: ModelProvider.thinkingModel, tools: true)
        XCTAssertEqual(replay.compactMap { $0["role"] as? String }, ["user", "assistant", "tool", "assistant", "user"])
        XCTAssertEqual(replay[1]["reasoning_content"] as? String, "Calculate")
        XCTAssertEqual(replay[2]["tool_call_id"] as? String, "call_one")
        XCTAssertEqual(replay[3]["reasoning_content"] as? String, "Answer")
        let switched = LocalAgentHost.providerHistory(history, provider: provider, model: ModelProvider.defaultModel, tools: true)
        XCTAssertEqual(switched.compactMap { $0["role"] as? String }, ["user"])
    }

    func testOldBotAndMessageFilesDecode() throws {
        let bot = try JSONDecoder().decode(BotProfile.self, from: Data(#"{"id":"b1","name":"Legacy","roleLabel":"Helper","model":"deepseek-chat"}"#.utf8))
        XCTAssertEqual(bot.model, "deepseek-chat")
        let old = try JSONDecoder().decode(ChatMessageItem.self, from: Data(#"{"id":"m","sessionId":"b1","role":"assistant","content":"Hello","reasoning":"","timestamp":0}"#.utf8))
        XCTAssertNil(old.transcript)
        XCTAssertEqual(old.content, "Hello")
    }
}

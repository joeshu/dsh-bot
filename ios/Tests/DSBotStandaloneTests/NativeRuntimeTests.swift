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

    func testARM64GuestPTYCodecHandlesFragmentedCoalescedAndNoisySerialFrames() throws {
        let first = ARM64GuestPTYFrame(type: .input, sessionID: 0xD5B07001, payload: Data([0x61, 0x0a]))
        let second = ARM64GuestPTYFrame(type: .output, sessionID: 0xD5B07002, payload: Data(repeating: 0x7f, count: 257))
        let firstBytes = try ARM64GuestPTYCodec.encode(first)
        XCTAssertEqual(Array(firstBytes.prefix(16)), [
            0x44, 0x53, 0x42, 0x50, 0x00, 0x01, 0x00, 0x02,
            0xd5, 0xb0, 0x70, 0x01, 0x00, 0x00, 0x00, 0x02,
        ])

        var wire = Data([0xaa, 0xbb, 0x44]) // noise ending in a partial magic prefix
        wire.append(firstBytes.dropFirst(1))
        wire.append(try ARM64GuestPTYCodec.encode(second))
        var decoder = ARM64GuestPTYDecoder()
        var decoded: [ARM64GuestPTYFrame] = []
        for offset in stride(from: 0, to: wire.count, by: 7) {
            decoded += try decoder.push(wire.subdata(in: offset..<min(offset + 7, wire.count)))
        }

        XCTAssertEqual(decoded, [first, second])
        XCTAssertEqual(decoder.pendingBytes, 0)
    }

    func testARM64GuestPTYCodecRejectsUnboundedAndUnknownFrames() throws {
        let oversized = ARM64GuestPTYFrame(type: .input, sessionID: 1, payload: Data(repeating: 0, count: 65_537))
        XCTAssertThrowsError(try ARM64GuestPTYCodec.encode(oversized)) { error in
            XCTAssertEqual(error as? ARM64GuestPTYProtocolError, .frameTooLarge(65_537))
        }

        var unknown = try ARM64GuestPTYCodec.encode(ARM64GuestPTYFrame(type: .ready, sessionID: 0))
        unknown[6] = 0x7f
        unknown[7] = 0xff
        var decoder = ARM64GuestPTYDecoder()
        XCTAssertThrowsError(try decoder.push(unknown)) { error in
            XCTAssertEqual(error as? ARM64GuestPTYProtocolError, .unsupportedFrameType(0x7fff))
        }

        var wrongVersion = try ARM64GuestPTYCodec.encode(ARM64GuestPTYFrame(type: .ready, sessionID: 0))
        wrongVersion[5] = 0x02
        XCTAssertThrowsError(try decoder.push(wrongVersion)) { error in
            XCTAssertEqual(error as? ARM64GuestPTYProtocolError, .unsupportedVersion(2))
        }
    }

    func testARM64GuestPTYSessionDirectoryBindsIDsToOneOwner() async throws {
        let bot = try XCTUnwrap(ARM64GuestPTYOwner(kind: .bot, sessionID: "ios:main:thread-1"))
        let web = try XCTUnwrap(ARM64GuestPTYOwner(kind: .web, sessionID: "ios:main:thread-1"))
        XCTAssertNil(ARM64GuestPTYOwner(kind: .bot, sessionID: "main\nforged"))

        let directory = ARM64GuestPTYSessionDirectory()
        let botID = try await directory.sessionID(for: bot)
        let sameBotID = try await directory.sessionID(for: bot)
        let webID = try await directory.sessionID(for: web)
        XCTAssertNotEqual(botID, 0)
        XCTAssertEqual(botID, sameBotID)
        XCTAssertNotEqual(botID, webID)
        let botAuthorized = await directory.authorize(guestSessionID: botID, for: bot)
        let crossOwnerDenied = await directory.authorize(guestSessionID: botID, for: web)
        XCTAssertTrue(botAuthorized)
        XCTAssertFalse(crossOwnerDenied)

        await directory.revoke(owner: bot)
        let revoked = await directory.authorize(guestSessionID: botID, for: bot)
        XCTAssertFalse(revoked)
    }

    func testARM64GuestPTYBrokerAuthenticatesAndMultiplexesSessionFrames() async throws {
        let transport = FakeGuestSerialTransport()
        let broker = ARM64GuestPTYBroker(transport: transport)
        await broker.start()

        let readiness = Task { try await broker.waitUntilReady(timeoutSeconds: 5) }
        let ping = try await transport.waitForFrame(.ping)
        transport.deliver(ARM64GuestPTYFrame(type: .pong, sessionID: 0, payload: ping.payload))
        try await readiness.value

        let owner = try XCTUnwrap(ARM64GuestPTYOwner(kind: .bot, sessionID: "ios:main:thread-1"))
        let otherOwner = try XCTUnwrap(ARM64GuestPTYOwner(kind: .web, sessionID: "ios:main:thread-1"))
        let opening = Task { try await broker.open(owner: owner, rows: 42, columns: 100) }
        let create = try await transport.waitForFrame(.create)
        XCTAssertEqual(Array(create.payload), [0, 42, 0, 100])
        transport.deliver(ARM64GuestPTYFrame(type: .ready, sessionID: create.sessionID))
        let output = try await opening.value

        do {
            try await broker.sendInput(Data("should-not-cross".utf8), from: otherOwner)
            XCTFail("A different owner must not write to this PTY")
        } catch let error as ARM64GuestPTYProtocolError {
            XCTAssertEqual(error, .ownerNotAuthorized)
        }

        try await broker.sendInput(Data([0x61, 0x0a]), from: owner)
        try await broker.resize(owner: owner, rows: 42, columns: 100)
        let input = try await transport.waitForFrame(.input)
        let resize = try await transport.waitForFrame(.resize)
        XCTAssertEqual(input.sessionID, create.sessionID)
        XCTAssertEqual(resize.sessionID, create.sessionID)

        let payload = Data("shell output".utf8)
        transport.deliver(ARM64GuestPTYFrame(type: .output, sessionID: create.sessionID, payload: payload))
        var iterator = output.makeAsyncIterator()
        let outputEvent = try await iterator.next()
        XCTAssertEqual(outputEvent, .output(payload))

        let closing = Task { try await broker.close(owner: owner) }
        _ = try await transport.waitForFrame(.close)
        var exitPayload = Data()
        exitPayload.append(contentsOf: [0, 0, 0, 7])
        transport.deliver(ARM64GuestPTYFrame(type: .exit, sessionID: create.sessionID, payload: exitPayload))
        let exitStatus = try await closing.value
        XCTAssertEqual(exitStatus, Optional(Int32(7)))
        let exitEvent = try await iterator.next()
        XCTAssertEqual(exitEvent, .exited(7))
        let streamEnd = try await iterator.next()
        XCTAssertNil(streamEnd)
        let activeSessions = await broker.activeSessionCount()
        XCTAssertEqual(activeSessions, 0)
    }

    func testARM64GuestPTYBrokerRetainsCancelledSessionUntilGuestCleanup() async throws {
        let transport = FakeGuestSerialTransport()
        let broker = ARM64GuestPTYBroker(transport: transport)
        await broker.start()

        let readiness = Task { try await broker.waitUntilReady(timeoutSeconds: 5) }
        let ping = try await transport.waitForFrame(.ping)
        transport.deliver(ARM64GuestPTYFrame(type: .pong, sessionID: 0, payload: ping.payload))
        try await readiness.value

        let owner = try XCTUnwrap(ARM64GuestPTYOwner(kind: .native, sessionID: "ios:main:cancelled-terminal"))
        let opening = Task { try await broker.open(owner: owner) }
        let create = try await transport.waitForFrame(.create)
        transport.deliver(ARM64GuestPTYFrame(type: .ready, sessionID: create.sessionID))
        let output = try await opening.value

        let consumer = Task {
            var iterator = output.makeAsyncIterator()
            do {
                _ = try await iterator.next()
            } catch {
                // Cancellation closes the stream and should request guest cleanup.
            }
        }
        try await Task.sleep(nanoseconds: 20_000_000)
        consumer.cancel()
        _ = try await transport.waitForFrame(.close)

        let closingSessionCount = await broker.activeSessionCount()
        XCTAssertEqual(closingSessionCount, 1, "The guest slot must remain reserved during PTY cleanup")

        var exitPayload = Data()
        exitPayload.append(contentsOf: [0, 0, 0, 0])
        transport.deliver(ARM64GuestPTYFrame(type: .exit, sessionID: create.sessionID, payload: exitPayload))
        await consumer.value

        let deadline = Date().addingTimeInterval(1)
        while await broker.activeSessionCount() != 0 && Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let activeSessionCount = await broker.activeSessionCount()
        XCTAssertEqual(activeSessionCount, 0)
    }

    func testModelSelectionAndEndpointBinding() throws {
        let official = try ModelProvider("https://API.DeepSeek.COM:443/v1/")
        let custom = try ModelProvider("https://example.test/gateway/v1/")
        XCTAssertEqual(official.endpoint("chat/completions").absoluteString, "https://api.deepseek.com/chat/completions")
        XCTAssertEqual(try official.modelFields("deepseek-chat")["model"] as? String, "deepseek-flash")
        XCTAssertEqual(try official.modelFields("deepseek-reasoner")["thinking"] as? [String: String], ["type": "enabled"])
        XCTAssertEqual(try custom.modelFields("deepseek-reasoner")["model"] as? String, "deepseek-reasoner")
        XCTAssertEqual(custom.endpoint("models").absoluteString, "https://example.test/gateway/v1/models")
        let httpCustom = try ModelProvider("http://85.189.66.232:17187/v1/")
        XCTAssertEqual(httpCustom.endpoint("models").absoluteString, "http://85.189.66.232:17187/v1/models")
        XCTAssertFalse(httpCustom.isDeepSeek)
        XCTAssertThrowsError(try ModelProvider("https://user:pass@example.test"))
        XCTAssertThrowsError(try ModelProvider("ftp://example.test/v1"))
        XCTAssertThrowsError(try ModelProvider.httpsComponents("http://example.test/v1"))
    }

    @MainActor
    func testEmbeddedDSHRuntimeStartsInSimulator() async throws {
        let host = LocalAgentHost.shared
        if host.state == .idle { await host.boot() }
        let deadline = Date().addingTimeInterval(60)
        while host.state == .starting && Date() < deadline {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        guard host.state == .ready, let channel = host.rpc() else {
            throw IPCFrameError.remoteError(code: -32000, message: "The app's embedded DSH runtime did not become ready.")
        }
        let info = try await channel.request("agent.info", timeoutSeconds: 30)
        _ = try await channel.request("session.list", timeoutSeconds: 30)
        XCTAssertEqual(info["engine"] as? String, "node+dsh")
        XCTAssertEqual(info["dshVersion"] as? String, "0.2.2-rc.5")
        XCTAssertNotNil(info["nodeVersion"] as? String)
        XCTAssertEqual(info["bootLifecycle"] as? String, "official-runProfile")
        let plugins = Set(info["plugins"] as? [String] ?? [])
        XCTAssertTrue(plugins.contains("dsh-agent"))
        XCTAssertTrue(plugins.contains("dsbot-ios-sqlite-session-persistence"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: NodeRuntimeTransport.defaultWorkspace
            .appendingPathComponent("dsh-sessions.sqlite").path))
    }

    func testParserHandlesMultilineSSEAndKeepAlives() throws {
        var events = ServerSentEvents()
        let sample = "\u{FEFF}: keep alive\r\n"
            + #"data: {"choices":[{"delta":{"reasoning_content":"思考","# + "\r\n"
            + #"data: "content":"回答"},"finish_reason":"stop"}]}"# + "\r\n\r\n"
        let payloads = try sample.utf8.compactMap { try events.append(byte: $0) }
        let event = try XCTUnwrap(payloads.first)
        XCTAssertEqual(payloads.count, 1)
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
        XCTAssertEqual(info["engine"] as? String, "native-workspace-bridge")
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
        let wait = await runtime.evaluate("Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0)", timeoutMilliseconds: 100)
        XCTAssertFalse(wait.ok)
        let isolated = await runtime.evaluate("typeof fetch + ',' + typeof require + ',' + typeof process")
        XCTAssertEqual(isolated.value, "undefined,undefined,undefined")
    }

    func testOldBotAndMessageFilesDecode() throws {
        let bot = try JSONDecoder().decode(BotProfile.self, from: Data(#"{"id":"b1","name":"Legacy","roleLabel":"Helper","model":"deepseek-chat"}"#.utf8))
        XCTAssertEqual(bot.model, "deepseek-chat")
        let old = try JSONDecoder().decode(ChatMessageItem.self, from: Data(#"{"id":"m","sessionId":"b1","role":"assistant","content":"Hello","reasoning":"","timestamp":0}"#.utf8))
        XCTAssertNil(old.transcript)
        XCTAssertEqual(old.content, "Hello")
    }

    func testHostRPCKeepsPrivilegedWorkspaceMethodsOffNode() {
        XCTAssertTrue(HostRPC.directWorkspaceMethods.isDisjoint(with: HostRPC.nodeOriginatedMethods))
        XCTAssertFalse(HostRPC.nodeOriginatedMethods.contains("approval.respond"))
        XCTAssertFalse(HostRPC.nodeOriginatedMethods.contains("connectors.upsert"))
        XCTAssertFalse(HostRPC.nodeOriginatedMethods.contains("memory.add"))
        XCTAssertTrue(HostRPC.directWorkspaceMethods.contains("approval.respond"))
        XCTAssertTrue(HostRPC.nodeOriginatedMethods.contains("side.ask"))
    }

    func testWorkspaceFileToolsContainPathsAndRequireWriteApproval() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("dsbot-ws-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("secret".utf8).write(to: root.appendingPathComponent("chats.json"))

        let transport = LocalAgentTransport(root: root)
        let traversal = try await transport.executeNativeTool(
            name: "workspace_read", arguments: ["path": "../chats.json"], botId: "main", turnId: "t1", isGroup: false
        )
        XCTAssertTrue((traversal["output"] as? String ?? "").contains("Invalid"))

        let approvalSeen = expectation(description: "workspace_write asks for approval")
        transport.setNativeNotificationHandler { method, params in
            guard method == "approval.request",
                  let approvalId = params["approvalId"] as? String else { return }
            approvalSeen.fulfill()
            Task {
                _ = try? await transport.nativeWorkspaceRequest(method: "approval.respond", params: [
                    "approvalId": approvalId, "turnId": "t1", "sessionId": "main", "approved": true
                ])
            }
        }
        let written = try await transport.executeNativeTool(
            name: "workspace_write", arguments: ["path": "notes/todo.md", "content": "hello dsh"], botId: "main", turnId: "t1", isGroup: false
        )
        await fulfillment(of: [approvalSeen], timeout: 3)
        XCTAssertTrue((written["output"] as? String ?? "").contains("Saved files/notes/todo.md"))

        let listed = try await transport.executeNativeTool(
            name: "workspace_list", arguments: ["path": "notes"], botId: "main", turnId: "t1", isGroup: false
        )
        XCTAssertTrue((listed["output"] as? String ?? "").contains("todo.md"))

        let readBack = try await transport.executeNativeTool(
            name: "workspace_read", arguments: ["path": "notes/todo.md"], botId: "main", turnId: "t1", isGroup: false
        )
        XCTAssertEqual(readBack["output"] as? String, "hello dsh")
    }

    func testSessionAddressParsingLegacyCompatibilityAndMalformedRejection() {
        let known: Set<String> = ["main", "bot_alpha"]

        // Legacy main thread compatibility
        let mainDefault = SessionAddress.resolve("main", knownBotIDs: known)
        XCTAssertEqual(mainDefault?.botID, "main")
        XCTAssertNil(mainDefault?.threadID)
        XCTAssertEqual(mainDefault?.canonicalSessionId, "main")
        XCTAssertEqual(mainDefault?.dshSessionId, "ios:main")

        // Explicit ios: prefix and default thread normalization
        let prefixedDefault = SessionAddress.resolve("ios:main:default", knownBotIDs: known)
        XCTAssertEqual(prefixedDefault, mainDefault)

        // Child thread isolation
        let child = SessionAddress.resolve("bot_alpha:t-42", knownBotIDs: known)
        XCTAssertEqual(child?.botID, "bot_alpha")
        XCTAssertEqual(child?.threadID, "t-42")
        XCTAssertEqual(child?.canonicalSessionId, "bot_alpha:t-42")
        XCTAssertEqual(child?.dshSessionId, "ios:bot_alpha:t-42")
        XCTAssertEqual(SessionAddress.resolve("ios:bot_alpha:t-42", knownBotIDs: known), child)

        // Malformed or unknown addresses MUST return nil (never fall back to main)
        XCTAssertNil(SessionAddress.resolve("", knownBotIDs: known))
        XCTAssertNil(SessionAddress.resolve("main:", knownBotIDs: known))
        XCTAssertNil(SessionAddress.resolve("main:a:b", knownBotIDs: known))
        XCTAssertNil(SessionAddress.resolve("unknown_bot", knownBotIDs: known))
        XCTAssertNil(SessionAddress.resolve("unknown_bot:t-1", knownBotIDs: known))
    }

    func testAppActionCatalogAvailabilityAndPrivacyBoundaries() {
        let clear = AppActionCatalog.descriptor(for: .clearSession)
        XCTAssertTrue(clear.requiresConfirmation)
        XCTAssertEqual(clear.scope, .session)
        XCTAssertFalse(clear.isAvailable(isPrivate: false, isStreaming: true))
        XCTAssertTrue(clear.isAvailable(isPrivate: false, isStreaming: false))

        let export = AppActionCatalog.descriptor(for: .exportSession)
        XCTAssertTrue(export.requiresCrossSpaceConfirmationForPrivate)
        XCTAssertEqual(export.scope, .workspace)

        let save = AppActionCatalog.descriptor(for: .saveToWorkspaceFile)
        XCTAssertTrue(save.requiresCrossSpaceConfirmationForPrivate)

        let approval = AppActionCatalog.descriptor(for: .resolveApproval)
        XCTAssertTrue(approval.isAvailable(isPrivate: true, isStreaming: true))
    }
}

private final class FakeGuestSerialTransport: ARM64GuestSerialTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var sent: [Data] = []
    private var receiveHandler: (@Sendable (Data) -> Void)?
    private var closeHandler: (@Sendable () -> Void)?

    func setReceiveHandler(_ handler: (@Sendable (Data) -> Void)?) {
        lock.lock()
        receiveHandler = handler
        lock.unlock()
    }

    func setCloseHandler(_ handler: (@Sendable () -> Void)?) {
        lock.lock()
        closeHandler = handler
        lock.unlock()
    }

    func send(_ bytes: Data) throws {
        lock.lock()
        sent.append(bytes)
        lock.unlock()
    }

    func close() {
        lock.lock()
        let handler = closeHandler
        lock.unlock()
        handler?()
    }

    func deliver(_ frame: ARM64GuestPTYFrame) {
        let data = try! ARM64GuestPTYCodec.encode(frame)
        lock.lock()
        let handler = receiveHandler
        lock.unlock()
        handler?(data)
    }

    func sentFrames() throws -> [ARM64GuestPTYFrame] {
        lock.lock()
        let data = sent
        lock.unlock()
        var decoder = ARM64GuestPTYDecoder()
        return try data.flatMap { try decoder.push($0) }
    }

    func waitForFrame(_ type: ARM64GuestPTYFrameType) async throws -> ARM64GuestPTYFrame {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if let frame = try sentFrames().first(where: { $0.type == type }) { return frame }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw ARM64GuestPTYProtocolError.timeout("test transport frame")
    }
}

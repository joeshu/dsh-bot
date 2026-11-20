import XCTest
@testable import DSBotStandalone

final class KernelRuntimeTests: XCTestCase {
    func testIPCFrameCodecHandlesFragmentedAndCoalescedChunks() throws {
        let f1 = try IPCFrameCodec.encode(["jsonrpc": "2.0", "id": 1, "method": "kernel.ping"])
        let f2 = try IPCFrameCodec.encode(["jsonrpc": "2.0", "id": 2, "result": ["dsh": "0.2.2-rc.5"]])
        var combined = Data()
        combined.append(f1)
        combined.append(f2)

        let decoder = IPCFrameDecoder()
        var decoded: [[String: Any]] = []
        var offset = 0
        while offset < combined.count {
            let end = min(offset + 5, combined.count)
            decoded.append(contentsOf: try decoder.push(combined.subdata(in: offset..<end)))
            offset = end
        }
        XCTAssertEqual(decoder.pendingBytes, 0)
        XCTAssertEqual(decoded.count, 2)
        XCTAssertEqual(decoded[0]["method"] as? String, "kernel.ping")
    }

    func testSQLiteBridgeParameterizedQueriesAndSandboxContainment() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let bridge = SQLiteBridge(allowedRoot: tmp)
        // Sandbox escape must be blocked
        XCTAssertThrowsError(try bridge.open(path: "/etc/passwd"))

        let dbPath = tmp.appendingPathComponent("sessions.sqlite").path
        _ = try bridge.open(path: dbPath)
        _ = try bridge.exec(path: dbPath, sql: "CREATE TABLE items (id INTEGER PRIMARY KEY, name TEXT, score REAL);")
        _ = try bridge.run(path: dbPath, sql: "INSERT INTO items (name, score) VALUES (?, ?);", params: ["DSH 0.2.2-rc.5", 99.5])

        let res = try bridge.query(path: dbPath, sql: "SELECT name, score FROM items WHERE name = ?;", params: ["DSH 0.2.2-rc.5"])
        let rows = res["rows"] as? [[String: Any]]
        XCTAssertEqual(rows?.count, 1)
        XCTAssertEqual(rows?.first?["name"] as? String, "DSH 0.2.2-rc.5")
        _ = try bridge.close(path: dbPath)
    }

    func testKernelManagerHotSwapAndAutoRollbackToBaseline() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let baseData = Data("baseline-dsh-0.2.2-rc.5".utf8)
        let baseURL = tmp.appendingPathComponent("dsh-kernel-0.2.2-rc.5.bundle")
        try baseData.write(to: baseURL)
        let baseManifest = KernelManifest(
            schemaVersion: 1,
            dshVersion: "0.2.2-rc.5",
            dsBotVersion: "0.3.8",
            ipcProtocolVersion: IPCFrameCodec.protocolVersion,
            minShellVersion: "0.1.0",
            bundleFile: "dsh-kernel-0.2.2-rc.5.bundle",
            sha256: KernelManager.sha256Hex(of: baseData),
            sizeBytes: baseData.count
        )
        let baseManifestURL = tmp.appendingPathComponent("kernel-manifest.json")
        try JSONEncoder().encode(baseManifest).write(to: baseManifestURL)

        let manager = KernelManager(
            storageRoot: tmp.appendingPathComponent("store"),
            baselineBundleURL: baseURL,
            baselineManifestURL: baseManifestURL
        )

        let initial = try manager.resolveActiveKernel()
        XCTAssertEqual(initial.manifest.dshVersion, "0.2.2-rc.5")
        XCTAssertTrue(initial.isBaseline)

        let nextData = Data("hotswap-dsh-0.2.2-rc.6".utf8)
        let nextManifest = KernelManifest(
            schemaVersion: 1,
            dshVersion: "0.2.2-rc.6",
            dsBotVersion: "0.3.8",
            ipcProtocolVersion: IPCFrameCodec.protocolVersion,
            minShellVersion: "0.1.0",
            bundleFile: "dsh-kernel-0.2.2-rc.6.bundle",
            sha256: KernelManager.sha256Hex(of: nextData),
            sizeBytes: nextData.count
        )
        let nextManifestData = try JSONEncoder().encode(nextManifest)
        _ = try manager.installHotSwapKernel(bundleData: nextData, manifestData: nextManifestData)

        let upgraded = try manager.resolveActiveKernel()
        XCTAssertEqual(upgraded.manifest.dshVersion, "0.2.2-rc.6")
        XCTAssertFalse(upgraded.isBaseline)

        manager.rollbackFromFaultyKernel(version: "0.2.2-rc.6")
        let rolledBack = try manager.resolveActiveKernel()
        XCTAssertEqual(rolledBack.manifest.dshVersion, "0.2.2-rc.5")
        XCTAssertTrue(rolledBack.isBaseline)
        XCTAssertTrue(manager.failedVersions().contains("0.2.2-rc.6"))

        manager.resetToBaseline()
        XCTAssertTrue(manager.failedVersions().isEmpty)
    }

    func testLocalAgentTransportEndToEndRPCs() async throws {
        let transport = LocalAgentTransport(dshVersion: "0.2.2-rc.5")
        let channel = IPCChannel(transport: transport)
        defer { Task { await channel.close() } }

        let ping = try await channel.request("kernel.ping")
        XCTAssertEqual(ping["pong"] as? Bool, true)
        XCTAssertEqual(ping["dshVersion"] as? String, "0.2.2-rc.5")

        let added = try await channel.request("memory.add", params: [
            "title": "Test Pref",
            "content": "Concise",
            "layer": "pinned"
        ])
        let journalId = try XCTUnwrap(added["journalId"] as? String)
        let undoRes = try await channel.request("memory.undo", params: ["journalId": journalId])
        XCTAssertEqual(undoRes["undone"] as? Bool, true)

        let goalRes = try await channel.request("group.goal.set", params: ["groupId": "g1", "title": "Ship v0.9.0"])
        let goal = goalRes["goal"] as? [String: Any]
        XCTAssertEqual(goal?["title"] as? String, "Ship v0.9.0")
    }

    func testJSCEmbeddedRuntimeEvaluatesAndIsolatesErrors() {
        let runtime = JSCEmbeddedRuntime()
        let okRes = runtime.evaluate(script: "console.log('hi'); JSON.stringify({ sum: 21 * 2 })")
        XCTAssertTrue(okRes.ok)
        XCTAssertEqual(okRes.logs, ["hi"])
        XCTAssertTrue(okRes.value.contains("42"))

        let errRes = runtime.evaluate(script: "throw new Error('sandbox boom')")
        XCTAssertFalse(errRes.ok)
        XCTAssertTrue((errRes.error ?? "").contains("sandbox boom"))
    }

    func testGroupTodosAndPluginGuardAndKeychainValidation() async throws {
        let transport = LocalAgentTransport(dshVersion: "0.2.2-rc.5")
        let channel = IPCChannel(transport: transport)
        defer { Task { await channel.close() } }

        let added = try await channel.request("group.todo.add", params: ["groupId": "g_ci", "text": "Verify IPA"])
        let todo = try XCTUnwrap(added["todo"] as? [String: Any])
        let todoId = try XCTUnwrap(todo["id"] as? String)

        _ = try await channel.request("group.todo.toggle", params: ["groupId": "g_ci", "id": todoId, "done": true])
        let cleared = try await channel.request("group.todo.clearCompleted", params: ["groupId": "g_ci"])
        XCTAssertGreaterThanOrEqual(cleared["removed"] as? Int ?? 0, 1)

        // DSH 0.2.2-rc.5 #13730 guard: core builtin plugin must be rejected with structured IPC error
        do {
            _ = try await channel.request("plugins.install", params: ["name": "@deepseek-ai/dsh"])
            XCTFail("Expected core-builtin shadowing to throw")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("0.2.2-rc.5"))
        }

        // DSH 0.2.2-rc.5 #13819 guard: invalid credential name must be rejected
        let kc = KeychainBridge()
        XCTAssertThrowsError(try kc.setSecret(account: "bad key/space!", value: "x"))
    }

    func testBotProfileBackwardCompatibleDecoding() throws {
        let legacyJSON = Data(#"{"id":"b1","name":"Legacy","roleLabel":"Helper"}"#.utf8)
        let decoded = try JSONDecoder().decode(BotProfile.self, from: legacyJSON)
        XCTAssertEqual(decoded.name, "Legacy")
        XCTAssertEqual(decoded.systemPrompt, "")
        XCTAssertEqual(decoded.model, "deepseek-chat")
    }

    func testIPCChannelStrictFIFOOrder() async throws {
        final class LoopbackTransport: IPCByteTransport {
            var handler: ((Data) -> Void)?
            func setReceiveHandler(_ handler: @escaping (Data) -> Void) { self.handler = handler }
            func write(_ data: Data) {}
            func close() { handler = nil }
            func push(_ data: Data) { handler?(data) }
        }
        let transport = LoopbackTransport()
        let channel = IPCChannel(transport: transport)
        defer { Task { await channel.close() } }

        let exp = expectation(description: "40 FIFO notifications")
        var received: [Int] = []
        let lock = NSLock()
        _ = await channel.onNotification { method, params in
            guard method == "chat.delta", let seq = params["seq"] as? Int else { return }
            lock.lock()
            received.append(seq)
            let done = received.count == 40
            lock.unlock()
            if done { exp.fulfill() }
        }
        for i in 0..<40 {
            let frame = try IPCFrameCodec.encode(["jsonrpc": "2.0", "method": "chat.delta", "params": ["seq": i]])
            transport.push(frame)
        }
        await fulfillment(of: [exp], timeout: 3.0)
        XCTAssertEqual(received, Array(0..<40))
    }
}

import XCTest
@testable import DSBotStandalone

private final class FixtureURLProtocol: URLProtocol {
    struct Reply {
        var headers = ["Content-Type": "application/json"]
        var status = 200
        var body = Data()
    }

    private static let lock = NSLock()
    private static var handler: ((URLRequest) throws -> Reply)?

    static func session(using handler: @escaping (URLRequest) throws -> Reply) -> URLSession {
        lock.lock()
        self.handler = handler
        lock.unlock()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [Self.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            Self.lock.lock()
            let handler = Self.handler
            Self.lock.unlock()
            let reply = try XCTUnwrap(handler)(request)
            let url = try XCTUnwrap(request.url)
            let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers))
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if !reply.body.isEmpty { client?.urlProtocol(self, didLoad: reply.body) }
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

final class NativeHTTPTests: XCTestCase {
    func testMCPInitializesBeforeListingAndCallingTools() async throws {
        let session = FixtureURLProtocol.session { request in
            let body = try Self.json(request)
            let method = try XCTUnwrap(body["method"] as? String)
            let id = body["id"] as? String
            switch method {
            case "initialize":
                XCTAssertEqual((body["params"] as? [String: Any])?["protocolVersion"] as? String, "2025-03-26")
                return try Self.reply(id: XCTUnwrap(id), result: ["protocolVersion": "2025-03-26", "capabilities": ["tools": [:]]], extra: ["Mcp-Session-Id": "fixture"])
            case "notifications/initialized":
                XCTAssertNil(id)
                XCTAssertEqual(request.value(forHTTPHeaderField: "Mcp-Session-Id"), "fixture")
                return .init(status: 202)
            case "tools/list":
                XCTAssertEqual(request.value(forHTTPHeaderField: "Mcp-Session-Id"), "fixture")
                XCTAssertEqual(request.value(forHTTPHeaderField: "MCP-Protocol-Version"), "2025-03-26")
                return try Self.reply(id: XCTUnwrap(id), result: ["tools": [["name": "echo"]]])
            case "tools/call":
                XCTAssertEqual(request.value(forHTTPHeaderField: "Mcp-Session-Id"), "fixture")
                return try Self.reply(id: XCTUnwrap(id), result: ["content": [["type": "text", "text": "hello"]]])
            default: throw URLError(.badServerResponse)
            }
        }
        defer { session.invalidateAndCancel() }
        let mcp = RemoteMCPClient(session: session)
        let endpoint = "https://fixture.test/mcp"
        let tools = try await mcp.listTools(endpoint: endpoint)
        XCTAssertEqual(tools.map(\.name), ["echo"])
        let result = try await mcp.callTool(endpoint: endpoint, name: "echo", arguments: ["value": "hello"])
        XCTAssertEqual(result, "hello")
    }

    func testInterruptedSSEFinishesWithAnError() async throws {
        let session = FixtureURLProtocol.session { _ in
            .init(headers: ["Content-Type": "text/event-stream"],
                  body: Data("data: {\"choices\":[{\"delta\":{\"content\":\"partial\"},\"finish_reason\":null}]}\n\n".utf8))
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let channel = IPCChannel(transport: LocalAgentTransport(root: root, session: session, modelKey: { _ in "fixture" }))
        defer { Task { await channel.close() } }
        let finished = expectation(description: "interrupted turn")
        _ = await channel.onNotification { method, params in
            if method == "chat.done" {
                XCTAssertEqual(params["turnId"] as? String, "t1")
                XCTAssertEqual(params["status"] as? String, "error")
                XCTAssertNotNil(params["error"])
                finished.fulfill()
            }
        }
        let result = try await channel.request("chat.send", params: ["turnId": "t1", "history": [["role": "user", "content": "Hi"]]])
        XCTAssertEqual(result["status"] as? String, "accepted")
        await fulfillment(of: [finished], timeout: 5)
    }

    private static func reply(id: String, result: [String: Any], extra: [String: String] = [:]) throws -> FixtureURLProtocol.Reply {
        let data = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "result": result])
        return .init(headers: ["Content-Type": "application/json"].merging(extra) { _, value in value }, body: data)
    }

    private static func json(_ request: URLRequest) throws -> [String: Any] {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                data.append(contentsOf: buffer.prefix(count))
            }
        }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

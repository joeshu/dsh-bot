import Foundation

/// UI-facing request router.
///
/// Third-party DSH plugins execute inside the embedded Node process, so anything that travels
/// through Node can be observed or forged by plugin code. UI-owned workspace actions (approvals,
/// connector secrets, memory edits, speech, local JS) are therefore sent straight to the Swift
/// workspace, while DSH-owned methods (chat, sessions, plugins, usage, side chat) still go to Node.
public struct HostRPC: Sendable {
    /// Workspace methods the Node runtime itself is allowed to originate via `workspace.request`.
    static let nodeOriginatedMethods: Set<String> = ["side.ask", "side.cancel"]

    /// Workspace methods that only the native UI may invoke; they never transit Node.
    static let directWorkspaceMethods: Set<String> = [
        "models.test", "memory.add", "memory.journal", "memory.legacy", "memory.assign", "memory.undo",
        "group.state", "group.goal.set", "group.todo.add", "group.todo.toggle", "group.todo.clearCompleted",
        "connectors.list", "connectors.upsert", "connectors.delete", "usage.legacySummary", "tools.jsEval",
        "device.status", "device.speak", "device.stopSpeaking", "mcp.listTools", "mcp.callTool",
        "approval.respond",
    ]

    let channel: IPCChannel
    let workspace: LocalAgentTransport

    public func request(_ method: String, params: [String: Any] = [:], timeoutSeconds: UInt64 = 15) async throws -> [String: Any] {
        if Self.directWorkspaceMethods.contains(method) {
            return try await workspace.nativeWorkspaceRequest(method: method, params: params)
        }
        return try await channel.request(method, params: params, timeoutSeconds: timeoutSeconds)
    }
}

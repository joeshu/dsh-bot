import Foundation

public struct ARM64GuestPTYCommandResult: Sendable, Equatable {
    public let output: String
    public let exitCode: Int32
    public let truncated: Bool
}

public enum ARM64GuestPTYCommandPolicy {
    public static func validate(_ command: String) throws -> String {
        guard !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ARM64GuestPTYProtocolError.guestRejected("terminal_exec requires a non-empty command.")
        }
        guard command.utf16.count <= 8_000, command.utf8.count <= 32_000 else {
            throw ARM64GuestPTYProtocolError.guestRejected("terminal_exec command exceeds the 8,000-character / 32 KiB limit.")
        }
        guard !command.split(separator: "\n", omittingEmptySubsequences: false).contains(where: { $0.utf8.count > 3_500 }) else {
            throw ARM64GuestPTYProtocolError.guestRejected("Each terminal_exec command line must be at most 3.5 KiB for Linux canonical PTY input.")
        }
        for scalar in command.unicodeScalars {
            let value = scalar.value
            let forbiddenControl = (value <= 0x1f && value != 0x0a) || value == 0x7f
            let invisibleOrBidi = value == 0x061c
                || (0x200b...0x200f).contains(value)
                || (0x2028...0x202e).contains(value)
                || (0x2060...0x206f).contains(value)
                || value == 0xfeff
            guard !forbiddenControl, !invisibleOrBidi else {
                throw ARM64GuestPTYProtocolError.guestRejected("terminal_exec does not accept tabs, control characters, or invisible/bidirectional Unicode controls.")
            }
        }
        return command
    }
}

/// Runs Bot commands through a fresh, owner-scoped Linux PTY and tears down the
/// entire guest UID process tree on completion, cancellation, or timeout.
public actor ARM64GuestPTYCommandRunner {
    public static let shared = ARM64GuestPTYCommandRunner()

    private struct TurnKey: Hashable {
        let sessionID: String
        let turnID: String
    }

    private enum RaceResult: Sendable {
        case completed(Result<ARM64GuestPTYCommandResult, Error>)
        case timeout
    }

    private let runtime: ARM64GuestQEMURuntime
    private let maxOutputBytes = 32 * 1024
    private var activeOwners: [TurnKey: Set<ARM64GuestPTYOwner>] = [:]
    private var cancelledTurns: Set<TurnKey> = []

    public init(runtime: ARM64GuestQEMURuntime = .shared) {
        self.runtime = runtime
    }

    public func execute(
        command rawCommand: String,
        sessionID: String,
        turnID: String,
        timeoutSeconds: UInt64 = 90
    ) async throws -> ARM64GuestPTYCommandResult {
        let command = try ARM64GuestPTYCommandPolicy.validate(rawCommand)
        guard !sessionID.isEmpty, !turnID.isEmpty else {
            throw ARM64GuestPTYProtocolError.invalidOwner
        }
        let key = TurnKey(sessionID: sessionID, turnID: turnID)
        let owner = try Self.makeOwner(sessionID: sessionID)
        activeOwners[key, default: []].insert(owner)
        defer {
            activeOwners[key]?.remove(owner)
            if activeOwners[key]?.isEmpty == true {
                activeOwners.removeValue(forKey: key)
                cancelledTurns.remove(key)
            }
        }

        let broker = try await runtime.acquirePTYLease()
        defer { Task { await runtime.releasePTYLease() } }
        guard !cancelledTurns.contains(key) else { throw CancellationError() }
        let stream = try await broker.open(owner: owner, rows: 24, columns: 80, timeoutSeconds: 20)
        guard !cancelledTurns.contains(key) else {
            try? await broker.close(owner: owner)
            throw CancellationError()
        }

        // Disable terminal echo after the shell reads the first line. The following
        // command stays a complete POSIX shell program and EOF returns its status.
        var input = Data("stty -echo\n".utf8)
        input.append(Data(command.utf8))
        input.append(Data("\nexit\n".utf8))

        do {
            return try await withTaskCancellationHandler {
                try await broker.sendInput(input, from: owner)
                return try await withThrowingTaskGroup(of: RaceResult.self) { group in
                    let outputLimit = maxOutputBytes
                    group.addTask {
                        do {
                            return .completed(.success(try await Self.collectOutput(from: stream, maxBytes: outputLimit)))
                        } catch {
                            return .completed(.failure(error))
                        }
                    }
                    group.addTask {
                        do {
                            try await Task.sleep(nanoseconds: min(max(1, timeoutSeconds), 110) * 1_000_000_000)
                            return .timeout
                        } catch {
                            return .timeout
                        }
                    }
                    let first = try await group.next() ?? .timeout
                    group.cancelAll()
                    if Task.isCancelled {
                        try? await broker.close(owner: owner)
                        throw CancellationError()
                    }
                    switch first {
                    case .completed(.success(let result)):
                        return result
                    case .completed(.failure(let error)):
                        try? await broker.close(owner: owner)
                        throw error
                    case .timeout:
                        try? await broker.close(owner: owner)
                        throw ARM64GuestPTYProtocolError.timeout("command execution")
                    }
                }
            } onCancel: {
                Task { try? await broker.close(owner: owner) }
            }
        } catch {
            try? await broker.close(owner: owner)
            throw error
        }
    }

    public func cancel(sessionID: String, turnID: String) async {
        let key = TurnKey(sessionID: sessionID, turnID: turnID)
        cancelledTurns.insert(key)
        let owners = activeOwners[key] ?? []
        guard !owners.isEmpty, let broker = await runtime.brokerIfStarted() else { return }
        for owner in owners { try? await broker.close(owner: owner) }
    }

    private static func makeOwner(sessionID: String) throws -> ARM64GuestPTYOwner {
        guard let owner = ARM64GuestPTYOwner(
            kind: .bot,
            sessionID: sessionID,
            terminalID: UUID().uuidString.lowercased()
        ) else {
            throw ARM64GuestPTYProtocolError.invalidOwner
        }
        return owner
    }

    private static func collectOutput(
        from stream: AsyncThrowingStream<ARM64GuestPTYEvent, Error>,
        maxBytes: Int
    ) async throws -> ARM64GuestPTYCommandResult {
        var bytes = Data()
        var truncated = false
        var iterator = stream.makeAsyncIterator()
        while let event = try await iterator.next() {
            try Task.checkCancellation()
            switch event {
            case .output(let chunk):
                let remaining = max(0, maxBytes - bytes.count)
                if chunk.count > remaining { truncated = true }
                if remaining > 0 { bytes.append(contentsOf: chunk.prefix(remaining)) }
            case .exited(let status):
                return ARM64GuestPTYCommandResult(
                    output: String(decoding: bytes, as: UTF8.self),
                    exitCode: status,
                    truncated: truncated
                )
            }
        }
        throw ARM64GuestPTYProtocolError.transportClosed
    }
}

import Foundation

public enum ARM64GuestPTYFrameType: UInt16, Equatable, Sendable {
    case create = 1
    case input = 2
    case resize = 3
    case close = 4
    case ping = 5
    case output = 0x81
    case exit = 0x82
    case error = 0x83
    case ready = 0x84
    case pong = 0x85
    case progress = 0x86
}

public struct ARM64GuestPTYFrame: Equatable, Sendable {
    public let type: ARM64GuestPTYFrameType
    public let sessionID: UInt32
    public let payload: Data

    public init(type: ARM64GuestPTYFrameType, sessionID: UInt32, payload: Data = Data()) {
        self.type = type
        self.sessionID = sessionID
        self.payload = payload
    }
}

public enum ARM64GuestPTYProtocolError: Error, Equatable, LocalizedError {
    case frameTooLarge(Int)
    case unsupportedVersion(UInt16)
    case unsupportedFrameType(UInt16)
    case invalidOwner
    case invalidDimensions
    case sessionIDSpaceExhausted
    case guestNotReady
    case ownerNotAuthorized
    case sessionLimitReached
    case sessionNotOpen
    case timeout(String)
    case transportClosed
    case outputBackpressure
    case guestRejected(String)
    case invalidFrame

    public var errorDescription: String? {
        switch self {
        case .frameTooLarge(let size): return "Guest PTY frame is too large: \(size) bytes."
        case .unsupportedVersion(let version): return "Unsupported guest PTY protocol version: \(version)."
        case .unsupportedFrameType(let type): return "Unsupported guest PTY frame type: \(type)."
        case .invalidOwner: return "Guest PTY owner identity is invalid."
        case .invalidDimensions: return "Guest PTY terminal dimensions are invalid."
        case .sessionIDSpaceExhausted: return "No guest PTY session identifiers are available."
        case .guestNotReady: return "The ARM64 Linux guest PTY agent is not ready."
        case .ownerNotAuthorized: return "This caller does not own the guest PTY session."
        case .sessionLimitReached: return "The guest PTY session limit has been reached."
        case .sessionNotOpen: return "The guest PTY session is not open."
        case .timeout(let operation): return "Guest PTY \(operation) timed out."
        case .transportClosed: return "The guest serial connection is closed."
        case .outputBackpressure: return "The guest PTY output consumer is too slow; the session was closed."
        case .guestRejected(let message): return message
        case .invalidFrame: return "The guest PTY agent returned a malformed frame."
        }
    }
}

/// DSBP/1 codec for the guest UART stream. Integers use network byte order.
public enum ARM64GuestPTYCodec {
    public static let protocolVersion: UInt16 = 1
    public static let headerBytes = 16
    public static let maxPayloadBytes = 64 * 1024
    private static let magic: [UInt8] = [0x44, 0x53, 0x42, 0x50] // DSBP

    public static func encode(_ frame: ARM64GuestPTYFrame) throws -> Data {
        guard frame.payload.count <= maxPayloadBytes else {
            throw ARM64GuestPTYProtocolError.frameTooLarge(frame.payload.count)
        }
        var bytes = magic
        append(protocolVersion, to: &bytes)
        append(frame.type.rawValue, to: &bytes)
        append(frame.sessionID, to: &bytes)
        append(UInt32(frame.payload.count), to: &bytes)
        bytes.append(contentsOf: frame.payload)
        return Data(bytes)
    }

    fileprivate static func decodeHeader(_ bytes: ArraySlice<UInt8>) throws -> (ARM64GuestPTYFrameType, UInt32, Int) {
        let header = Array(bytes)
        let version = UInt16(header[4]) << 8 | UInt16(header[5])
        guard version == protocolVersion else {
            throw ARM64GuestPTYProtocolError.unsupportedVersion(version)
        }
        let rawType = UInt16(header[6]) << 8 | UInt16(header[7])
        guard let type = ARM64GuestPTYFrameType(rawValue: rawType) else {
            throw ARM64GuestPTYProtocolError.unsupportedFrameType(rawType)
        }
        let sessionID = readUInt32(header, at: 8)
        let payloadLength = Int(readUInt32(header, at: 12))
        guard payloadLength <= maxPayloadBytes else {
            throw ARM64GuestPTYProtocolError.frameTooLarge(payloadLength)
        }
        return (type, sessionID, payloadLength)
    }

    fileprivate static func magicBytes() -> [UInt8] { magic }

    private static func append(_ value: UInt16, to bytes: inout [UInt8]) {
        bytes.append(UInt8((value >> 8) & 0xff))
        bytes.append(UInt8(value & 0xff))
    }

    private static func append(_ value: UInt32, to bytes: inout [UInt8]) {
        bytes.append(UInt8((value >> 24) & 0xff))
        bytes.append(UInt8((value >> 16) & 0xff))
        bytes.append(UInt8((value >> 8) & 0xff))
        bytes.append(UInt8(value & 0xff))
    }

    private static func readUInt32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        UInt32(bytes[offset]) << 24
            | UInt32(bytes[offset + 1]) << 16
            | UInt32(bytes[offset + 2]) << 8
            | UInt32(bytes[offset + 3])
    }
}

/// Incremental decoder that accepts fragmented frames, coalesced frames, and UART noise.
public struct ARM64GuestPTYDecoder {
    private var buffer: [UInt8] = []

    public init() {}

    public var pendingBytes: Int { buffer.count }

    public mutating func push(_ data: Data) throws -> [ARM64GuestPTYFrame] {
        let maxChunkBytes = ARM64GuestPTYCodec.maxPayloadBytes * 4
        guard data.count <= maxChunkBytes else {
            throw ARM64GuestPTYProtocolError.frameTooLarge(data.count)
        }
        buffer.append(contentsOf: data)
        var frames: [ARM64GuestPTYFrame] = []
        let magic = ARM64GuestPTYCodec.magicBytes()

        while buffer.count >= ARM64GuestPTYCodec.headerBytes {
            guard let offset = magicOffset(in: buffer, magic: magic) else {
                buffer = Array(buffer.suffix(magic.count - 1))
                break
            }
            if offset > 0 { buffer.removeFirst(offset) }
            guard buffer.count >= ARM64GuestPTYCodec.headerBytes else { break }

            do {
                let (type, sessionID, payloadLength) = try ARM64GuestPTYCodec.decodeHeader(buffer[0..<ARM64GuestPTYCodec.headerBytes])
                let frameLength = ARM64GuestPTYCodec.headerBytes + payloadLength
                guard buffer.count >= frameLength else { break }
                let payload = Data(buffer[ARM64GuestPTYCodec.headerBytes..<frameLength])
                frames.append(ARM64GuestPTYFrame(type: type, sessionID: sessionID, payload: payload))
                buffer.removeFirst(frameLength)
            } catch {
                buffer.removeAll(keepingCapacity: false)
                throw error
            }
        }

        // Keep only the bytes that could be the start of a split DSBP header.
        if buffer.count > ARM64GuestPTYCodec.maxPayloadBytes + ARM64GuestPTYCodec.headerBytes {
            let size = buffer.count
            buffer.removeAll(keepingCapacity: false)
            throw ARM64GuestPTYProtocolError.frameTooLarge(size)
        }
        return frames
    }

    private func magicOffset(in bytes: [UInt8], magic: [UInt8]) -> Int? {
        guard bytes.count >= magic.count else { return nil }
        for offset in 0...(bytes.count - magic.count) {
            if bytes[offset..<(offset + magic.count)].elementsEqual(magic) { return offset }
        }
        return nil
    }
}

public enum ARM64GuestPTYOwnerKind: String, Hashable, Sendable {
    case bot
    case web
    case native
}

/// A host-created identity. Callers never choose the guest's numeric session ID.
public struct ARM64GuestPTYOwner: Hashable, Sendable {
    public let kind: ARM64GuestPTYOwnerKind
    public let sessionID: String
    public let terminalID: String

    public init?(kind: ARM64GuestPTYOwnerKind, sessionID: String, terminalID: String = "default") {
        let session = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        let terminal = terminalID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isSafeIdentifier(session), Self.isSafeIdentifier(terminal) else { return nil }
        self.kind = kind
        self.sessionID = session
        self.terminalID = terminal
    }

    private static func isSafeIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 128
            && !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    }
}

/// Binds guest-visible IDs to host-authenticated owners for this app process.
/// A mapping is revoked on PTY close; it is never restored from persistent state.
public actor ARM64GuestPTYSessionDirectory {
    private var guestIDsByOwner: [ARM64GuestPTYOwner: UInt32] = [:]
    private var ownersByGuestID: [UInt32: ARM64GuestPTYOwner] = [:]

    public init() {}

    public func sessionID(for owner: ARM64GuestPTYOwner) throws -> UInt32 {
        if let existing = guestIDsByOwner[owner] { return existing }
        let usedGuestUIDs = Set(ownersByGuestID.keys.map { $0 % 10_000 })
        for _ in 0..<128 {
            let candidate = UInt32.random(in: 1...UInt32.max)
            // The guest derives an isolated uid from sessionID % 10,000.
            guard ownersByGuestID[candidate] == nil,
                  !usedGuestUIDs.contains(candidate % 10_000) else { continue }
            guestIDsByOwner[owner] = candidate
            ownersByGuestID[candidate] = owner
            return candidate
        }
        throw ARM64GuestPTYProtocolError.sessionIDSpaceExhausted
    }

    public func authorize(guestSessionID: UInt32, for owner: ARM64GuestPTYOwner) -> Bool {
        ownersByGuestID[guestSessionID] == owner
    }

    public func existingSessionID(for owner: ARM64GuestPTYOwner) -> UInt32? {
        guestIDsByOwner[owner]
    }

    public func revoke(owner: ARM64GuestPTYOwner) {
        guard let guestID = guestIDsByOwner.removeValue(forKey: owner) else { return }
        ownersByGuestID.removeValue(forKey: guestID)
    }

    public func removeAll() {
        guestIDsByOwner.removeAll(keepingCapacity: false)
        ownersByGuestID.removeAll(keepingCapacity: false)
    }
}

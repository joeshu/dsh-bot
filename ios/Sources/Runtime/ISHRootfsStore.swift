import CryptoKit
import Foundation
import SQLite3

public enum ISHRootfsStoreError: Error, LocalizedError, Equatable {
    case missingBundleResources
    case invalidManifest
    case rootfsHashMismatch
    case rootfsImageTooLarge
    case existingRootfsNeedsRecovery
    case rootfsImageChanged(installed: String, bundled: String)
    case invalidArchive(String)
    case invalidRootfsLayout
    case metadataDatabaseInvalid

    public var errorDescription: String? {
        switch self {
        case .missingBundleResources:
            return "The pinned iSH Alpine rootfs is not bundled with this app build."
        case .invalidManifest:
            return "The bundled iSH rootfs manifest is invalid."
        case .rootfsHashMismatch:
            return "The bundled iSH rootfs ZIP does not match its SHA-256 manifest."
        case .rootfsImageTooLarge:
            return "The bundled iSH rootfs exceeds the install size limit."
        case .existingRootfsNeedsRecovery:
            return "An untracked iSH rootfs already exists; it was left untouched for recovery."
        case .rootfsImageChanged(let installed, let bundled):
            return "The bundled iSH rootfs changed from \(installed) to \(bundled); migrate or reset the existing rootfs before upgrading."
        case .invalidArchive(let reason):
            return "The bundled iSH rootfs archive is invalid: \(reason)"
        case .invalidRootfsLayout:
            return "The iSH rootfs is missing required Alpine files."
        case .metadataDatabaseInvalid:
            return "The iSH fakefs metadata database failed its integrity check."
        }
    }
}

/// Installs the pinned fakefs image once into Application Support and keeps it
/// separate from the app bundle. Upgrades never replace a rootfs with user data.
public actor ISHRootfsStore {
    public static let shared = ISHRootfsStore()

    private struct Manifest: Decodable {
        struct Source: Decodable {
            let sha256: String
        }

        struct Image: Decodable {
            let path: String
            let sha256: String
            let bytes: Int
            let expandedFakefsBytes: Int
            let metadataPathCount: Int
            let archiveEntryCount: Int
            let metaDatabaseBytes: Int
        }

        let format: String
        let distributionVersion: String
        let architecture: String
        let source: Source
        let image: Image
    }

    private struct InstallMarker: Codable {
        let schemaVersion: Int
        let alpineVersion: String
        let imageSHA256: String
    }

    private let bundle: Bundle
    private let fileManager: FileManager
    private let supportDirectory: URL

    public init(bundle: Bundle = .main, supportDirectory: URL? = nil) {
        let manager = FileManager.default
        self.bundle = bundle
        self.fileManager = manager
        self.supportDirectory = supportDirectory
            ?? (manager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                .appendingPathComponent("DSBot/ISH", isDirectory: true))
    }

    public var rootfsURL: URL {
        supportDirectory.appendingPathComponent("AlpineRootfs", isDirectory: true)
    }

    /// Returns the persistent fakefs directory expected by `mount_root`.
    /// Extraction happens in a sibling staging directory and is moved into
    /// place only after ZIP, CRC, path, layout, and SQLite checks succeed.
    public func installIfNeeded() throws -> URL {
        let resources = bundle.resourceURL?.appendingPathComponent("DSBotISHRuntime", isDirectory: true)
        guard let resources else { throw ISHRootfsStoreError.missingBundleResources }
        let archiveURL = resources.appendingPathComponent("alpine-rootfs.zip")
        let manifestURL = resources.appendingPathComponent("rootfs-manifest.json")
        guard fileManager.fileExists(atPath: archiveURL.path),
              fileManager.fileExists(atPath: manifestURL.path) else {
            throw ISHRootfsStoreError.missingBundleResources
        }

        let manifest: Manifest
        do {
            manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifestURL))
        } catch {
            throw ISHRootfsStoreError.invalidManifest
        }
        guard manifest.format == "iSH fakefs rootfs ZIP",
              manifest.architecture == "aarch64",
              !manifest.distributionVersion.isEmpty,
              manifest.source.sha256.count == 64,
              manifest.image.path == "rootfs/alpine-rootfs.zip",
              manifest.image.sha256.count == 64,
              manifest.image.bytes > 0,
              manifest.image.expandedFakefsBytes > 0,
              manifest.image.metadataPathCount > 0,
              manifest.image.metadataPathCount <= 20_001,
              manifest.image.archiveEntryCount > 0,
              manifest.image.archiveEntryCount <= 20_000,
              manifest.image.metaDatabaseBytes > 0 else {
            throw ISHRootfsStoreError.invalidManifest
        }
        guard manifest.image.bytes <= 64 * 1024 * 1024,
              manifest.image.expandedFakefsBytes <= 128 * 1024 * 1024 else {
            throw ISHRootfsStoreError.rootfsImageTooLarge
        }
        let attributes = try fileManager.attributesOfItem(atPath: archiveURL.path)
        guard let byteCount = attributes[.size] as? NSNumber,
              byteCount.intValue == manifest.image.bytes,
              try Self.sha256(archiveURL) == manifest.image.sha256 else {
            throw ISHRootfsStoreError.rootfsHashMismatch
        }

        try fileManager.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: rootfsURL.path) {
            let markerURL = rootfsURL.appendingPathComponent(".dsbot-rootfs-install.json")
            guard fileManager.fileExists(atPath: markerURL.path) else {
                throw ISHRootfsStoreError.existingRootfsNeedsRecovery
            }
            let marker = try JSONDecoder().decode(InstallMarker.self, from: Data(contentsOf: markerURL))
            guard marker.schemaVersion == 1,
                  marker.alpineVersion == manifest.distributionVersion else {
                throw ISHRootfsStoreError.existingRootfsNeedsRecovery
            }
            guard marker.imageSHA256 == manifest.image.sha256 else {
                throw ISHRootfsStoreError.rootfsImageChanged(
                    installed: marker.imageSHA256,
                    bundled: manifest.image.sha256
                )
            }
            try Self.validateRootfs(at: rootfsURL, manifest: manifest, verifyBaseMetadata: false)
            return rootfsURL
        }

        try removeAbandonedStagingDirectories()
        let stagingURL = supportDirectory.appendingPathComponent(
            ".AlpineRootfs.staging.\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        try fileManager.createDirectory(at: stagingURL, withIntermediateDirectories: false)
        do {
            try ISHRootfsZIPExtractor.extract(
                archiveURL,
                into: stagingURL,
                expectedEntries: manifest.image.archiveEntryCount,
                expectedExpandedBytes: manifest.image.expandedFakefsBytes
            )
            try Self.validateRootfs(at: stagingURL, manifest: manifest, verifyBaseMetadata: true)
            let marker = InstallMarker(
                schemaVersion: 1,
                alpineVersion: manifest.distributionVersion,
                imageSHA256: manifest.image.sha256
            )
            let markerData = try JSONEncoder().encode(marker)
            try markerData.write(
                to: stagingURL.appendingPathComponent(".dsbot-rootfs-install.json"),
                options: .atomic
            )
            try fileManager.moveItem(at: stagingURL, to: rootfsURL)
            return rootfsURL
        } catch {
            try? fileManager.removeItem(at: stagingURL)
            throw error
        }
    }

    private func removeAbandonedStagingDirectories() throws {
        let entries = try fileManager.contentsOfDirectory(
            at: supportDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        )
        for entry in entries where entry.lastPathComponent.hasPrefix(".AlpineRootfs.staging.") {
            try? fileManager.removeItem(at: entry)
        }
    }

    private static func validateRootfs(
        at root: URL,
        manifest: Manifest,
        verifyBaseMetadata: Bool
    ) throws {
        let required = [
            "data/bin/ash",
            "data/bin/busybox",
            "data/lib/apk/db/installed",
            "meta.db",
        ]
        guard required.allSatisfy({ FileManager.default.fileExists(atPath: root.appendingPathComponent($0).path) }) else {
            throw ISHRootfsStoreError.invalidRootfsLayout
        }
        let metadataURL = root.appendingPathComponent("meta.db")
        let metadata = try Data(contentsOf: metadataURL, options: [.mappedIfSafe])
        guard metadata.starts(with: Data([0x53, 0x51, 0x4c, 0x69, 0x74, 0x65, 0x20, 0x66, 0x6f, 0x72, 0x6d, 0x61, 0x74, 0x20, 0x33, 0x00])),
              !verifyBaseMetadata || metadata.count == manifest.image.metaDatabaseBytes else {
            throw ISHRootfsStoreError.metadataDatabaseInvalid
        }
        try validateSQLiteDatabase(
            at: metadataURL,
            expectedPathCount: verifyBaseMetadata ? manifest.image.metadataPathCount : nil
        )
    }

    private static func validateSQLiteDatabase(at url: URL, expectedPathCount: Int?) throws {
        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let database else {
            if let database { sqlite3_close(database) }
            throw ISHRootfsStoreError.metadataDatabaseInvalid
        }
        defer { sqlite3_close(database) }

        var integrityStatement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA integrity_check", -1, &integrityStatement, nil) == SQLITE_OK,
              let integrityStatement else {
            throw ISHRootfsStoreError.metadataDatabaseInvalid
        }
        defer { sqlite3_finalize(integrityStatement) }
        guard sqlite3_step(integrityStatement) == SQLITE_ROW,
              let integrityText = sqlite3_column_text(integrityStatement, 0),
              String(cString: UnsafeRawPointer(integrityText).assumingMemoryBound(to: CChar.self)) == "ok" else {
            throw ISHRootfsStoreError.metadataDatabaseInvalid
        }

        if let expectedPathCount {
            var pathsStatement: OpaquePointer?
            guard sqlite3_prepare_v2(database, "SELECT count(*) FROM paths", -1, &pathsStatement, nil) == SQLITE_OK,
                  let pathsStatement else {
                throw ISHRootfsStoreError.metadataDatabaseInvalid
            }
            defer { sqlite3_finalize(pathsStatement) }
            guard sqlite3_step(pathsStatement) == SQLITE_ROW,
                  Int(sqlite3_column_int64(pathsStatement, 0)) == expectedPathCount else {
                throw ISHRootfsStoreError.metadataDatabaseInvalid
            }
        }
    }

    private static func sha256(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

private struct ISHRootfsZIPExtractor {
    private struct Entry {
        let path: String
        let isDirectory: Bool
        let compressionMethod: UInt16
        let crc32: UInt32
        let compressedSize: Int
        let uncompressedSize: Int
        let localHeaderOffset: Int
    }

    private let bytes: Data
    private let entries: [Entry]

    private init(url: URL) throws {
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        guard data.count >= 22, data.count <= 64 * 1024 * 1024 else {
            throw ISHRootfsStoreError.invalidArchive("unsupported archive size")
        }
        self.bytes = data
        self.entries = try Self.parse(data)
    }

    static func extract(
        _ archiveURL: URL,
        into destination: URL,
        expectedEntries: Int,
        expectedExpandedBytes: Int
    ) throws {
        let archive = try ISHRootfsZIPExtractor(url: archiveURL)
        guard archive.entries.count == expectedEntries + 1 else {
            throw ISHRootfsStoreError.invalidArchive("entry count differs from the manifest")
        }
        let expandedBytes = archive.entries.reduce(0) { $0 + ($1.isDirectory ? 0 : $1.uncompressedSize) }
        guard expandedBytes == expectedExpandedBytes,
              expandedBytes <= 128 * 1024 * 1024 else {
            throw ISHRootfsStoreError.invalidArchive("expanded size differs from the manifest")
        }

        for entry in archive.entries {
            guard entry.path == "alpine-rootfs/" || entry.path.hasPrefix("alpine-rootfs/") else {
                throw ISHRootfsStoreError.invalidArchive("entry escaped the alpine-rootfs directory")
            }
            let relative = String(entry.path.dropFirst("alpine-rootfs/".count))
            if relative.isEmpty { continue }
            let target = try Self.safeTarget(relative, under: destination)
            if entry.isDirectory {
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
                continue
            }
            let payload = try archive.payload(for: entry)
            try FileManager.default.createDirectory(
                at: target.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try payload.write(to: target, options: .atomic)
        }
    }

    private func payload(for entry: Entry) throws -> Data {
        let localOffset = entry.localHeaderOffset
        guard Self.hasRange(bytes, offset: localOffset, length: 30),
              Self.uint32(bytes, localOffset) == 0x04034b50 else {
            throw ISHRootfsStoreError.invalidArchive("bad local file header")
        }
        let flags = Self.uint16(bytes, localOffset + 6)
        let method = Self.uint16(bytes, localOffset + 8)
        let nameLength = Int(Self.uint16(bytes, localOffset + 26))
        let extraLength = Int(Self.uint16(bytes, localOffset + 28))
        guard flags & 0x0001 == 0,
              method == entry.compressionMethod,
              Self.hasRange(bytes, offset: localOffset + 30, length: nameLength + extraLength) else {
            throw ISHRootfsStoreError.invalidArchive("local and central headers disagree")
        }
        let localNameData = bytes.subdata(in: (localOffset + 30)..<(localOffset + 30 + nameLength))
        guard String(data: localNameData, encoding: .utf8) == entry.path else {
            throw ISHRootfsStoreError.invalidArchive("local and central file names disagree")
        }
        let dataOffset = localOffset + 30 + nameLength + extraLength
        guard Self.hasRange(bytes, offset: dataOffset, length: entry.compressedSize) else {
            throw ISHRootfsStoreError.invalidArchive("compressed payload is out of bounds")
        }
        let compressed = bytes.subdata(in: dataOffset..<(dataOffset + entry.compressedSize))
        let output: Data
        switch entry.compressionMethod {
        case 0:
            guard entry.compressedSize == entry.uncompressedSize else {
                throw ISHRootfsStoreError.invalidArchive("stored entry has a size mismatch")
            }
            output = compressed
        case 8:
            var inflated = Data(count: entry.uncompressedSize)
            let status = compressed.withUnsafeBytes { source in
                inflated.withUnsafeMutableBytes { destination in
                    dsbot_inflate_raw_deflate(
                        source.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        compressed.count,
                        destination.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        inflated.count
                    )
                }
            }
            guard status == 0 else {
                throw ISHRootfsStoreError.invalidArchive("raw DEFLATE decoding failed")
            }
            output = inflated
        default:
            throw ISHRootfsStoreError.invalidArchive("unsupported compression method")
        }

        let checksum = output.withUnsafeBytes { buffer in
            dsbot_zip_crc32(buffer.baseAddress?.assumingMemoryBound(to: UInt8.self), output.count)
        }
        guard checksum == entry.crc32 else {
            throw ISHRootfsStoreError.invalidArchive("entry CRC does not match")
        }
        return output
    }

    private static func parse(_ data: Data) throws -> [Entry] {
        guard let eocd = findEndRecord(in: data) else {
            throw ISHRootfsStoreError.invalidArchive("end-of-directory record is missing")
        }
        let disk = uint16(data, eocd + 4)
        let centralDisk = uint16(data, eocd + 6)
        let entriesOnDisk = Int(uint16(data, eocd + 8))
        let entryCount = Int(uint16(data, eocd + 10))
        let centralSize = Int(uint32(data, eocd + 12))
        let centralOffset = Int(uint32(data, eocd + 16))
        let commentLength = Int(uint16(data, eocd + 20))
        guard disk == 0, centralDisk == 0, entriesOnDisk == entryCount,
              entryCount > 0, entryCount <= 20_001,
              eocd + 22 + commentLength == data.count,
              hasRange(data, offset: centralOffset, length: centralSize),
              centralOffset + centralSize <= eocd else {
            throw ISHRootfsStoreError.invalidArchive("multi-disk, ZIP64, or out-of-range archive")
        }

        var entries: [Entry] = []
        var names = Set<String>()
        var caseFoldedNames = Set<String>()
        var cursor = centralOffset
        let centralEnd = centralOffset + centralSize
        for _ in 0..<entryCount {
            guard hasRange(data, offset: cursor, length: 46), uint32(data, cursor) == 0x02014b50 else {
                throw ISHRootfsStoreError.invalidArchive("bad central-directory entry")
            }
            let flags = uint16(data, cursor + 8)
            let method = uint16(data, cursor + 10)
            let crc = uint32(data, cursor + 16)
            let compressedSize = uint32(data, cursor + 20)
            let uncompressedSize = uint32(data, cursor + 24)
            let nameLength = Int(uint16(data, cursor + 28))
            let extraLength = Int(uint16(data, cursor + 30))
            let commentLength = Int(uint16(data, cursor + 32))
            let diskStart = uint16(data, cursor + 34)
            let externalAttributes = uint32(data, cursor + 38)
            let localOffset = uint32(data, cursor + 42)
            let recordLength = 46 + nameLength + extraLength + commentLength
            guard hasRange(data, offset: cursor, length: recordLength),
                  cursor + recordLength <= centralEnd,
                  flags & 0x0001 == 0,
                  diskStart == 0,
                  compressedSize != UInt32.max,
                  uncompressedSize != UInt32.max,
                  localOffset != UInt32.max,
                  method == 0 || method == 8 else {
                throw ISHRootfsStoreError.invalidArchive("unsupported or encrypted ZIP entry")
            }
            let nameData = data.subdata(in: (cursor + 46)..<(cursor + 46 + nameLength))
            guard let name = String(data: nameData, encoding: .utf8),
                  isSafeArchiveName(name) else {
                throw ISHRootfsStoreError.invalidArchive("invalid archive path")
            }
            let directory = name.hasSuffix("/")
            let fileType = (externalAttributes >> 16) & 0xf000
            guard fileType != 0xa000 else {
                throw ISHRootfsStoreError.invalidArchive("symbolic links are not accepted")
            }
            guard fileType == 0 || (directory ? fileType == 0x4000 : fileType == 0x8000) else {
                throw ISHRootfsStoreError.invalidArchive("unsupported file type")
            }
            let normalizedName = directory ? String(name.dropLast()) : name
            guard names.insert(normalizedName).inserted,
                  caseFoldedNames.insert(normalizedName.lowercased()).inserted else {
                throw ISHRootfsStoreError.invalidArchive("duplicate or case-colliding path")
            }
            let size = Int(uncompressedSize)
            let compressed = Int(compressedSize)
            guard size <= 64 * 1024 * 1024,
                  size == 0 || compressed > 0,
                  compressed == 0 || size <= compressed * 1000 else {
                throw ISHRootfsStoreError.invalidArchive("entry exceeds extraction limits")
            }
            entries.append(Entry(
                path: name,
                isDirectory: directory,
                compressionMethod: method,
                crc32: crc,
                compressedSize: compressed,
                uncompressedSize: size,
                localHeaderOffset: Int(localOffset)
            ))
            cursor += recordLength
        }
        guard cursor == centralEnd else {
            throw ISHRootfsStoreError.invalidArchive("central-directory size does not match entries")
        }
        try validateParentTypes(entries)
        return entries
    }

    private static func validateParentTypes(_ entries: [Entry]) throws {
        var types: [String: Bool] = [:]
        for entry in entries where entry.path != "alpine-rootfs/" {
            let normalized = entry.path.hasSuffix("/") ? String(entry.path.dropLast()) : entry.path
            types[normalized] = entry.isDirectory
        }
        for (path, isDirectory) in types {
            let components = path.split(separator: "/")
            if components.count > 1 {
                for length in 1..<components.count {
                    let parent = components.prefix(length).joined(separator: "/")
                    if let parentIsDirectory = types[parent], !parentIsDirectory {
                        throw ISHRootfsStoreError.invalidArchive("a file is used as a parent directory")
                    }
                }
            }
            if !isDirectory {
                let childPrefix = path + "/"
                if types.keys.contains(where: { $0.hasPrefix(childPrefix) }) {
                    throw ISHRootfsStoreError.invalidArchive("a file conflicts with a directory")
                }
            }
        }
    }

    private static func safeTarget(_ path: String, under root: URL) throws -> URL {
        guard isSafeRelativePath(path) else {
            throw ISHRootfsStoreError.invalidArchive("unsafe extraction path")
        }
        let target = root.appendingPathComponent(path).standardizedFileURL
        let rootPath = root.standardizedFileURL.path + "/"
        guard target.path.hasPrefix(rootPath) else {
            throw ISHRootfsStoreError.invalidArchive("extraction path escaped staging directory")
        }
        return target
    }

    private static func isSafeArchiveName(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\"), !path.contains("\0") else {
            return false
        }
        let normalized = path.hasSuffix("/") ? String(path.dropLast()) : path
        let components = normalized.split(separator: "/", omittingEmptySubsequences: false)
        return !components.isEmpty && components.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    private static func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.hasPrefix("/"), !path.contains("\\"), !path.contains("\0") else { return false }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        return !components.isEmpty && components.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    private static func findEndRecord(in data: Data) -> Int? {
        guard data.count >= 22 else { return nil }
        let lower = max(0, data.count - 65_557)
        for offset in stride(from: data.count - 22, through: lower, by: -1) {
            guard uint32(data, offset) == 0x06054b50 else { continue }
            let commentLength = Int(uint16(data, offset + 20))
            if offset + 22 + commentLength == data.count { return offset }
        }
        return nil
    }

    private static func hasRange(_ data: Data, offset: Int, length: Int) -> Bool {
        offset >= 0 && length >= 0 && offset <= data.count && length <= data.count - offset
    }

    private static func uint16(_ data: Data, _ offset: Int) -> UInt16 {
        UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private static func uint32(_ data: Data, _ offset: Int) -> UInt32 {
        UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }
}

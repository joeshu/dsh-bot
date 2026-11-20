import CryptoKit
import Foundation

public struct KernelManifest: Codable, Equatable {
    public let schemaVersion: Int
    public let dshVersion: String
    public let dsBotVersion: String
    public let ipcProtocolVersion: String
    public let minShellVersion: String
    public let bundleFile: String
    public let sha256: String
    public let sizeBytes: Int
}

public enum KernelManagerError: Error, LocalizedError {
    case baselineMissing
    case checksumMismatch(expected: String, actual: String)
    case incompatibleProtocol(expected: String, actual: String)
    case invalidManifest
    case downloadFailed(Int)

    public var errorDescription: String? {
        switch self {
        case .baselineMissing: return "Embedded baseline DSH kernel not found in app bundle."
        case .checksumMismatch(let exp, let act): return "Kernel SHA-256 mismatch: expected \(exp.prefix(12)), got \(act.prefix(12))."
        case .incompatibleProtocol(let exp, let act): return "Kernel IPC protocol mismatch: shell expects \(exp), kernel provides \(act)."
        case .invalidManifest: return "Invalid kernel-manifest.json."
        case .downloadFailed(let code): return "Failed to download hot-swap kernel (HTTP \(code))."
        }
    }
}

/// Manages versioned DSH kernel bundles on iOS with CryptoKit SHA-256 verification,
/// atomic hot-swap activation, OTA download, and automatic rollback to the embedded 0.2.2-rc.5 baseline.
public final class KernelManager {
    public static let baselineVersion = "0.2.2-rc.5"

    private let fileManager: FileManager
    private let storageRoot: URL
    private let baselineBundleURLOverride: URL?
    private let baselineManifestURLOverride: URL?
    private let activePointerURL: URL
    private let failedVersionsURL: URL

    public init(
        storageRoot: URL? = nil,
        baselineBundleURL: URL? = nil,
        baselineManifestURL: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.fileManager = fileManager
        if let root = storageRoot {
            self.storageRoot = root
        } else {
            let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            self.storageRoot = appSupport.appendingPathComponent("DSBotKernels", isDirectory: true)
        }
        self.baselineBundleURLOverride = baselineBundleURL
        self.baselineManifestURLOverride = baselineManifestURL
        self.activePointerURL = self.storageRoot.appendingPathComponent("active-version.txt")
        self.failedVersionsURL = self.storageRoot.appendingPathComponent("failed-versions.json")
        try? fileManager.createDirectory(at: self.storageRoot, withIntermediateDirectories: true)
    }

    public static func sha256Hex(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Resolves embedded baseline manifest & bundle dynamically across both `KernelAssets/` subdirectory and flat bundle layouts.
    private func resolveBaseline() throws -> (bundleURL: URL, manifest: KernelManifest) {
        let mURL = baselineManifestURLOverride
            ?? Bundle.main.url(forResource: "kernel-manifest", withExtension: "json", subdirectory: "KernelAssets")
            ?? Bundle.main.url(forResource: "kernel-manifest", withExtension: "json")

        guard let manifestURL = mURL,
              let manifestData = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(KernelManifest.self, from: manifestData) else {
            throw KernelManagerError.baselineMissing
        }

        let bundleName = (manifest.bundleFile as NSString).deletingPathExtension
        let bundleExt = (manifest.bundleFile as NSString).pathExtension
        let bURL = baselineBundleURLOverride
            ?? Bundle.main.url(forResource: bundleName, withExtension: bundleExt, subdirectory: "KernelAssets")
            ?? Bundle.main.url(forResource: bundleName, withExtension: bundleExt)

        guard let bundleURL = bURL, fileManager.fileExists(atPath: bundleURL.path) else {
            throw KernelManagerError.baselineMissing
        }
        return (bundleURL, manifest)
    }

    /// Returns the currently active verified kernel URL and manifest (falling back to embedded baseline).
    public func resolveActiveKernel() throws -> (bundleURL: URL, manifest: KernelManifest, isBaseline: Bool) {
        if let activeVersion = try? String(contentsOf: activePointerURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
           !activeVersion.isEmpty,
           !failedVersions().contains(activeVersion) {
            let dir = storageRoot.appendingPathComponent(activeVersion, isDirectory: true)
            let manifestURL = dir.appendingPathComponent("kernel-manifest.json")
            if let manifestData = try? Data(contentsOf: manifestURL),
               let manifest = try? JSONDecoder().decode(KernelManifest.self, from: manifestData) {
                let bundleURL = dir.appendingPathComponent(manifest.bundleFile)
                if let bundleData = try? Data(contentsOf: bundleURL),
                   Self.sha256Hex(of: bundleData) == manifest.sha256,
                   manifest.ipcProtocolVersion == IPCFrameCodec.protocolVersion {
                    return (bundleURL, manifest, false)
                }
            }
        }

        let baseline = try resolveBaseline()
        return (baseline.bundleURL, baseline.manifest, true)
    }

    /// Downloads a remote `kernel-manifest.json` and its sibling `.bundle`, verifies SHA-256, and activates it atomically.
    public func downloadAndInstallHotSwap(manifestURL: URL, session: URLSession = .shared) async throws -> KernelManifest {
        let (manifestData, mResp) = try await session.data(from: manifestURL)
        if let http = mResp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw KernelManagerError.downloadFailed(http.statusCode)
        }
        guard let manifest = try? JSONDecoder().decode(KernelManifest.self, from: manifestData) else {
            throw KernelManagerError.invalidManifest
        }
        let bundleURL = manifestURL.deletingLastPathComponent().appendingPathComponent(manifest.bundleFile)
        let (bundleData, bResp) = try await session.data(from: bundleURL)
        if let http = bResp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw KernelManagerError.downloadFailed(http.statusCode)
        }
        return try installHotSwapKernel(bundleData: bundleData, manifestData: manifestData)
    }

    /// Install and atomically activate a hot-swapped DSH kernel bundle after verifying SHA-256 & IPC protocol.
    public func installHotSwapKernel(bundleData: Data, manifestData: Data) throws -> KernelManifest {
        guard let manifest = try? JSONDecoder().decode(KernelManifest.self, from: manifestData) else {
            throw KernelManagerError.invalidManifest
        }
        guard manifest.ipcProtocolVersion == IPCFrameCodec.protocolVersion else {
            throw KernelManagerError.incompatibleProtocol(
                expected: IPCFrameCodec.protocolVersion,
                actual: manifest.ipcProtocolVersion
            )
        }
        let actualSha = Self.sha256Hex(of: bundleData)
        guard actualSha == manifest.sha256 else {
            throw KernelManagerError.checksumMismatch(expected: manifest.sha256, actual: actualSha)
        }

        let targetDir = storageRoot.appendingPathComponent(manifest.dshVersion, isDirectory: true)
        let stagingDir = storageRoot.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: stagingDir) }

        try bundleData.write(to: stagingDir.appendingPathComponent(manifest.bundleFile), options: .atomic)
        try manifestData.write(to: stagingDir.appendingPathComponent("kernel-manifest.json"), options: .atomic)

        if fileManager.fileExists(atPath: targetDir.path) {
            try fileManager.removeItem(at: targetDir)
        }
        try fileManager.moveItem(at: stagingDir, to: targetDir)

        try manifest.dshVersion.write(to: activePointerURL, atomically: true, encoding: .utf8)
        return manifest
    }

    /// Blacklists a faulty hot-swapped kernel version and immediately reverts to embedded baseline.
    public func rollbackFromFaultyKernel(version: String) {
        guard version != Self.baselineVersion else { return }
        var failed = failedVersions()
        failed.insert(version)
        if let encoded = try? JSONEncoder().encode(Array(failed)) {
            try? encoded.write(to: failedVersionsURL, options: .atomic)
        }
        try? fileManager.removeItem(at: activePointerURL)
    }

    /// Explicitly resets to the immutable embedded baseline kernel and clears the failed-version blacklist.
    public func resetToBaseline() {
        try? fileManager.removeItem(at: activePointerURL)
        try? fileManager.removeItem(at: failedVersionsURL)
    }

    public func failedVersions() -> Set<String> {
        guard let data = try? Data(contentsOf: failedVersionsURL),
              let arr = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return Set(arr)
    }
}

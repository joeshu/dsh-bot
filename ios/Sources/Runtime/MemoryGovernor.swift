import Darwin
import Foundation
import ImageIO
import MetricKit
import UIKit
import os

/// Memory pressure tier derived from iOS Jetsam headroom (`os_proc_available_memory`),
/// Mach `task_vm_info.phys_footprint`, and `DispatchSourceMemoryPressure`.
public enum MemoryPressureTier: String, Sendable, CaseIterable {
    case normal
    case warning
    case urgent
    case critical

    public var displayName: String {
        switch self {
        case .normal: return "正常"
        case .warning: return "偏高"
        case .urgent: return "紧张"
        case .critical: return "临界"
        }
    }
}

public struct MemoryTelemetrySnapshot: Sendable, Equatable {
    public let physFootprintMB: Double
    public let availableMB: Double
    public let physicalMemoryGB: Double
    public let openFDCount: Int
    public let nodeHeapLimitMB: Int
    public let tier: MemoryPressureTier
    public let metricKitDeliveries: Int
    public let lastMetricSummary: String
    public let timestamp: Date

    public static let empty = MemoryTelemetrySnapshot(
        physFootprintMB: 0,
        availableMB: 0,
        physicalMemoryGB: Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824.0,
        openFDCount: 0,
        nodeHeapLimitMB: MemoryGovernor.recommendedNodeOldSpaceMB(),
        tier: .normal,
        metricKitDeliveries: 0,
        lastMetricSummary: "尚无 MetricKit 报告",
        timestamp: Date()
    )
}

private final class MetricKitRelay: NSObject, MXMetricManagerSubscriber {
    private let onReport: @Sendable (String) -> Void

    init(onReport: @escaping @Sendable (String) -> Void) {
        self.onReport = onReport
        super.init()
        MXMetricManager.shared.add(self)
    }

    deinit {
        MXMetricManager.shared.remove(self)
    }

    func didReceive(_ payloads: [MXMetricPayload]) {
        guard let latest = payloads.last else { return }
        let peakMB: String
        if let peak = latest.memoryMetrics?.peakMemoryUsage {
            let mb = peak.converted(to: .megabytes).value
            peakMB = String(format: "%.1f MB", mb)
        } else {
            peakMB = "N/A"
        }
        onReport("MetricKit 峰值内存: \(peakMB) (\(payloads.count) 份)")
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        guard !payloads.isEmpty else { return }
        let crashes = payloads.reduce(0) { $0 + ($1.crashDiagnostics?.count ?? 0) }
        let hangs = payloads.reduce(0) { $0 + ($1.hangDiagnostics?.count ?? 0) }
        onReport("MetricKit 诊断: 崩溃 \(crashes) / 卡顿 \(hangs)")
    }
}

/// Centralized Jetsam / Memory / FD governor for the standalone iOS host.
@MainActor
public final class MemoryGovernor: ObservableObject {
    public static let shared = MemoryGovernor()

    @Published public private(set) var snapshot: MemoryTelemetrySnapshot = .empty
    @Published public private(set) var tier: MemoryPressureTier = .normal

    /// Optional callback invoked on MainActor when pressure enters `.critical`.
    public var onCriticalPressure: (() -> Void)?

    private var pressureSource: DispatchSourceMemoryPressure?
    private var metricRelay: MetricKitRelay?
    private var metricKitDeliveries: Int = 0
    private var lastMetricSummary: String = "尚无 MetricKit 报告"
    private var started = false

    private init() {}

    /// Recommended V8 `--max-old-space-size` (in MB) tiered by device physical RAM
    /// to stay safely below iOS Jetsam limits across 4GB / 6GB / 8GB+ devices.
    nonisolated public static func recommendedNodeOldSpaceMB(
        physicalMemoryBytes: UInt64 = ProcessInfo.processInfo.physicalMemory
    ) -> Int {
        let gib = Double(physicalMemoryBytes) / 1_073_741_824.0
        if gib <= 4.5 {
            return 192
        } else if gib <= 6.5 {
            return 320
        } else {
            return 512
        }
    }

    public func startMonitoring() {
        guard !started else { return }
        started = true
        refreshSnapshot()

        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical],
            queue: DispatchQueue.global(qos: .utility)
        )
        source.setEventHandler { [weak self] in
            let event = source.data
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.refreshSnapshot(osEvent: event)
                if self.tier == .critical {
                    self.onCriticalPressure?()
                }
            }
        }
        source.resume()
        pressureSource = source

        metricRelay = MetricKitRelay { [weak self] summary in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.metricKitDeliveries += 1
                self.lastMetricSummary = summary
                self.refreshSnapshot()
            }
        }
    }

    @discardableResult
    public func refreshSnapshot(osEvent: DispatchSource.MemoryPressureEvent = []) -> MemoryTelemetrySnapshot {
        let physFootprintMB = Self.readPhysFootprintMB()
        let availableMB = Self.readAvailableMemoryMB()
        let openFDCount = Self.readOpenFileDescriptorCount()
        let physicalGB = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824.0
        let computedTier = Self.classifyTier(availableMB: availableMB, osEvent: osEvent)

        let updated = MemoryTelemetrySnapshot(
            physFootprintMB: physFootprintMB,
            availableMB: availableMB,
            physicalMemoryGB: physicalGB,
            openFDCount: openFDCount,
            nodeHeapLimitMB: Self.recommendedNodeOldSpaceMB(),
            tier: computedTier,
            metricKitDeliveries: metricKitDeliveries,
            lastMetricSummary: lastMetricSummary,
            timestamp: Date()
        )
        snapshot = updated
        tier = computedTier
        return updated
    }

    /// Admission control gate for heavy work (Pyodide WASM, large attachments, multi-bot fan-out).
    public func canAdmitHeavyWork() -> Bool {
        let current = refreshSnapshot()
        if current.tier == .critical { return false }
        // On simulator `os_proc_available_memory()` can return 0; only gate when > 0.
        if current.availableMB > 0 && current.availableMB < 180 { return false }
        return true
    }

    /// Streams and downsamples an image via `ImageIO` without decoding the full bitmap into memory.
    nonisolated public static func downsampleImage(
        at url: URL,
        maxPixelSize: CGFloat = 1568,
        compressionQuality: CGFloat = 0.85
    ) -> Data? {
        let sourceOptions: [CFString: Any] = [
            kCGImageSourceShouldCache: false
        ]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions as CFDictionary) else {
            return nil
        }
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) else {
            return nil
        }
        return UIImage(cgImage: cgImage).jpegData(compressionQuality: compressionQuality)
    }

    nonisolated private static func classifyTier(
        availableMB: Double,
        osEvent: DispatchSource.MemoryPressureEvent
    ) -> MemoryPressureTier {
        if osEvent.contains(.critical) { return .critical }
        if availableMB > 0 {
            if availableMB < 120 { return .critical }
            if availableMB < 240 { return .urgent }
            if availableMB < 420 { return .warning }
        }
        if osEvent.contains(.warning) { return .warning }
        return .normal
    }

    nonisolated private static func readPhysFootprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), intPtr, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Double(info.phys_footprint) / 1_048_576.0
    }

    nonisolated private static func readAvailableMemoryMB() -> Double {
        let bytes = os_proc_available_memory()
        return Double(bytes) / 1_048_576.0
    }

    nonisolated private static func readOpenFileDescriptorCount() -> Int {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd") else {
            return 0
        }
        return entries.count
    }
}

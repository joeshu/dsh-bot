import Foundation
import UIKit

final class DeviceCapabilitiesBridge {
    @MainActor
    func deviceStatus() -> [String: Any] {
        let info = ProcessInfo.processInfo
        let device = UIDevice.current
        let wasMonitoring = device.isBatteryMonitoringEnabled
        device.isBatteryMonitoringEnabled = true
        defer { device.isBatteryMonitoringEnabled = wasMonitoring }
        return [
            "osVersion": info.operatingSystemVersionString,
            "lowPowerMode": info.isLowPowerModeEnabled,
            "thermalState": thermalLabel(info.thermalState),
            "processorCount": info.processorCount,
            "physicalMemoryMB": Int(info.physicalMemory / (1024 * 1024)),
            "deviceModel": device.model,
            "batteryLevel": device.batteryLevel
        ]
    }

    private func thermalLabel(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }
}

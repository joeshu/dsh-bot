import AVFoundation
import Foundation
import UIKit

final class DeviceCapabilitiesBridge {
    @MainActor private lazy var synthesizer = AVSpeechSynthesizer()

    @MainActor
    func speak(_ text: String) {
        guard !Task.isCancelled else { return }
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        synthesizer.speak(utterance)
    }

    @MainActor
    func stopSpeaking() {
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
    }

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

import AVFoundation
import Foundation
import UserNotifications
#if canImport(UIKit)
import UIKit
#endif

/// Native iOS device status for the local agent.
/// Covers device status, clipboard, text-to-speech (AVSpeechSynthesizer), and local notifications.
public final class DeviceCapabilitiesBridge: @unchecked Sendable {
    private let synthesizer = AVSpeechSynthesizer()

    public init() {}

    public func deviceStatus() -> [String: Any] {
        let info = ProcessInfo.processInfo
        var result: [String: Any] = [
            "osVersion": info.operatingSystemVersionString,
            "lowPowerMode": info.isLowPowerModeEnabled,
            "thermalState": thermalLabel(info.thermalState),
            "processorCount": info.processorCount,
            "physicalMemoryMB": Int(info.physicalMemory / (1024 * 1024))
        ]
        #if canImport(UIKit)
        let readDevice = {
            UIDevice.current.isBatteryMonitoringEnabled = true
            result["deviceModel"] = UIDevice.current.model
            result["batteryLevel"] = UIDevice.current.batteryLevel
        }
        if Thread.isMainThread { readDevice() } else { DispatchQueue.main.sync(execute: readDevice) }
        #endif
        return result
    }

    public func readClipboard() -> String {
        #if canImport(UIKit)
        return Thread.isMainThread ? (UIPasteboard.general.string ?? "") : DispatchQueue.main.sync { UIPasteboard.general.string ?? "" }
        #else
        return ""
        #endif
    }

    public func writeClipboard(_ text: String) {
        #if canImport(UIKit)
        DispatchQueue.main.async { UIPasteboard.general.string = text }
        #endif
    }

    public func speak(text: String, language: String = "zh-CN") {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: language)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        DispatchQueue.main.async { [synthesizer] in
            if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
            synthesizer.speak(utterance)
        }
    }

    public func scheduleLocalNotification(title: String, body: String, delaySeconds: TimeInterval) async -> Bool {
        let center = UNUserNotificationCenter.current()
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        guard granted else { return false }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, delaySeconds), repeats: false)
        let req = UNNotificationRequest(identifier: "dsbot_\(UUID().uuidString.prefix(8))", content: content, trigger: trigger)
        return (try? await center.add(req)) != nil
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

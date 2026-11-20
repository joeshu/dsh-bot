import AVFoundation
import Foundation
import Speech
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

@MainActor
public final class SpeechInputController: ObservableObject {
    @Published public private(set) var isRecording = false
    @Published public private(set) var errorMessage: String?

    private let audioEngine = AVAudioEngine()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN")) ?? SFSpeechRecognizer()

    public init() {}

    public func toggle(onTranscript: @escaping (String) -> Void) {
        if isRecording {
            stop()
        } else {
            Task { await start(onTranscript: onTranscript) }
        }
    }

    public func stop() {
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionRequest = nil
        recognitionTask = nil
        isRecording = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func start(onTranscript: @escaping (String) -> Void) async {
        errorMessage = nil
        let auth = await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { status in cont.resume(returning: status) }
        }
        guard auth == .authorized else {
            errorMessage = "请在系统设置中允许 DS Bot 使用语音识别。"
            return
        }
        let micGranted = await withCheckedContinuation { cont in
            AVAudioSession.sharedInstance().requestRecordPermission { ok in cont.resume(returning: ok) }
        }
        guard micGranted else {
            errorMessage = "请在系统设置中允许 DS Bot 访问麦克风。"
            return
        }
        guard let recognizer, recognizer.isAvailable else {
            errorMessage = "当前设备语音识别不可用。"
            return
        }
        stop()
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            recognitionRequest = request
            let inputNode = audioEngine.inputNode
            let format = inputNode.outputFormat(forBus: 0)
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak request] buffer, _ in
                request?.append(buffer)
            }
            audioEngine.prepare()
            try audioEngine.start()
            isRecording = true
            recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if let result {
                        onTranscript(result.bestTranscription.formattedString)
                        if result.isFinal { self.stop() }
                    } else if let error {
                        if self.isRecording {
                            self.errorMessage = error.localizedDescription
                            self.stop()
                        }
                    }
                }
            }
        } catch {
            errorMessage = "无法启动语音输入：\(error.localizedDescription)"
            stop()
        }
    }
}

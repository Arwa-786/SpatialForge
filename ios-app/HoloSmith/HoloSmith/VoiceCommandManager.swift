//
//  VoiceCommandManager.swift
//  HoloSmith
//
//  SpatialForge — on-device continuous speech recognition for hands-free
//  commands. Both hands are already committed (right: the puck, left:
//  gestures), so voice covers everything else: reset, import, calibration,
//  and setting/reading the model's color.
//

import AVFoundation
import Combine
import Speech

final class VoiceCommandManager: NSObject, ObservableObject {
    @Published var isListening = false
    @Published var lastHeard = ""

    var onReset: (() -> Void)?
    var onImportModel: (() -> Void)?
    var onCalibrateWhite: (() -> Void)?
    var onCalibrateBlack: (() -> Void)?
    var onReadColor: (() -> Void)?
    var onSetColor: ((String) -> Void)?
    var onClearColorOverride: (() -> Void)?

    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let audioEngine = AVAudioEngine()
    private let synthesizer = AVSpeechSynthesizer()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var lastCommandTime = Date.distantPast

    func start() {
        requestPermissions { [weak self] granted in
            guard let self = self, granted else { return }
            self.beginAudioEngineIfNeeded()
            self.startRecognitionLoop()
            self.isListening = true
        }
    }

    func stop() {
        isListening = false
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    func speak(_ text: String) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        synthesizer.speak(utterance)
    }

    private func requestPermissions(completion: @escaping (Bool) -> Void) {
        SFSpeechRecognizer.requestAuthorization { status in
            guard status == .authorized else {
                DispatchQueue.main.async { completion(false) }
                return
            }
            AVAudioSession.sharedInstance().requestRecordPermission { micGranted in
                DispatchQueue.main.async { completion(micGranted) }
            }
        }
    }

    private func beginAudioEngineIfNeeded() {
        guard !audioEngine.isRunning else { return }
        let audioSession = AVAudioSession.sharedInstance()
        try? audioSession.setCategory(.playAndRecord, mode: .default, options: [.duckOthers, .defaultToSpeaker, .allowBluetooth])
        try? audioSession.setActive(true, options: .notifyOthersOnDeactivation)

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.recognitionRequest?.append(buffer)
        }
        audioEngine.prepare()
        try? audioEngine.start()
    }

    // A recognition segment finalizes on its own after a pause in speech.
    // Each time that happens, start a fresh request/task so listening keeps
    // going indefinitely instead of stopping after the first phrase. The
    // audio engine/tap above stays running the whole time and always feeds
    // whichever request is current.
    private func startRecognitionLoop() {
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if speechRecognizer?.supportsOnDeviceRecognition == true {
            request.requiresOnDeviceRecognition = true
        }
        recognitionRequest = request

        recognitionTask = speechRecognizer?.recognitionTask(with: request) { [weak self] result, error in
            guard let self = self else { return }
            if let result = result {
                let text = result.bestTranscription.formattedString.lowercased()
                self.lastHeard = text
                self.handle(text: text)
            }
            if error != nil || (result?.isFinal ?? false) {
                self.recognitionTask = nil
                self.recognitionRequest = nil
                if self.isListening {
                    self.startRecognitionLoop()
                }
            }
        }
    }

    // Requires "Friday" somewhere in the phrase before acting on anything,
    // so an ordinary word said in passing ("reset" mentioned in conversation,
    // say) never fires a command by accident.
    private func handle(text: String) {
        guard text.contains("friday") else { return }
        guard Date().timeIntervalSince(lastCommandTime) > 1.5 else { return }

        var matched = true
        if text.contains("reset") {
            onReset?()
        } else if text.contains("import") {
            onImportModel?()
        } else if text.contains("calibrate") && text.contains("white") {
            onCalibrateWhite?()
        } else if text.contains("calibrate") && text.contains("black") {
            onCalibrateBlack?()
        } else if text.contains("what color") {
            onReadColor?()
        } else if text.contains("use sensor") || text.contains("live color") {
            onClearColorOverride?()
        } else if text.contains("color"), let entry = namedColors.first(where: { text.contains($0.name.lowercased()) }) {
            onSetColor?(entry.name)
        } else {
            matched = false
        }

        if matched { lastCommandTime = Date() }
    }
}

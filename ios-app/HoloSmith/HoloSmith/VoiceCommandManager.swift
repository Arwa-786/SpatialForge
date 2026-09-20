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
    var onCloseImporter: (() -> Void)?
    var onCalibrateWhite: (() -> Void)?
    var onCalibrateBlack: (() -> Void)?
    var onReadColor: (() -> Void)?
    var onSetColor: ((String) -> Void)?
    var onClearColorOverride: (() -> Void)?
    var onExplode: (() -> Void)?
    var onCollapse: (() -> Void)?
    // Clears the drag-accumulated position offset only — unlike "reset,"
    // which also wipes the loaded model back to the default torus. Dragging
    // the model around (pinch-drag, or open-palm-drag — see ContentView)
    // had no hands-free way to undo without this.
    var onRecenter: (() -> Void)?
    // Fires with whatever free-form text followed a labeling trigger phrase
    // ("label this left ventricle" -> "left ventricle") — unlike model
    // loading, a label isn't matched against a known fixed set, it's
    // whatever you actually said, verbatim.
    var onLabelPart: ((String) -> Void)?

    // Bundled models the app can load hands-free. Instead of requiring an
    // exact trigger phrase per model, a spoken request is scored against
    // each option's aliases and whichever scores highest wins — so "load
    // the segmented one" and "show me the six parts" both resolve to the
    // same model without either being a hardcoded exact match.
    struct VoiceModelOption {
        let aliases: [String]
        let action: () -> Void
    }
    var modelOptions: [VoiceModelOption] = []
    private let modelLoadIntentWords = ["load", "open", "show", "bring", "get", "switch", "use", "pull", "give", "import"]

    // Hardcoding a specific locale (first en-US, then a guessed en-IN swap)
    // means guessing at your accent instead of just asking the phone what
    // it already knows — Locale.current reflects your device's own
    // Language & Region setting, which is a much better bet than any
    // locale I pick myself. Falls back to en-US only if that somehow isn't
    // a locale Speech supports at all.
    private let speechRecognizer = SFSpeechRecognizer(locale: .current)
        ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let audioEngine = AVAudioEngine()
    private let synthesizer = AVSpeechSynthesizer()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var lastCommandTime = Date.distantPast
    private var silenceTimer: Timer?
    private let silenceTimeout: TimeInterval = 0.8
    // Covers the brief echo/reverb tail right after speech ends, in addition
    // to muting outright while synthesizer.isSpeaking is true (see the tap
    // below) — without both, the mic can still pick up the tail end of the
    // phone's own voice.
    private var speechEndCooldownUntil = Date.distantPast

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
        silenceTimer?.invalidate()
        silenceTimer = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    func speak(_ text: String) {
        synthesizer.delegate = self // idempotent; drives speechEndCooldownUntil below
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
            guard let self = self else { return }
            // Without this, the mic hears the phone's own spoken
            // confirmations, transcribes them, and re-triggers a command —
            // confirmed live: it got stuck responding to itself saying
            // "Closed" in an endless loop, completely ignoring anything
            // actually said afterward.
            guard !self.synthesizer.isSpeaking, Date() >= self.speechEndCooldownUntil else { return }
            self.recognitionRequest?.append(buffer)
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
        // Deliberately NOT forcing requiresOnDeviceRecognition here: on-device
        // is meaningfully less accurate than Apple's server-based recognition,
        // confirmed live — real multi-word phrases were coming through
        // ("friday open party me") but individual words kept getting
        // mistranscribed. Leaving this at its default (false) lets iOS use
        // server-based recognition whenever a network path exists (most
        // testing) and fall back to on-device automatically when it doesn't
        // (e.g. actually connected to the puck's own AP, which has no
        // internet) — best available accuracy in both cases, not a hardcoded
        // tradeoff of accuracy for a scenario that isn't always true.
        recognitionRequest = request

        recognitionTask = speechRecognizer?.recognitionTask(with: request) { [weak self] result, error in
            // SFSpeechRecognitionTask does not guarantee this callback runs on
            // the main thread. Everything it touches below (lastHeard is
            // @Published, and handle() fires closures that mutate SwiftUI
            // @State in ContentView) needs to happen on main, or updates can
            // be silently dropped or applied unreliably — which is exactly
            // what "sometimes doesn't work" looks like from the outside.
            DispatchQueue.main.async {
                guard let self = self else { return }
                if let result = result {
                    let text = result.bestTranscription.formattedString.lowercased()
                    self.lastHeard = text
                    // Waiting for Apple's own result.isFinal was the previous
                    // fix for the runaway-accumulation bug, but isFinal
                    // depends on the recognizer's own internal silence
                    // detection, which can be slow or just not fire at all
                    // in casual continuous listening — meaning commands could
                    // stop firing almost entirely. Self-timed debounce
                    // instead: restart a short timer on every partial update;
                    // once the transcript stops growing for silenceTimeout,
                    // that's treated as "done speaking" — same fix for the
                    // original bug (old words can't keep accumulating
                    // forever), but on a timeout this code controls directly
                    // instead of depending on Speech's own opaque timing.
                    self.silenceTimer?.invalidate()
                    self.silenceTimer = Timer.scheduledTimer(withTimeInterval: self.silenceTimeout, repeats: false) { [weak self] _ in
                        self?.handle(text: text)
                        self?.recognitionTask?.finish() // force this segment to end so a fresh one starts
                    }
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
    }

    // No wake-word requirement — matches directly on command words, the way
    // this originally worked. Requiring "Friday" first (added, then debugged
    // through a real segmentation bug, then fixed) was strictly less
    // reliable than this: it meant needing Speech to correctly recognize
    // TWO things — the wake word and the command — instead of just one.
    // That's an inherent tradeoff of a wake word, not a bug to fix, and the
    // call to drop it back to direct matching was made deliberately, not by
    // accident.
    private func handle(text: String) {
        let now = Date()
        guard now.timeIntervalSince(lastCommandTime) > 1.5 else { return }

        // Every branch below speaks a short confirmation after acting, so
        // you always hear *something* telling you what it understood —
        // that's most of what makes Siri feel "conversational" for simple
        // commands like these, not actual back-and-forth dialogue (which
        // would need real language understanding, not string matching).
        // onReadColor and onLabelPart already speak their own result inside
        // ContentView, so they're not duplicated here; same for tryLoadModel,
        // which speaks the specific file's name from where it's loaded.
        var matched = true
        if text.contains("reset") {
            onReset?()
            speak("Resetting")
        } else if text.contains("center") || text.contains("centre") {
            onRecenter?()
            speak("Centered")
        } else if text.contains("close") || text.contains("cancel") || text.contains("dismiss") {
            onCloseImporter?()
            speak("Closed")
        } else if tryLoadModel(text) {
            // Handled inside tryLoadModel — loads a model already bundled
            // with the app, no touch needed. Unlike "import," which still
            // requires tapping a file in Apple's own system picker (there's
            // no API for a third-party app to select an item inside that
            // picker programmatically).
        } else if text.contains("import") {
            onImportModel?()
            speak("Opening the file browser")
        } else if text.contains("calibrate") && text.contains("white") {
            onCalibrateWhite?()
            speak("Calibrating white point")
        } else if text.contains("calibrate") && text.contains("black") {
            onCalibrateBlack?()
            speak("Calibrating black point")
        } else if text.contains("color") && (text.contains("what") || text.contains("tell") || text.contains("which")) {
            onReadColor?()
        } else if text.contains("use sensor") || text.contains("live color") {
            onClearColorOverride?()
            speak("Using live sensor color")
        } else if text.contains("color"), let entry = namedColors.first(where: { text.contains($0.name.lowercased()) }) {
            onSetColor?(entry.name)
            speak("Setting color to \(entry.name)")
        } else if text.contains("explode") || text.contains("separate") || text.contains("apart") {
            onExplode?()
            speak("Exploding")
        } else if text.contains("collapse") || text.contains("together") || text.contains("reassemble") {
            onCollapse?()
            speak("Collapsing")
        } else if let label = extractLabel(from: text) {
            onLabelPart?(label)
        } else {
            matched = false
        }

        if matched {
            lastCommandTime = now
        }
    }

    // Looks for a labeling trigger phrase and, if found, returns everything
    // spoken after it as the label — "label this left ventricle" and just
    // "label left ventricle" both yield "left ventricle". Order matters:
    // the longer "X this"/"X it" phrasings are checked first, so if someone
    // does say "this"/"it," it isn't accidentally captured as part of the
    // label itself — only checked against the bare word as a fallback.
    // Bare "call" is deliberately left out (unlike bare "label"/"name") —
    // it's common enough in ordinary conversation that it'd misfire far
    // more often, now that there's no wake word gating this anymore.
    private let labelTriggers = ["label this", "label it", "name this", "name it", "call this", "call it", "label", "name"]

    private func extractLabel(from text: String) -> String? {
        for trigger in labelTriggers {
            guard let range = text.range(of: trigger) else { continue }
            let after = text[range.upperBound...].trimmingCharacters(in: .whitespaces)
            guard !after.isEmpty else { return nil }
            // A label is a short name ("left ventricle"), not a sentence —
            // capped defensively even now that only finalized speech is
            // acted on, in case someone keeps talking after the trigger.
            let words = after.split(separator: " ").prefix(4)
            return words.joined(separator: " ")
        }
        return nil
    }

    // Scores every registered model option by how many of its alias words
    // appear in the phrase and loads whichever scores highest — this is
    // what lets "load the heart" or "show me the parts" work without
    // matching some exact predefined command name. Requires at least one
    // generic load-ish word too, so a sentence that happens to mention
    // "heart" for an unrelated reason doesn't trigger a load by accident.
    // Ties go to whichever option was registered first.
    private func tryLoadModel(_ text: String) -> Bool {
        guard !modelOptions.isEmpty else { return false }
        guard modelLoadIntentWords.contains(where: { text.contains($0) }) else { return false }

        var bestScore = 0
        var bestOption: VoiceModelOption?
        for option in modelOptions {
            let score = option.aliases.reduce(0) { $0 + (text.contains($1) ? 1 : 0) }
            if score > bestScore {
                bestScore = score
                bestOption = option
            }
        }
        guard let best = bestOption, bestScore > 0 else { return false }
        best.action()
        return true
    }
}

extension VoiceCommandManager: AVSpeechSynthesizerDelegate {
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        speechEndCooldownUntil = Date().addingTimeInterval(0.4)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        speechEndCooldownUntil = Date().addingTimeInterval(0.4)
    }
}

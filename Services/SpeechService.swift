import AVFoundation
import Foundation
import Speech

@MainActor
final class SpeechService: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    enum RecordingState {
        case idle
        case requestingPermission
        case recording
        case unavailable(String)
    }

    private let recognizer = SFSpeechRecognizer()
    private let audioEngine = AVAudioEngine()
    private let speechSynthesizer = AVSpeechSynthesizer()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?

    @Published var state: RecordingState = .idle
    @Published var transcript = ""
    @Published var isSpeaking = false
    @Published var autoSpeak: Bool {
        didSet {
            UserDefaults.standard.set(autoSpeak, forKey: "speech.autoSpeak")
            if autoSpeak == false {
                stopSpeaking()
            }
        }
    }
    @Published var speechRate: Double {
        didSet {
            UserDefaults.standard.set(speechRate, forKey: "speech.rate")
        }
    }

    override init() {
        let storedRate = UserDefaults.standard.object(forKey: "speech.rate") as? Double
        self.speechRate = storedRate ?? 0.39
        self.autoSpeak = UserDefaults.standard.object(forKey: "speech.autoSpeak") as? Bool ?? true
        super.init()
        speechSynthesizer.delegate = self
    }

    var isRecording: Bool {
        if case .recording = state { return true }
        return false
    }

    func toggleRecording() {
        if isRecording {
            stopRecording()
        } else {
            Task { await startRecording() }
        }
    }

    func startRecording() async {
        state = .requestingPermission

        let speechStatus = await requestSpeechAuthorization()
        guard speechStatus == .authorized else {
            state = .unavailable("Speech recognition permission is needed to learn by voice.")
            return
        }

        let audioStatus = await requestMicrophoneAuthorization()
        guard audioStatus else {
            state = .unavailable("Microphone permission is needed to hear your questions.")
            return
        }

        do {
            try configureRecognition()
            transcript = ""
            state = .recording
        } catch {
            state = .unavailable(error.localizedDescription)
        }
    }

    func stopRecording() {
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionRequest = nil
        recognitionTask = nil
        state = .idle
    }

    func speak(_ text: String) {
        guard autoSpeak else { return }

        speechSynthesizer.stopSpeaking(at: .immediate)

        let utterance = AVSpeechUtterance(string: spokenText(from: text))
        utterance.voice = preferredVoice()
        utterance.rate = Float(speechRate)
        utterance.pitchMultiplier = 1.0
        utterance.volume = 0.95
        utterance.preUtteranceDelay = 0.08
        utterance.postUtteranceDelay = 0.18

        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        speechSynthesizer.speak(utterance)
    }

    func stopSpeaking() {
        speechSynthesizer.stopSpeaking(at: .immediate)
        isSpeaking = false
    }

    func previewVoice() {
        speak("Hey, I am Accordian. I can answer from your saved notes and help you understand them.")
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        Task { @MainActor in
            isSpeaking = true
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            isSpeaking = false
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in
            isSpeaking = false
        }
    }

    private func configureRecognition() throws {
        recognitionTask?.cancel()
        recognitionTask = nil

        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.record, mode: .measurement, options: .duckOthers)
        try audioSession.setActive(true, options: .notifyOthersOnDeactivation)

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        recognitionRequest = request

        guard let recognizer, recognizer.isAvailable else {
            throw SpeechServiceError.recognizerUnavailable
        }
        guard recognizer.supportsOnDeviceRecognition else {
            throw SpeechServiceError.onDeviceRecognitionUnavailable
        }

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self else { return }
                if let result {
                    self.transcript = result.bestTranscription.formattedString
                }
                if error != nil || result?.isFinal == true {
                    self.stopRecording()
                }
            }
        }

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1_024, format: format) { [weak request] buffer, _ in
            request?.append(buffer)
        }

        audioEngine.prepare()
        try audioEngine.start()
    }

    private func requestSpeechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }

    private func requestMicrophoneAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { isAllowed in
                continuation.resume(returning: isAllowed)
            }
        }
    }

    private func preferredVoice() -> AVSpeechSynthesisVoice? {
        let voices = AVSpeechSynthesisVoice.speechVoices()
        let preferredNames = ["Ava", "Samantha", "Nicky", "Allison"]

        for name in preferredNames {
            if let voice = voices.first(where: { $0.language == "en-US" && $0.name == name && $0.quality == .premium }) {
                return voice
            }

            if let voice = voices.first(where: { $0.language == "en-US" && $0.name == name && $0.quality == .enhanced }) {
                return voice
            }
        }

        if let premiumVoice = voices.first(where: { $0.language == "en-US" && $0.quality == .premium }) {
            return premiumVoice
        }

        return voices.first { $0.language == "en-US" && $0.quality == .enhanced }
            ?? AVSpeechSynthesisVoice(language: "en-US")
    }

    private func spokenText(from text: String) -> String {
        text
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "#", with: "")
            .replacingOccurrences(of: "- ", with: "")
            .replacingOccurrences(of: "•", with: "")
            .replacingOccurrences(of: "Front:", with: "Front.")
            .replacingOccurrences(of: "Back:", with: "Back.")
            .replacingOccurrences(of: "Quiz Me", with: "quiz me")
            .replacingOccurrences(of: "\n\n", with: ". ")
            .replacingOccurrences(of: "\n", with: ". ")
    }
}

enum SpeechServiceError: LocalizedError {
    case recognizerUnavailable
    case onDeviceRecognitionUnavailable

    var errorDescription: String? {
        switch self {
        case .recognizerUnavailable:
            "Speech recognition is unavailable on this device."
        case .onDeviceRecognitionUnavailable:
            "On-device speech recognition is unavailable on this simulator or device."
        }
    }
}

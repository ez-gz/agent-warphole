import Foundation
import Speech
import AVFoundation

/// Streams live on-device speech recognition into `transcript` as the user speaks.
/// Tap start() → words appear in real time → tap stop() to finalize.
@MainActor
final class DictationEngine: ObservableObject {
    @Published var transcript: String = ""
    @Published var isRecording: Bool = false
    @Published var isAvailable: Bool = false
    @Published var permissionDenied: Bool = false

    private let recognizer: SFSpeechRecognizer? = {
        SFSpeechRecognizer(locale: Locale.current) ?? SFSpeechRecognizer(locale: Locale(identifier: "en_US"))
    }()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()

    init() {
        Task { await requestPermissions() }
    }

    // MARK: - Permissions

    private func requestPermissions() async {
        let speechAuth = await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0) }
        }

        let micGranted: Bool
        if #available(iOS 17.0, *) {
            micGranted = await AVAudioApplication.requestRecordPermission()
        } else {
            micGranted = await withCheckedContinuation { cont in
                AVAudioSession.sharedInstance().requestRecordPermission { cont.resume(returning: $0) }
            }
        }

        if speechAuth == .denied || speechAuth == .restricted || !micGranted {
            permissionDenied = true
            isAvailable = false
            return
        }

        isAvailable = speechAuth == .authorized && micGranted && (recognizer?.isAvailable == true)
    }

    // MARK: - Control

    func toggle() {
        isRecording ? stop() : start()
    }

    func start() {
        guard !isRecording else { return }
        guard recognizer?.isAvailable == true else {
            if !isAvailable { Task { await requestPermissions() } }
            return
        }

        do {
            transcript = ""

            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)

            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            request.requiresOnDeviceRecognition = false   // cloud = faster, more accurate
            request.taskHint = .dictation
            if #available(iOS 16.0, *) {
                request.addsPunctuation = true
            }
            recognitionRequest = request

            recognitionTask = recognizer?.recognitionTask(with: request) { [weak self] result, error in
                guard let self else { return }
                Task { @MainActor in
                    if let result {
                        self.transcript = result.bestTranscription.formattedString
                    }
                    if error != nil || result?.isFinal == true {
                        self.stopAudioEngine()
                        self.isRecording = false
                    }
                }
            }

            let inputNode = audioEngine.inputNode
            let format = inputNode.outputFormat(forBus: 0)
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
                self?.recognitionRequest?.append(buffer)
            }

            audioEngine.prepare()
            try audioEngine.start()
            isRecording = true
        } catch {
            stopAudioEngine()
        }
    }

    func stop() {
        guard isRecording else { return }
        recognitionRequest?.endAudio()
        stopAudioEngine()
        isRecording = false
    }

    private func stopAudioEngine() {
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionTask?.cancel()
        recognitionRequest = nil
        recognitionTask = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

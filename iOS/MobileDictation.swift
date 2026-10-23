import AVFoundation
import Speech

/// Ditado só no aparelho: as notas sobre a fotografia não saem do iPhone.
@MainActor @Observable
final class MobileDictation {
    enum Problem { case denied, unavailable, failed(String) }

    var transcript = ""
    private(set) var isRecording = false
    private(set) var problem: Problem?
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    /// O que já estava escrito antes de começar a ditar; o ditado acrescenta a seguir.
    private var prefix = ""

    func toggle(portuguese: Bool) async {
        if isRecording { stop() } else { await start(portuguese: portuguese) }
    }

    func start(portuguese: Bool) async {
        problem = nil
        guard await Self.authorize() else { problem = .denied; return }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: portuguese ? "pt-PT" : "en-US")),
              recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else { problem = .unavailable; return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            request.requiresOnDeviceRecognition = true
            request.addsPunctuation = true
            Self.feed(engine.inputNode, into: request)
            engine.prepare()
            try engine.start()
            prefix = transcript.isEmpty ? "" : transcript + " "
            self.request = request
            task = Self.recognize(request, with: recognizer) { [weak self] text, done in
                guard let self else { return }
                if let text { self.transcript = self.prefix + text }
                if done { self.stop() }
            }
            isRecording = true
        } catch {
            stop()
            problem = .failed(error.localizedDescription)
        }
    }

    func stop() {
        if engine.isRunning {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
        request?.endAudio()
        task?.finish()
        request = nil
        task = nil
        guard isRecording else { return }
        isRecording = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private static func authorize() async -> Bool {
        let speech = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard speech == .authorized else { return false }
        return await AVAudioApplication.requestRecordPermission()
    }

    // Os blocos de áudio e de reconhecimento correm fora da main thread, por isso nascem fora do MainActor.

    private nonisolated static func feed(_ input: AVAudioInputNode, into request: SFSpeechAudioBufferRecognitionRequest) {
        input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { buffer, _ in
            request.append(buffer)
        }
    }

    private nonisolated static func recognize(_ request: SFSpeechAudioBufferRecognitionRequest, with recognizer: SFSpeechRecognizer,
                                              update: @escaping @MainActor (String?, Bool) -> Void) -> SFSpeechRecognitionTask {
        recognizer.recognitionTask(with: request) { result, error in
            let text = result?.bestTranscription.formattedString
            let done = (result?.isFinal ?? false) || error != nil
            Task { @MainActor in update(text, done) }
        }
    }
}

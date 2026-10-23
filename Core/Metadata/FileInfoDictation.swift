import AVFoundation
import Speech

/// Ditado só no aparelho: as notas sobre a fotografia não saem do iPhone nem do Mac.
@MainActor @Observable
final class FileInfoDictation {
    enum Problem { case denied, unavailable, failed(String) }

    var transcript = ""
    private(set) var isRecording = false
    private(set) var problem: Problem?
    private let engine = AVAudioEngine()
    /// Guardado enquanto se dita: sem referência forte, o reconhecimento pode parar a meio.
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var tapInstalled = false
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
            #if os(iOS)
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            let inputAvailable = session.isInputAvailable
            #else
            // No Mac não há sessão de áudio: sem microfone, o formato da entrada vem vazio.
            let inputAvailable = true
            #endif
            // Sem microfone (ou com um formato inválido) o installTap lança uma exceção que fecha a app.
            let format = engine.inputNode.outputFormat(forBus: 0)
            guard inputAvailable, format.sampleRate > 0, format.channelCount > 0 else {
                stop()
                Self.deactivateSession()
                problem = .unavailable
                return
            }
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            request.requiresOnDeviceRecognition = true
            request.addsPunctuation = true
            Self.feed(engine.inputNode, format: format, into: request)
            tapInstalled = true
            engine.prepare()
            try engine.start()
            prefix = transcript.isEmpty ? "" : transcript + " "
            self.request = request
            self.recognizer = recognizer
            task = Self.recognize(request, with: recognizer) { [weak self] text, done in
                guard let self else { return }
                if let text { self.transcript = self.prefix + text }
                if done { self.stop() }
            }
            isRecording = true
        } catch {
            stop()
            Self.deactivateSession()
            problem = .failed(error.localizedDescription)
        }
    }

    func stop() {
        if engine.isRunning { engine.stop() }
        // Também depois de um arranque falhado, senão o próximo installTap encontra o antigo e a app fecha.
        // Só se toca no inputNode se já foi usado: criá-lo liga o hardware de áudio.
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        request?.endAudio()
        task?.finish()
        request = nil
        task = nil
        recognizer = nil
        guard isRecording else { return }
        isRecording = false
        Self.deactivateSession()
    }

    private static func deactivateSession() {
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    // O sistema responde ao pedido de autorização numa fila qualquer; se o bloco herdasse o MainActor, a app fechava.
    private nonisolated static func authorize() async -> Bool {
        let speech = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard speech == .authorized else { return false }
        return await AVAudioApplication.requestRecordPermission()
    }

    // Os blocos de áudio e de reconhecimento também correm fora da main thread, por isso nascem fora do MainActor.

    private nonisolated static func feed(_ input: AVAudioInputNode, format: AVAudioFormat, into request: SFSpeechAudioBufferRecognitionRequest) {
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
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

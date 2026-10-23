import SwiftUI

/// Ditar notas sobre a fotografia e, com Apple Intelligence, deixar a IA propor o file info. Nada é aplicado sem confirmação.
struct MobileFileInfoAssistant: View {
    @Environment(AppState.self) private var app
    @Binding var fields: IPTCFields
    @Binding var changed: Set<String>
    let photo: Photo?
    @State private var dictation = MobileDictation()
    @State private var proposal: FileInfoProposal?
    @State private var thinking = false
    @State private var failure: String?

    private var portuguese: Bool { app.language == .pt }
    private var aiStatus: FileInfoAI.Status { FileInfoAI.status(portuguese: portuguese) }
    private var aiAvailable: Bool { aiStatus == .ready }
    private var notes: String { dictation.transcript.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        Section {
            TextField(app.m("Notes about this photograph", "Notas sobre esta fotografia"), text: $dictation.transcript, axis: .vertical)
                .lineLimit(2...6)
                .accessibilityIdentifier("fileinfo-notes")
            HStack {
                Button {
                    Task { await dictation.toggle(portuguese: portuguese) }
                } label: {
                    Label(dictation.isRecording ? app.m("Stop", "Parar") : app.m("Dictate", "Ditar"),
                          systemImage: dictation.isRecording ? "stop.circle.fill" : "mic")
                }
                .accessibilityIdentifier("fileinfo-dictate")
                Spacer()
                if aiAvailable {
                    Button { propose() } label: { Label(app.m("Fill with AI", "Preencher com IA"), systemImage: "sparkles") }
                        .disabled(notes.isEmpty || thinking)
                        .accessibilityIdentifier("fileinfo-ai")
                } else {
                    Button(app.m("Use as caption", "Usar como legenda")) {
                        dictation.stop()
                        fields.caption = notes
                        changed.insert("caption")
                    }
                    .disabled(notes.isEmpty)
                    .accessibilityIdentifier("fileinfo-use-caption")
                }
            }
            .buttonStyle(.borderless)
            if thinking { ProgressView(app.m("Writing a proposal…", "A preparar uma proposta…")) }
            if let proposal {
                if proposal.isEmpty {
                    Text(app.m("The notes did not give enough to fill any field.", "As notas não chegam para preencher nenhum campo."))
                } else {
                    ForEach(proposal.entries) { entry in
                        LabeledContent(app.t(entry.spec.labelKey)) { Text(entry.value).multilineTextAlignment(.trailing) }
                    }
                    HStack {
                        Button(app.m("Apply proposal", "Aplicar proposta")) {
                            let result = proposal.applied(to: fields)
                            fields = result.fields
                            changed.formUnion(result.changed)
                            self.proposal = nil
                        }
                        .accessibilityIdentifier("fileinfo-apply")
                        Spacer()
                        Button(app.m("Discard", "Descartar"), role: .destructive) { self.proposal = nil }
                    }
                    .buttonStyle(.borderless)
                }
            }
            if let message { Text(message).foregroundStyle(.red) }
        } header: {
            Text(app.m("Assistant", "Assistente"))
        } footer: {
            switch aiStatus {
            case .ready:
                Text(app.m("Dictation and AI run on this device. Check names and facts before saving.",
                           "O ditado e a IA funcionam no aparelho. Confirma nomes e factos antes de guardar."))
            case .preparing:
                Text(app.m("Dictation runs on this device. Filling with AI will appear once Apple Intelligence finishes downloading.",
                           "O ditado funciona no aparelho. Preencher com IA aparece quando o Apple Intelligence acabar de descarregar."))
            case .unavailable:
                Text(app.m("Dictation runs on this device. Filling with AI needs Apple Intelligence.",
                           "O ditado funciona no aparelho. Preencher com IA precisa do Apple Intelligence."))
            }
        }
        .onDisappear { dictation.stop() }
    }

    private var message: String? {
        if let failure { return failure }
        switch dictation.problem {
        case .denied: return app.m("Allow the microphone and speech recognition in Settings to dictate.",
                                   "Autoriza o microfone e o reconhecimento de fala nas Definições para ditar.")
        case .unavailable: return app.m("Dictation on this device is not available for this language. Use the keyboard microphone.",
                                        "O ditado no aparelho não está disponível para esta língua. Usa o microfone do teclado.")
        case .failed(let text): return text
        case nil: return nil
        }
    }

    private func propose() {
        dictation.stop()
        failure = nil
        thinking = true
        let notes = notes, fields = fields, portuguese = portuguese
        let date = photo?.captureDate, camera = photo?.camera, url = photo?.url
        Task {
            defer { thinking = false }
            let scene = await Task.detached { url.map { AutoKeywords.suggest(url: $0) } ?? [] }.value
            do {
                proposal = try await FileInfoAI.propose(notes: notes, date: date, camera: camera, fields: fields,
                                                        sceneKeywords: scene, portuguese: portuguese)
            } catch {
                failure = app.m("The AI could not write a proposal. Try again, or fill in the fields yourself.",
                                "A IA não conseguiu preparar uma proposta. Tenta outra vez, ou preenche os campos à mão.")
            }
        }
    }
}

import SwiftUI

/// O assistente do file info no Mac: ditar notas sobre a fotografia e, com Apple Intelligence, deixar a IA propor os campos.
/// Nada é aplicado sem confirmação, e tudo corre no próprio Mac.
struct FileInfoAssistant: View {
    @Environment(AppState.self) private var app
    @Binding var fields: IPTCFields
    /// Em "Todas juntas" não há uma foto só: a data, a câmara e o que se vê na imagem ficam de fora.
    let photo: Photo?
    @State private var dictation = FileInfoDictation()
    @State private var proposal: FileInfoProposal?
    @State private var thinking = false
    @State private var failure: String?

    private var portuguese: Bool { app.language == .pt }
    private var aiStatus: FileInfoAI.Status { FileInfoAI.status(portuguese: portuguese) }
    private var notes: String { dictation.transcript.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(app.t("assistant.title").uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(Palette.textSecondary)
            TextField(app.t("assistant.notes"), text: $dictation.transcript, axis: .vertical)
                .lineLimit(2...4)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("fileinfo-notes")
            HStack {
                Button {
                    Task { await dictation.toggle(portuguese: portuguese) }
                } label: {
                    Label(dictation.isRecording ? app.t("assistant.stop") : app.t("assistant.dictate"),
                          systemImage: dictation.isRecording ? "stop.circle.fill" : "mic")
                }
                .accessibilityIdentifier("fileinfo-dictate")
                Spacer()
                if aiStatus == .ready {
                    Button { propose() } label: { Label(app.t("assistant.fillAI"), systemImage: "sparkles") }
                        .disabled(notes.isEmpty || thinking)
                        .accessibilityIdentifier("fileinfo-ai")
                } else {
                    Button(app.t("assistant.useCaption")) {
                        dictation.stop()
                        fields.caption = notes
                    }
                    .disabled(notes.isEmpty)
                    .accessibilityIdentifier("fileinfo-use-caption")
                }
            }
            if thinking { ProgressView(app.t("assistant.thinking")).controlSize(.small) }
            if let proposal { proposalView(proposal) }
            if let message { Text(message).font(Typography.caption).foregroundStyle(Brand.error) }
            Text(footer)
                .font(Typography.caption)
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .background(Palette.panel, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Palette.separator))
        .onDisappear { dictation.stop() }
        // Outra foto (em "Uma a uma"): a proposta e as notas eram da anterior.
        .onChange(of: photo?.id) { _, _ in
            dictation.stop()
            dictation.transcript = ""
            proposal = nil
            failure = nil
        }
    }

    @ViewBuilder
    private func proposalView(_ proposal: FileInfoProposal) -> some View {
        if proposal.isEmpty {
            Text(app.t("assistant.empty"))
                .font(Typography.caption)
        } else {
            ScrollView {
                Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 4) {
                    ForEach(proposal.entries) { entry in
                        GridRow {
                            Text(app.t(entry.spec.labelKey) + ":").foregroundStyle(Palette.textSecondary)
                            Text(entry.value).textSelection(.enabled)
                        }
                        .font(Typography.caption)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 150)
            HStack {
                Button(app.t("assistant.discard"), role: .destructive) { self.proposal = nil }
                Spacer()
                Button(app.t("assistant.apply")) {
                    fields = proposal.applied(to: fields).fields
                    self.proposal = nil
                }
                .accessibilityIdentifier("fileinfo-apply")
            }
        }
    }

    private var footer: String {
        switch aiStatus {
        case .ready:
            app.t("assistant.footerReady")
        case .preparing:
            app.t("assistant.footerPreparing")
        case .unavailable:
            app.t("assistant.footerUnavailable")
        }
    }

    private var message: String? {
        if let failure { return failure }
        switch dictation.problem {
        case .denied: return app.t("assistant.denied")
        case .unavailable: return app.t("assistant.unavailable")
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
                failure = app.t("assistant.failed")
            }
        }
    }
}

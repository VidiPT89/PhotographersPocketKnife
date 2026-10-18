import SwiftUI
import SwiftData

struct MobileSettings: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \UploadDestination.name) private var destinations: [UploadDestination]
    @State private var modelProgress = 0.0
    @State private var installing = false
    @State private var message: String?
    @State private var rosterPicker = false
    @State private var watchPicker = false
    @State private var modelsVersion = 0
    @State private var backupPicker = false
    @AppStorage("mobile.import.template") private var importTemplate = "{date}"
    @AppStorage("mobile.import.event") private var importEvent = ""
    @AppStorage("mobile.import.backup") private var backupPath = ""
    var body: some View {
        @Bindable var state = app
        @Bindable var hot = app.hotFolder
        @Bindable var watch = app.watchFolder
        @Bindable var queue = app.transfers
        Form {
            Section {
                HStack(spacing: 14) {
                    Image("BrandIcon").resizable().frame(width: 66, height: 66).clipShape(RoundedRectangle(cornerRadius: 14))
                    VStack(alignment: .leading) { Text("Photographer's Pocket Knife").font(.headline); Text("David Arsénio Martins · iVidi.dev").font(.caption).foregroundStyle(.secondary) }
                }
                Picker(app.m("Language", "Idioma"), selection: $state.language) { Text("English").tag(AppLanguage.en); Text("Português (Portugal)").tag(AppLanguage.pt) }.accessibilityIdentifier("mobile-language")
                Picker(app.m("Appearance", "Aspeto"), selection: $state.theme) { ForEach(AppTheme.allCases) { Text(app.t($0.labelKey)).tag($0) } }
                Toggle(app.m("Save .ppk sidecars", "Guardar ficheiros .ppk"), isOn: Bindable(app.sidecars).isEnabled)
            }
            Section {
                NavigationLink(app.m("Open-source licences", "Licenças de código aberto")) {
                    ScrollView { Text((Bundle.main.url(forResource: "ThirdPartyNotices", withExtension: "txt").flatMap { try? String(contentsOf: $0, encoding: .utf8) }) ?? "").font(.caption).textSelection(.enabled).padding() }
                        .navigationTitle(app.m("Licences", "Licenças"))
                }
            }
            Section(app.m("Import", "Importação")) {
                TextField(app.m("Session / event", "Sessão / evento"), text: $importEvent)
                TextField(app.m("Folder template", "Modelo de pastas"), text: $importTemplate)
                Text(IngestTemplate.tokens.joined(separator: " ")).font(.caption)
                Button(app.m("Choose simultaneous backup folder", "Escolher pasta de cópia de segurança simultânea")) { backupPicker = true }
                if !backupPath.isEmpty {
                    Text(backupPath).font(.caption).lineLimit(2)
                    Button(app.m("Disable backup", "Desativar cópia de segurança")) { backupPath = "" }
                }
                Text(app.m("Every imported copy is verified with SHA-256.", "Todas as cópias importadas são verificadas com SHA-256.")).font(.caption)
            }
            Section(app.m("Local models", "Modelos locais")) {
                Text(app.m("Optional downloads for object selection and generative removal. Processing stays on this device.", "Downloads opcionais para seleção de objetos e remoção generativa. O processamento fica neste dispositivo."))
                Button(GenerativeInpainter.shared.isInstalled ? app.m("Removal model installed", "Modelo de remoção instalado") : app.m("Download removal model (94 MB)", "Descarregar modelo de remoção (94 MB)")) { install(false) }.disabled(installing || GenerativeInpainter.shared.isInstalled)
                Button(SegmentAnything.shared.isInstalled ? app.m("Selection model installed", "Modelo de seleção instalado") : app.m("Download object selection model", "Descarregar modelo de seleção de objetos")) { install(true) }.disabled(installing || SegmentAnything.shared.isInstalled)
                if installing { ProgressView(value: modelProgress) }
                if let message { Text(message).font(.caption) }
            }.id(modelsVersion)
            Section(app.m("Code replacements", "Substituições de código")) {
                Text(CodeReplacementStore.fileName ?? app.m("No roster imported", "Nenhuma lista importada"))
                Button(app.m("Import tab-separated roster", "Importar lista separada por tabulações")) { rosterPicker = true }
                Text(app.m("Use =7= in captions to insert the matching name.", "Usa =7= nas legendas para inserir o nome correspondente.")).font(.caption)
            }
            Section(app.m("Automatic delivery", "Entrega automática")) {
                Toggle(app.m("Export and upload labelled photos", "Exportar e enviar fotografias etiquetadas"), isOn: $hot.isEnabled)
                Picker(app.m("Label", "Etiqueta"), selection: $hot.label) { ForEach(ColorLabel.allCases) { Text(app.t($0.labelKey)).tag($0) } }
                Picker(app.m("Destination", "Destino"), selection: $hot.destinationID) {
                    Text(app.m("None", "Nenhum")).tag(nil as UUID?)
                    ForEach(destinations) { Text($0.name).tag(Optional($0.id)) }
                }
                TextField(app.m("Event", "Evento"), text: $hot.event)
                Stepper(app.m("Concurrent transfers: \(queue.maxConcurrent)", "Envios simultâneos: \(queue.maxConcurrent)"), value: $queue.maxConcurrent, in: 1...4)
                Stepper(app.m("Maximum attempts: \(queue.maxAttempts)", "Máximo de tentativas: \(queue.maxAttempts)"), value: $queue.maxAttempts, in: 1...6)
            }
            Section(app.m("Watched folder", "Pasta vigiada")) {
                Toggle(app.m("Import incoming photographs", "Importar fotografias recebidas"), isOn: $watch.isEnabled)
                Button(app.m("Choose folder", "Escolher pasta")) { watchPicker = true }
                Text(watch.folderPath).font(.caption).lineLimit(2)
                TextField(app.m("Session name", "Nome da sessão"), text: $watch.sessionName)
                Text(app.m("Folder monitoring and transfers run while the app is active. Reopen the app to continue.", "A vigilância de pastas e os envios funcionam enquanto a app está ativa. Reabre a app para continuar.")).font(.caption)
            }
        }.navigationTitle(app.m("Settings", "Definições"))
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(app.m("Done", "Concluído")) { dismiss() } } }
            .fileImporter(isPresented: $backupPicker, allowedContentTypes: [.folder]) { result in
                do {
                    let url = try result.get()
                    let access = url.startAccessingSecurityScopedResource()
                    FolderAccess.shared.remember(url)
                    backupPath = url.path
                    if access { url.stopAccessingSecurityScopedResource() }
                } catch { message = error.localizedDescription }
            }
            .fileImporter(isPresented: $rosterPicker, allowedContentTypes: [.plainText, .data]) { result in
                do {
                    let url = try result.get(); let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
                    CodeReplacementStore.save(text: try CodeReplacementStore.readText(url), fileName: url.lastPathComponent)
                    app.showToast(app.m("Roster imported", "Lista importada"))
                } catch { message = error.localizedDescription }
            }
            .fileImporter(isPresented: $watchPicker, allowedContentTypes: [.folder]) { result in
                do {
                    let url = try result.get()
                    _ = url.startAccessingSecurityScopedResource()
                    FolderAccess.shared.remember(url)
                    watch.folderPath = url.path
                } catch { message = error.localizedDescription }
            }
    }
    private func install(_ selection: Bool) {
        installing = true; modelProgress = 0; message = nil
        Task {
            do {
                let progress: @Sendable (Double) -> Void = { value in Task { @MainActor in modelProgress = value } }
                if selection { try await SegmentAnything.shared.install(progress: progress) }
                else { try await GenerativeInpainter.shared.install(progress: progress) }
                modelsVersion += 1
            } catch { message = error.localizedDescription }
            installing = false
        }
    }
}

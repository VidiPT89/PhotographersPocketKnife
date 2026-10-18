import SwiftUI
import SwiftData
import Photos

struct MobileExport: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \UploadDestination.name) private var destinations: [UploadDestination]
    let photos: [Photo]
    @State private var settings = ExportPresetStore.lastSettings
    @State private var destinationID = DestinationDefaults.storedID
    @State private var progress = 0
    @State private var working = false
    @State private var cancelled = false
    @State private var files: [URL] = []
    @State private var failure: String?
    @State private var failedIDs: Set<UUID> = []
    @State private var jobCount = 0
    @State private var savingToPhotos = false
    @State private var shares: SharedFiles?
    @State private var presetName = ""
    @State private var presets = ExportPresetStore.presets()
    var body: some View {
        Form {
            Group {
            Section(app.m("Format", "Formato")) {
                Text(app.m("\(photos.count) photographs", "\(photos.count) fotografias"))
                Picker(app.m("Format", "Formato"), selection: $settings.format) {
                    ForEach(ExportFormat.allCases) { Text($0.displayName).tag($0) }
                }
                if settings.format.supportsQuality { Slider(value: $settings.quality, in: 0.1...1) { Text(app.m("Quality", "Qualidade")) } }
                if settings.format.supports16Bit { Toggle("16-bit", isOn: $settings.sixteenBit) }
                Picker(app.m("Colour space", "Espaço de cor"), selection: $settings.colorSpace) { ForEach(ExportColorSpace.allCases) { Text($0.displayName).tag($0) } }
                TextField(app.m("Filename suffix", "Sufixo do nome"), text: $settings.suffix)
            }
            Section(app.m("Size & detail", "Tamanho e detalhe")) {
                Toggle(app.m("Resize", "Redimensionar"), isOn: $settings.resize)
                if settings.resize {
                    Picker(app.m("Resize by", "Redimensionar por"), selection: $settings.resizeMode) { ForEach(ResizeMode.allCases) { Text(app.t($0.labelKey)).tag($0) } }
                    if settings.resizeMode == .longEdge { Stepper("\(settings.longEdge) px", value: $settings.longEdge, in: 256...12000, step: 256) }
                    else { Stepper("\(settings.resizePercent)%", value: $settings.resizePercent, in: 1...100) }
                }
                Stepper("\(settings.dpi) DPI", value: $settings.dpi, in: 72...600)
                Picker(app.m("Output sharpening", "Nitidez de saída"), selection: $settings.outputSharpening) { ForEach(OutputSharpening.allCases) { Text(app.t($0.labelKey)).tag($0) } }
            }
            Section(app.m("Watermark & metadata", "Marca de água e metadados")) {
                Toggle(app.m("Watermark", "Marca de água"), isOn: $settings.watermarkEnabled)
                if settings.watermarkEnabled {
                    TextField(app.m("Text", "Texto"), text: $settings.watermarkText)
                    Picker(app.m("Position", "Posição"), selection: $settings.watermarkPosition) { ForEach(WatermarkPosition.allCases) { Text(app.t($0.labelKey)).tag($0) } }
                    Slider(value: $settings.watermarkOpacity, in: 0.1...1) { Text(app.m("Opacity", "Opacidade")) }
                    Slider(value: $settings.watermarkSize, in: 0.01...0.12) { Text(app.m("Size", "Tamanho")) }
                }
                Picker(app.m("Metadata", "Metadados"), selection: $settings.metadataRule) { ForEach(MetadataRule.allCases) { Text(app.t($0.labelKey)).tag($0) } }
            }
            Section(app.m("Presets", "Presets")) {
                ForEach(presets) { preset in Button(preset.name) { settings = preset.settings } }
                TextField(app.m("Preset name", "Nome do preset"), text: $presetName)
                Button(app.m("Save preset", "Guardar preset")) {
                    presets.append(ExportPreset(name: presetName, settings: settings)); ExportPresetStore.save(presets); presetName = ""
                }.disabled(presetName.isEmpty)
            }
            }.disabled(working || savingToPhotos)
            Section(app.m("Delivery", "Entrega")) {
                Picker(app.m("Upload after export", "Enviar após exportar"), selection: $destinationID) {
                    Text(app.m("Save to Files", "Guardar em Ficheiros")).tag(nil as UUID?)
                    ForEach(destinations) { Text($0.name).tag(Optional($0.id)) }
                }.disabled(working || savingToPhotos)
                Text(app.m("Files are saved in On My iPhone/iPad → Photographer's Pocket Knife → Exports.", "Os ficheiros ficam em No meu iPhone/iPad → Photographer's Pocket Knife → Exports."))
                    .font(.caption).foregroundStyle(.secondary)
                if working { ProgressView(value: Double(progress), total: Double(max(jobCount, 1))); Button(app.m("Cancel", "Cancelar"), role: .cancel) { cancelled = true } }
                else { Button(app.m("Export photographs", "Exportar fotografias")) { export() }.disabled(photos.isEmpty) }
                if !working && !files.isEmpty {
                    Button(app.m("Share or save files", "Partilhar ou guardar ficheiros")) { shares = SharedFiles(urls: files) }
                    if files.allSatisfy({ ["jpg", "jpeg", "heic", "png"].contains($0.pathExtension.lowercased()) }) { Button(app.m("Save to Photos", "Guardar em Fotografias")) { saveToPhotos() } }
                }
                if let failure { Text(failure).foregroundStyle(.red) }
                if !working && !failedIDs.isEmpty { Button(app.m("Retry unfinished photographs", "Repetir fotografias por concluir")) { export(retry: true) } }
            }
        }
        .disabled(savingToPhotos)
        .navigationTitle(app.m("Export", "Exportar"))
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button(app.m("Done", "Concluído")) { dismiss() }.disabled(working || savingToPhotos) } }
        .interactiveDismissDisabled(working || savingToPhotos)
        .sheet(item: $shares) { ShareFiles(urls: $0.urls) }
    }
    private func export(retry: Bool = false) {
        let settings = settings
        ExportPresetStore.lastSettings = settings
        let jobs = photos.filter { !retry || failedIDs.contains($0.id) }.map { ($0.url, $0.recipeData.flatMap { try? JSONDecoder().decode(EditRecipe.self, from: $0) } ?? EditRecipe(), $0.id) }
        let destination = destinations.first { $0.id == destinationID }
        let event = photos.first?.sessionName ?? ""
        working = true; cancelled = false; if !retry { files = [] }; failure = nil; progress = 0
        failedIDs = Set(jobs.map { $0.2 }); jobCount = jobs.count
        Task {
            var sources: [URL: UUID] = [:]
            do {
                try FileManager.default.createDirectory(at: MobileFiles.exports, withIntermediateDirectories: true)
                for (url, recipe, id) in jobs {
                    if cancelled { break }
                    do {
                        let output = try await Task.detached(priority: .userInitiated) {
                            try ImageRenderer.shared.export(url: url, recipe: recipe, settings: settings, to: MobileFiles.exports)
                        }.value
                        files.append(output); sources[output] = id; failedIDs.remove(id)
                    } catch { failedIDs.insert(id); failure = "\(url.lastPathComponent): \(error.localizedDescription)" }
                    progress += 1
                }
                if !cancelled, let destination { app.transfers.enqueue(files: Array(sources.keys), destination: destination, event: event, sources: sources) }
            } catch { failure = error.localizedDescription }
            working = false
        }
    }
    private func saveToPhotos() {
        guard !savingToPhotos else { return }
        savingToPhotos = true
        let urls = files
        Task {
            defer { savingToPhotos = false }
            let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard status == .authorized || status == .limited else { failure = app.m("Allow photo access in Settings to save photographs.", "Permite o acesso nas Definições para guardar fotografias."); return }
            do {
                try await PHPhotoLibrary.shared().performChanges {
                    for url in urls { PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: url) }
                }
                app.showToast(app.m("Saved to Photos", "Guardado em Fotografias"))
            } catch { failure = error.localizedDescription }
        }
    }
}

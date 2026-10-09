import SwiftUI
import SwiftData

struct ExportPreset: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var settings: ExportSettings
}

enum ExportPresetStore {
    private static let presetsKey = "export.presets"
    private static let lastKey = "export.lastSettings"

    static func presets() -> [ExportPreset] {
        guard let data = UserDefaults.standard.data(forKey: presetsKey) else { return [] }
        return (try? JSONDecoder().decode([ExportPreset].self, from: data)) ?? []
    }

    static func save(_ presets: [ExportPreset]) {
        UserDefaults.standard.set(try? JSONEncoder().encode(presets), forKey: presetsKey)
    }

    static var lastSettings: ExportSettings {
        get {
            UserDefaults.standard.data(forKey: lastKey).flatMap { try? JSONDecoder().decode(ExportSettings.self, from: $0) } ?? ExportSettings()
        }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: lastKey) }
    }
}

struct ExportSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \UploadDestination.name) private var destinations: [UploadDestination]
    let photos: [Photo]

    init(photos: [Photo], startWithUpload: Bool = false) {
        self.photos = photos
        _uploadAfter = State(initialValue: startWithUpload)
    }

    @State private var settings = ExportPresetStore.lastSettings
    @State private var presets = ExportPresetStore.presets()
    @State private var presetName = ""
    @AppStorage("export.folder") private var folderPath = ""
    @AppStorage("upload.tab") private var uploadTab: UploadTab = .queue
    @State private var uploadAfter = false
    @State private var destinationID: UUID?
    @State private var event = ""
    @State private var progress: Double?
    /// Pedido para parar entre fotos; a que está a ser exportada termina.
    @State private var stopRequested = false
    @State private var errors: [String] = []
    /// Fotos que falharam no último lote, para repetir só essas.
    @State private var failedIDs: Set<UUID> = []

    var body: some View {
        VStack(spacing: 0) {
            Form {
                presetsSection
                formatSection
                sizeSection
                colorSection
                watermarkSection
                Section(app.t("export.file")) {
                    Picker(app.t("export.metadataRule"), selection: $settings.metadataRule) {
                        ForEach(MetadataRule.allCases) { Text(app.t($0.labelKey)).tag($0) }
                    }
                    TextField(app.t("export.suffix"), text: $settings.suffix)
                    LabeledContent(app.t("export.folder")) {
                        HStack {
                            Text(folderPath.isEmpty ? "—" : folderPath).lineLimit(1).truncationMode(.middle)
                            Button(app.t("common.choose")) {
                                if let url = FilePanels.chooseFolder(prompt: app.t("common.choose")) { folderPath = url.path }
                            }
                        }
                    }
                }
                Section(app.t("export.andUpload")) {
                    Toggle(app.t("export.uploadAfter"), isOn: $uploadAfter.animation(Motion.snappy))
                    if uploadAfter {
                        if destinations.isEmpty {
                            Text(app.t("upload.noDestinations")).foregroundStyle(Palette.textSecondary)
                            Button(app.t("upload.tab.destinations")) {
                                uploadTab = .destinations
                                dismiss()
                                app.module = .upload
                            }
                        }
                        Picker(app.t("upload.destination"), selection: $destinationID) {
                            Text("—").tag(UUID?.none)
                            ForEach(destinations) { Text($0.name).tag(Optional($0.id)) }
                        }
                        TextField(app.t("rename.event"), text: $event)
                    }
                }
                ForEach(errors, id: \.self) { Text($0).foregroundStyle(Brand.error) }
                if !failedIDs.isEmpty, progress == nil {
                    Button(String(format: app.t("export.retryFailed"), failedIDs.count)) { startExport(only: failedIDs) }
                }
            }
            .formStyle(.grouped)
            .disabled(progress != nil)

            if let progress {
                HStack(spacing: 12) {
                    BrandProgressBar(value: progress)
                    Button(app.t("export.stop")) { stopRequested = true }
                        .disabled(stopRequested)
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
            }

            SheetButtons(
                confirmTitle: app.t("export.title"),
                confirmDisabled: folderPath.isEmpty || progress != nil || (uploadAfter && destinationID == nil),
                isWorking: progress != nil,
                cancelDisabled: progress != nil
            ) { startExport() }
        }
        .frame(width: 560, height: 760)
        .interactiveDismissDisabled(progress != nil)
        .onAppear { destinationID = destinationID ?? DestinationDefaults.preferredID(among: destinations.map(\.id)) }
    }

    private var presetsSection: some View {
        Section(app.t("export.presets")) {
            Picker(app.t("export.loadPreset"), selection: Binding<UUID?>(
                get: { presets.first { $0.settings == settings }?.id },
                set: { id in if let preset = presets.first(where: { $0.id == id }) { settings = preset.settings } }
            )) {
                Text("—").tag(UUID?.none)
                ForEach(presets) { Text($0.name).tag(Optional($0.id)) }
            }
            HStack {
                TextField(app.t("presets.name"), text: $presetName)
                Button(app.t("presets.save")) {
                    presets.append(ExportPreset(name: presetName, settings: settings))
                    ExportPresetStore.save(presets)
                    presetName = ""
                }
                .disabled(presetName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private var formatSection: some View {
        Section(String(format: app.t("export.count"), photos.count)) {
            Picker(app.t("export.format"), selection: $settings.format) {
                ForEach(ExportFormat.allCases) { Text($0.displayName).tag($0) }
            }
            if settings.format.supportsQuality {
                LabeledContent(app.t("export.quality")) {
                    Slider(value: $settings.quality, in: 0.3...1)
                    Text("\(Int(settings.quality * 100))%").monospacedDigit().frame(width: 40)
                }
            }
            if settings.format.supports16Bit {
                Toggle(app.t("export.16bit"), isOn: $settings.sixteenBit)
            }
        }
    }

    private var sizeSection: some View {
        Section(app.t("export.size")) {
            Toggle(app.t("export.resize"), isOn: $settings.resize.animation(Motion.snappy))
            if settings.resize {
                Picker(app.t("export.resizeMode"), selection: $settings.resizeMode) {
                    ForEach(ResizeMode.allCases) { Text(app.t($0.labelKey)).tag($0) }
                }
                .pickerStyle(.segmented)
                switch settings.resizeMode {
                case .longEdge: TextField(app.t("export.longEdge"), value: $settings.longEdge, format: .number)
                case .percent: Stepper("\(app.t("export.percent")): \(settings.resizePercent)%", value: $settings.resizePercent, in: 5...100, step: 5)
                }
            }
            TextField(app.t("export.dpi"), value: $settings.dpi, format: .number)
        }
    }

    private var colorSection: some View {
        Section(app.t("export.color")) {
            Picker(app.t("export.colorSpace"), selection: $settings.colorSpace) {
                ForEach(ExportColorSpace.allCases) { Text($0.displayName).tag($0) }
            }
            .disabled(settings.format == .dng)
            if settings.format == .dng {
                Text(app.t("export.dngLinear")).font(.caption).foregroundStyle(Palette.textSecondary)
            }
            Picker(app.t("export.outputSharpening"), selection: $settings.outputSharpening) {
                ForEach(OutputSharpening.allCases) { Text(app.t($0.labelKey)).tag($0) }
            }
        }
    }

    private var watermarkSection: some View {
        Section(app.t("export.watermark")) {
            Toggle(app.t("export.watermarkEnable"), isOn: $settings.watermarkEnabled.animation(Motion.snappy))
            if settings.watermarkEnabled {
                TextField(app.t("export.watermarkText"), text: $settings.watermarkText)
                Picker(app.t("export.watermarkPosition"), selection: $settings.watermarkPosition) {
                    ForEach(WatermarkPosition.allCases) { Text(app.t($0.labelKey)).tag($0) }
                }
                LabeledContent(app.t("export.watermarkOpacity")) {
                    Slider(value: $settings.watermarkOpacity, in: 0.1...1)
                    Text("\(Int(settings.watermarkOpacity * 100))%").monospacedDigit().frame(width: 40)
                }
                LabeledContent(app.t("export.watermarkSize")) {
                    Slider(value: $settings.watermarkSize, in: 0.015...0.1)
                }
                WatermarkPreview(settings: settings)
                    .frame(height: 90)
            }
        }
    }

    private func startExport(only retry: Set<UUID>? = nil) {
        let folder = URL(fileURLWithPath: folderPath, isDirectory: true)
        let settings = settings
        ExportPresetStore.lastSettings = settings
        let jobs = photos.filter { retry?.contains($0.id) ?? true }.map { photo in
            (id: photo.id, url: photo.url, recipe: photo.recipeData.flatMap { try? JSONDecoder().decode(EditRecipe.self, from: $0) } ?? EditRecipe())
        }
        let destination = destinations.first { $0.id == destinationID }
        let uploadAfter = uploadAfter
        let event = event
        progress = 0
        stopRequested = false
        errors = []
        failedIDs = []

        Task {
            var outputs: [URL] = []
            var sources: [URL: UUID] = [:]
            for (index, job) in jobs.enumerated() {
                guard !stopRequested else { break }
                let result = await Task.detached(priority: .userInitiated) { () -> Result<URL, Error> in
                    Result { try ImageRenderer.shared.export(url: job.url, recipe: job.recipe, settings: settings, to: folder) }
                }.value
                switch result {
                case .success(let url):
                    outputs.append(url)
                    sources[url] = job.id
                case .failure(let error):
                    errors.append("\(job.url.lastPathComponent): \(error.localizedDescription)")
                    failedIDs.insert(job.id)
                }
                withAnimation { progress = Double(index + 1) / Double(jobs.count) }
            }
            // Parar é sinal de que algo estava errado: o que já saiu fica na pasta, mas não é enviado.
            if stopRequested {
                progress = nil
                app.showToast(String(format: app.t("toast.exportStopped"), outputs.count), icon: "stop.circle.fill")
                if errors.isEmpty { dismiss() }
                return
            }
            if uploadAfter, let destination {
                app.transfers.enqueue(files: outputs, destination: destination, event: event, sources: sources)
                app.module = .upload
            }
            progress = nil
            if errors.isEmpty {
                app.showToast(String(format: app.t("toast.exported"), outputs.count), icon: "square.and.arrow.up.fill")
                dismiss()
            }
        }
    }
}

/// Pré-visualização da posição e do tamanho da marca de água num retângulo 3:2.
private struct WatermarkPreview: View {
    let settings: ExportSettings

    var body: some View {
        GeometryReader { geo in
            let height = geo.size.height
            let width = height * 1.5
            let fontSize = max(height * settings.watermarkSize * 1.4, 6)
            let text = settings.watermarkText.replacingOccurrences(of: "{year}", with: String(Calendar.current.component(.year, from: Date())))
            ZStack {
                LinearGradient(colors: [Color(hex: 0x3A3A44), Color(hex: 0x1A1A22)], startPoint: .top, endPoint: .bottom)
                Text(text)
                    .font(.system(size: fontSize, weight: .semibold))
                    .foregroundStyle(.white.opacity(settings.watermarkOpacity))
                    .shadow(radius: 1)
                    .lineLimit(1)
                    .padding(height * 0.06)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
            }
            .frame(width: width, height: height)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .frame(maxWidth: .infinity)
            .animation(Motion.snappy, value: settings.watermarkPosition)
        }
    }

    private var alignment: Alignment {
        switch settings.watermarkPosition {
        case .topLeft: .topLeading
        case .topRight: .topTrailing
        case .center: .center
        case .bottomLeft: .bottomLeading
        case .bottomRight: .bottomTrailing
        }
    }
}

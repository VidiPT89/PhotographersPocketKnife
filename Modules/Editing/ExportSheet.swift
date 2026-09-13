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
    @State private var uploadAfter = false
    @State private var destinationID: UUID?
    @State private var event = ""
    @State private var progress: Double?
    @State private var errors: [String] = []

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
                        Picker(app.t("upload.destination"), selection: $destinationID) {
                            Text("—").tag(UUID?.none)
                            ForEach(destinations) { Text($0.name).tag(Optional($0.id)) }
                        }
                        TextField(app.t("rename.event"), text: $event)
                    }
                }
                if let progress {
                    BrandProgressBar(value: progress)
                }
                ForEach(errors, id: \.self) { Text($0).foregroundStyle(Brand.error) }
            }
            .formStyle(.grouped)

            SheetButtons(
                confirmTitle: app.t("export.title"),
                confirmDisabled: folderPath.isEmpty || progress != nil || (uploadAfter && destinationID == nil),
                isWorking: progress != nil
            ) { startExport() }
        }
        .frame(width: 560, height: 760)
        .onAppear { destinationID = destinationID ?? destinations.first?.id }
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

    private func startExport() {
        let folder = URL(fileURLWithPath: folderPath, isDirectory: true)
        let settings = settings
        ExportPresetStore.lastSettings = settings
        let jobs = photos.map { photo in
            (url: photo.url, recipe: photo.recipeData.flatMap { try? JSONDecoder().decode(EditRecipe.self, from: $0) } ?? EditRecipe())
        }
        let destination = destinations.first { $0.id == destinationID }
        progress = 0
        errors = []

        Task {
            var outputs: [URL] = []
            for (index, job) in jobs.enumerated() {
                let result = await Task.detached(priority: .userInitiated) { () -> Result<URL, Error> in
                    Result { try ImageRenderer.shared.export(url: job.url, recipe: job.recipe, settings: settings, to: folder) }
                }.value
                switch result {
                case .success(let url): outputs.append(url)
                case .failure(let error): errors.append(error.localizedDescription)
                }
                withAnimation { progress = Double(index + 1) / Double(jobs.count) }
            }
            if uploadAfter, let destination {
                app.transfers.enqueue(files: outputs, destination: destination, event: event)
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

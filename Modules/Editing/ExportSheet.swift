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
                    Toggle(app.t("export.resize"), isOn: $settings.resize)
                    if settings.resize {
                        TextField(app.t("export.longEdge"), value: $settings.longEdge, format: .number)
                    }
                    TextField(app.t("export.suffix"), text: $settings.suffix)
                    Toggle(app.t("export.metadata"), isOn: $settings.includeMetadata)
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
                    Toggle(app.t("export.uploadAfter"), isOn: $uploadAfter)
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
        .frame(width: 520, height: 640)
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

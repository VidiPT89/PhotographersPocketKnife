import SwiftUI
import SwiftData

@Observable
@MainActor
final class GalleryProgress {
    var done = 0
}

/// Cria uma galeria para o cliente (página + fotos) e, se escolhido, envia-a para um destino.
struct GallerySheet: View {
    @Environment(AppState.self) private var app
    @Query(sort: \UploadDestination.name) private var destinations: [UploadDestination]
    let photos: [Photo]

    @State private var options = GalleryOptions()
    @AppStorage("gallery.photographer") private var photographer = ""
    @AppStorage("gallery.email") private var email = ""
    @AppStorage("gallery.website") private var website = ""
    @AppStorage("gallery.folder") private var folderPath = ""
    @State private var destinationID: UUID?
    @State private var isBuilding = false
    @State private var progress = GalleryProgress()
    @State private var result: URL?
    @State private var message: String?

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section(String(format: app.t("gallery.photos"), photos.count)) {
                    TextField(app.t("gallery.titleField"), text: $options.title)
                    TextField(app.t("gallery.photographer"), text: $photographer)
                    TextField(app.t("gallery.email"), text: $email)
                    TextField(app.t("gallery.website"), text: $website)
                }
                Section {
                    Picker(app.t("export.size"), selection: $options.longEdge) {
                        ForEach([1600, 2048, 2560], id: \.self) { Text("\($0) px").tag($0) }
                    }
                    Toggle(app.t("gallery.allowDownload"), isOn: $options.allowDownload)
                    Toggle(app.t("gallery.watermark"), isOn: $options.watermark)
                }
                Section {
                    LabeledContent(app.t("gallery.folder")) {
                        HStack {
                            Text(folderPath.isEmpty ? app.t("gallery.chooseFolder") : folderPath)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .foregroundStyle(Palette.textSecondary)
                            Button(app.t("common.choose")) {
                                if let url = FilePanels.chooseFolder(prompt: app.t("common.choose")) { folderPath = url.path }
                            }
                        }
                    }
                    Picker(app.t("gallery.upload"), selection: $destinationID) {
                        Text(app.t("gallery.noUpload")).tag(UUID?.none)
                        ForEach(destinations) { Text($0.name).tag(Optional($0.id)) }
                    }
                }
                if isBuilding {
                    ProgressView(value: Double(progress.done), total: Double(max(photos.count, 1))) {
                        Text(String(format: app.t("gallery.building"), progress.done, photos.count)).font(Typography.caption)
                    }
                    .tint(Brand.orange)
                }
                if let result {
                    Section {
                        Label(app.t("gallery.ready"), systemImage: "checkmark.seal.fill").foregroundStyle(Brand.success)
                        Button(app.t("gallery.open")) { NSWorkspace.shared.open(result) }
                    }
                    .transition(.opacity)
                }
                if let message { Text(message).foregroundStyle(Brand.error) }
            }
            .formStyle(.grouped)
            SheetButtons(
                confirmTitle: app.t("gallery.create"),
                confirmDisabled: isBuilding || photos.isEmpty || folderPath.isEmpty || result != nil,
                isWorking: isBuilding
            ) { build() }
        }
        .frame(width: 540)
        .animation(Motion.smooth, value: result)
        .onAppear {
            if options.title.isEmpty { options.title = photos.first?.sessionName ?? "" }
        }
    }

    private var strings: ClientGallery.Strings {
        ClientGallery.Strings(
            lang: app.language.rawValue,
            search: app.t("gallery.web.search"), favourites: app.t("gallery.web.favourites"),
            send: app.t("gallery.web.send"), copy: app.t("gallery.web.copy"), copied: app.t("gallery.web.copied"),
            download: app.t("gallery.web.download"), photos: app.t("gallery.web.photos"), close: app.t("gallery.web.close"),
            previous: app.t("gallery.web.previous"), next: app.t("gallery.web.next"), empty: app.t("gallery.web.empty"),
            by: app.t("gallery.web.by")
        )
    }

    private func build() {
        guard !folderPath.isEmpty else { return }
        var configured = options
        configured.photographer = photographer
        configured.email = email
        configured.website = website
        let options = configured
        let name = RenameTemplate.sanitize(options.title).trimmingCharacters(in: .whitespaces)
        let target = URL(fileURLWithPath: folderPath, isDirectory: true).appendingPathComponent(name.isEmpty ? "Gallery" : name, isDirectory: true)
        let jobs = photos.map { photo in
            GalleryPhoto(
                url: photo.url,
                recipe: photo.recipeData.flatMap { try? JSONDecoder().decode(EditRecipe.self, from: $0) } ?? EditRecipe(),
                caption: "",
                keywords: (photo.keywords ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            )
        }
        let strings = strings
        let settings = ExportPresetStore.lastSettings
        let destination = destinations.first { $0.id == destinationID }
        let progress = progress
        progress.done = 0
        isBuilding = true
        message = nil
        Task {
            do {
                let files = try await Task.detached(priority: .userInitiated) {
                    try ClientGallery.build(jobs, options: options, strings: strings, exportSettings: settings, to: target) { finished, _ in
                        Task { @MainActor in progress.done = finished }
                    }
                }.value
                result = files.first { $0.lastPathComponent == "index.html" }
                if let destination {
                    app.transfers.enqueue(files: files, destination: destination, event: options.title)
                    app.showToast(String(format: app.t("toast.galleryUploading"), files.count), icon: "arrow.up.circle.fill")
                } else {
                    app.showToast(app.t("gallery.ready"), icon: "photo.on.rectangle.angled")
                }
            } catch {
                message = error.localizedDescription
            }
            isBuilding = false
        }
    }
}

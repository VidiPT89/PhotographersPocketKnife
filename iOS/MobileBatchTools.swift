import SwiftUI
import SwiftData
import ZIPFoundation

struct MobileBatchTools: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Query(sort: \UploadDestination.name) private var destinations: [UploadDestination]
    let kind: MobileSheet
    let photos: [Photo]
    let catalog: [Photo]
    @State private var name = ""
    @State private var template = "{date}_{event}_{seq}"
    @State private var shift = 0.0
    @State private var strength = 0.5
    @State private var gallery = GalleryOptions()
    @State private var destinationID: UUID?
    @State private var busy = false
    @State private var message: String?
    @State private var shares: SharedFiles?
    @State private var confirmRename = false
    var body: some View {
        Form {
            Section { Text(app.m("\(photos.count) photographs", "\(photos.count) fotografias")) }
            switch kind {
            case .rename:
                Section {
                    TextField(app.m("Template", "Modelo"), text: $template)
                    TextField(app.m("Event", "Evento"), text: $name)
                    Text(RenameTemplate.tokens.joined(separator: " ")).font(.caption)
                    ForEach(Array(renamePlans.prefix(8).enumerated()), id: \.offset) { _, plan in Text("\(plan.from.lastPathComponent) → \(plan.to.lastPathComponent)").font(.caption) }
                    Button(app.m("Rename photographs", "Renomear fotografias")) { confirmRename = true }.disabled(!BatchRenamer.conflicts(renamePlans).isEmpty || busy)
                }
            case .time:
                Section {
                    TextField(app.m("Offset in seconds", "Diferença em segundos"), value: $shift, format: .number).keyboardType(.numbersAndPunctuation)
                    Text(app.m("The same offset is applied to every selected capture date in the catalog.", "A mesma diferença é aplicada à data de captura de todas as fotografias selecionadas no catálogo.")).font(.caption)
                    Button(app.m("Apply offset", "Aplicar diferença")) {
                        for photo in photos { if let date = photo.captureDate { photo.captureDate = date.addingTimeInterval(shift) } }
                        do { try context.save(); message = app.m("Capture times updated", "Horas de captura atualizadas") } catch { message = error.localizedDescription }
                    }
                }
            case .duplicates:
                Section {
                    Button(app.m("Find identical files (SHA-256)", "Encontrar ficheiros iguais (SHA-256)")) {
                        Task { await app.culling.findExactDuplicates(in: photos); message = app.m("\(app.culling.duplicateGroups.count) photographs in duplicate groups", "\(app.culling.duplicateGroups.count) fotografias em grupos duplicados") }
                    }
                    Button(app.m("Find visually similar photographs", "Encontrar fotografias semelhantes")) { Task { await app.culling.findDuplicates(in: photos) } }
                    if app.culling.isFindingDuplicates { ProgressView() }
                    ForEach(photos.filter { app.culling.duplicateGroups[$0.id] != nil }) { photo in
                        HStack {
                            ThumbnailView(url: photo.url, maxPixel: 140).frame(width: 65, height: 45)
                            Text(photo.fileName).font(.caption)
                            Spacer()
                            Text("#\(app.culling.duplicateGroups[photo.id] ?? 0)")
                        }
                    }
                    Button(app.m("Select duplicate groups", "Selecionar grupos duplicados")) {
                        app.culling.selection = Set(app.culling.duplicateGroups.keys)
                    }
                }
            case .denoise:
                Section {
                    Slider(value: $strength, in: 0.05...1) { Text(app.m("Strength", "Intensidade")) }
                    Text(app.m("Creates separate 16-bit TIFF copies. Originals stay untouched.", "Cria cópias TIFF de 16 bits. Os originais ficam intactos."))
                    Button(app.m("Reduce noise", "Reduzir ruído")) {
                        app.denoise.start(photos.map { .init(url: $0.url, strength: strength) }, session: photos.first?.sessionName ?? "Denoise", culling: app.culling, context: context)
                    }.disabled(app.denoise.isRunning)
                    if app.denoise.isRunning { ProgressView(value: app.denoise.progress) }
                    if app.denoise.failed > 0 { Text(app.m("\(app.denoise.failed) files failed", "\(app.denoise.failed) ficheiros falharam")) }
                }
            case .keywords:
                Section { Button(app.m("Generate and write keywords", "Gerar e gravar palavras-chave")) { keywords() }.disabled(busy) }
            case .contact:
                Section {
                    TextField(app.m("Title", "Título"), text: $name)
                    Button(app.m("Create PDF", "Criar PDF")) { contactSheet() }.disabled(busy)
                }
            case .gallery:
                Section {
                    TextField(app.m("Title", "Título"), text: $gallery.title)
                    TextField(app.m("Photographer", "Fotógrafo"), text: $gallery.photographer)
                    TextField("Email", text: $gallery.email).keyboardType(.emailAddress).textInputAutocapitalization(.never)
                    TextField("Website", text: $gallery.website).keyboardType(.URL).textInputAutocapitalization(.never)
                    Toggle(app.m("Allow downloads", "Permitir downloads"), isOn: $gallery.allowDownload)
                    Toggle(app.m("Watermark", "Marca de água"), isOn: $gallery.watermark)
                    Picker(app.m("Upload to", "Enviar para"), selection: $destinationID) {
                        Text(app.m("Share ZIP", "Partilhar ZIP")).tag(nil as UUID?)
                        ForEach(destinations) { Text($0.name).tag(Optional($0.id)) }
                    }
                    Button(app.m("Build gallery", "Criar galeria")) { buildGallery() }.disabled(busy)
                }
            default: EmptyView()
            }
            if busy { ProgressView() }
            if let message { Text(message) }
        }
        .sheet(item: $shares) { ShareFiles(urls: $0.urls) }
        .confirmationDialog(app.m("Rename the imported copies?", "Renomear as cópias importadas?"), isPresented: $confirmRename) {
            Button(app.m("Rename", "Renomear")) { rename() }
        }
        .interactiveDismissDisabled(busy)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button(app.m("Close", "Fechar")) { dismiss() }.disabled(busy) } }
    }
    private var renamePlans: [BatchRenamer.Plan] { BatchRenamer.plan(photos.map { .init(url: $0.url, date: $0.captureDate, camera: $0.camera) }, template: template, event: name) }
    private func rename() {
        let plans = renamePlans
        busy = true
        Task {
            do {
                try await Task.detached { try BatchRenamer.apply(plans) }.value
                for plan in plans {
                    if let photo = photos.first(where: { $0.path == plan.from.path }) { photo.path = plan.to.path; photo.fileName = plan.to.lastPathComponent }
                }
                try context.save(); message = app.m("Photographs renamed", "Fotografias renomeadas")
            } catch { message = error.localizedDescription }
            busy = false
        }
    }
    private func keywords() {
        let jobs = photos.map { ($0.id, $0.url) }
        busy = true
        Task {
            var failures = 0
            for (id, url) in jobs {
                do {
                    let fields = try await Task.detached { _ = try AutoKeywords.apply(to: url); return MetadataReader.iptcFields(for: url) }.value
                    photos.first { $0.id == id }?.updateFileInfo(fields)
                } catch { failures += 1 }
            }
            do { try context.save() } catch { message = error.localizedDescription }
            if message == nil { message = app.m("Finished, \(failures) failures", "Concluído, \(failures) falhas") }
            busy = false
        }
    }
    private func contactSheet() {
        let items = photos.map { ContactSheet.Item(url: $0.url, title: $0.fileName, subtitle: "\(String(repeating: "★", count: $0.rating)) \($0.camera ?? "")") }
        let title = name
        busy = true
        Task {
            do {
                let url = try await Task.detached {
                    try FileManager.default.createDirectory(at: MobileFiles.exports, withIntermediateDirectories: true)
                    let url = PhotoImporter.uniqueURL(MobileFiles.exports.appendingPathComponent("ContactSheet.pdf"))
                    try ContactSheet.render(items, title: title, subtitle: "Photographer's Pocket Knife", to: url)
                    return url
                }.value
                shares = SharedFiles(urls: [url])
            } catch { message = error.localizedDescription }
            busy = false
        }
    }
    private func buildGallery() {
        let options = gallery, settings = ExportPresetStore.lastSettings
        let jobs = photos.map { GalleryPhoto(url: $0.url, recipe: $0.recipeData.flatMap { try? JSONDecoder().decode(EditRecipe.self, from: $0) } ?? EditRecipe(), caption: "", keywords: IPTCFields.list($0.keywords ?? "")) }
        let strings = ClientGallery.Strings(lang: app.language.rawValue, search: app.t("gallery.web.search"), favourites: app.t("gallery.web.favourites"), send: app.t("gallery.web.send"), copy: app.t("gallery.web.copy"), copied: app.t("gallery.web.copied"), download: app.t("gallery.web.download"), photos: app.t("gallery.web.photos"), close: app.t("gallery.web.close"), previous: app.t("gallery.web.previous"), next: app.t("gallery.web.next"), empty: app.t("gallery.web.empty"), by: app.t("gallery.web.by"))
        let destination = destinations.first { $0.id == destinationID }
        busy = true
        Task {
            do {
                let result = try await Task.detached {
                    let folder = MobileFiles.exports.appendingPathComponent("Gallery-\(UUID().uuidString)")
                    let files = try ClientGallery.build(jobs, options: options, strings: strings, exportSettings: settings, to: folder) { _, _ in }
                    let zip = folder.appendingPathExtension("zip")
                    try FileManager.default.zipItem(at: folder, to: zip)
                    return (files, zip)
                }.value
                if let destination { app.transfers.enqueue(files: result.0, destination: destination, event: options.title) }
                shares = SharedFiles(urls: [result.1])
            } catch { message = error.localizedDescription }
            busy = false
        }
    }
}

import SwiftUI
import SwiftData
import PhotosUI
import UniformTypeIdentifiers

struct MobileRoot: View {
    @Environment(AppState.self) private var app
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var phase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Query(sort: \Photo.importedAt, order: .reverse) private var photos: [Photo]
    @State private var settings = false
    @State private var importFiles = false
    @State private var importFolder = false
    @State private var picker: [PhotosPickerItem] = []
    @State private var sheet: MobileSheet?
    @State private var error: String?
    @State private var selecting = false
    @State private var imported = false
    @State private var removeSelection = false

    private var list: [Photo] { app.culling.visible(photos) }
    private var targets: [Photo] { app.culling.targets(in: list) }
    var body: some View {
        @Bindable var culling = app.culling
        @Bindable var state = app
        let libraryTitle = app.m("Photo Library", "Fotografias")
        TabView(selection: $state.module) {
            NavigationStack {
                catalog
                    .safeAreaInset(edge: .bottom) { tools.padding(.horizontal).padding(.vertical, 10).background(.regularMaterial) }
                    .navigationTitle("Pocket Knife")
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button { settings = true } label: { Image(systemName: "gearshape") }.accessibilityLabel(app.m("Settings", "Definições")).accessibilityIdentifier("mobile-settings")
                        }
                        ToolbarItem(placement: .topBarTrailing) {
                            Menu {
                                PhotosPicker(selection: $picker, matching: .images, preferredItemEncoding: .current) {
                                    Label(libraryTitle, systemImage: "photo.on.rectangle")
                                }
                                Button(app.m("Import files", "Importar ficheiros"), systemImage: "doc") { importFiles = true }
                                Button(app.m("Import folder or card", "Importar pasta ou cartão"), systemImage: "externaldrive") { importFolder = true }
                            } label: { Image(systemName: "plus") }
                            .accessibilityLabel(app.m("Import photos", "Importar fotografias"))
                        }
                        ToolbarItem(placement: .topBarTrailing) {
                            Button { selecting.toggle() } label: { Image(systemName: selecting ? "checkmark.circle.fill" : "checkmark.circle") }
                                .accessibilityLabel(selecting ? app.m("Done", "Concluído") : app.m("Select", "Selecionar"))
                                .accessibilityIdentifier("mobile-select")
                        }
                    }
                    .searchable(text: $culling.searchText, prompt: app.m("Search photos and metadata", "Pesquisar fotos e metadados"))
            }.tabItem { Label(app.t("module.culling"), systemImage: "square.grid.2x2") }.tag(AppModule.culling)
            NavigationStack {
                MobileEditor(photos: photos)
            }.tabItem { Label(app.t("module.editing"), systemImage: "slider.horizontal.3") }.tag(AppModule.editing)
            NavigationStack {
                MobileDelivery(photos: targets)
            }.tabItem { Label(app.t("module.upload"), systemImage: "arrow.up.to.line") }.tag(AppModule.upload)
        }
        .confirmationDialog(app.m("Remove selected photographs from the catalogue? Originals will be kept.", "Remover as fotografias selecionadas do catálogo? Os originais serão mantidos."), isPresented: $removeSelection) {
            Button(app.m("Remove from catalogue", "Remover do catálogo"), role: .destructive) {
                let ids = Set(targets.map(\.id))
                if let current = app.editing.photo, ids.contains(current.id) { app.editing.unload() }
                CatalogService.remove(targets, from: context)
                app.culling.selection = []; app.culling.focusedID = nil
            }
        }
        .sheet(isPresented: $settings) { NavigationStack { MobileSettings() } }
        .sheet(item: $sheet) { kind in
            NavigationStack {
                MobileTools(sheet: kind, photos: targets.isEmpty ? list : targets, catalog: photos)
            }
        }
        .fileImporter(isPresented: $importFiles, allowedContentTypes: [.image, .rawImage], allowsMultipleSelection: true, onCompletion: importResult)
        .fileImporter(isPresented: $importFolder, allowedContentTypes: [.folder], allowsMultipleSelection: false, onCompletion: importResult)
        .onChange(of: picker) { _, values in
            Task {
                var urls: [URL] = []
                defer { for url in urls { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) } }
                do {
                    for item in values {
                        guard let image = try await item.loadTransferable(type: PickedPhoto.self) else { throw CocoaError(.fileReadUnknown) }
                        urls.append(image.url)
                    }
                    await ingest(urls)
                    picker = []
                } catch { self.error = error.localizedDescription }
            }
        }
        .alert(app.m("Unable to complete", "Não foi possível concluir"), isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
        .overlay(alignment: .top) {
            if let toast = app.toast {
                Label(toast.message, systemImage: toast.icon).font(.callout).padding()
                    .background(.regularMaterial, in: Capsule()).padding().allowsHitTesting(false)
            }
        }
        .task {
            guard !imported else { return }; imported = true
            FolderAccess.shared.restore()
            MobileFiles.restorePaths(photos)
            app.transfers.attach(context: context)
            app.transfers.restore(from: CatalogStore.url.deletingLastPathComponent().appendingPathComponent("MobileTransfers.json"))
            app.sidecars.attach(context: context)
            app.hotFolder.attach(context: context)
            app.watchFolder.attach(context: context, culling: app.culling)
            await app.culling.indexFileInfo(photos)
        }
        .onChange(of: phase) { _, value in
            app.watchFolder.setActive(value == .active)
            if value != .active {
                app.transfers.pause()
                try? context.save()
                Task { await app.sidecars.flush() }
            }
        }
        .onOpenURL { url in Task { await ingest([url]) } }
    }

    @ViewBuilder private var catalog: some View {
        if photos.isEmpty && !app.culling.isImporting {
            ContentUnavailableView {
                Label(app.m("Your next edit starts here", "A próxima edição começa aqui"), systemImage: "photo.stack")
            } description: {
                Text(app.m("Import a shoot from Photos, Files or a connected card. Originals stay untouched.", "Importa uma sessão das Fotografias, de Ficheiros ou de um cartão ligado. Os originais ficam intactos."))
            } actions: { Button(app.m("Import photos", "Importar fotografias")) { importFiles = true }.buttonStyle(.borderedProminent) }
        } else {
            VStack(spacing: 0) {
                if app.culling.isImporting { ProgressView(value: app.culling.importProgress).padding() }
                (dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading)) : AnyLayout(HStackLayout())) {
                    Text(app.m("\(list.count) photographs", "\(list.count) fotografias")).font(.caption).foregroundStyle(.secondary)
                    if !dynamicTypeSize.isAccessibilitySize { Spacer() }
                    Menu(app.m("Filter & sort", "Filtrar e ordenar"), systemImage: "line.3.horizontal.decrease.circle") {
                        Picker(app.m("Flag", "Marcação"), selection: Bindable(app.culling).flagFilter) {
                            ForEach(FlagFilter.allCases) { Text(app.t($0.labelKey)).tag($0) }
                        }
                        Picker(app.m("Minimum stars", "Estrelas mínimas"), selection: Bindable(app.culling).minRating) {
                            ForEach(0...5, id: \.self) { Text("\($0) ★").tag($0) }
                        }
                        Picker(app.m("Sort", "Ordenar"), selection: Bindable(app.culling).sort) {
                            ForEach(PhotoSort.allCases) { Text(app.t($0.labelKey)).tag($0) }
                        }
                        Toggle(app.m("Ascending", "Ascendente"), isOn: Bindable(app.culling).sortAscending)
                        Toggle(app.m("Stack RAW + JPEG", "Agrupar RAW + JPEG"), isOn: Bindable(app.culling).stackPairs)
                        Button(app.m("Advanced filters", "Filtros avançados")) { sheet = .filters }
                        Button(app.m("Clear filters", "Limpar filtros")) { app.culling.clearFilters() }
                    }
                }.padding(.horizontal).padding(.vertical, 8)
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: dynamicTypeSize.isAccessibilitySize ? 280 : app.culling.thumbnailSize), spacing: 8)], spacing: 12) {
                        ForEach(list) { photo in
                            Button {
                                if selecting {
                                    if !app.culling.selection.insert(photo.id).inserted { app.culling.selection.remove(photo.id) }
                                    app.culling.focusedID = photo.id
                                } else {
                                    app.culling.click(photo, in: list)
                                    app.editing.load(photo)
                                    app.module = .editing
                                }
                            } label: {
                                VStack(alignment: .leading, spacing: 5) {
                                    ThumbnailView(url: photo.url, maxPixel: 440, recipeData: photo.recipeData)
                                        .frame(height: 145).clipShape(RoundedRectangle(cornerRadius: 8))
                                        .overlay(alignment: .topTrailing) {
                                            if app.culling.selection.contains(photo.id) { Image(systemName: "checkmark.circle.fill").foregroundStyle(.white, Brand.orange).padding(6) }
                                        }
                                    Text(photo.fileName).font(.caption).lineLimit(1)
                                    HStack(spacing: 4) {
                                        Text(String(repeating: "★", count: photo.rating)).foregroundStyle(Brand.amber)
                                        Spacer()
                                        if photo.flag != .none { Image(systemName: photo.flag == .pick ? "flag.fill" : "xmark").foregroundStyle(photo.flag == .pick ? Brand.success : Brand.error) }
                                        if let color = photo.colorLabel.color { Circle().fill(color).frame(width: 8, height: 8) }
                                        if photo.deliveredAt != nil { Image(systemName: "checkmark.icloud") }
                                    }.font(.caption2).frame(minHeight: 12)
                                }.foregroundStyle(.primary)
                            }.buttonStyle(.plain).accessibilityIdentifier("photo-\(photo.fileName)")
                        }
                    }.padding()
                }
            }
        }
    }
    private var tools: some View {
        HStack {
            Menu(app.m("Rate", "Classificar"), systemImage: "star") {
                ForEach(0...5, id: \.self) { rating in Button("\(rating) ★") { classify { $0.rating = rating } } }
                Button(app.m("Pick", "Escolher")) { classify { $0.flag = .pick } }
                Button(app.m("Reject", "Rejeitar")) { classify { $0.flag = .reject } }
                Button(app.m("Unflag", "Desmarcar")) { classify { $0.flag = .none } }
                ForEach(ColorLabel.allCases) { label in Button(app.t(label.labelKey)) { classify { $0.colorLabel = label }; app.hotFolder.handleLabelChange(targets, transfers: app.transfers) } }
            }.disabled(targets.isEmpty)
            Spacer()
            Menu(app.m("Tools", "Ferramentas"), systemImage: "wrench.and.screwdriver") {
                Button(app.m("Select all", "Selecionar todas")) { app.culling.selection = Set(list.map(\.id)); selecting = true }
                Button(app.m("Clear selection", "Limpar seleção")) { app.culling.selection = [] }
                ForEach(MobileSheet.allCases) { item in Button(app.m(item.en, item.pt), systemImage: item.icon) { sheet = item } }
                Button(app.m("Remove from catalogue", "Remover do catálogo"), role: .destructive) { removeSelection = true }.disabled(targets.isEmpty)
            }.disabled(photos.isEmpty)
            Spacer()
            Button(app.m("Export", "Exportar"), systemImage: "square.and.arrow.up") { sheet = .export }.disabled(targets.isEmpty)
        }.labelStyle(MobileToolbarLabelStyle()).frame(minHeight: 44)
    }
    private func classify(_ update: (Photo) -> Void) {
        let keys = Set(targets.map { PhotoPairs.key($0.path) })
        let affected = app.culling.stackPairs ? photos.filter { keys.contains(PhotoPairs.key($0.path)) } : targets
        for photo in affected { update(photo) }
        do { try context.save() } catch { self.error = error.localizedDescription }
    }
    private func importResult(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls): Task { await ingest(urls) }
        case .failure(let error): self.error = error.localizedDescription
        }
    }
    private func ingest(_ urls: [URL]) async {
        let scoped = urls.filter { $0.startAccessingSecurityScopedResource() }
        defer { scoped.forEach { $0.stopAccessingSecurityScopedResource() } }
        let files = await Task.detached { urls.flatMap { url in
            (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true ? PhotoImporter.imageFiles(in: url) : [url]
        } }.value
        var options = PhotoImporter.Options()
        options.copyDestination = MobileFiles.originals
        options.verifyChecksum = true
        options.folderTemplate = UserDefaults.standard.string(forKey: "mobile.import.template") ?? "{date}"
        options.event = UserDefaults.standard.string(forKey: "mobile.import.event") ?? ""
        let backup = UserDefaults.standard.string(forKey: "mobile.import.backup").flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
        let backupAccess = backup?.startAccessingSecurityScopedResource() ?? false
        defer { if backupAccess { backup?.stopAccessingSecurityScopedResource() } }
        options.backupDestination = backup
        await app.culling.importFiles(files, options: options, session: options.event.isEmpty ? Date().formatted(date: .abbreviated, time: .omitted) : options.event, context: context)
        app.culling.clearFilters()
        if app.culling.lastImportFailures > 0 { error = app.m("Some photographs could not be imported. Check the available space and source files.", "Não foi possível importar algumas fotografias. Verifica o espaço disponível e os ficheiros de origem.") }
    }
}

private struct MobileToolbarLabelStyle: LabelStyle {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    func makeBody(configuration: Configuration) -> some View {
        if dynamicTypeSize.isAccessibilitySize {
            Label(configuration).labelStyle(.iconOnly)
        } else {
            Label(configuration).labelStyle(.titleAndIcon)
        }
    }
}

extension AppState {
    func m(_ english: String, _ portuguese: String) -> String { language == .pt ? portuguese : english }
}

enum MobileFiles {
    static var documents: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }
    static var originals: URL { documents.appendingPathComponent("Originals", isDirectory: true) }
    static var exports: URL { documents.appendingPathComponent("Exports", isDirectory: true) }
    @MainActor static func restorePaths(_ photos: [Photo]) {
        for photo in photos {
            let restored = LocalFileLocation.restored(photo.url)
            if restored.path != photo.path { photo.path = restored.path }
        }
    }
}
struct PickedPhoto: Transferable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { received in
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent(received.file.lastPathComponent)
            try FileManager.default.copyItem(at: received.file, to: url)
            return PickedPhoto(url: url)
        }
    }
}

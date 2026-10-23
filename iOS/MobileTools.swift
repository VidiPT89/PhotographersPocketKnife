import SwiftUI
import SwiftData
import MapKit
import ZIPFoundation

enum MobileSheet: String, CaseIterable, Identifiable {
    case filters, metadata, smartCull, compare, map, rename, time, duplicates, denoise, keywords, contact, gallery, export
    var id: String { rawValue }
    var en: String { switch self {
        case .filters: "Advanced filters"; case .metadata: "File info"; case .smartCull: "Smart selection"; case .compare: "Compare"; case .map: "Photo map"
        case .rename: "Batch rename"; case .time: "Adjust capture time"; case .duplicates: "Find duplicates"
        case .denoise: "Denoise"; case .keywords: "Automatic keywords"; case .contact: "Contact sheet PDF"; case .gallery: "Client gallery"; case .export: "Export"
    } }
    var pt: String { switch self {
        case .filters: "Filtros avançados"; case .metadata: "Informações do ficheiro"; case .smartCull: "Seleção inteligente"; case .compare: "Comparar"; case .map: "Mapa de fotos"
        case .rename: "Renomear em lote"; case .time: "Ajustar hora de captura"; case .duplicates: "Encontrar duplicados"
        case .denoise: "Reduzir ruído"; case .keywords: "Palavras-chave automáticas"; case .contact: "Folha de contactos PDF"; case .gallery: "Galeria para clientes"; case .export: "Exportar"
    } }
    var icon: String { switch self {
        case .filters: "line.3.horizontal.decrease.circle"; case .metadata: "info.circle"; case .smartCull: "sparkles"; case .compare: "rectangle.split.2x1"; case .map: "map"
        case .rename: "pencil"; case .time: "clock"; case .duplicates: "square.on.square"; case .denoise: "camera.filters"
        case .keywords: "tag"; case .contact: "doc.richtext"; case .gallery: "globe"; case .export: "square.and.arrow.up"
    } }
}
struct MobileTools: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    let sheet: MobileSheet
    let photos: [Photo]
    let catalog: [Photo]
    var body: some View {
        Group {
            switch sheet {
            case .filters: MobileFilters(photos: catalog)
            case .metadata: MobileMetadata(photos: photos)
            case .export: MobileExport(photos: photos)
            case .smartCull: MobileSmartCull(photos: photos)
            case .compare: MobileCompare(photos: Array(photos.prefix(4)))
            case .map:
                Map {
                    ForEach(photos.filter { $0.latitude != nil && $0.longitude != nil }) { photo in
                        Annotation(photo.fileName, coordinate: CLLocationCoordinate2D(latitude: photo.latitude!, longitude: photo.longitude!)) {
                            Button { app.editing.load(photo); app.module = .editing; dismiss() } label: { ThumbnailView(url: photo.url, maxPixel: 120).frame(width: 42, height: 42).clipShape(RoundedRectangle(cornerRadius: 6)) }
                        }
                    }
                }
            default: MobileBatchTools(kind: sheet, photos: photos, catalog: catalog)
            }
        }.navigationTitle(app.m(sheet.en, sheet.pt))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { if [.filters, .smartCull, .compare, .map].contains(sheet) { ToolbarItem(placement: .cancellationAction) { Button(app.m("Close", "Fechar")) { dismiss() } } } }
    }
}

struct MobileCompare: View {
    @Environment(AppState.self) private var app
    let photos: [Photo]
    @State private var zoom = ZoomPosition()
    var body: some View {
        GeometryReader { geo in
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())]) {
                ForEach(photos) { photo in
                    VStack {
                        MobileZoom(position: $zoom, identifier: "mobile-compare-zoom-\(photo.id)",
                                   actionNames: [app.m("Zoom in", "Ampliar"), app.m("Zoom out", "Reduzir"), app.m("Fit photograph", "Ajustar fotografia ao ecrã")]) {
                            ThumbnailView(url: photo.url, maxPixel: 2400, recipeData: photo.recipeData, fit: true)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                        .frame(height: geo.size.height / (photos.count > 2 ? 2.3 : 1.3))
                        Text(photo.fileName).font(.caption).lineLimit(1)
                    }
                }
            }.padding(8)
        }.background(Palette.canvas)
    }
}

struct MobileMetadata: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    let photos: [Photo]
    @State private var fields = IPTCFields()
    @State private var changed: Set<String> = []
    @State private var loaded = false
    @State private var index = -1
    @State private var discard = false
    private var targets: [Photo] { index < 0 ? photos : [photos[min(index, photos.count - 1)]] }
    @State private var message: String?
    @State private var working = false
    @State private var templatePicker = false
    @State private var shares: SharedFiles?
    var body: some View {
        Form {
            if photos.count > 1 {
                Section {
                    Picker(app.m("Mode", "Modo"), selection: $index) {
                        Text(app.m("All selected", "Todas as selecionadas")).tag(-1)
                        ForEach(Array(photos.enumerated()), id: \.offset) { offset, photo in Text(photo.fileName).tag(offset) }
                    }.disabled(!changed.isEmpty || working)
                    if index >= 0 {
                        HStack {
                            Button(app.m("Save & previous", "Guardar e anterior")) { save(next: index - 1) }.disabled(index == 0 || working)
                            Spacer()
                            Button(app.m("Save & next", "Guardar e seguinte")) { save(next: index + 1) }.disabled(index >= photos.count - 1 || working)
                        }
                    }
                }
            }
            MobileFileInfoAssistant(fields: $fields, changed: $changed, photo: targets.first)
            if let first = targets.first {
                Section("EXIF") {
                    Text(first.fileName)
                    LabeledContent(app.m("Camera", "Câmara"), value: first.camera ?? "")
                    LabeledContent(app.m("Lens", "Objetiva"), value: first.lens ?? "")
                    LabeledContent("ISO", value: first.iso.map(String.init) ?? "")
                    Text("\(first.pixelWidth) × \(first.pixelHeight)")
                }
            }
            ForEach(IPTCGroup.allCases, id: \.rawValue) { group in
                Section(app.t(group.labelKey)) {
                    ForEach(IPTCFields.specs.filter { $0.group == group }) { spec in
                        TextField(app.t(spec.labelKey), text: Binding(get: { fields[keyPath: spec.path] }, set: { fields[keyPath: spec.path] = $0; changed.insert(spec.name) }), axis: .vertical)
                    }
                }
            }
            Section {
                Text(app.m("Only fields you change are applied to the selected photographs.", "Só os campos alterados são aplicados às fotografias selecionadas.")).font(.caption)
                Button(app.m("Copy fields", "Copiar campos")) { app.culling.fileInfoClipboard = fields }
                if let clipboard = app.culling.fileInfoClipboard {
                    Button(app.m("Paste fields", "Colar campos")) { fields = clipboard; changed = Set(IPTCFields.specs.map(\.name)) }
                }
                Button(app.m("Save stationery pad", "Guardar modelo habitual")) { UserDefaults.standard.set(try? JSONEncoder().encode(fields), forKey: "metadata.lastFields") }
                Button(app.m("Apply stationery pad", "Aplicar modelo habitual")) {
                    if let data = UserDefaults.standard.data(forKey: "metadata.lastFields"), let pad = try? JSONDecoder().decode(IPTCFields.self, from: data) {
                        for spec in IPTCFields.specs where !pad[keyPath: spec.path].isEmpty { fields[keyPath: spec.path] = pad[keyPath: spec.path]; changed.insert(spec.name) }
                    }
                }
                Button(app.m("Save metadata", "Guardar metadados")) { save() }.disabled(changed.isEmpty || working)
                Button(app.m("Load XMP template", "Carregar modelo XMP")) { templatePicker = true }
                Button(app.m("Share XMP template", "Partilhar modelo XMP")) {
                    do {
                        guard let data = MetadataWriter.xmpData(for: fields) else { throw CocoaError(.fileWriteUnknown) }
                        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Stationery.xmp")
                        try data.write(to: url); shares = SharedFiles(urls: [url])
                    } catch { message = error.localizedDescription }
                }
                if working { ProgressView() }
                if let message { Text(message) }
            }
        }.disabled(working || !loaded)
        .task(id: index) {
            loaded = false
            let urls = targets.map(\.url)
            let values = await Task.detached { urls.map { MetadataReader.iptcFields(for: $0) } }.value
            fields = IPTCFields.common(values).fields
            loaded = true
        }
        .fileImporter(isPresented: $templatePicker, allowedContentTypes: [.data]) { result in
            do {
                let url = try result.get(); let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
                guard let imported = MetadataReader.iptcFields(xmpData: try Data(contentsOf: url)) else { throw CocoaError(.fileReadCorruptFile) }
                fields = imported
                changed = Set(IPTCFields.specs.map(\.name))
            } catch { message = error.localizedDescription }
        }
        .sheet(item: $shares) { ShareFiles(urls: $0.urls) }
        .interactiveDismissDisabled(!changed.isEmpty || working)
        .toolbar { ToolbarItem(placement: .cancellationAction) {
            Button(app.m("Close", "Fechar")) { if changed.isEmpty { dismiss() } else { discard = true } }.disabled(working)
        } }
        .confirmationDialog(app.m("Discard unsaved metadata?", "Descartar metadados por guardar?"), isPresented: $discard) {
            Button(app.m("Discard changes", "Descartar alterações"), role: .destructive) { dismiss() }
        }
    }
    private func save(next: Int? = nil) {
        let fields = fields, changed = changed
        let jobs = targets.enumerated().map { ($0.element.id, $0.element.url, CaptionTemplate.Context(date: $0.element.captureDate, event: $0.element.sessionName, camera: $0.element.camera, fileName: $0.element.fileName, sequence: $0.offset + 1)) }
        let roster = CodeReplacementStore.load()
        let conjunction = app.m(" and ", " e ")
        working = true
        Task {
            var failures: [String] = []
            for (id, url, captionContext) in jobs {
                do {
                    let result = try await Task.detached {
                        var current = MetadataReader.iptcFields(for: url)
                        for spec in IPTCFields.specs where changed.contains(spec.name) { current[keyPath: spec.path] = fields[keyPath: spec.path] }
                        current = roster.apply(to: current)
                        var captionContext = captionContext
                        captionContext.city = current.city; captionContext.country = current.country; captionContext.creator = current.creator
                        if !roster.isEmpty, CaptionTemplate.usesPlayers(current.caption + current.title + current.headline), let image = ThumbnailCache.shared.thumbnail(for: url, maxPixel: 1600)?.cgImage {
                            captionContext.players = CaptionTemplate.joinNames(JerseyNumbers.players(JerseyNumbers.detect(in: image), roster: roster), and: conjunction)
                        }
                        current.resolveVariables(captionContext)
                        try MetadataWriter.write(current, to: url, clearEmpty: true)
                        return current
                    }.value
                    photos.first { $0.id == id }?.updateFileInfo(result)
                } catch { failures.append("\(url.lastPathComponent): \(error.localizedDescription)") }
            }
            do { try context.save() } catch { failures.append(error.localizedDescription) }
            message = failures.isEmpty ? app.m("Metadata saved", "Metadados guardados") : failures.joined(separator: "\n")
            if failures.isEmpty { self.changed = []; if let next { index = next } }
            working = false
        }
    }
}

struct MobileSmartCull: View {
    @Environment(AppState.self) private var app
    @Environment(\.modelContext) private var context
    let photos: [Photo]
    @State private var options = CullOptions()
    @State private var automatic = false
    @State private var tasteID: UUID?
    @State private var name = ""
    @State private var tastes = TasteProfileStore().all()
    @State private var message: String?
    var body: some View {
        Form {
            Section {
                Picker(app.m("Genre", "Género"), selection: $options.genre) { ForEach(CullGenre.allCases) { Text(app.t($0.labelKey)).tag($0) } }
                Toggle(app.m("Apply decisions automatically", "Aplicar decisões automaticamente"), isOn: $automatic)
                Stepper(app.m("Keep per moment: \(options.keepPerMoment)", "Escolhas por momento: \(options.keepPerMoment)"), value: $options.keepPerMoment, in: 1...5)
                Toggle(app.m("Keep manual decisions", "Manter decisões manuais"), isOn: $options.keepManualDecisions)
                Toggle(app.m("Reject problems", "Rejeitar problemas"), isOn: $options.rejectProblems)
                Toggle(app.m("Assign stars", "Atribuir estrelas"), isOn: $options.assignStars)
                Slider(value: $options.blurTolerance, in: 0...1) { Text(app.m("Blur tolerance", "Tolerância ao desfoque")) }
                Picker(app.m("Taste profile", "Perfil de seleção"), selection: $tasteID) {
                    Text(app.m("None", "Nenhum")).tag(nil as UUID?)
                    ForEach(tastes) { Text($0.name).tag(Optional($0.id)) }
                }
                if app.culling.isAnalyzing { ProgressView(value: Double(app.culling.analysisDone), total: Double(max(app.culling.analysisTotal, 1))) }
                Button(app.m("Analyze photographs", "Analisar fotografias")) { analyze() }.disabled(app.culling.isAnalyzing)
                Button(app.m("Undo automatic selection", "Desfazer seleção automática")) { app.culling.undoAutomaticCull(in: photos); try? context.save() }
                if let message { Text(message) }
            }
            Section(app.m("Learn your taste", "Aprender as tuas escolhas")) {
                TextField(app.m("Profile name", "Nome do perfil"), text: $name)
                Button(app.m("Learn from picks and rejects", "Aprender com escolhas e rejeições")) {
                    Task {
                        let examples = CullingModel.decisionExamples(photos)
                        if let profile = await app.culling.learnTaste(named: name, keepers: examples.keepers, rejects: examples.rejects) {
                            TasteProfileStore().save(profile); tastes = TasteProfileStore().all(); tasteID = profile.id
                        } else { message = app.m("Rate more photographs to train a profile.", "Classifica mais fotografias para treinar um perfil.") }
                    }
                }.disabled(name.isEmpty || app.culling.isAnalyzing)
            }
            if app.culling.cullReport != nil {
                Section(app.m("Analysis", "Análise")) {
                    ForEach(photos) { photo in
                        HStack {
                            ThumbnailView(url: photo.url, maxPixel: 160).frame(width: 60, height: 45)
                            Text(photo.fileName).font(.caption)
                            Spacer()
                            Text(String(format: "%.2f", app.culling.cullReport?.scores[photo.id] ?? 0))
                        }
                    }
                }
            }
        }
    }
    private func analyze() {
        var options = options; options.momentGap = options.genre.momentGap
        let taste = tastes.first { $0.id == tasteID }
        Task {
            await app.culling.analyze(photos, options: options, taste: taste)
            if automatic {
                let count = app.culling.applyAutomatic(to: photos, options: options)
                message = app.m("\(count.picks) picks, \(count.rejects) rejects", "\(count.picks) escolhas, \(count.rejects) rejeições")
            }
            try? context.save()
        }
    }
}

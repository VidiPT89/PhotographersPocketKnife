import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct MobileEditor: View {
    @Environment(AppState.self) private var app
    @Environment(\.modelContext) private var context
    @Environment(\.horizontalSizeClass) private var sizeClass
    let photos: [Photo]
    @State private var exporting = false
    @State private var fullScreen = false
    @State private var zoom = MobileZoomPosition()
    @State private var presentationZoom = MobileZoomPosition()
    var body: some View {
        Group {
            if app.editing.photo != nil {
                GeometryReader { geo in
                    if sizeClass == .regular && geo.size.width > 700 {
                        HStack(spacing: 0) { canvas; controls.frame(width: 340) }
                    } else {
                        VStack(spacing: 0) { canvas.frame(height: max(200, geo.size.height * 0.46)); controls }
                    }
                }
            } else {
                ContentUnavailableView(app.m("Choose a photograph", "Escolhe uma fotografia"), systemImage: "slider.horizontal.3", description: Text(app.m("Open a photo from Cull to start editing.", "Abre uma foto na Seleção para começar a editar.")))
            }
        }
        .navigationTitle(app.editing.photo?.fileName ?? app.t("module.editing"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { app.editing.undo() } label: { Image(systemName: "arrow.uturn.backward") }.disabled(!app.editing.history.canUndo)
                    .accessibilityLabel(app.m("Undo", "Desfazer"))
                Menu {
                    ForEach(CompareMode.allCases) { mode in Button(app.t(mode.labelKey)) { app.editing.compareMode = mode } }
                    Button(app.m("Copy settings", "Copiar ajustes")) { app.editing.copySettings() }
                    if let recipe = app.editing.clipboard {
                        Button(app.m("Paste settings", "Colar ajustes")) { app.editing.applySettings(recipe, labelKey: "history.paste", to: app.culling.targets(in: photos)) }
                    }
                    Button(app.m("Presentation", "Apresentação")) { presentationZoom = MobileZoomPosition(); fullScreen = true }
                    Button(app.m("Export", "Exportar")) { exporting = true }
                    Button(app.m("Reset edits", "Repor edição"), role: .destructive) { app.editing.reset() }
                } label: { Image(systemName: "ellipsis.circle") }
                .accessibilityLabel(app.m("Editing options", "Opções de edição"))
                .accessibilityIdentifier("mobile-editing-options")
            }
        }
        .sheet(isPresented: $exporting) { NavigationStack { MobileExport(photos: app.editing.photo.map { [$0] } ?? []) } }
        .fullScreenCover(isPresented: $fullScreen) {
            ZStack(alignment: .topTrailing) {
                Color.black.ignoresSafeArea()
                MobileZoom(position: $presentationZoom, identifier: "mobile-presentation-zoom") {
                    EditCanvas().environment(app).allowsHitTesting(false)
                }
                .id(app.editing.photo?.id)
                Button { fullScreen = false; presentationZoom = MobileZoomPosition() } label: { Image(systemName: "xmark.circle.fill").font(.largeTitle).padding() }
                    .accessibilityLabel(app.m("Close presentation", "Fechar apresentação"))
            }
        }
        .onChange(of: previewDetail) { _, detail in app.editing.previewDetail = detail; app.editing.scheduleRender() }
        .onDisappear { app.editing.previewDetail = 1 }
        .onAppear { if let photo = app.editing.photo { app.editing.load(photo) } }
        .onDisappear { try? context.save() }
        .onChange(of: app.culling.focusedID) { _, id in
            if let photo = photos.first(where: { $0.id == id }) { app.editing.load(photo) }
        }
    }
    private var canvas: some View {
        VStack(spacing: 0) {
            MobileZoom(position: $zoom, editingTouches: usesEditingTouches) {
                EditCanvas().environment(app)
            }
            .id(app.editing.photo?.id)
            .onChange(of: app.editing.photo?.id) { _, _ in zoom = MobileZoomPosition() }
            HStack {
                Button { navigate(-1) } label: { Image(systemName: "chevron.left").frame(width: 44, height: 44) }
                    .accessibilityLabel(app.m("Previous photograph", "Fotografia anterior"))
                    .accessibilityIdentifier("mobile-previous-photo")
                Spacer()
                Button { zoom = MobileZoomPosition() } label: {
                    Text(String(format: "%.1f×", zoom.scale)).monospacedDigit().frame(minWidth: 44, minHeight: 44)
                }
                .accessibilityLabel(app.m("Fit photograph", "Ajustar fotografia ao ecrã"))
                .accessibilityIdentifier("mobile-fit-photo")
                if let photo = app.editing.photo {
                    Menu {
                        ForEach(0...5, id: \.self) { n in Button("\(n) ★") { photo.rating = n; try? context.save() } }
                    } label: { Text("\(photo.rating) ★").frame(minWidth: 44, minHeight: 44) }
                    Button { photo.flag = photo.flag == .pick ? .none : .pick; try? context.save() } label: { Image(systemName: photo.flag == .pick ? "flag.fill" : "flag").frame(width: 44, height: 44) }
                        .accessibilityLabel(app.m("Toggle pick", "Alternar escolha"))
                }
                Spacer()
                Button { navigate(1) } label: { Image(systemName: "chevron.right").frame(width: 44, height: 44) }
                    .accessibilityLabel(app.m("Next photograph", "Fotografia seguinte"))
                    .accessibilityIdentifier("mobile-next-photo")
            }.padding(.horizontal).background(Palette.panel)
            if usesEditingTouches {
                Text(app.m("Use two fingers to zoom or move; one finger to edit.", "Usa dois dedos para ampliar ou mover; um dedo para editar."))
                    .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 8).padding(.bottom, 4)
            }
        }
    }
    /// Sharper previews while zoomed; capped to keep RAW rendering within iPhone memory.
    private var previewDetail: Double {
        let scale = max(zoom.scale, fullScreen ? presentationZoom.scale : 1)
        return scale > 3 ? 3 : scale > 1.5 ? 2 : 1
    }
    private var usesEditingTouches: Bool {
        app.editing.isCropping || app.editing.tab == .masks || app.editing.tab == .remove || app.editing.compareMode == .split
    }
    private var controls: some View {
        @Bindable var editing = app.editing
        return VStack(spacing: 0) {
            HStack {
                Picker(app.m("Editing tool", "Ferramenta de edição"), selection: $editing.tab) {
                    ForEach(EditTab.allCases) { Text($0 == .basic ? app.m("Basic", "Base") : app.t($0.labelKey)).tag($0) }
                }.pickerStyle(.menu).accessibilityIdentifier("mobile-editing-tool")
                Spacer()
                Button { editing.autoEnhance() } label: { Label(app.t("auto.button"), systemImage: "wand.and.stars") }.disabled(editing.isAutoEnhancing)
            }.padding(.horizontal)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HistogramView(data: editing.histogram).frame(height: 65)
                    Toggle(app.m("Clipping warnings", "Avisos de recorte de luz"), isOn: $editing.showClipping)
                    switch editing.tab {
                    case .basic:
                        ForEach(AdjustmentSpec.sections, id: \.titleKey) { section in
                            DisclosureGroup(app.t(section.titleKey)) {
                                ForEach(section.specs) { spec in AdjustmentSlider(labelKey: spec.labelKey, value: spec.keyPath, range: spec.range, defaultValue: spec.defaultValue) }
                            }
                        }
                    case .curve: CurvePanel()
                    case .hsl: HSLPanel()
                    case .grading: ColorGradingPanel()
                    case .masks:
                        Toggle(app.m("Erase brush", "Borracha"), isOn: $editing.brushErase)
                        MasksPanel()
                    case .remove: RemovalPanel()
                    case .geometry: GeometryPanel()
                    case .presets: PresetsPanel(list: photos)
                    case .history: HistoryPanel()
                    }
                }.padding()
            }
        }.background(Palette.panel)
    }
    private func navigate(_ step: Int) {
        let list = app.culling.visible(photos)
        app.culling.move(by: step, in: list, extend: false)
        if let photo = app.culling.focused(in: list) { app.editing.load(photo) }
    }
}

struct PanelHeader: View {
    let title: String
    var body: some View { Text(title).font(.headline).padding(.top, 8) }
}

struct PresetsPanel: View {
    @Environment(AppState.self) private var app
    @Environment(\.modelContext) private var context
    @Query(sort: \EditPreset.name) private var presets: [EditPreset]
    let list: [Photo]
    @State private var name = ""
    @State private var importing = false
    @State private var shares: SharedFiles?
    @State private var error: String?
    var body: some View {
        TextField(app.m("Preset name", "Nome do preset"), text: $name).textFieldStyle(.roundedBorder)
        HStack {
            Button(app.t("presets.save")) {
                do {
                    context.insert(EditPreset(name: name, recipeData: try JSONEncoder().encode(app.editing.recipe)))
                    try context.save(); name = ""
                } catch { self.error = error.localizedDescription }
            }.disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            Spacer()
            Button(app.t("presets.import")) { importing = true }
        }
        ForEach(presets) { preset in
            HStack {
                Button(preset.name) {
                    guard let recipe = try? JSONDecoder().decode(EditRecipe.self, from: preset.recipeData) else { return }
                    app.editing.recipe = recipe; app.editing.commit("history.preset")
                }
                Spacer()
                Button { share(preset) } label: { Image(systemName: "square.and.arrow.up") }
                Button(role: .destructive) { context.delete(preset); try? context.save() } label: { Image(systemName: "trash") }
            }.padding(.vertical, 5)
        }
        MobileStyle(photos: list)
        if let error { Text(error).foregroundStyle(.red) }
        Color.clear.frame(height: 1)
            .fileImporter(isPresented: $importing, allowedContentTypes: [.data], allowsMultipleSelection: true) { result in
                do {
                    for url in try result.get() {
                        let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
                        let data = try Data(contentsOf: url)
                        let preset: PresetFile
                        if url.pathExtension.lowercased() == "xmp" {
                            guard let parsed = LightroomPreset.parse(data) else { throw CocoaError(.fileReadCorruptFile) }
                            preset = PresetFile(name: parsed.name ?? url.deletingPathExtension().lastPathComponent, recipe: parsed.recipe)
                        } else { preset = try PresetFile.decode(data) }
                        context.insert(EditPreset(name: preset.name, recipeData: try JSONEncoder().encode(preset.recipe)))
                    }
                    try context.save()
                } catch { self.error = error.localizedDescription }
            }
            .sheet(item: $shares) { ShareFiles(urls: $0.urls) }
    }
    private func share(_ preset: EditPreset) {
        do {
            let recipe = try JSONDecoder().decode(EditRecipe.self, from: preset.recipeData)
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(RenameTemplate.sanitize(preset.name)).ppkpreset")
            try PresetFile(name: preset.name, recipe: recipe).encoded().write(to: url)
            shares = SharedFiles(urls: [url])
        } catch { self.error = error.localizedDescription }
    }
}

struct SharedFiles: Identifiable { let id = UUID(); let urls: [URL] }
struct ShareFiles: UIViewControllerRepresentable {
    let urls: [URL]
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: urls, applicationActivities: nil) }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

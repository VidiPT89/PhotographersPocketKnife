import SwiftUI
import SwiftData

struct CullingView: View {
    @Environment(AppState.self) private var app
    @Query(sort: \Photo.importedAt) private var photos: [Photo]
    @FocusState private var keyboardFocus: Bool

    var body: some View {
        @Bindable var culling = app.culling
        let list = culling.visible(photos)

        VStack(spacing: 0) {
            CullingToolbar(photos: photos, visible: list)
            Divider()
            HStack(spacing: 0) {
                content(list: list)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if culling.showInfoPanel, !photos.isEmpty {
                    Divider()
                    InfoPanel(photo: culling.focused(in: list))
                        .frame(width: 260)
                        .transition(.move(edge: .trailing))
                }
            }
            .animation(Motion.smooth, value: culling.showInfoPanel)
        }
        .focusable()
        .focusEffectDisabled()
        .focused($keyboardFocus)
        .onAppear { keyboardFocus = true }
        .simultaneousGesture(TapGesture().onEnded { keyboardFocus = true })
        .onKeyPress(phases: .down) { press in handleKey(press, list: list) }
        .sheet(item: $culling.activeSheet) { sheet in
            switch sheet {
            case .importFolder(let url): ImportSheet(folder: url)
            case .rename: RenameSheet(photos: culling.targets(in: list))
            case .metadata: MetadataSheet(photos: culling.targets(in: list))
            case .smartCull:
                let selected = culling.targets(in: list)
                SmartCullSheet(photos: selected.count > 1 ? selected : list)
            case .gallery:
                let selected = culling.targets(in: list)
                GallerySheet(photos: selected.count > 1 ? selected : list)
            }
        }
    }

    @ViewBuilder
    private func content(list: [Photo]) -> some View {
        if photos.isEmpty {
            EmptyModuleView(
                systemImage: "photo.stack",
                title: app.t("culling.empty.title"),
                subtitle: app.t("culling.empty.subtitle"),
                actionTitle: app.t("culling.import"),
                action: { FilePanels.chooseImportFolder(app) }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .folderDropTarget { app.culling.activeSheet = .importFolder($0) }
        } else {
            switch app.culling.viewMode {
            case .grid: PhotoGridView(list: list).transition(.opacity)
            case .loupe: LoupeView(list: list).transition(.opacity)
            case .compare: CompareView(list: list).transition(.opacity)
            }
        }
    }

    private func handleKey(_ press: KeyPress, list: [Photo]) -> KeyPress.Result {
        let culling = app.culling
        let extend = press.modifiers.contains(.shift)
        let rowStep = culling.viewMode == .grid ? max(culling.gridColumns, 1) : 1
        switch press.key {
        case .leftArrow: culling.move(by: -1, in: list, extend: extend); return .handled
        case .rightArrow: culling.move(by: 1, in: list, extend: extend); return .handled
        case .upArrow: culling.move(by: -rowStep, in: list, extend: extend); return .handled
        case .downArrow: culling.move(by: rowStep, in: list, extend: extend); return .handled
        case .escape:
            if culling.zoomed || culling.magnifier {
                withAnimation(Motion.snappy) { culling.zoomed = false; culling.magnifier = false }
                return .handled
            }
            guard culling.viewMode != .grid else { return .ignored }
            withAnimation(Motion.smooth) { culling.viewMode = .grid }
            return .handled
        default: break
        }
        if press.modifiers.contains(.command) {
            guard press.characters == "a" else { return .ignored }
            culling.selection = Set(list.map(\.id))
            return .handled
        }
        // "+" é Shift + "=" no teclado: as duas teclas aumentam as miniaturas.
        let characters = press.characters == "+" ? "=" : press.characters
        guard let action = app.shortcuts.action(for: characters) else { return .ignored }
        switch action {
        case .develop:
            app.module = .editing
            return .handled
        case .crop:
            app.module = .editing
            app.editing.tab = .geometry
            return .handled
        default:
            break
        }
        let affected = culling.viewMode == .compare ? 1 : culling.targets(in: list).count
        withAnimation(Motion.pop) { culling.perform(action, in: list) }
        if action.isColorLabel, app.hotFolder.isEnabled {
            let started = app.hotFolder.handleLabelChange(culling.targets(in: list), transfers: app.transfers)
            if started > 0 {
                app.showToast(String(format: app.t("toast.hotFolder"), started), icon: "flame.fill")
                return .handled
            }
        }
        if action.showsToast, affected > 0 {
            app.showToast(String(format: app.t("toast.action"), app.t(action.labelKey), affected), icon: action.icon)
        }
        return .handled
    }
}

struct CullingToolbar: View {
    @Environment(AppState.self) private var app
    let photos: [Photo]
    let visible: [Photo]

    var body: some View {
        @Bindable var c = app.culling
        let cameras = Set(photos.compactMap(\.camera)).sorted()
        let lenses = Set(photos.compactMap(\.lens)).sorted()
        let focalLengths = Set(photos.compactMap { $0.focalLength?.rounded() }).sorted()
        let hasTargets = !c.targets(in: visible).isEmpty

        HStack(spacing: 10) {
            PrimaryButton(title: app.t("culling.import"), systemImage: "square.and.arrow.down") {
                FilePanels.chooseImportFolder(app)
            }

            Picker("", selection: $c.viewMode) {
                ForEach(CullingViewMode.allCases) { Image(systemName: $0.icon).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(width: 110)

            Menu {
                Picker(app.t("filter.minRating"), selection: $c.minRating) {
                    ForEach(0...5, id: \.self) { Text($0 == 0 ? app.t("filter.any") : String(repeating: "★", count: $0)).tag($0) }
                }
                Picker(app.t("filter.flag"), selection: $c.flagFilter) {
                    ForEach(FlagFilter.allCases) { Text(app.t($0.labelKey)).tag($0) }
                }
                Picker(app.t("filter.color"), selection: $c.colorFilter) {
                    Text(app.t("filter.any")).tag(ColorLabel?.none)
                    ForEach(ColorLabel.allCases.dropFirst()) { Text(app.t($0.labelKey)).tag(Optional($0)) }
                }
                Picker(app.t("meta.camera"), selection: $c.camera) {
                    Text(app.t("filter.any")).tag(String?.none)
                    ForEach(cameras, id: \.self) { Text($0).tag(Optional($0)) }
                }
                Picker(app.t("meta.lens"), selection: $c.lens) {
                    Text(app.t("filter.any")).tag(String?.none)
                    ForEach(lenses, id: \.self) { Text($0).tag(Optional($0)) }
                }
                Picker(app.t("filter.iso"), selection: $c.minISO) {
                    ForEach(CullingModel.isoSteps, id: \.self) { Text($0 == 0 ? app.t("filter.any") : "≥ ISO \($0)").tag($0) }
                }
                Picker(app.t("meta.focal"), selection: $c.focalLength) {
                    Text(app.t("filter.any")).tag(Double?.none)
                    ForEach(focalLengths, id: \.self) { Text("\(Int($0)) mm").tag(Optional($0)) }
                }
                if c.cullReport != nil {
                    Toggle(app.t("filter.issuesOnly"), isOn: $c.showIssuesOnly)
                }
                Divider()
                Button(app.t("filter.clear")) { c.clearFilters() }
            } label: {
                Label(app.t("filter.title"), systemImage: c.hasActiveFilters ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
            }
            .fixedSize()

            Menu {
                Picker(app.t("sort.title"), selection: $c.sort) {
                    ForEach(PhotoSort.allCases) { Text(app.t($0.labelKey)).tag($0) }
                }
                Toggle(app.t("sort.ascending"), isOn: $c.sortAscending)
            } label: {
                Label(app.t("sort.title"), systemImage: "arrow.up.arrow.down")
            }
            .fixedSize()

            TextField(app.t("filter.search"), text: $c.searchText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 140)

            Spacer()

            Button { c.activeSheet = .smartCull } label: {
                if c.isAnalyzing {
                    ProgressView().controlSize(.mini)
                } else {
                    Label(app.t("cull.title"), systemImage: "wand.and.stars")
                        .labelStyle(.titleAndIcon)
                        .lineLimit(1)
                        .foregroundStyle(Brand.orange)
                }
            }
            .fixedSize()
            .help(app.t("cull.title"))
            .disabled(photos.isEmpty)

            if c.cullReport != nil {
                Button { withAnimation(Motion.smooth) { c.showCullBadges.toggle() } } label: {
                    Image(systemName: c.showCullBadges ? "gauge.with.dots.needle.67percent" : "gauge.with.dots.needle.0percent")
                }
                .help(app.t("cull.badges"))
            }

            Button {
                if c.showDuplicatesOnly {
                    c.showDuplicatesOnly = false
                } else {
                    Task { await c.findDuplicates(in: photos) }
                }
            } label: {
                if c.isFindingDuplicates {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: c.showDuplicatesOnly ? "square.on.square.fill" : "square.on.square")
                }
            }
            .help(app.t("culling.duplicates"))

            Button { c.activeSheet = .rename } label: { Image(systemName: "character.cursor.ibeam") }
                .help(app.t("rename.title"))
                .disabled(!hasTargets)
            Button { c.activeSheet = .metadata } label: { Image(systemName: "tag") }
                .help(app.t("metadata.title"))
                .disabled(!hasTargets)

            Menu {
                Button(app.t("culling.presentation"), systemImage: "play.rectangle") {
                    withAnimation(Motion.smooth) { c.presenting = true }
                }
                Divider()
                Button(app.t("culling.saveSidecars"), systemImage: "doc.badge.gearshape") { saveSidecars() }
                Button(app.t("culling.exportXMP"), systemImage: "arrow.up.doc") { exportXMP() }
                Button(app.t("keywords.auto"), systemImage: "text.badge.star") { autoKeywords() }
                Divider()
                Button(app.t("gallery.create"), systemImage: "photo.on.rectangle.angled") { c.activeSheet = .gallery }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuIndicator(.hidden)
            .fixedSize()
            .help(app.t("culling.more"))

            Slider(
                value: Binding(get: { Double(c.thumbnailStep) }, set: { c.thumbnailStep = Int($0.rounded()) }),
                in: 0...Double(CullingModel.thumbnailSizes.count - 1),
                step: 1
            )
            .frame(width: 90)
            .help(app.t("culling.thumbnailSize"))

            Button { c.showInfoPanel.toggle() } label: { Image(systemName: "sidebar.right") }
                .help(app.t("info.metadata"))
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// A seleção, ou todas as fotos visíveis se não houver seleção.
    private var actionTargets: [Photo] {
        let targets = app.culling.targets(in: visible)
        return targets.isEmpty ? visible : targets
    }

    private func saveSidecars() {
        let items = CatalogService.sidecars(for: actionTargets)
        let app = app
        Task {
            let written = await Task.detached(priority: .userInitiated) {
                items.filter { (try? $0.sidecar.write(for: $0.url)) != nil }.count
            }.value
            app.showToast(String(format: app.t("toast.sidecars"), written), icon: "doc.badge.gearshape")
        }
    }

    private func autoKeywords() {
        let targets = actionTargets
        let jobs = targets.map { (id: $0.id, url: $0.url) }
        let app = app
        Task {
            let results = await Task.detached(priority: .userInitiated) {
                jobs.compactMap { job -> (UUID, [String])? in
                    guard let keywords = try? AutoKeywords.apply(to: job.url), !keywords.isEmpty else { return nil }
                    return (job.id, keywords)
                }
            }.value
            let byID = Dictionary(results, uniquingKeysWith: { first, _ in first })
            for photo in targets {
                if let keywords = byID[photo.id] { photo.keywords = keywords.joined(separator: ", ") }
            }
            app.showToast(String(format: app.t("toast.keywords"), results.count), icon: "text.badge.star")
        }
    }

    private func exportXMP() {
        let items = actionTargets.map { (url: $0.url, rating: $0.rating, label: $0.colorLabel) }
        let app = app
        Task {
            let written = await Task.detached(priority: .userInitiated) {
                items.filter { (try? MetadataWriter.writeRating($0.rating, label: $0.label, to: $0.url)) != nil }.count
            }.value
            app.showToast(String(format: app.t("toast.xmp"), written), icon: "arrow.up.doc.fill")
        }
    }
}

@MainActor
enum FilePanels {
    static func chooseFolder(prompt: String) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = prompt
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func chooseImportFolder(_ app: AppState) {
        guard let url = chooseFolder(prompt: app.t("culling.import")) else { return }
        app.module = .culling
        app.culling.activeSheet = .importFolder(url)
    }
}

extension View {
    /// Aceita pastas largadas por drag & drop, com a zona a brilhar.
    func folderDropTarget(_ onFolder: @escaping (URL) -> Void) -> some View {
        modifier(FolderDropTarget(onFolder: onFolder))
    }
}

private struct FolderDropTarget: ViewModifier {
    let onFolder: (URL) -> Void
    @State private var targeted = false

    func body(content: Content) -> some View {
        content
            .dropDestination(for: URL.self) { urls, _ in
                guard let folder = urls.first(where: { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }) else { return false }
                onFolder(folder)
                return true
            } isTargeted: { targeted = $0 }
            .overlay { DropZoneOverlay(active: targeted) }
    }
}

/// Contorno tracejado âmbar que "respira" enquanto há ficheiros por cima de uma zona de largada.
struct DropZoneOverlay: View {
    let active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: CGFloat = 0
    @State private var breathe = false

    var body: some View {
        ZStack {
            if active {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Brand.amber.opacity(0.07))
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Brand.amber, style: StrokeStyle(lineWidth: 2.5, dash: [10, 7], dashPhase: phase))
                    .shadow(color: Brand.orange.opacity(breathe ? 0.8 : 0.35), radius: breathe ? 14 : 6)
                    .transition(.opacity)
            }
        }
        .padding(6)
        .scaleEffect(active && breathe && !reduceMotion ? 0.995 : 1)
        .allowsHitTesting(false)
        .animation(Motion.smooth, value: active)
        .onChange(of: active) { _, isActive in
            guard isActive, !reduceMotion else {
                phase = 0
                breathe = false
                return
            }
            withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) { phase = -17 }
            withAnimation(.easeInOut(duration: 1.1).repeatForever()) { breathe = true }
        }
    }
}

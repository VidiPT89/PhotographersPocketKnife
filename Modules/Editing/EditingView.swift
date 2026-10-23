import SwiftUI
import SwiftData

struct EditingView: View {
    @Environment(AppState.self) private var app
    @Query(sort: \Photo.importedAt) private var photos: [Photo]
    @State private var showExport = false
    @State private var exportWithUpload = false
    @FocusState private var keyboardFocus: Bool
    @State private var zoom = ZoomPosition()

    var body: some View {
        let list = app.culling.visible(photos)
        let photo = app.culling.focused(in: list) ?? app.culling.targets(in: list).first ?? list.first

        if let photo {
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    EditingToolbar(list: list, showExport: $showExport, zoom: $zoom)
                    Divider()
                    EditZoom(position: $zoom, dragPans: !usesPointer, actionNames: [app.t("zoom.in"), app.t("zoom.out"), app.t("zoom.fit")]) {
                        EditCanvas()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                    FilmStrip(list: list)
                }
                Divider()
                AdjustmentPanel(list: list)
                    .frame(width: 300)
            }
            .focusable()
            .focusEffectDisabled()
            .focused($keyboardFocus)
            .onAppear {
                keyboardFocus = true
                consumeExportRequest()
            }
            .onKeyPress(phases: .down) { press in handleKey(press) }
            .task(id: "\(photo.id)|\(photo.path)") { app.editing.load(photo) }
            // Outra foto começa ajustada à janela; ampliada, o preview é renderizado com mais detalhe.
            .onChange(of: photo.id) { _, _ in zoom = ZoomPosition() }
            .onChange(of: zoom.previewDetail()) { _, detail in
                app.editing.previewDetail = detail
                app.editing.scheduleRender()
            }
            .onDisappear { app.editing.previewDetail = 1 }
            .sheet(isPresented: $showExport) {
                ExportSheet(photos: app.culling.targets(in: list).isEmpty ? [photo] : app.culling.targets(in: list), startWithUpload: exportWithUpload)
            }
            .onChange(of: showExport) { _, shown in if !shown { exportWithUpload = false } }
            .onChange(of: app.pendingExport) { _, _ in consumeExportRequest() }
            .onReceive(NotificationCenter.default.publisher(for: .pasteDevelop)) { _ in
                guard let clipboard = app.editing.clipboard else { return }
                let targets = app.culling.targets(in: list)
                app.editing.applySettings(clipboard, labelKey: "history.paste", to: targets)
                app.showToast(app.t("toast.pasted", count: targets.count), icon: "doc.on.clipboard.fill")
            }
        } else {
            EmptyModuleView(
                systemImage: "slider.horizontal.3",
                title: app.t("editing.empty.title"),
                subtitle: app.t("editing.empty.subtitle")
            )
        }
    }

    /// Ferramentas em que arrastar edita a foto (recorte, máscaras, remoção, divisão antes/depois).
    private var usesPointer: Bool {
        let editing = app.editing
        return editing.isCropping || editing.tab == .masks || editing.tab == .remove || editing.compareMode == .split
    }

    /// `⌘E` / `⌘⇧E` podem chegar antes de este ecrã existir: o pedido fica no estado da app até ser consumido.
    private func consumeExportRequest() {
        guard let withUpload = app.pendingExport else { return }
        app.pendingExport = nil
        exportWithUpload = withUpload
        showExport = true
    }

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        guard !press.modifiers.contains(.command) else { return .ignored }
        let editing = app.editing
        switch press.characters {
        case "\\":
            withAnimation(Motion.snappy) { editing.compareMode = editing.compareMode == .before ? .off : .before }
            return .handled
        case "r":
            withAnimation(Motion.snappy) { editing.tab = editing.tab == .geometry ? .basic : .geometry }
            return .handled
        case "m":
            withAnimation(Motion.snappy) { editing.tab = .masks }
            return .handled
        default:
            return .ignored
        }
    }
}

extension Notification.Name {
    static let pasteDevelop = Notification.Name("PhotographersPocketKnife.pasteDevelop")
}

struct EditingToolbar: View {
    @Environment(AppState.self) private var app
    let list: [Photo]
    @Binding var showExport: Bool
    @Binding var zoom: ZoomPosition

    var body: some View {
        @Bindable var editing = app.editing
        HStack(spacing: 10) {
            Button { editing.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                .disabled(!editing.history.canUndo)
                .hint(app.t("history.undo"))
            Button { editing.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                .disabled(!editing.history.canRedo)
                .hint(app.t("history.redo"))

            Picker("", selection: $editing.compareMode) {
                ForEach(CompareMode.allCases) { Text(app.t($0.labelKey)).tag($0) }
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .hint(app.t("compare.mode"))

            Button { withAnimation(Motion.snappy) { zoom = zoom.stepped(1 / 1.5) } } label: { Image(systemName: "minus.magnifyingglass") }
                .keyboardShortcut("-", modifiers: .command)
                .disabled(zoom.scale <= 1)
                .hint(app.t("zoom.out"))
            Button { withAnimation(Motion.snappy) { zoom = ZoomPosition() } } label: {
                Text("\(Int((zoom.scale * 100).rounded())) %").monospacedDigit().frame(minWidth: 40)
            }
            .keyboardShortcut("0", modifiers: .command)
            .hint(app.t("zoom.fit"))
            Button { withAnimation(Motion.snappy) { zoom = zoom.stepped(1.5) } } label: { Image(systemName: "plus.magnifyingglass") }
                .keyboardShortcut("=", modifiers: .command)
                .disabled(zoom.scale >= ZoomPosition.maxScale)
                .hint(app.t("zoom.in"))

            Spacer(minLength: 8)

            Button {
                editing.copySettings()
                app.showToast(app.t("toast.copied"), icon: "doc.on.doc.fill")
            } label: { Image(systemName: "doc.on.doc") }
            .hint(app.t("editing.copy"))
            Button {
                guard let clipboard = editing.clipboard else { return }
                let targets = app.culling.targets(in: list)
                editing.applySettings(clipboard, labelKey: "history.paste", to: targets)
                app.showToast(app.t("toast.pasted", count: targets.count), icon: "doc.on.clipboard.fill")
            } label: { Image(systemName: "doc.on.clipboard") }
            .disabled(editing.clipboard == nil)
            .hint(app.t("editing.paste"))
            Button { editing.reset() } label: { Image(systemName: "arrow.counterclockwise") }
                .hint(app.t("editing.reset"))

            PrimaryButton(title: app.t("export.title"), systemImage: "square.and.arrow.up") { showExport = true }
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

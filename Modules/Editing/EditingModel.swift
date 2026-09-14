import SwiftUI

enum RemovalMode: String, CaseIterable, Identifiable {
    case object, brush
    var id: String { rawValue }
    var labelKey: String { "removal.mode.\(rawValue)" }
    var icon: String { self == .object ? "cursorarrow.rays" : "paintbrush.pointed" }
}

enum EditTab: String, CaseIterable, Identifiable {
    case basic, curve, hsl, grading, masks, remove, geometry, presets, history
    var id: String { rawValue }
    var labelKey: String { "editTab.\(rawValue)" }

    var icon: String {
        switch self {
        case .basic: "slider.horizontal.3"
        case .curve: "point.topleft.down.to.point.bottomright.curvepath"
        case .hsl: "paintpalette"
        case .grading: "circle.lefthalf.striped.horizontal"
        case .masks: "circle.dashed.inset.filled"
        case .remove: "eraser.line.dashed"
        case .geometry: "crop.rotate"
        case .presets: "square.stack"
        case .history: "clock.arrow.circlepath"
        }
    }
}

enum CompareMode: String, CaseIterable, Identifiable {
    case off, before, split
    var id: String { rawValue }
    var labelKey: String { "compare.\(rawValue)" }
}

enum CropAspect: String, CaseIterable, Identifiable {
    case free, square, fourThree, threeTwo, sixteenNine, fourFive
    var id: String { rawValue }

    var label: String {
        switch self {
        case .free: "—"
        case .square: "1:1"
        case .fourThree: "4:3"
        case .threeTwo: "3:2"
        case .sixteenNine: "16:9"
        case .fourFive: "4:5"
        }
    }

    var ratio: Double? {
        switch self {
        case .free: nil
        case .square: 1
        case .fourThree: 4 / 3
        case .threeTwo: 3 / 2
        case .sixteenNine: 16 / 9
        case .fourFive: 4 / 5
        }
    }
}

enum CropGuide: String, CaseIterable, Identifiable {
    case thirds, golden, none
    var id: String { rawValue }
    var labelKey: String { "guide.\(rawValue)" }
}

enum HSLComponent: String, CaseIterable, Identifiable {
    case hue, saturation, luminance
    var id: String { rawValue }
    var labelKey: String { "hslComponent.\(rawValue)" }
}

@Observable
@MainActor
final class EditingModel {
    var recipe = EditRecipe()
    private(set) var history = EditHistory()
    private(set) var preview: CGImage?
    private(set) var beforeImage: CGImage?
    private(set) var histogram: HistogramData?
    private(set) var clippingOverlay: CGImage?
    private(set) var isRendering = false
    /// Mostra a vermelho/azul as zonas com altas luzes ou sombras recortadas.
    var showClipping = false {
        didSet { scheduleRender() }
    }
    /// Receita temporária para pré-visualizar um preset ao passar o rato.
    var hoverPreview: EditRecipe? {
        didSet { if hoverPreview != oldValue { scheduleRender() } }
    }
    /// Muda sempre que um preset é aplicado (dispara o reflexo de luz no canvas).
    private(set) var presetFlash = UUID()
    var selectedMaskID: UUID?

    /// O último separador fica guardado entre sessões.
    var tab: EditTab = EditTab(rawValue: UserDefaults.standard.string(forKey: "editing.tab") ?? "") ?? .basic {
        didSet {
            UserDefaults.standard.set(tab.rawValue, forKey: "editing.tab")
            if oldValue == .geometry || tab == .geometry { scheduleRender() }
        }
    }
    var compareMode: CompareMode = .off {
        didSet { scheduleRender() }
    }
    var splitPosition = 0.5
    var curveChannel: CurveChannel = .master
    var hslComponent: HSLComponent = .saturation
    var cropAspect: CropAspect = .free
    var cropGuide: CropGuide = .thirds
    var clipboard: EditRecipe?
    var removalMode: RemovalMode = .object
    var removalBrushSize = 0.05
    private(set) var isAutoEnhancing = false

    @ObservationIgnored private(set) weak var photo: Photo?
    @ObservationIgnored private var url: URL?
    @ObservationIgnored private var rendering = false
    @ObservationIgnored private var dirty = false
    @ObservationIgnored var previewMaxPixel = 2000

    /// No separador de geometria mostra-se a imagem inteira para ajustar o recorte.
    var isCropping: Bool { tab == .geometry }

    func load(_ photo: Photo) {
        guard photo.id != self.photo?.id || photo.url != url else { return }
        self.photo = photo
        url = photo.url
        history = photo.historyData.flatMap { try? JSONDecoder().decode(EditHistory.self, from: $0) } ?? EditHistory()
        recipe = photo.recipeData.flatMap { try? JSONDecoder().decode(EditRecipe.self, from: $0) } ?? history.current
        preview = nil
        beforeImage = nil
        clippingOverlay = nil
        hoverPreview = nil
        selectedMaskID = recipe.masks.first?.id
        scheduleRender()
    }

    // MARK: Snapshots e máscaras

    func saveSnapshot(named name: String) {
        history.snapshots.append(EditSnapshot(name: name, recipe: recipe))
        persist()
    }

    func applySnapshot(_ snapshot: EditSnapshot) {
        recipe = snapshot.recipe
        commit("history.snapshot")
    }

    func deleteSnapshot(_ snapshot: EditSnapshot) {
        history.snapshots.removeAll { $0.id == snapshot.id }
        persist()
    }

    func addMask(_ kind: MaskKind) {
        var mask = LocalMask(kind: kind)
        mask.exposure = 0.5
        recipe.masks.append(mask)
        selectedMaskID = mask.id
        commit("history.mask")
    }

    func deleteMask(_ id: UUID) {
        recipe.masks.removeAll { $0.id == id }
        if selectedMaskID == id { selectedMaskID = recipe.masks.last?.id }
        commit("history.mask")
    }

    var selectedMaskIndex: Int? {
        recipe.masks.firstIndex { $0.id == selectedMaskID }
    }

    // MARK: Remoção de objetos e edição automática

    func addRemoval(_ removal: Removal) {
        recipe.removals.append(removal)
        commit("history.remove")
    }

    func deleteRemoval(_ id: UUID) {
        recipe.removals.removeAll { $0.id == id }
        commit("history.remove")
    }

    func clearRemovals() {
        recipe.removals = []
        commit("history.remove")
    }

    /// Só acrescenta a remoção se o Vision encontrar um objeto no ponto; devolve se encontrou.
    func pickObject(at point: CurvePoint) async -> Bool {
        guard let url else { return false }
        let recipe = recipe
        let maxPixel = previewMaxPixel
        let found = await Task.detached(priority: .userInitiated) {
            ImageRenderer.shared.hasObject(url: url, recipe: recipe, at: point, maxPixel: maxPixel)
        }.value
        guard found, self.url == url else { return false }
        addRemoval(Removal(objectPoint: point))
        return true
    }

    func autoEnhance() {
        guard let url, !isAutoEnhancing else { return }
        isAutoEnhancing = true
        let recipe = recipe
        // Com um estilo pessoal marcado como predefinido, o Automático edita no estilo do fotógrafo.
        let style = UserDefaults.standard.string(forKey: "style.default")
            .flatMap(UUID.init(uuidString:))
            .flatMap { StyleProfileStore().profile(id: $0) }
        Task {
            let enhanced = await Task.detached(priority: .userInitiated) { () -> EditRecipe? in
                if let style { return ImageRenderer.shared.styled(url: url, profile: style, current: recipe) }
                return ImageRenderer.shared.autoEnhanced(url: url, recipe: recipe, maxPixel: 1024)
            }.value
            isAutoEnhancing = false
            guard self.url == url, let enhanced else { return }
            self.recipe = enhanced
            commit(style == nil ? "history.auto" : "history.style")
            flashPreset()
        }
    }

    func flashPreset() {
        presetFlash = UUID()
    }

    // MARK: Histórico

    func commit(_ labelKey: String) {
        history.push(labelKey, recipe)
        persist()
        scheduleRender()
    }

    func undo() {
        guard history.canUndo else { return }
        recipe = history.undo()
        persist()
        scheduleRender()
    }

    func redo() {
        guard history.canRedo else { return }
        recipe = history.redo()
        persist()
        scheduleRender()
    }

    func jump(to index: Int) {
        recipe = history.jump(to: index)
        persist()
        scheduleRender()
    }

    func reset() {
        recipe = EditRecipe()
        commit("history.reset")
    }

    // MARK: Presets e sincronização

    func copySettings() {
        clipboard = recipe
    }

    /// Aplica ajustes a várias fotos, mantendo o recorte de cada uma. Cada foto ganha uma entrada no histórico.
    func applySettings(_ settings: EditRecipe, labelKey: String, to photos: [Photo]) {
        for target in photos {
            if target.id == photo?.id {
                recipe = recipe.applyingSettings(from: settings)
                commit(labelKey)
                continue
            }
            var targetHistory = target.historyData.flatMap { try? JSONDecoder().decode(EditHistory.self, from: $0) } ?? EditHistory()
            let current = target.recipeData.flatMap { try? JSONDecoder().decode(EditRecipe.self, from: $0) } ?? targetHistory.current
            let updated = current.applyingSettings(from: settings)
            targetHistory.push(labelKey, updated)
            target.recipeData = updated.isIdentity ? nil : try? JSONEncoder().encode(updated)
            target.historyData = try? JSONEncoder().encode(targetHistory)
        }
    }

    private func persist() {
        guard let photo else { return }
        photo.recipeData = recipe.isIdentity ? nil : try? JSONEncoder().encode(recipe)
        photo.historyData = try? JSONEncoder().encode(history)
    }

    // MARK: Render

    /// Só um render de cada vez; pedidos durante um render juntam-se num único render seguinte.
    func scheduleRender() {
        dirty = true
        guard !rendering else { return }
        startRender()
    }

    private func startRender() {
        guard let url else { return }
        dirty = false
        rendering = true
        isRendering = true
        let recipe = hoverPreview ?? recipe
        let applyCrop = !isCropping
        let maxPixel = previewMaxPixel
        let needsBefore = compareMode != .off
        let needsClipping = showClipping

        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> (SendableImage?, SendableImage?, HistogramData?, SendableImage?) in
                let after = ImageRenderer.shared.renderPreview(url: url, recipe: recipe, maxPixel: maxPixel, applyCrop: applyCrop)
                let before = needsBefore
                    ? ImageRenderer.shared.renderPreview(url: url, recipe: recipe.geometryOnly, maxPixel: maxPixel, applyCrop: applyCrop)
                    : nil
                let clipping = needsClipping ? after.flatMap { ClippingOverlay.make(from: $0.cgImage) }.map { SendableImage(cgImage: $0) } : nil
                return (after, before, after.map { Histogram.compute($0.cgImage) }, clipping)
            }.value

            if self.url == url {
                preview = result.0?.cgImage
                beforeImage = result.1?.cgImage
                histogram = result.2
                clippingOverlay = result.3?.cgImage
            }
            rendering = false
            if dirty {
                startRender()
            } else {
                isRendering = false
            }
        }
    }
}

import SwiftUI

enum EditTab: String, CaseIterable, Identifiable {
    case basic, curve, hsl, geometry, presets, history
    var id: String { rawValue }
    var labelKey: String { "editTab.\(rawValue)" }

    var icon: String {
        switch self {
        case .basic: "slider.horizontal.3"
        case .curve: "point.topleft.down.to.point.bottomright.curvepath"
        case .hsl: "paintpalette"
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
    private(set) var isRendering = false

    var tab: EditTab = .basic {
        didSet { if oldValue == .geometry || tab == .geometry { scheduleRender() } }
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
        scheduleRender()
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
        let recipe = recipe
        let applyCrop = !isCropping
        let maxPixel = previewMaxPixel
        let needsBefore = compareMode != .off

        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> (SendableImage?, SendableImage?, HistogramData?) in
                let after = ImageRenderer.shared.renderPreview(url: url, recipe: recipe, maxPixel: maxPixel, applyCrop: applyCrop)
                let before = needsBefore
                    ? ImageRenderer.shared.renderPreview(url: url, recipe: recipe.geometryOnly, maxPixel: maxPixel, applyCrop: applyCrop)
                    : nil
                return (after, before, after.map { Histogram.compute($0.cgImage) })
            }.value

            if self.url == url {
                preview = result.0?.cgImage
                beforeImage = result.1?.cgImage
                histogram = result.2
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

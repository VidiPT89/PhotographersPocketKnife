import Foundation

struct CurvePoint: Codable, Hashable, Sendable {
    var x: Double
    var y: Double
}

enum CurveChannel: String, CaseIterable, Identifiable, Sendable {
    case master, red, green, blue
    var id: String { rawValue }
    var labelKey: String { "curve.\(rawValue)" }
}

enum HSLBand: Int, CaseIterable, Identifiable, Sendable {
    case red, orange, yellow, green, aqua, blue, purple, magenta
    var id: Int { rawValue }
    var labelKey: String { "hsl.\(self)" }

    /// Matiz central da banda, em graus.
    var hue: Double { [0, 30, 60, 120, 180, 240, 270, 300][rawValue] }
}

struct HSLAdjustment: Codable, Equatable, Sendable {
    var hue = 0.0
    var saturation = 0.0
    var luminance = 0.0
}

/// Recorte normalizado (0...1), origem no canto superior esquerdo.
struct CropRect: Codable, Equatable, Sendable {
    var x = 0.0
    var y = 0.0
    var width = 1.0
    var height = 1.0

    var isFull: Bool { self == CropRect() }
}

enum MaskKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case linear, radial, brush
    var id: String { rawValue }
    var labelKey: String { "mask.\(rawValue)" }

    var icon: String {
        switch self {
        case .linear: "rectangle.lefthalf.inset.filled"
        case .radial: "circle.dashed.inset.filled"
        case .brush: "paintbrush.pointed.fill"
        }
    }
}

/// Uma pincelada da máscara de pincel: pontos normalizados (0…1, origem no canto superior esquerdo).
struct BrushStroke: Codable, Equatable, Sendable {
    var points: [CurvePoint]
    /// Pinceladas de borracha tiram área à máscara.
    var erase = false
    /// Diâmetro como fração do lado menor da imagem.
    var size = 0.06
}

/// Ajuste local com máscara de gradiente. Coordenadas normalizadas na imagem final (depois do recorte).
struct LocalMask: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var kind: MaskKind
    // Radial
    var centerX = 0.5
    var centerY = 0.5
    var radiusX = 0.25
    var radiusY = 0.25
    // Linear: efeito total no início, nenhum no fim
    var startX = 0.5
    var startY = 0.15
    var endX = 0.5
    var endY = 0.55
    var feather = 0.5
    var invert = false
    // Pincel
    var strokes: [BrushStroke] = []
    var brushSize = 0.06
    // Ajustes
    var exposure = 0.0
    var contrast = 0.0
    var saturation = 0.0
    var temperature = 0.0
    var clarity = 0.0

    var isNeutral: Bool {
        exposure == 0 && contrast == 0 && saturation == 0 && temperature == 0 && clarity == 0
    }
}

extension LocalMask {
    private enum CodingKeys: String, CodingKey {
        case id, kind, centerX, centerY, radiusX, radiusY, startX, startY, endX, endY, feather, invert
        case strokes, brushSize, exposure, contrast, saturation, temperature, clarity
    }

    /// Máscaras de versões anteriores (sem pincel) continuam a abrir.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(MaskKind.self, forKey: .kind)
        let defaults = LocalMask(kind: kind)
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? container.decodeIfPresent(T.self, forKey: key)) ?? fallback
        }
        self.kind = kind
        id = value(.id, defaults.id)
        centerX = value(.centerX, defaults.centerX)
        centerY = value(.centerY, defaults.centerY)
        radiusX = value(.radiusX, defaults.radiusX)
        radiusY = value(.radiusY, defaults.radiusY)
        startX = value(.startX, defaults.startX)
        startY = value(.startY, defaults.startY)
        endX = value(.endX, defaults.endX)
        endY = value(.endY, defaults.endY)
        feather = value(.feather, defaults.feather)
        invert = value(.invert, defaults.invert)
        strokes = value(.strokes, defaults.strokes)
        brushSize = value(.brushSize, defaults.brushSize)
        exposure = value(.exposure, defaults.exposure)
        contrast = value(.contrast, defaults.contrast)
        saturation = value(.saturation, defaults.saturation)
        temperature = value(.temperature, defaults.temperature)
        clarity = value(.clarity, defaults.clarity)
    }
}

/// A "receita" não-destrutiva de uma foto. O original nunca é alterado.
struct EditRecipe: Equatable, Sendable {
    static let linearCurve = [CurvePoint(x: 0, y: 0), CurvePoint(x: 1, y: 1)]

    // Luz e presença
    var exposure = 0.0
    var contrast = 0.0
    var highlights = 0.0
    var shadows = 0.0
    var whites = 0.0
    var blacks = 0.0
    var texture = 0.0
    var clarity = 0.0
    // Cor
    var temperature = 0.0
    var tint = 0.0
    var vibrance = 0.0
    var saturation = 0.0
    // Detalhe
    var sharpness = 0.0
    var sharpenRadius = 1.0
    var sharpenMasking = 0.0
    var noiseReduction = 0.0
    var colorNoiseReduction = 0.0
    // Ótica e efeitos
    var chromaticAberration = 0.0
    var vignette = 0.0
    var grain = 0.0
    var grainSize = 0.5
    // Curvas e HSL
    var curveMaster = linearCurve
    var curveRed = linearCurve
    var curveGreen = linearCurve
    var curveBlue = linearCurve
    var hsl = Array(repeating: HSLAdjustment(), count: HSLBand.allCases.count)
    // Gradação de cor (matiz em graus, saturação 0…1)
    var shadowsHue = 220.0
    var shadowsSaturation = 0.0
    var midtonesHue = 30.0
    var midtonesSaturation = 0.0
    var highlightsHue = 45.0
    var highlightsSaturation = 0.0
    var gradingBalance = 0.0
    // Ajustes locais
    var masks: [LocalMask] = []
    // Geometria e lente
    var crop = CropRect()
    var straighten = 0.0
    var quarterTurns = 0
    var flipHorizontal = false
    var perspectiveVertical = 0.0
    var perspectiveHorizontal = 0.0
    var lensCorrection = false

    static let identity = EditRecipe()

    var isIdentity: Bool { self == .identity }

    var hasColorGrading: Bool {
        shadowsSaturation > 0 || midtonesSaturation > 0 || highlightsSaturation > 0
    }

    var needsToneCube: Bool {
        whites != 0 || blacks != 0 || highlights > 0 || hasColorGrading
            || [curveMaster, curveRed, curveGreen, curveBlue].contains { $0 != Self.linearCurve }
            || hsl.contains { $0 != HSLAdjustment() }
    }

    /// Só os campos que entram na LUT 3D (para a cache do cubo não depender do resto).
    var cubeRecipe: EditRecipe {
        var recipe = EditRecipe()
        recipe.whites = whites
        recipe.blacks = blacks
        recipe.highlights = max(0, highlights)
        recipe.curveMaster = curveMaster
        recipe.curveRed = curveRed
        recipe.curveGreen = curveGreen
        recipe.curveBlue = curveBlue
        recipe.hsl = hsl
        recipe.shadowsHue = shadowsHue
        recipe.shadowsSaturation = shadowsSaturation
        recipe.midtonesHue = midtonesHue
        recipe.midtonesSaturation = midtonesSaturation
        recipe.highlightsHue = highlightsHue
        recipe.highlightsSaturation = highlightsSaturation
        recipe.gradingBalance = gradingBalance
        return recipe
    }

    func curve(_ channel: CurveChannel) -> [CurvePoint] {
        switch channel {
        case .master: curveMaster
        case .red: curveRed
        case .green: curveGreen
        case .blue: curveBlue
        }
    }

    mutating func setCurve(_ points: [CurvePoint], for channel: CurveChannel) {
        let sorted = points.sorted { $0.x < $1.x }
        switch channel {
        case .master: curveMaster = sorted
        case .red: curveRed = sorted
        case .green: curveGreen = sorted
        case .blue: curveBlue = sorted
        }
    }

    /// Só a geometria (para o "antes" alinhar com o "depois").
    var geometryOnly: EditRecipe {
        var recipe = EditRecipe()
        recipe.crop = crop
        recipe.straighten = straighten
        recipe.quarterTurns = quarterTurns
        recipe.flipHorizontal = flipHorizontal
        recipe.perspectiveVertical = perspectiveVertical
        recipe.perspectiveHorizontal = perspectiveHorizontal
        recipe.lensCorrection = lensCorrection
        return recipe
    }

    /// Copia os ajustes de `other` mas mantém o enquadramento e as máscaras desta foto (presets e sincronização).
    func applyingSettings(from other: EditRecipe) -> EditRecipe {
        var result = other
        result.crop = crop
        result.straighten = straighten
        result.quarterTurns = quarterTurns
        result.flipHorizontal = flipHorizontal
        result.perspectiveVertical = perspectiveVertical
        result.perspectiveHorizontal = perspectiveHorizontal
        result.masks = masks
        return result
    }
}

extension EditRecipe: Codable {
    private enum CodingKeys: String, CodingKey {
        case exposure, contrast, highlights, shadows, whites, blacks, texture, clarity
        case temperature, tint, vibrance, saturation
        case sharpness, sharpenRadius, sharpenMasking, noiseReduction, colorNoiseReduction
        case chromaticAberration, vignette, grain, grainSize
        case curveMaster, curveRed, curveGreen, curveBlue, hsl
        case shadowsHue, shadowsSaturation, midtonesHue, midtonesSaturation, highlightsHue, highlightsSaturation, gradingBalance
        case masks
        case crop, straighten, quarterTurns, flipHorizontal, perspectiveVertical, perspectiveHorizontal, lensCorrection
    }

    /// Campos em falta (receitas de versões anteriores) ficam com o valor por defeito.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = EditRecipe()
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? container.decodeIfPresent(T.self, forKey: key)) ?? fallback
        }
        exposure = value(.exposure, defaults.exposure)
        contrast = value(.contrast, defaults.contrast)
        highlights = value(.highlights, defaults.highlights)
        shadows = value(.shadows, defaults.shadows)
        whites = value(.whites, defaults.whites)
        blacks = value(.blacks, defaults.blacks)
        texture = value(.texture, defaults.texture)
        clarity = value(.clarity, defaults.clarity)
        temperature = value(.temperature, defaults.temperature)
        tint = value(.tint, defaults.tint)
        vibrance = value(.vibrance, defaults.vibrance)
        saturation = value(.saturation, defaults.saturation)
        sharpness = value(.sharpness, defaults.sharpness)
        sharpenRadius = value(.sharpenRadius, defaults.sharpenRadius)
        sharpenMasking = value(.sharpenMasking, defaults.sharpenMasking)
        noiseReduction = value(.noiseReduction, defaults.noiseReduction)
        colorNoiseReduction = value(.colorNoiseReduction, defaults.colorNoiseReduction)
        chromaticAberration = value(.chromaticAberration, defaults.chromaticAberration)
        vignette = value(.vignette, defaults.vignette)
        grain = value(.grain, defaults.grain)
        grainSize = value(.grainSize, defaults.grainSize)
        curveMaster = value(.curveMaster, defaults.curveMaster)
        curveRed = value(.curveRed, defaults.curveRed)
        curveGreen = value(.curveGreen, defaults.curveGreen)
        curveBlue = value(.curveBlue, defaults.curveBlue)
        hsl = value(.hsl, defaults.hsl)
        shadowsHue = value(.shadowsHue, defaults.shadowsHue)
        shadowsSaturation = value(.shadowsSaturation, defaults.shadowsSaturation)
        midtonesHue = value(.midtonesHue, defaults.midtonesHue)
        midtonesSaturation = value(.midtonesSaturation, defaults.midtonesSaturation)
        highlightsHue = value(.highlightsHue, defaults.highlightsHue)
        highlightsSaturation = value(.highlightsSaturation, defaults.highlightsSaturation)
        gradingBalance = value(.gradingBalance, defaults.gradingBalance)
        masks = value(.masks, defaults.masks)
        crop = value(.crop, defaults.crop)
        straighten = value(.straighten, defaults.straighten)
        quarterTurns = value(.quarterTurns, defaults.quarterTurns)
        flipHorizontal = value(.flipHorizontal, defaults.flipHorizontal)
        perspectiveVertical = value(.perspectiveVertical, defaults.perspectiveVertical)
        perspectiveHorizontal = value(.perspectiveHorizontal, defaults.perspectiveHorizontal)
        lensCorrection = value(.lensCorrection, defaults.lensCorrection)
    }
}

struct HistoryEntry: Codable, Equatable, Sendable {
    var labelKey: String
    var recipe: EditRecipe
}

/// Estado guardado com nome, para voltar a ele a qualquer momento.
struct EditSnapshot: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var name: String
    var recipe: EditRecipe
    var date = Date()
}

struct EditHistory: Equatable, Sendable {
    static let maxEntries = 100

    var entries = [HistoryEntry(labelKey: "history.original", recipe: .identity)]
    var index = 0
    var snapshots: [EditSnapshot] = []

    var current: EditRecipe { entries[index].recipe }
    var canUndo: Bool { index > 0 }
    var canRedo: Bool { index < entries.count - 1 }

    mutating func push(_ labelKey: String, _ recipe: EditRecipe) {
        guard recipe != current else { return }
        entries.removeSubrange((index + 1)...)
        entries.append(HistoryEntry(labelKey: labelKey, recipe: recipe))
        if entries.count > Self.maxEntries {
            entries.remove(at: 1)
        }
        index = entries.count - 1
    }

    mutating func undo() -> EditRecipe {
        index = max(index - 1, 0)
        return current
    }

    mutating func redo() -> EditRecipe {
        index = min(index + 1, entries.count - 1)
        return current
    }

    mutating func jump(to newIndex: Int) -> EditRecipe {
        index = min(max(newIndex, 0), entries.count - 1)
        return current
    }
}

extension EditHistory: Codable {
    private enum CodingKeys: String, CodingKey { case entries, index, snapshots }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decoded = try container.decode([HistoryEntry].self, forKey: .entries)
        entries = decoded.isEmpty ? EditHistory().entries : decoded
        index = min(max(try container.decode(Int.self, forKey: .index), 0), entries.count - 1)
        snapshots = (try? container.decodeIfPresent([EditSnapshot].self, forKey: .snapshots)) ?? []
    }
}

/// Interpolação cúbica monótona (Fritsch–Carlson): passa pelos pontos sem "ondular".
struct MonotoneCurve {
    private let xs: [Double]
    private let ys: [Double]
    private let slopes: [Double]

    init(_ points: [CurvePoint]) {
        let sorted = points.sorted { $0.x < $1.x }
        xs = sorted.map(\.x)
        ys = sorted.map(\.y)
        let n = sorted.count
        guard n >= 2 else {
            slopes = []
            return
        }
        var delta = [Double](repeating: 0, count: n - 1)
        for i in 0..<(n - 1) {
            delta[i] = (ys[i + 1] - ys[i]) / max(xs[i + 1] - xs[i], 1e-9)
        }
        var m = [Double](repeating: 0, count: n)
        m[0] = delta[0]
        m[n - 1] = delta[n - 2]
        if n > 2 {
            for i in 1..<(n - 1) {
                m[i] = delta[i - 1] * delta[i] <= 0 ? 0 : (delta[i - 1] + delta[i]) / 2
            }
        }
        for i in 0..<(n - 1) {
            if delta[i] == 0 {
                m[i] = 0
                m[i + 1] = 0
                continue
            }
            let a = m[i] / delta[i], b = m[i + 1] / delta[i]
            let s = a * a + b * b
            if s > 9 {
                let t = 3 / s.squareRoot()
                m[i] = t * a * delta[i]
                m[i + 1] = t * b * delta[i]
            }
        }
        slopes = m
    }

    func evaluate(_ x: Double) -> Double {
        guard xs.count >= 2, let first = xs.first, let last = xs.last else { return x }
        if x <= first { return ys[0] }
        if x >= last { return ys[ys.count - 1] }
        var k = 0
        while k < xs.count - 2, x > xs[k + 1] { k += 1 }
        let h = max(xs[k + 1] - xs[k], 1e-9)
        let t = (x - xs[k]) / h
        let t2 = t * t, t3 = t2 * t
        return (2 * t3 - 3 * t2 + 1) * ys[k] + (t3 - 2 * t2 + t) * h * slopes[k]
            + (-2 * t3 + 3 * t2) * ys[k + 1] + (t3 - t2) * h * slopes[k + 1]
    }
}

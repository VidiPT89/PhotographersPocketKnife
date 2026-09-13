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

/// A "receita" não-destrutiva de uma foto. O original nunca é alterado.
struct EditRecipe: Codable, Equatable, Sendable {
    static let linearCurve = [CurvePoint(x: 0, y: 0), CurvePoint(x: 1, y: 1)]

    // Luz
    var exposure = 0.0
    var contrast = 0.0
    var highlights = 0.0
    var shadows = 0.0
    var whites = 0.0
    var blacks = 0.0
    // Cor
    var temperature = 0.0
    var tint = 0.0
    var vibrance = 0.0
    var saturation = 0.0
    // Detalhe e efeitos
    var sharpness = 0.0
    var noiseReduction = 0.0
    var vignette = 0.0
    // Curvas e HSL
    var curveMaster = linearCurve
    var curveRed = linearCurve
    var curveGreen = linearCurve
    var curveBlue = linearCurve
    var hsl = Array(repeating: HSLAdjustment(), count: HSLBand.allCases.count)
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

    var needsToneCube: Bool {
        whites != 0 || blacks != 0 || highlights > 0
            || [curveMaster, curveRed, curveGreen, curveBlue].contains { $0 != Self.linearCurve }
            || hsl.contains { $0 != HSLAdjustment() }
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

    /// Copia os ajustes de `other` mas mantém o enquadramento desta foto (presets e sincronização).
    func applyingSettings(from other: EditRecipe) -> EditRecipe {
        var result = other
        result.crop = crop
        result.straighten = straighten
        result.quarterTurns = quarterTurns
        result.flipHorizontal = flipHorizontal
        result.perspectiveVertical = perspectiveVertical
        result.perspectiveHorizontal = perspectiveHorizontal
        return result
    }
}

struct HistoryEntry: Codable, Equatable, Sendable {
    var labelKey: String
    var recipe: EditRecipe
}

struct EditHistory: Codable, Equatable, Sendable {
    static let maxEntries = 100

    var entries = [HistoryEntry(labelKey: "history.original", recipe: .identity)]
    var index = 0

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

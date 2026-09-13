import Foundation

/// Gera uma LUT 3D com brancos/pretos, realces positivos, curvas e HSL numa única passagem.
enum ColorCube {
    static let dimension = 33

    static func data(for recipe: EditRecipe) -> Data {
        let n = dimension
        let master = MonotoneCurve(recipe.curveMaster)
        let red = MonotoneCurve(recipe.curveRed)
        let green = MonotoneCurve(recipe.curveGreen)
        let blue = MonotoneCurve(recipe.curveBlue)
        let hasHSL = recipe.hsl.contains { $0 != HSLAdjustment() }

        var cube = [Float](repeating: 0, count: n * n * n * 4)
        var offset = 0
        // Ordem exigida pelo CIColorCube: o vermelho varia mais depressa.
        for b in 0..<n {
            for g in 0..<n {
                for r in 0..<n {
                    var rgb = (
                        Double(r) / Double(n - 1),
                        Double(g) / Double(n - 1),
                        Double(b) / Double(n - 1)
                    )
                    rgb.0 = red.evaluate(master.evaluate(tone(rgb.0, recipe)))
                    rgb.1 = green.evaluate(master.evaluate(tone(rgb.1, recipe)))
                    rgb.2 = blue.evaluate(master.evaluate(tone(rgb.2, recipe)))
                    if hasHSL { rgb = applyHSL(rgb, recipe.hsl) }
                    cube[offset] = Float(clamp(rgb.0))
                    cube[offset + 1] = Float(clamp(rgb.1))
                    cube[offset + 2] = Float(clamp(rgb.2))
                    cube[offset + 3] = 1
                    offset += 4
                }
            }
        }
        return cube.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    static func tone(_ value: Double, _ recipe: EditRecipe) -> Double {
        var v = value
        v += recipe.blacks * 0.25 * pow(1 - v, 3)
        v += recipe.whites * 0.25 * pow(v, 3)
        if recipe.highlights > 0 {
            v += recipe.highlights * 0.6 * v * v * (1 - v)
        }
        return clamp(v)
    }

    static func applyHSL(_ rgb: (Double, Double, Double), _ adjustments: [HSLAdjustment]) -> (Double, Double, Double) {
        var (h, s, l) = rgbToHSL(rgb)
        guard s > 0.0001 else { return rgb }
        var hueShift = 0.0, satScale = 0.0, lumShift = 0.0
        // Interpola entre as duas bandas vizinhas: no centro de uma banda o efeito é 100% e os pesos somam sempre 1.
        let bands = HSLBand.allCases.filter { $0.rawValue < adjustments.count }
        guard !bands.isEmpty else { return rgb }
        var weights: [(band: HSLBand, weight: Double)] = []
        for (index, lower) in bands.enumerated() {
            let upper = bands[(index + 1) % bands.count]
            let upperHue = upper.hue <= lower.hue ? upper.hue + 360 : upper.hue
            let hue = h < lower.hue ? h + 360 : h
            guard hue >= lower.hue, hue < upperHue else { continue }
            let t = (hue - lower.hue) / (upperHue - lower.hue)
            weights = [(lower, 1 - t), (upper, t)]
            break
        }
        for (band, weight) in weights {
            let adjustment = adjustments[band.rawValue]
            hueShift += weight * adjustment.hue * 30
            satScale += weight * adjustment.saturation
            lumShift += weight * adjustment.luminance
        }
        h = (h + hueShift).truncatingRemainder(dividingBy: 360)
        if h < 0 { h += 360 }
        let originalSaturation = s
        s = clamp(s * (1 + satScale))
        // Luminância pesada pela saturação, para não mexer em cinzentos.
        l = clamp(l + lumShift * 0.25 * originalSaturation)
        return hslToRGB(h, s, l)
    }

    static func rgbToHSL(_ rgb: (Double, Double, Double)) -> (Double, Double, Double) {
        let (r, g, b) = rgb
        let maxV = max(r, g, b), minV = min(r, g, b)
        let l = (maxV + minV) / 2
        let d = maxV - minV
        guard d > 0 else { return (0, 0, l) }
        let s = l > 0.5 ? d / (2 - maxV - minV) : d / (maxV + minV)
        var h: Double
        if maxV == r {
            h = (g - b) / d + (g < b ? 6 : 0)
        } else if maxV == g {
            h = (b - r) / d + 2
        } else {
            h = (r - g) / d + 4
        }
        h *= 60
        return (h, s, l)
    }

    static func hslToRGB(_ h: Double, _ s: Double, _ l: Double) -> (Double, Double, Double) {
        guard s > 0 else { return (l, l, l) }
        let q = l < 0.5 ? l * (1 + s) : l + s - l * s
        let p = 2 * l - q
        func channel(_ t: Double) -> Double {
            var t = t
            if t < 0 { t += 1 }
            if t > 1 { t -= 1 }
            if t < 1 / 6 { return p + (q - p) * 6 * t }
            if t < 1 / 2 { return q }
            if t < 2 / 3 { return p + (q - p) * (2 / 3 - t) * 6 }
            return p
        }
        let hk = h / 360
        return (channel(hk + 1 / 3), channel(hk), channel(hk - 1 / 3))
    }

    private static func clamp(_ v: Double) -> Double { min(max(v, 0), 1) }
}

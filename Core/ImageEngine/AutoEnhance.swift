import CoreImage
import CoreImage.CIFilterBuiltins
import Vision

/// Edição automática: mede a foto com o próprio pipeline e escolhe valores de partida para os sliders.
/// O Vision (no Mac) dá mais peso ao que chama a atenção ao medir a exposição e deteta o horizonte.
enum AutoEnhance {
    static let analysisSide: CGFloat = 256
    /// Luminância média (sRGB) de uma foto bem exposta.
    static let targetLuminance: Float = 0.46

    private struct Stats {
        var luminance: Float = 0
        var castBlueRed: Float = 0
        var castGreen: Float = 0
        var clippedHighlights: Float = 0
        var deepShadows: Float = 0
        var spread: Float = 0
        var saturation: Float = 0
        var neutralShare: Float = 0
    }

    static func enhance(_ recipe: EditRecipe, image input: CIImage, renderer: ImageRenderer = .shared) -> EditRecipe {
        let e = input.extent
        guard !e.isInfinite, e.width >= 16, e.height >= 16 else { return recipe }
        let scale = min(analysisSide / max(e.width, e.height), 1)
        let width = max(Int(e.width * scale), 8), height = max(Int(e.height * scale), 8)
        let f = CIFilter.lanczosScaleTransform()
        f.inputImage = input.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY)).clampedToExtent()
        f.scale = Float(CGFloat(height) / e.height)
        f.aspectRatio = Float((CGFloat(width) / e.width) / (CGFloat(height) / e.height))
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        let linear = CGColorSpace(name: CGColorSpace.extendedLinearSRGB) ?? renderer.sRGB
        guard let scaled = f.outputImage,
              let floatImage = renderer.context.createCGImage(scaled, from: bounds, format: .RGBAh, colorSpace: linear),
              let visionImage = renderer.context.createCGImage(scaled, from: bounds, format: .RGBA8, colorSpace: renderer.sRGB) else { return recipe }
        let small = CIImage(cgImage: floatImage)
        let weights = saliencyWeights(visionImage, width: width, height: height)

        var probe = EditRecipe()
        func measure() -> Stats { stats(renderer.apply(probe, to: small, applyCrop: false), renderer: renderer, weights: weights, width: width, height: height) }

        // Exposição: procura binária até à luminância alvo, com a atenção a pesar mais.
        func solveExposure() -> Double {
            var low = -3.0, high = 3.0
            for _ in 0..<12 {
                probe.exposure = (low + high) / 2
                if measure().luminance < targetLuminance { low = probe.exposure } else { high = probe.exposure }
            }
            let exposure = min(max((low + high) / 2 * 0.9, -2.5), 2.5)
            return abs(exposure) < 0.08 ? 0 : (exposure * 100).rounded() / 100
        }

        // Fotos claras de propósito (neve, papel, high-key) sem nada recortado não devem ser escurecidas.
        let untouched = measure()
        func limited(_ exposure: Double) -> Double {
            exposure < 0 && untouched.clippedHighlights < 0.005 ? max(exposure, -0.3) : exposure
        }

        // 1. Exposição provisória, para medir a cor com os tons médios bem visíveis.
        probe.exposure = limited(solveExposure())

        // 2. Balanço de brancos: temperatura e tonalidade que deixam neutros os tons quase cinzentos.
        let original = measure()
        probe.temperature = bestValue(in: -0.6...0.6) { probe.temperature = $0; return abs(measure().castBlueRed) }
        probe.tint = bestValue(in: -0.6...0.6) { probe.tint = $0; return abs(measure().castGreen) }
        // Em fotos com pouco neutro (pôr do sol, palco) a cor é intencional: corrige menos.
        let strength = original.neutralShare > 0.05 ? 0.8 : 0.45
        probe.temperature = (probe.temperature * strength * 100).rounded() / 100
        probe.tint = (probe.tint * strength * 100).rounded() / 100

        // 3. Exposição final, já com a cor corrigida.
        probe.exposure = limited(solveExposure())

        // 4. Altas luzes, sombras, contraste e vibração a partir do resultado já exposto.
        let exposed = measure()
        if exposed.clippedHighlights > 0.004 {
            probe.highlights = -min(0.8, 0.2 + Double(exposed.clippedHighlights) * 20)
        }
        if exposed.deepShadows > 0.12 {
            probe.shadows = min(0.6, Double(exposed.deepShadows - 0.12) * 2 + 0.15)
        }
        if exposed.spread < 0.16 {
            probe.contrast = min(0.35, Double(0.16 - exposed.spread) * 2.5)
        } else if exposed.spread > 0.3 {
            probe.contrast = -min(0.25, Double(exposed.spread - 0.3) * 2)
        }
        probe.vibrance = exposed.saturation < 0.22 ? min(0.35, Double(0.22 - exposed.saturation) * 2 + 0.1) : 0.1

        // O contraste desloca a luminância média: a exposição final já conta com ele.
        probe.exposure = limited(solveExposure())

        var result = recipe
        result.exposure = probe.exposure
        result.temperature = probe.temperature
        result.tint = probe.tint
        result.highlights = (probe.highlights * 100).rounded() / 100
        result.shadows = (probe.shadows * 100).rounded() / 100
        result.contrast = (probe.contrast * 100).rounded() / 100
        result.vibrance = (probe.vibrance * 100).rounded() / 100
        result.whites = 0
        result.blacks = 0

        // 5. Horizonte: só com a foto na orientação original e sem endireitar à mão.
        if recipe.straighten == 0, recipe.quarterTurns % 4 == 0, !recipe.flipHorizontal, let angle = horizonAngle(visionImage) {
            // O Vision dá o ângulo da linha; endireitar é rodar no sentido contrário.
            result.straighten = (-angle * 10).rounded() / 10
        }
        return result
    }

    /// Ângulo do horizonte em graus, se estiver ligeiramente torto (0,3° a 10°).
    static func horizonAngle(_ image: CGImage) -> Double? {
        let request = VNDetectHorizonRequest()
        guard (try? VNImageRequestHandler(cgImage: image).perform([request])) != nil,
              let angle = request.results?.first?.angle else { return nil }
        let degrees = Double(angle) * 180 / .pi
        return abs(degrees) >= 0.3 && abs(degrees) <= 10 ? degrees : nil
    }

    /// Valor com menor custo numa grelha grossa, refinada uma vez à volta do melhor.
    private static func bestValue(in range: ClosedRange<Double>, cost: (Double) -> Float) -> Double {
        var best = 0.0
        var bestCost = cost(0)
        for value in stride(from: range.lowerBound, through: range.upperBound, by: 0.125) {
            let c = cost(value)
            if c < bestCost { best = value; bestCost = c }
        }
        for value in stride(from: best - 0.1, through: best + 0.1, by: 0.025) where range.contains(value) {
            let c = cost(value)
            if c < bestCost { best = value; bestCost = c }
        }
        return best
    }

    /// Peso de cada píxel: 1 por defeito, mais nas zonas que o Vision considera que chamam a atenção.
    private static func saliencyWeights(_ image: CGImage, width: Int, height: Int) -> [Float] {
        var weights = [Float](repeating: 1, count: width * height)
        let request = VNGenerateAttentionBasedSaliencyImageRequest()
        guard (try? VNImageRequestHandler(cgImage: image).perform([request])) != nil,
              let buffer = request.results?.first?.pixelBuffer else { return weights }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_OneComponent32Float,
              let base = CVPixelBufferGetBaseAddress(buffer) else { return weights }
        let bw = CVPixelBufferGetWidth(buffer), bh = CVPixelBufferGetHeight(buffer)
        let stride = CVPixelBufferGetBytesPerRow(buffer) / MemoryLayout<Float>.size
        let values = base.assumingMemoryBound(to: Float.self)
        var maximum: Float = 0
        for y in 0..<bh { for x in 0..<bw { maximum = max(maximum, values[y * stride + x]) } }
        guard maximum > 0 else { return weights }
        for y in 0..<height {
            for x in 0..<width {
                let v = values[(y * bh / height) * stride + x * bw / width] / maximum
                weights[y * width + x] = 0.35 + 0.65 * v
            }
        }
        return weights
    }

    private static func stats(_ image: CIImage, renderer: ImageRenderer, weights: [Float], width: Int, height: Int) -> Stats {
        var rgba = [Float](repeating: 0, count: width * height * 4)
        renderer.context.render(image, toBitmap: &rgba, rowBytes: width * 16, bounds: CGRect(x: 0, y: 0, width: width, height: height),
                                format: .RGBAf, colorSpace: renderer.sRGB)
        var weightSum: Float = 0, luminanceSum: Float = 0, squareSum: Float = 0
        // Somas de cor para o balanço de brancos: só píxeis nem pretos nem recortados, e à parte os quase neutros.
        var neutral: (Float, Float, Float) = (0, 0, 0), neutralCount: Float = 0
        var usable: (Float, Float, Float) = (0, 0, 0), usableCount: Float = 0
        var clipped: Float = 0, deep: Float = 0, saturation: Float = 0
        let count = Float(width * height)
        for i in 0..<(width * height) {
            let r = min(max(rgba[i * 4], 0), 1.2), g = min(max(rgba[i * 4 + 1], 0), 1.2), b = min(max(rgba[i * 4 + 2], 0), 1.2)
            let l = 0.2126 * r + 0.7152 * g + 0.0722 * b
            let w = weights[i]
            weightSum += w
            luminanceSum += w * l
            squareSum += w * l * l
            let high = max(r, g, b), low = min(r, g, b)
            if high > 0.03, high < 0.98 {
                usable.0 += r; usable.1 += g; usable.2 += b; usableCount += 1
                if (high - low) / high < 0.3 {
                    neutral.0 += r; neutral.1 += g; neutral.2 += b; neutralCount += 1
                }
            }
            if high > 0.985 { clipped += 1 }
            if l < 0.06 { deep += 1 }
            if high > 0.02 { saturation += (high - low) / high }
        }
        var stats = Stats()
        stats.luminance = luminanceSum / max(weightSum, 1)
        stats.spread = (max(squareSum / max(weightSum, 1) - stats.luminance * stats.luminance, 0)).squareRoot()
        stats.clippedHighlights = clipped / count
        stats.deepShadows = deep / count
        stats.saturation = saturation / count
        stats.neutralShare = neutralCount / count
        // Diferenças relativas ao brilho: o resultado não depende da exposição.
        let reference = neutralCount > max(count * 0.05, 1) ? neutral : usable
        let total = max(reference.0 + reference.1 + reference.2, 1e-4)
        stats.castBlueRed = usableCount > 0 ? 3 * (reference.2 - reference.0) / total : 0
        stats.castGreen = usableCount > 0 ? 3 * (reference.1 - (reference.0 + reference.2) / 2) / total : 0
        return stats
    }
}

extension ImageRenderer {
    func autoEnhanced(url: URL, recipe: EditRecipe, maxPixel: Int) -> EditRecipe? {
        guard let base = previewBase(url: url, maxPixel: maxPixel, lensCorrection: recipe.lensCorrection) else { return nil }
        return AutoEnhance.enhance(recipe, image: CIImage(cgImage: base), renderer: self)
    }
}

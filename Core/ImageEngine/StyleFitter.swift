import CoreImage
import CoreImage.CIFilterBuiltins

/// Descobre que ajustes transformam o original na versão final entregue (editada noutro programa),
/// para o estilo pessoal aprender com trabalho antigo sem ser preciso reeditar nada.
enum StyleFitter {
    static let side = 128

    static func fit(original: CIImage, final: CIImage, renderer: ImageRenderer = .shared) -> EditRecipe? {
        let a = original.extent, b = final.extent
        guard !a.isInfinite, !b.isInfinite, a.width > 0, a.height > 0, b.width > 0, b.height > 0 else { return nil }
        // Com recortes diferentes, a comparação píxel a píxel não faz sentido.
        guard abs(a.width / a.height - b.width / b.height) < 0.03 else { return nil }
        let width = side, height = max(Int((CGFloat(side) * a.height / a.width).rounded()), 8)
        let linear = CGColorSpace(name: CGColorSpace.extendedLinearSRGB) ?? renderer.sRGB
        guard let sourceImage = scaled(original, width: width, height: height)
                .flatMap({ renderer.context.createCGImage($0, from: CGRect(x: 0, y: 0, width: width, height: height), format: .RGBAh, colorSpace: linear) }),
              let finalImage = scaled(final, width: width, height: height) else { return nil }
        let source = CIImage(cgImage: sourceImage)
        let target = pixels(finalImage, width: width, height: height, renderer: renderer)

        func error(_ recipe: EditRecipe) -> Double {
            let rendered = pixels(renderer.apply(recipe, to: source, applyCrop: false), width: width, height: height, renderer: renderer)
            var total = 0.0
            for i in 0..<rendered.count where i % 4 != 3 {
                let d = Double(rendered[i] - target[i])
                total += d * d
            }
            return total / Double(width * height * 3)
        }

        var recipe = EditRecipe()
        var best = error(recipe)
        let parameters: [(WritableKeyPath<EditRecipe, Double>, Double, ClosedRange<Double>)] = [
            (\.exposure, 0.5, -3...3), (\.temperature, 0.25, -1...1), (\.tint, 0.25, -1...1), (\.contrast, 0.25, -1...1),
            (\.highlights, 0.25, -1...1), (\.shadows, 0.25, -1...1), (\.saturation, 0.25, -1...1), (\.vibrance, 0.25, -1...1),
        ]
        var scale = 1.0
        for _ in 0..<5 {
            for (key, step, range) in parameters {
                for direction in [1.0, -1.0] {
                    while true {
                        var candidate = recipe
                        candidate[keyPath: key] = min(max(recipe[keyPath: key] + direction * step * scale, range.lowerBound), range.upperBound)
                        guard candidate[keyPath: key] != recipe[keyPath: key] else { break }
                        let value = error(candidate)
                        guard value < best - 1e-7 else { break }
                        recipe = candidate
                        best = value
                    }
                }
            }
            scale /= 2
        }

        // Curva de tons: aproxima a distribuição de luminância da versão final.
        let rendered = pixels(renderer.apply(recipe, to: source, applyCrop: false), width: width, height: height, renderer: renderer)
        let from = luminances(rendered), to = luminances(target)
        var points = [CurvePoint(x: 0, y: 0)]
        for quantile in [0.1, 0.3, 0.5, 0.7, 0.9] {
            let x = from[Int(Double(from.count - 1) * quantile)], y = to[Int(Double(to.count - 1) * quantile)]
            if let last = points.last, x > last.x + 0.02, x < 0.98 { points.append(CurvePoint(x: x, y: min(max(y, 0), 1))) }
        }
        points.append(CurvePoint(x: 1, y: 1))
        if points.count > 2 {
            var curved = recipe
            curved.setCurve(points, for: .master)
            if error(curved) < best { recipe = curved }
        }
        return recipe
    }

    private static func scaled(_ image: CIImage, width: Int, height: Int) -> CIImage? {
        let e = image.extent
        let f = CIFilter.lanczosScaleTransform()
        f.inputImage = image.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY)).clampedToExtent()
        f.scale = Float(CGFloat(height) / e.height)
        f.aspectRatio = Float((CGFloat(width) / e.width) / (CGFloat(height) / e.height))
        return f.outputImage?.cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
    }

    /// RGBA em sRGB, cada valor limitado a 0…1 (como aparece no ecrã).
    private static func pixels(_ image: CIImage, width: Int, height: Int, renderer: ImageRenderer) -> [Float] {
        var rgba = [Float](repeating: 0, count: width * height * 4)
        renderer.context.render(image, toBitmap: &rgba, rowBytes: width * 16, bounds: CGRect(x: 0, y: 0, width: width, height: height),
                                format: .RGBAf, colorSpace: renderer.sRGB)
        return rgba.map { min(max($0, 0), 1) }
    }

    private static func luminances(_ rgba: [Float]) -> [Double] {
        var values: [Double] = []
        values.reserveCapacity(rgba.count / 4)
        for i in stride(from: 0, to: rgba.count - 3, by: 4) {
            let red = Double(rgba[i]) * 0.2126
            let green = Double(rgba[i + 1]) * 0.7152
            let blue = Double(rgba[i + 2]) * 0.0722
            values.append(red + green + blue)
        }
        return values.sorted()
    }
}

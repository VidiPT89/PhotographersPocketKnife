import CoreImage
import CoreImage.CIFilterBuiltins

/// Remove objetos: junta as zonas pintadas e os objetos clicados numa só máscara e preenche-a com o `Inpainter`.
/// As correspondências são calculadas sobre a foto sem ajustes e ficam em cache: mexer nos sliders só volta a copiar píxeis.
final class ObjectRemover: @unchecked Sendable {
    static let shared = ObjectRemover()
    /// Lado maior da região onde corre o preenchimento: equilíbrio entre qualidade e tempo de resposta.
    static let workingSide: CGFloat = 512

    private struct Solution {
        let region: CGRect
        let width: Int
        let height: Int
        let hole: [Bool]
        let field: Inpainter.Field
        let blendMask: CIImage
    }

    private let lock = NSLock()
    private var cache: [String: Solution] = [:]
    private var order: [String] = []

    func apply(_ removals: [Removal], to image: CIImage, reference: CIImage) -> CIImage {
        let e = image.extent
        guard !removals.isEmpty, !e.isInfinite, e.width >= 16, e.height >= 16,
              let solution = solution(for: removals, reference: reference),
              let current = Self.pixels(of: image, region: solution.region, width: solution.width, height: solution.height),
              let patch = Self.image(from: Inpainter.fill(current, hole: solution.hole, field: solution.field), region: solution.region)
        else { return image }
        return patch
            .applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: image, kCIInputMaskImageKey: solution.blendMask])
            .cropped(to: e)
    }

    private func solution(for removals: [Removal], reference: CIImage) -> Solution? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let key = SmartSelection.fingerprint(reference) + "|" + String(decoding: (try? encoder.encode(removals)) ?? Data(), as: UTF8.self)
        if let hit = lock.withLock({ cache[key] }) { return hit }

        let e = reference.extent
        guard let holeMask = Self.holeMask(for: removals, reference: reference),
              let bounds = Self.boundingBox(of: holeMask, extent: e) else { return nil }
        // Margem suficiente para haver textura à volta, sem obrigar a reduzir demasiado a região.
        let margin = max(min(bounds.width, bounds.height) * 0.5, min(e.width, e.height) * 0.04)
        let region = bounds.insetBy(dx: -margin, dy: -margin).intersection(e).integral
        let scale = min(Self.workingSide / max(region.width, region.height), 1)
        let width = max(Int(region.width * scale), 8), height = max(Int(region.height * scale), 8)
        guard let referencePixels = Self.pixels(of: reference, region: region, width: width, height: height),
              let maskPixels = Self.pixels(of: holeMask, region: region, width: width, height: height) else { return nil }

        let rawHole = (0..<(width * height)).map { maskPixels.pixels[$0 * 3] > 0.05 }
        let hole = Self.dilate(rawHole, width: width, height: height, radius: 2)
        let field = Inpainter.solve(referencePixels, hole: hole)
        let pixelSize = Double(region.width) / Double(width)
        let blendMask = holeMask.clampedToExtent().applyingGaussianBlur(sigma: max(pixelSize, 1) * 1.2).cropped(to: e)

        let solution = Solution(region: region, width: width, height: height, hole: hole, field: field, blendMask: blendMask)
        lock.withLock {
            cache[key] = solution
            order.append(key)
            if order.count > 6 { cache[order.removeFirst()] = nil }
        }
        return solution
    }

    private static func holeMask(for removals: [Removal], reference: CIImage) -> CIImage? {
        let e = reference.extent
        var combined: CIImage?
        func add(_ mask: CIImage) {
            combined = combined.map { mask.applyingFilter("CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey: $0]) } ?? mask
        }
        if let raster = ImageRenderer.rasterizeStrokes(removals.flatMap(\.strokes), extent: e) {
            add(raster.image)
        }
        for point in removals.compactMap(\.objectPoint) {
            guard let object = SmartSelection.shared.objectMask(for: reference, at: point) else { continue }
            // Alarga um pouco para levar também os contornos e a sombra colada ao objeto.
            let grow = min(max(e.width, e.height) * 0.006, 40)
            add(object.clampedToExtent().applyingFilter("CIMorphologyMaximum", parameters: [kCIInputRadiusKey: grow]).cropped(to: e))
        }
        return combined?.cropped(to: e)
    }

    private static func boundingBox(of mask: CIImage, extent e: CGRect) -> CGRect? {
        let scale = min(256 / max(e.width, e.height), 1)
        let width = max(Int(e.width * scale), 1), height = max(Int(e.height * scale), 1)
        guard let small = pixels(of: mask, region: e, width: width, height: height) else { return nil }
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            for x in 0..<width where small.pixels[(y * width + x) * 3] > 0.05 {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= 0 else { return nil }
        let sx = e.width / CGFloat(width), sy = e.height / CGFloat(height)
        // A linha 0 do bitmap é o topo da imagem; em Core Image o y cresce para cima.
        return CGRect(x: e.minX + CGFloat(minX) * sx, y: e.maxY - CGFloat(maxY + 1) * sy,
                      width: CGFloat(maxX - minX + 1) * sx, height: CGFloat(maxY - minY + 1) * sy)
    }

    private static func dilate(_ mask: [Bool], width: Int, height: Int, radius: Int) -> [Bool] {
        var out = mask
        for y in 0..<height {
            for x in 0..<width where mask[y * width + x] {
                for dy in -radius...radius {
                    for dx in -radius...radius {
                        let nx = x + dx, ny = y + dy
                        if nx >= 0, nx < width, ny >= 0, ny < height { out[ny * width + nx] = true }
                    }
                }
            }
        }
        return out
    }

    /// Região da imagem reduzida para `width`×`height`, em valores do espaço de trabalho (sem conversão de cor).
    static func pixels(of image: CIImage, region: CGRect, width: Int, height: Int) -> Inpainter.Image? {
        guard width > 0, height > 0, region.width > 0, region.height > 0 else { return nil }
        let local = image.cropped(to: region)
            .transformed(by: CGAffineTransform(translationX: -region.minX, y: -region.minY))
            .clampedToExtent()
        let f = CIFilter.lanczosScaleTransform()
        f.inputImage = local
        f.scale = Float(CGFloat(height) / region.height)
        f.aspectRatio = Float((CGFloat(width) / region.width) / (CGFloat(height) / region.height))
        guard let scaled = f.outputImage else { return nil }
        var rgba = [Float](repeating: 0, count: width * height * 4)
        ImageRenderer.shared.context.render(scaled, toBitmap: &rgba, rowBytes: width * 16,
                                            bounds: CGRect(x: 0, y: 0, width: width, height: height), format: .RGBAf, colorSpace: nil)
        var rgb = [Float](repeating: 0, count: width * height * 3)
        for i in 0..<(width * height) {
            rgb[i * 3] = rgba[i * 4]; rgb[i * 3 + 1] = rgba[i * 4 + 1]; rgb[i * 3 + 2] = rgba[i * 4 + 2]
        }
        return Inpainter.Image(width: width, height: height, pixels: rgb)
    }

    static func image(from buffer: Inpainter.Image, region: CGRect) -> CIImage? {
        let w = buffer.width, h = buffer.height
        guard w > 0, h > 0, buffer.pixels.count == w * h * 3 else { return nil }
        var rgba = [Float](repeating: 1, count: w * h * 4)
        for i in 0..<(w * h) {
            rgba[i * 4] = buffer.pixels[i * 3]; rgba[i * 4 + 1] = buffer.pixels[i * 3 + 1]; rgba[i * 4 + 2] = buffer.pixels[i * 3 + 2]
        }
        let data = rgba.withUnsafeBufferPointer { Data(buffer: $0) }
        return CIImage(bitmapData: data, bytesPerRow: w * 16, size: CGSize(width: w, height: h), format: .RGBAf, colorSpace: nil)
            .transformed(by: CGAffineTransform(scaleX: region.width / CGFloat(w), y: region.height / CGFloat(h)))
            .transformed(by: CGAffineTransform(translationX: region.minX, y: region.minY))
    }
}

extension ImageRenderer {
    /// Confirma se há um objeto no ponto antes de o acrescentar às remoções (e deixa a análise em cache).
    func hasObject(url: URL, recipe: EditRecipe, at point: CurvePoint, maxPixel: Int) -> Bool {
        guard let base = previewBase(url: url, maxPixel: maxPixel, lensCorrection: recipe.lensCorrection) else { return false }
        let reference = referenceImage(recipe, input: CIImage(cgImage: base), applyCrop: true)
        return SmartSelection.shared.objectMask(for: reference, at: point) != nil
    }
}

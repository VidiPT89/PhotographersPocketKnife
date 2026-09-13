import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO
import UniformTypeIdentifiers

enum ExportFormat: String, CaseIterable, Identifiable, Codable, Sendable {
    case jpeg, tiff, png, heic, dng
    var id: String { rawValue }

    var utType: UTType {
        switch self {
        case .jpeg: .jpeg
        case .tiff: .tiff
        case .png: .png
        case .heic: .heic
        case .dng: UTType("com.adobe.raw-image") ?? .tiff
        }
    }

    var fileExtension: String { self == .jpeg ? "jpg" : rawValue }
    var displayName: String { rawValue.uppercased() }
    var supportsQuality: Bool { self == .jpeg || self == .heic }
    var supports16Bit: Bool { self == .tiff || self == .png }
}

struct ExportSettings: Codable, Equatable, Sendable {
    var format: ExportFormat = .jpeg
    var quality = 0.9
    var resize = false
    var longEdge = 2048
    var suffix = ""
    var includeMetadata = true
    var sixteenBit = false
}

enum ExportError: LocalizedError {
    case unreadable(String)
    case cannotWrite(String)

    var errorDescription: String? {
        switch self {
        case .unreadable(let name): "Cannot read \(name)"
        case .cannotWrite(let name): "Cannot export \(name)"
        }
    }
}

/// Pipeline Core Image (acelerado por Metal) partilhado pela edição, thumbnails editadas e exportação.
final class ImageRenderer: @unchecked Sendable {
    static let shared = ImageRenderer()

    let context = CIContext(options: [.cacheIntermediates: true])
    private let lock = NSLock()
    private var baseCache: [String: CGImage] = [:]
    private var baseOrder: [String] = []
    private var cubeCache: (recipe: EditRecipe, data: Data)?
    private let sRGB = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    private let extendedLinear = CGColorSpace(name: CGColorSpace.extendedLinearSRGB) ?? CGColorSpaceCreateDeviceRGB()

    // MARK: Preview

    func renderPreview(url: URL, recipe: EditRecipe, maxPixel: Int, applyCrop: Bool = true) -> SendableImage? {
        guard let base = previewBase(url: url, maxPixel: maxPixel, lensCorrection: recipe.lensCorrection) else { return nil }
        let output = apply(recipe, to: CIImage(cgImage: base), applyCrop: applyCrop)
        guard let image = context.createCGImage(output, from: output.extent.integral, format: .RGBA8, colorSpace: sRGB) else { return nil }
        return SendableImage(cgImage: image)
    }

    /// Imagem base já descodificada e reduzida, em cache, para os sliders responderem depressa.
    private func previewBase(url: URL, maxPixel: Int, lensCorrection: Bool) -> CGImage? {
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)?.timeIntervalSince1970 ?? 0
        let key = "\(url.path)|\(maxPixel)|\(lensCorrection)|\(modified)"
        lock.lock()
        if let hit = baseCache[key] {
            lock.unlock()
            return hit
        }
        lock.unlock()

        let image: CGImage?
        if PhotoImporter.isRaw(url), let raw = decodeRAW(url, maxPixel: maxPixel, lensCorrection: lensCorrection) {
            // Float de 16 bits em espaço linear: mantém a margem do RAW para recuperar exposição.
            image = context.createCGImage(raw, from: raw.extent.integral, format: .RGBAh, colorSpace: extendedLinear)
        } else {
            image = ThumbnailCache.generate(url: url, maxPixel: maxPixel)
        }
        guard let image else { return nil }

        lock.lock()
        baseCache[key] = image
        baseOrder.append(key)
        if baseOrder.count > 6 {
            baseCache[baseOrder.removeFirst()] = nil
        }
        lock.unlock()
        return image
    }

    func decodeRAW(_ url: URL, maxPixel: Int?, lensCorrection: Bool) -> CIImage? {
        guard let raw = CIRAWFilter(imageURL: url) else { return nil }
        if raw.isLensCorrectionSupported {
            raw.isLensCorrectionEnabled = lensCorrection
        }
        if let maxPixel {
            let size = raw.nativeSize
            let longest = max(size.width, size.height)
            if longest > CGFloat(maxPixel) {
                raw.scaleFactor = Float(CGFloat(maxPixel) / longest)
            }
        }
        return raw.outputImage
    }

    // MARK: Pipeline

    func apply(_ r: EditRecipe, to input: CIImage, applyCrop: Bool = true) -> CIImage {
        var image = input
        // Raios dos filtros proporcionais ao tamanho: a preview (≈2000 px) e a exportação dão o mesmo aspeto.
        let scale = max(max(input.extent.width, input.extent.height) / 2000, 0.25)

        if r.chromaticAberration != 0 {
            image = correctChromaticAberration(image, amount: r.chromaticAberration)
        }

        if r.exposure != 0 {
            let f = CIFilter.exposureAdjust()
            f.inputImage = image
            f.ev = Float(r.exposure)
            image = f.outputImage ?? image
        }
        if r.temperature != 0 || r.tint != 0 {
            let f = CIFilter.temperatureAndTint()
            f.inputImage = image
            f.neutral = CIVector(x: 6500 + r.temperature * 3000, y: r.tint * 100)
            f.targetNeutral = CIVector(x: 6500, y: 0)
            image = f.outputImage ?? image
        }
        if r.shadows != 0 || r.highlights < 0 {
            let f = CIFilter.highlightShadowAdjust()
            f.inputImage = image
            f.shadowAmount = Float(r.shadows)
            f.highlightAmount = Float(1 + min(0, r.highlights))
            f.radius = 8
            image = f.outputImage ?? image
        }
        if r.contrast != 0 || r.saturation != 0 {
            let f = CIFilter.colorControls()
            f.inputImage = image
            f.contrast = Float(1 + r.contrast * 0.5)
            f.saturation = Float(1 + r.saturation)
            f.brightness = 0
            image = f.outputImage ?? image
        }
        if r.vibrance != 0 {
            let f = CIFilter.vibrance()
            f.inputImage = image
            f.amount = Float(r.vibrance)
            image = f.outputImage ?? image
        }
        if r.clarity != 0 {
            image = localContrast(image, amount: r.clarity * 0.8, radius: 22 * scale)
        }
        if r.texture != 0 {
            image = localContrast(image, amount: r.texture * 0.9, radius: 3 * scale)
        }
        if r.needsToneCube {
            let f = CIFilter.colorCubeWithColorSpace()
            f.inputImage = image
            f.cubeDimension = Float(ColorCube.dimension)
            f.cubeData = cube(for: r)
            f.colorSpace = sRGB
            image = f.outputImage ?? image
        }
        if r.noiseReduction > 0 {
            let f = CIFilter.noiseReduction()
            f.inputImage = image
            f.noiseLevel = Float(r.noiseReduction * 0.06)
            f.sharpness = 0.4
            image = f.outputImage ?? image
        }
        if r.colorNoiseReduction > 0 {
            // Mantém a luminância original e usa a cor de uma versão desfocada: tira o ruído de cor sem perder detalhe.
            let e = image.extent
            let blurred = image.clampedToExtent().applyingGaussianBlur(sigma: r.colorNoiseReduction * 6 * scale).cropped(to: e)
            image = image.applyingFilter("CILuminosityBlendMode", parameters: [kCIInputBackgroundImageKey: blurred]).cropped(to: e)
        }
        if r.sharpness > 0 {
            let f = CIFilter.sharpenLuminance()
            f.inputImage = image
            f.sharpness = Float(r.sharpness * 1.2)
            f.radius = Float(max(r.sharpenRadius * scale, 0.5))
            let sharpened = (f.outputImage ?? image).cropped(to: image.extent)
            image = r.sharpenMasking > 0 ? blend(sharpened, over: image, mask: edgeMask(image, masking: r.sharpenMasking)) : sharpened
        }

        image = applyGeometry(r, to: image)

        if applyCrop, !r.crop.isFull {
            let e = image.extent
            let rect = CGRect(
                x: e.minX + r.crop.x * e.width,
                y: e.minY + (1 - r.crop.y - r.crop.height) * e.height,
                width: r.crop.width * e.width,
                height: r.crop.height * e.height
            ).integral
            image = image.cropped(to: rect)
        }
        for mask in r.masks where !mask.isNeutral {
            image = applyMask(mask, to: image, scale: scale)
        }
        if r.vignette != 0 {
            let e = image.extent
            let f = CIFilter.vignetteEffect()
            f.inputImage = image
            f.center = CGPoint(x: e.midX, y: e.midY)
            f.radius = Float(hypot(e.width, e.height) * 0.35)
            f.intensity = Float(-r.vignette)
            f.falloff = 0.6
            image = (f.outputImage ?? image).cropped(to: e)
        }
        if r.grain > 0 {
            image = addGrain(image, amount: r.grain, size: r.grainSize, scale: scale)
        }
        return image
    }

    // MARK: Filtros compostos

    /// Contraste local (clareza/textura). Valores negativos suavizam misturando uma versão desfocada.
    private func localContrast(_ image: CIImage, amount: Double, radius: CGFloat) -> CIImage {
        let e = image.extent
        if amount > 0 {
            let f = CIFilter.unsharpMask()
            f.inputImage = image.clampedToExtent()
            f.radius = Float(radius)
            f.intensity = Float(amount)
            return (f.outputImage ?? image).cropped(to: e)
        }
        let blurred = image.clampedToExtent().applyingGaussianBlur(sigma: Double(radius) * 0.5).cropped(to: e)
        return mix(image, blurred, amount: -amount)
    }

    /// Mistura `top` por cima de `base` com a opacidade indicada.
    private func mix(_ base: CIImage, _ top: CIImage, amount: Double) -> CIImage {
        let faded = top.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(min(max(amount, 0), 1)))])
        return faded.composited(over: base).cropped(to: base.extent)
    }

    private func blend(_ top: CIImage, over base: CIImage, mask: CIImage) -> CIImage {
        top.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: base, kCIInputMaskImageKey: mask]).cropped(to: base.extent)
    }

    /// Máscara de contornos para a nitidez: com `masking` alto só as arestas fortes são afiadas.
    private func edgeMask(_ image: CIImage, masking: Double) -> CIImage {
        let edges = image.applyingFilter("CIEdges", parameters: [kCIInputIntensityKey: 6]).applyingFilter("CIMaximumComponent")
        let f = CIFilter.colorControls()
        f.inputImage = edges
        f.contrast = Float(1 + masking * 3)
        f.brightness = Float(0.2 - masking * 0.5)
        f.saturation = 0
        return (f.outputImage ?? edges).cropped(to: image.extent)
    }

    /// Aberração cromática lateral: aproxima/afasta os canais vermelho e azul do centro.
    private func correctChromaticAberration(_ image: CIImage, amount: Double) -> CIImage {
        let e = image.extent
        let shift = CGFloat(amount) * 0.003
        func channel(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, scale: CGFloat) -> CIImage {
            let isolated = image.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: r, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: g, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: b, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            ])
            let transform = CGAffineTransform(translationX: e.midX, y: e.midY).scaledBy(x: scale, y: scale).translatedBy(x: -e.midX, y: -e.midY)
            return isolated.clampedToExtent().transformed(by: transform).cropped(to: e)
        }
        let red = channel(1, 0, 0, scale: 1 - shift)
        let green = channel(0, 1, 0, scale: 1)
        let blue = channel(0, 0, 1, scale: 1 + shift)
        return red
            .applyingFilter("CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey: green])
            .applyingFilter("CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey: blue])
            .cropped(to: e)
    }

    /// Grão monocromático em soft light, com tamanho proporcional à imagem.
    private func addGrain(_ image: CIImage, amount: Double, size: Double, scale: CGFloat) -> CIImage {
        let e = image.extent
        guard let noise = CIFilter.randomGenerator().outputImage else { return image }
        let strength = CGFloat(min(max(amount, 0), 1) * 0.55)
        let luma = CIVector(x: 0.3 * strength, y: 0.59 * strength, z: 0.11 * strength, w: 0)
        let neutral = 0.5 * (1 - strength)
        let grainScale = CGFloat(0.6 + size * 2.4) * scale
        let grain = noise
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": luma, "inputGVector": luma, "inputBVector": luma,
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
                "inputBiasVector": CIVector(x: neutral, y: neutral, z: neutral, w: 0),
            ])
            .transformed(by: CGAffineTransform(scaleX: grainScale, y: grainScale))
            .cropped(to: e)
        return grain.applyingFilter("CISoftLightBlendMode", parameters: [kCIInputBackgroundImageKey: image]).cropped(to: e)
    }

    // MARK: Máscaras locais

    func applyMask(_ mask: LocalMask, to image: CIImage, scale: CGFloat) -> CIImage {
        let e = image.extent
        var adjusted = image
        if mask.exposure != 0 {
            let f = CIFilter.exposureAdjust()
            f.inputImage = adjusted
            f.ev = Float(mask.exposure)
            adjusted = f.outputImage ?? adjusted
        }
        if mask.temperature != 0 {
            let f = CIFilter.temperatureAndTint()
            f.inputImage = adjusted
            f.neutral = CIVector(x: 6500 + mask.temperature * 3000, y: 0)
            f.targetNeutral = CIVector(x: 6500, y: 0)
            adjusted = f.outputImage ?? adjusted
        }
        if mask.contrast != 0 || mask.saturation != 0 {
            let f = CIFilter.colorControls()
            f.inputImage = adjusted
            f.contrast = Float(1 + mask.contrast * 0.5)
            f.saturation = Float(1 + mask.saturation)
            f.brightness = 0
            adjusted = f.outputImage ?? adjusted
        }
        if mask.clarity != 0 {
            adjusted = localContrast(adjusted, amount: mask.clarity * 0.8, radius: 22 * scale)
        }
        return blend(adjusted.cropped(to: e), over: image, mask: maskImage(mask, extent: e))
    }

    func maskImage(_ mask: LocalMask, extent e: CGRect) -> CIImage {
        var gradient: CIImage
        switch mask.kind {
        case .radial:
            let rx = max(CGFloat(mask.radiusX) * e.width, 1)
            let ry = max(CGFloat(mask.radiusY) * e.height, 1)
            let f = CIFilter.radialGradient()
            f.center = .zero
            f.radius0 = Float(rx * CGFloat(1 - mask.feather))
            f.radius1 = Float(rx)
            f.color0 = CIColor(red: 1, green: 1, blue: 1)
            f.color1 = CIColor(red: 0, green: 0, blue: 0)
            let center = CGPoint(x: e.minX + CGFloat(mask.centerX) * e.width, y: e.minY + CGFloat(1 - mask.centerY) * e.height)
            gradient = (f.outputImage ?? CIImage.empty())
                .transformed(by: CGAffineTransform(scaleX: 1, y: ry / rx).concatenating(CGAffineTransform(translationX: center.x, y: center.y)))
        case .linear:
            let f = CIFilter.linearGradient()
            f.point0 = CGPoint(x: e.minX + CGFloat(mask.startX) * e.width, y: e.minY + CGFloat(1 - mask.startY) * e.height)
            f.point1 = CGPoint(x: e.minX + CGFloat(mask.endX) * e.width, y: e.minY + CGFloat(1 - mask.endY) * e.height)
            f.color0 = CIColor(red: 1, green: 1, blue: 1)
            f.color1 = CIColor(red: 0, green: 0, blue: 0)
            gradient = f.outputImage ?? CIImage.empty()
        }
        if mask.invert {
            gradient = gradient.applyingFilter("CIColorInvert")
        }
        return gradient.cropped(to: e)
    }

    func applyGeometry(_ r: EditRecipe, to input: CIImage) -> CIImage {
        var image = input
        if r.flipHorizontal {
            image = image.oriented(.upMirrored)
        }
        let turns = ((r.quarterTurns % 4) + 4) % 4
        if turns != 0 {
            let orientations: [CGImagePropertyOrientation] = [.up, .right, .down, .left]
            image = image.oriented(orientations[turns])
        }
        if r.perspectiveVertical != 0 || r.perspectiveHorizontal != 0 {
            let e = image.extent
            let v = CGFloat(r.perspectiveVertical) * 0.25 * e.width
            let h = CGFloat(r.perspectiveHorizontal) * 0.25 * e.height
            let f = CIFilter.perspectiveTransform()
            f.inputImage = image
            f.topLeft = CGPoint(x: e.minX - v, y: e.maxY)
            f.topRight = CGPoint(x: e.maxX + v, y: e.maxY + h)
            f.bottomLeft = CGPoint(x: e.minX, y: e.minY)
            f.bottomRight = CGPoint(x: e.maxX, y: e.minY - h)
            image = (f.outputImage ?? image).cropped(to: e)
        }
        if r.straighten != 0 {
            let e = image.extent
            let angle = r.straighten * .pi / 180
            // Amplia o suficiente para não aparecerem cantos vazios.
            let k = abs(cos(angle)) + abs(sin(angle)) * max(e.width / e.height, e.height / e.width)
            let transform = CGAffineTransform(translationX: e.midX, y: e.midY)
                .rotated(by: -angle)
                .scaledBy(x: k, y: k)
                .translatedBy(x: -e.midX, y: -e.midY)
            image = image.clampedToExtent().transformed(by: transform).cropped(to: e)
        }
        return image
    }

    private func cube(for recipe: EditRecipe) -> Data {
        lock.lock()
        defer { lock.unlock() }
        let toneOnly = recipe.cubeRecipe
        if let cached = cubeCache, cached.recipe == toneOnly { return cached.data }
        let data = ColorCube.data(for: toneOnly)
        cubeCache = (toneOnly, data)
        return data
    }

    // MARK: Exportação

    func export(url: URL, recipe: EditRecipe, settings: ExportSettings, to folder: URL) throws -> URL {
        let source: CIImage?
        if PhotoImporter.isRaw(url) {
            source = decodeRAW(url, maxPixel: nil, lensCorrection: recipe.lensCorrection)
        } else {
            source = CIImage(contentsOf: url, options: [.applyOrientationProperty: true])
        }
        guard let source else { throw ExportError.unreadable(url.lastPathComponent) }

        var image = apply(recipe, to: source)
        if settings.resize {
            let longest = max(image.extent.width, image.extent.height)
            if longest > CGFloat(settings.longEdge) {
                let f = CIFilter.lanczosScaleTransform()
                f.inputImage = image
                f.scale = Float(CGFloat(settings.longEdge) / longest)
                f.aspectRatio = 1
                image = f.outputImage ?? image
                // O Lanczos deixa bordas fracionárias: corta para o tamanho exato pedido.
                let e = image.extent
                let scale = CGFloat(settings.longEdge) / longest
                let size = CGSize(width: (source.extent.width * scale).rounded(), height: (source.extent.height * scale).rounded())
                let fitted = e.width >= e.height
                    ? CGSize(width: CGFloat(settings.longEdge), height: min(size.height, e.height.rounded(.down)))
                    : CGSize(width: min(size.width, e.width.rounded(.down)), height: CGFloat(settings.longEdge))
                image = image.cropped(to: CGRect(origin: CGPoint(x: e.minX.rounded(.up), y: e.minY.rounded(.up)), size: fitted))
            }
        }
        image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))

        let baseName = url.deletingPathExtension().lastPathComponent + settings.suffix
        let target = PhotoImporter.uniqueURL(folder.appendingPathComponent(baseName).appendingPathExtension(settings.format.fileExtension))

        if settings.format == .dng {
            try DNGWriter.write(image, context: context, to: target, camera: MetadataReader.basicInfo(for: url).camera)
            return target
        }

        let format: CIFormat = settings.sixteenBit && settings.format.supports16Bit ? .RGBA16 : .RGBA8
        guard let cgImage = context.createCGImage(image, from: image.extent.integral, format: format, colorSpace: sRGB) else {
            throw ExportError.cannotWrite(url.lastPathComponent)
        }

        guard let destination = CGImageDestinationCreateWithURL(target as CFURL, settings.format.utType.identifier as CFString, 1, nil) else {
            throw ExportError.cannotWrite(url.lastPathComponent)
        }

        var properties: [CFString: Any] = [kCGImagePropertyOrientation: 1]
        if settings.format.supportsQuality {
            properties[kCGImageDestinationLossyCompressionQuality] = settings.quality
        }
        if settings.includeMetadata {
            let original = MetadataReader.properties(for: url)
            for key in [kCGImagePropertyExifDictionary, kCGImagePropertyIPTCDictionary, kCGImagePropertyGPSDictionary] {
                if let value = original[key as String] { properties[key] = value }
            }
            if var tiff = original[kCGImagePropertyTIFFDictionary as String] as? [String: Any] {
                tiff[kCGImagePropertyTIFFOrientation as String] = 1
                properties[kCGImagePropertyTIFFDictionary] = tiff
            }
        }

        // Em RAW, os IPTC vivem no sidecar XMP: vão junto com a imagem exportada.
        if settings.includeMetadata, PhotoImporter.isRaw(url), let xmp = MetadataWriter.readMetadata(for: url) {
            CGImageDestinationAddImageAndMetadata(destination, cgImage, xmp, properties as CFDictionary)
        } else {
            CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)
        }
        guard CGImageDestinationFinalize(destination) else { throw ExportError.cannotWrite(url.lastPathComponent) }
        return target
    }
}

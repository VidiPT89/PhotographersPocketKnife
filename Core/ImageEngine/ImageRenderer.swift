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
        if r.sharpness > 0 {
            let f = CIFilter.sharpenLuminance()
            f.inputImage = image
            f.sharpness = Float(r.sharpness * 1.2)
            f.radius = 1.5
            image = f.outputImage ?? image
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
        return image
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
        var toneOnly = EditRecipe()
        toneOnly.whites = recipe.whites
        toneOnly.blacks = recipe.blacks
        toneOnly.highlights = max(0, recipe.highlights)
        toneOnly.curveMaster = recipe.curveMaster
        toneOnly.curveRed = recipe.curveRed
        toneOnly.curveGreen = recipe.curveGreen
        toneOnly.curveBlue = recipe.curveBlue
        toneOnly.hsl = recipe.hsl
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

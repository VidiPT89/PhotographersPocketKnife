import Foundation
import AppKit
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

enum ExportColorSpace: String, CaseIterable, Identifiable, Codable, Sendable {
    case sRGB, displayP3, adobeRGB
    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .sRGB: "sRGB"
        case .displayP3: "Display P3"
        case .adobeRGB: "Adobe RGB (1998)"
        }
    }

    var cgColorSpace: CGColorSpace {
        let name: CFString = switch self {
        case .sRGB: CGColorSpace.sRGB
        case .displayP3: CGColorSpace.displayP3
        case .adobeRGB: CGColorSpace.adobeRGB1998
        }
        return CGColorSpace(name: name) ?? CGColorSpaceCreateDeviceRGB()
    }
}

enum OutputSharpening: String, CaseIterable, Identifiable, Codable, Sendable {
    case none, screen, matte, glossy
    var id: String { rawValue }
    var labelKey: String { "sharpening.\(rawValue)" }

    var amount: Double {
        switch self {
        case .none: 0
        case .screen: 0.4
        case .matte: 0.75
        case .glossy: 0.55
        }
    }
}

enum MetadataRule: String, CaseIterable, Identifiable, Codable, Sendable {
    case all, noGPS, copyrightOnly, none
    var id: String { rawValue }
    var labelKey: String { "metadataRule.\(rawValue)" }
}

enum ResizeMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case longEdge, percent
    var id: String { rawValue }
    var labelKey: String { "resizeMode.\(rawValue)" }
}

enum WatermarkPosition: String, CaseIterable, Identifiable, Codable, Sendable {
    case topLeft, topRight, center, bottomLeft, bottomRight
    var id: String { rawValue }
    var labelKey: String { "position.\(rawValue)" }
}

struct ExportSettings: Equatable, Sendable {
    var format: ExportFormat = .jpeg
    var quality = 0.9
    var sixteenBit = false
    var resize = false
    var resizeMode: ResizeMode = .longEdge
    var longEdge = 2048
    var resizePercent = 50
    var dpi = 300
    var colorSpace: ExportColorSpace = .sRGB
    var outputSharpening: OutputSharpening = .none
    var watermarkEnabled = false
    var watermarkText = "© {year} David Arsénio Martins"
    var watermarkPosition: WatermarkPosition = .bottomRight
    var watermarkOpacity = 0.7
    /// Altura do texto como fração do lado menor da imagem.
    var watermarkSize = 0.035
    var metadataRule: MetadataRule = .all
    var suffix = ""
}

extension ExportSettings: Codable {
    private enum CodingKeys: String, CodingKey {
        case format, quality, sixteenBit, resize, resizeMode, longEdge, resizePercent, dpi, colorSpace, outputSharpening
        case watermarkEnabled, watermarkText, watermarkPosition, watermarkOpacity, watermarkSize, metadataRule, suffix
    }

    private enum LegacyKeys: String, CodingKey {
        case includeMetadata
    }

    /// Definições e presets de versões anteriores continuam a abrir (campos novos ficam por defeito).
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = ExportSettings()
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? container.decodeIfPresent(T.self, forKey: key)) ?? fallback
        }
        format = value(.format, defaults.format)
        quality = value(.quality, defaults.quality)
        sixteenBit = value(.sixteenBit, defaults.sixteenBit)
        resize = value(.resize, defaults.resize)
        resizeMode = value(.resizeMode, defaults.resizeMode)
        longEdge = value(.longEdge, defaults.longEdge)
        resizePercent = value(.resizePercent, defaults.resizePercent)
        dpi = value(.dpi, defaults.dpi)
        colorSpace = value(.colorSpace, defaults.colorSpace)
        outputSharpening = value(.outputSharpening, defaults.outputSharpening)
        watermarkEnabled = value(.watermarkEnabled, defaults.watermarkEnabled)
        watermarkText = value(.watermarkText, defaults.watermarkText)
        watermarkPosition = value(.watermarkPosition, defaults.watermarkPosition)
        watermarkOpacity = value(.watermarkOpacity, defaults.watermarkOpacity)
        watermarkSize = value(.watermarkSize, defaults.watermarkSize)
        suffix = value(.suffix, defaults.suffix)
        let legacy = try decoder.container(keyedBy: LegacyKeys.self)
        let includeMetadata = (try? legacy.decodeIfPresent(Bool.self, forKey: .includeMetadata)) ?? true
        metadataRule = value(.metadataRule, includeMetadata ? MetadataRule.all : .none)
    }
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

extension ImageRenderer {
    /// Render à resolução total → redimensionar (Lanczos) → nitidez de saída → marca de água → perfil de cor → ficheiro.
    func export(url: URL, recipe: EditRecipe, settings: ExportSettings, to folder: URL) throws -> URL {
        try Diagnostics.shared.measure(.export) {
            try exportMeasured(url: url, recipe: recipe, settings: settings, to: folder)
        }
    }

    private func exportMeasured(url: URL, recipe: EditRecipe, settings: ExportSettings, to folder: URL) throws -> URL {
        let source: CIImage?
        if PhotoImporter.isRaw(url) {
            source = decodeRAW(url, maxPixel: nil, lensCorrection: recipe.lensCorrection)
        } else {
            source = CIImage(contentsOf: url, options: [.applyOrientationProperty: true])
        }
        guard let source else { throw ExportError.unreadable(url.lastPathComponent) }

        var image = resized(apply(recipe, to: source), settings: settings)
        let extent = image.extent

        if settings.outputSharpening != .none {
            let f = CIFilter.sharpenLuminance()
            f.inputImage = image.clampedToExtent()
            f.sharpness = Float(settings.outputSharpening.amount)
            f.radius = Float(max(max(extent.width, extent.height) / 2500, 1))
            image = (f.outputImage ?? image).cropped(to: extent)
        }
        if settings.watermarkEnabled, let mark = watermark(settings, in: extent) {
            image = mark.composited(over: image).cropped(to: extent)
        }
        image = image.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))

        let baseName = url.deletingPathExtension().lastPathComponent + settings.suffix
        let target = PhotoImporter.uniqueURL(folder.appendingPathComponent(baseName).appendingPathExtension(settings.format.fileExtension))

        if settings.format == .dng {
            try DNGWriter.write(image, context: context, to: target, camera: MetadataReader.basicInfo(for: url).camera)
            return target
        }

        let pixelFormat: CIFormat = settings.sixteenBit && settings.format.supports16Bit ? .RGBA16 : .RGBA8
        guard let cgImage = context.createCGImage(image, from: image.extent.integral, format: pixelFormat, colorSpace: settings.colorSpace.cgColorSpace),
              let destination = CGImageDestinationCreateWithURL(target as CFURL, settings.format.utType.identifier as CFString, 1, nil) else {
            throw ExportError.cannotWrite(url.lastPathComponent)
        }

        var properties: [CFString: Any] = [
            kCGImagePropertyOrientation: 1,
            kCGImagePropertyDPIWidth: settings.dpi,
            kCGImagePropertyDPIHeight: settings.dpi,
        ]
        if settings.format.supportsQuality {
            properties[kCGImageDestinationLossyCompressionQuality] = settings.quality
        }
        properties.merge(Self.metadata(from: MetadataReader.properties(for: url), rule: settings.metadataRule)) { $1 }

        // Em RAW, os IPTC vivem no sidecar XMP: vão com a imagem, exceto se a regra os excluir.
        let keepsXMP = settings.metadataRule == .all || settings.metadataRule == .noGPS
        if keepsXMP, PhotoImporter.isRaw(url), let xmp = MetadataWriter.readMetadata(for: url) {
            CGImageDestinationAddImageAndMetadata(destination, cgImage, xmp, properties as CFDictionary)
        } else {
            CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)
        }
        guard CGImageDestinationFinalize(destination) else { throw ExportError.cannotWrite(url.lastPathComponent) }
        return target
    }

    private func resized(_ image: CIImage, settings: ExportSettings) -> CIImage {
        guard settings.resize else { return image }
        let e = image.extent
        let longest = max(e.width, e.height)
        let scale: CGFloat = switch settings.resizeMode {
        case .longEdge: min(CGFloat(settings.longEdge) / longest, 1)
        case .percent: CGFloat(min(max(settings.resizePercent, 1), 100)) / 100
        }
        guard scale < 1 else { return image }
        let f = CIFilter.lanczosScaleTransform()
        f.inputImage = image
        f.scale = Float(scale)
        f.aspectRatio = 1
        let output = f.outputImage ?? image
        // O Lanczos deixa bordas fracionárias: corta para o tamanho exato pedido.
        let o = output.extent
        let width = min((e.width * scale).rounded(), o.width.rounded(.down))
        let height = min((e.height * scale).rounded(), o.height.rounded(.down))
        return output.cropped(to: CGRect(x: o.minX.rounded(.up), y: o.minY.rounded(.up), width: width, height: height))
    }

    func watermark(_ settings: ExportSettings, in extent: CGRect) -> CIImage? {
        let year = String(Calendar.current.component(.year, from: Date()))
        let text = settings.watermarkText.replacingOccurrences(of: "{year}", with: year)
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }

        let shortSide = min(extent.width, extent.height)
        let fontSize = max(shortSide * CGFloat(settings.watermarkSize), 8)
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.45 * settings.watermarkOpacity)
        shadow.shadowBlurRadius = fontSize * 0.18
        shadow.shadowOffset = NSSize(width: 0, height: -fontSize * 0.05)
        let attributed = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .semibold),
            .foregroundColor: NSColor.white.withAlphaComponent(settings.watermarkOpacity),
            .shadow: shadow,
        ])
        let f = CIFilter.attributedTextImageGenerator()
        f.text = attributed
        f.scaleFactor = 1
        guard let mark = f.outputImage else { return nil }

        let margin = shortSide * 0.03
        let size = mark.extent.size
        let origin: CGPoint = switch settings.watermarkPosition {
        case .topLeft: CGPoint(x: extent.minX + margin, y: extent.maxY - margin - size.height)
        case .topRight: CGPoint(x: extent.maxX - margin - size.width, y: extent.maxY - margin - size.height)
        case .center: CGPoint(x: extent.midX - size.width / 2, y: extent.midY - size.height / 2)
        case .bottomLeft: CGPoint(x: extent.minX + margin, y: extent.minY + margin)
        case .bottomRight: CGPoint(x: extent.maxX - margin - size.width, y: extent.minY + margin)
        }
        return mark.transformed(by: CGAffineTransform(translationX: origin.x - mark.extent.minX, y: origin.y - mark.extent.minY))
    }

    /// Metadados copiados do original conforme a regra (tudo / sem GPS / só copyright / nada).
    static func metadata(from original: [String: Any], rule: MetadataRule) -> [CFString: Any] {
        var result: [CFString: Any] = [:]
        var tiff = original[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
        tiff[kCGImagePropertyTIFFOrientation as String] = 1
        let iptc = original[kCGImagePropertyIPTCDictionary as String] as? [String: Any] ?? [:]

        switch rule {
        case .all, .noGPS:
            if let exif = original[kCGImagePropertyExifDictionary as String] { result[kCGImagePropertyExifDictionary] = exif }
            if !iptc.isEmpty { result[kCGImagePropertyIPTCDictionary] = iptc }
            if rule == .all, let gps = original[kCGImagePropertyGPSDictionary as String] { result[kCGImagePropertyGPSDictionary] = gps }
            result[kCGImagePropertyTIFFDictionary] = tiff
        case .copyrightOnly:
            var copyright: [String: Any] = [:]
            for key in [kCGImagePropertyIPTCCopyrightNotice, kCGImagePropertyIPTCByline, kCGImagePropertyIPTCRightsUsageTerms] {
                if let value = iptc[key as String] { copyright[key as String] = value }
            }
            if !copyright.isEmpty { result[kCGImagePropertyIPTCDictionary] = copyright }
            var tiffCopyright: [String: Any] = [kCGImagePropertyTIFFOrientation as String: 1]
            for key in [kCGImagePropertyTIFFCopyright, kCGImagePropertyTIFFArtist] {
                if let value = tiff[key as String] { tiffCopyright[key as String] = value }
            }
            result[kCGImagePropertyTIFFDictionary] = tiffCopyright
        case .none:
            break
        }
        return result
    }
}

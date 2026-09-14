import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import Vision

/// Um exemplo aprendido: como era a foto, o que o automático faria e o que o fotógrafo fez.
struct StyleExample: Codable, Sendable {
    /// Cor e luz médias (r, g, b, luminância, contraste, saturação).
    var stats: [Double]
    var featurePrint: Data?
    /// Edição do fotógrafo menos o automático, nos ajustes que dependem da luz de cada foto.
    var adaptive: [Double]
    /// A edição completa, sem enquadramento, máscaras nem remoções.
    var look: EditRecipe
}

struct StyleProfile: Codable, Identifiable, Sendable {
    var id = UUID()
    var name: String
    var examples: [StyleExample]
}

/// Estilo pessoal: aprende com as fotos já editadas e edita fotos novas da mesma forma,
/// usando as edições das fotos mais parecidas e adaptando exposição e cor à luz de cada uma.
enum PersonalStyle {
    static let minimumExamples = 3

    static var adaptiveKeys: [WritableKeyPath<EditRecipe, Double>] {
        [\.exposure, \.temperature, \.tint, \.highlights, \.shadows, \.contrast]
    }

    static var lookKeys: [WritableKeyPath<EditRecipe, Double>] {
        [
            \.whites, \.blacks, \.texture, \.clarity, \.vibrance, \.saturation,
            \.sharpness, \.sharpenRadius, \.sharpenMasking, \.noiseReduction, \.colorNoiseReduction,
            \.chromaticAberration, \.vignette, \.grain, \.grainSize, \.skinSmoothing, \.backgroundBlur,
            \.shadowsSaturation, \.midtonesSaturation, \.highlightsSaturation, \.gradingBalance,
        ]
    }

    static func example(image: CIImage, recipe: EditRecipe, renderer: ImageRenderer = .shared) -> StyleExample {
        let auto = AutoEnhance.enhance(EditRecipe(), image: image, renderer: renderer)
        return StyleExample(
            stats: stats(of: image, renderer: renderer),
            featurePrint: featurePrint(of: image, renderer: renderer),
            adaptive: adaptiveKeys.map { recipe[keyPath: $0] - auto[keyPath: $0] },
            look: cleaned(recipe)
        )
    }

    static func cleaned(_ recipe: EditRecipe) -> EditRecipe {
        var look = recipe
        look.masks = []
        look.removals = []
        look.crop = CropRect()
        look.straighten = 0
        look.quarterTurns = 0
        look.flipHorizontal = false
        look.perspectiveVertical = 0
        look.perspectiveHorizontal = 0
        return look
    }

    static func predict(_ profile: StyleProfile, for image: CIImage, current: EditRecipe, renderer: ImageRenderer = .shared) -> EditRecipe {
        guard !profile.examples.isEmpty else { return current }
        let stats = stats(of: image, renderer: renderer)
        let observation = featurePrint(of: image, renderer: renderer).flatMap(decode)
        let neighbours = profile.examples
            .map { ($0, distance(stats, observation, to: $0)) }
            .sorted { $0.1 < $1.1 }
            .prefix(5)
        let weights = neighbours.map { 1 / pow($0.1 + 0.05, 2) }
        let total = weights.reduce(0, +)
        func average(_ value: (StyleExample) -> Double) -> Double {
            zip(neighbours, weights).reduce(0) { $0 + value($1.0.0) * $1.1 } / total
        }

        // Curvas, matizes da gradação e correção de lente vêm do exemplo mais parecido.
        var result = neighbours.first?.0.look ?? current
        let auto = AutoEnhance.enhance(EditRecipe(), image: image, renderer: renderer)
        for (index, key) in adaptiveKeys.enumerated() {
            let offset = average { index < $0.adaptive.count ? $0.adaptive[index] : 0 }
            let limit = key == \EditRecipe.exposure ? 5.0 : 1.0
            result[keyPath: key] = min(max(auto[keyPath: key] + offset, -limit), limit)
        }
        for key in lookKeys {
            result[keyPath: key] = average { $0.look[keyPath: key] }
        }
        for band in result.hsl.indices {
            result.hsl[band].hue = average { band < $0.look.hsl.count ? $0.look.hsl[band].hue : 0 }
            result.hsl[band].saturation = average { band < $0.look.hsl.count ? $0.look.hsl[band].saturation : 0 }
            result.hsl[band].luminance = average { band < $0.look.hsl.count ? $0.look.hsl[band].luminance : 0 }
        }

        // O enquadramento, as máscaras e as remoções são desta foto.
        result.masks = current.masks
        result.removals = current.removals
        result.crop = current.crop
        result.straighten = current.straighten
        result.quarterTurns = current.quarterTurns
        result.flipHorizontal = current.flipHorizontal
        result.perspectiveVertical = current.perspectiveVertical
        result.perspectiveHorizontal = current.perspectiveHorizontal
        return result
    }

    private static func distance(_ stats: [Double], _ observation: VNFeaturePrintObservation?, to example: StyleExample) -> Double {
        let colour = zip(stats, example.stats).reduce(0) { $0 + pow($1.0 - $1.1, 2) }.squareRoot() * 2
        guard let observation, let other = example.featurePrint.flatMap(decode) else { return colour + 0.5 }
        var value: Float = 0
        return (try? observation.computeDistance(&value, to: other)) != nil ? Double(value) + colour : colour + 0.5
    }

    private static func decode(_ data: Data) -> VNFeaturePrintObservation? {
        try? NSKeyedUnarchiver.unarchivedObject(ofClass: VNFeaturePrintObservation.self, from: data)
    }

    static func stats(of image: CIImage, renderer: ImageRenderer) -> [Double] {
        let e = image.extent
        guard !e.isInfinite, e.width > 0, e.height > 0 else { return [0, 0, 0, 0, 0, 0] }
        let side = 32
        let f = CIFilter.lanczosScaleTransform()
        f.inputImage = image.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY)).clampedToExtent()
        f.scale = Float(CGFloat(side) / e.height)
        f.aspectRatio = Float(e.height / e.width)
        var rgba = [Float](repeating: 0, count: side * side * 4)
        if let small = f.outputImage {
            renderer.context.render(small, toBitmap: &rgba, rowBytes: side * 16, bounds: CGRect(x: 0, y: 0, width: side, height: side),
                                    format: .RGBAf, colorSpace: renderer.sRGB)
        }
        var r = 0.0, g = 0.0, b = 0.0, l = 0.0, l2 = 0.0, saturation = 0.0
        let count = Double(side * side)
        for i in 0..<(side * side) {
            let pr = Double(min(max(rgba[i * 4], 0), 1)), pg = Double(min(max(rgba[i * 4 + 1], 0), 1)), pb = Double(min(max(rgba[i * 4 + 2], 0), 1))
            let lum = 0.2126 * pr + 0.7152 * pg + 0.0722 * pb
            r += pr; g += pg; b += pb; l += lum; l2 += lum * lum
            let high = max(pr, pg, pb)
            if high > 0.02 { saturation += (high - min(pr, pg, pb)) / high }
        }
        let mean = l / count
        return [r / count, g / count, b / count, mean, max(l2 / count - mean * mean, 0).squareRoot(), saturation / count]
    }

    static func featurePrint(of image: CIImage, renderer: ImageRenderer) -> Data? {
        let e = image.extent
        guard !e.isInfinite, e.width > 0, e.height > 0 else { return nil }
        let scale = min(512 / max(e.width, e.height), 1)
        let scaled = image.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY)).transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let rect = CGRect(x: 0, y: 0, width: (e.width * scale).rounded(.down), height: (e.height * scale).rounded(.down))
        guard let cgImage = renderer.context.createCGImage(scaled, from: rect, format: .RGBA8, colorSpace: renderer.sRGB) else { return nil }
        let request = VNGenerateImageFeaturePrintRequest()
        guard (try? VNImageRequestHandler(cgImage: cgImage).perform([request])) != nil, let observation = request.results?.first else { return nil }
        return try? NSKeyedArchiver.archivedData(withRootObject: observation, requiringSecureCoding: true)
    }
}

/// Estilos guardados como ficheiros JSON em Application Support (fáceis de copiar para outro Mac).
struct StyleProfileStore: Sendable {
    let directory: URL

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PhotographersPocketKnife/Styles", isDirectory: true)
    }

    func all() -> [StyleProfile] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { try? JSONDecoder().decode(StyleProfile.self, from: Data(contentsOf: $0)) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func save(_ profile: StyleProfile) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? JSONEncoder().encode(profile).write(to: url(for: profile.id), options: .atomic)
    }

    func delete(_ id: UUID) {
        try? FileManager.default.removeItem(at: url(for: id))
    }

    private func url(for id: UUID) -> URL {
        directory.appendingPathComponent(id.uuidString).appendingPathExtension("json")
    }
}

extension ImageRenderer {
    func styleExample(url: URL, recipe: EditRecipe) -> StyleExample? {
        guard let base = previewBase(url: url, maxPixel: 1024, lensCorrection: recipe.lensCorrection) else { return nil }
        return PersonalStyle.example(image: CIImage(cgImage: base), recipe: recipe, renderer: self)
    }

    func styled(url: URL, profile: StyleProfile, current: EditRecipe) -> EditRecipe? {
        guard let base = previewBase(url: url, maxPixel: 1024, lensCorrection: current.lensCorrection) else { return nil }
        return PersonalStyle.predict(profile, for: CIImage(cgImage: base), current: current, renderer: self)
    }
}

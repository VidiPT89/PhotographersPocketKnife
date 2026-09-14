import CoreGraphics
import Foundation
import Vision

/// Medições de uma foto para a seleção inteligente. Absolutas: a comparação é feita dentro de cada sessão.
struct PhotoAssessment: Codable, Equatable, Sendable {
    static let currentVersion = 1
    var version = PhotoAssessment.currentVersion
    /// Variância do Laplaciano na zona principal (caras, objeto principal ou centro). Maior = mais nítida.
    var sharpness = 0.0
    /// Luminância média (0…1) e frações de píxeis quase brancos ou quase pretos.
    var brightness = 0.5
    var clippedHighlights = 0.0
    var clippedShadows = 0.0
    var faces = 0
    var closedEyes = 0
    /// Melhor qualidade de captura de cara (0…1), se houver caras.
    var faceQuality: Double?
    /// Pontuação estética do Vision (−1…1), só em macOS 15 ou mais recente.
    var aesthetics: Double?
    /// Documento, recibo ou captura de ecrã.
    var isUtility = false
    /// "Impressão digital" do Vision (arquivada), para saber se duas fotos são do mesmo momento.
    var featurePrint: Data?
}

/// Analisa fotos com o Vision, no próprio Mac, sobre a pré-visualização de 1024 px.
enum PhotoAssessor {
    static let analysisSide = 1024

    static func assess(url: URL) async -> PhotoAssessment? {
        guard let thumbnail = ThumbnailCache.shared.thumbnail(for: url, maxPixel: analysisSide) else { return nil }
        return await assess(thumbnail.cgImage)
    }

    static func assess(_ image: CGImage) async -> PhotoAssessment {
        var result = PhotoAssessment()
        let handler = VNImageRequestHandler(cgImage: image)
        let landmarks = VNDetectFaceLandmarksRequest()
        let quality = VNDetectFaceCaptureQualityRequest()
        let saliency = VNGenerateObjectnessBasedSaliencyImageRequest()
        let featurePrint = VNGenerateImageFeaturePrintRequest()
        // Um pedido de cada vez: se um falhar, os outros continuam a dar resultado.
        for request in [landmarks, quality, saliency, featurePrint] as [VNRequest] {
            try? handler.perform([request])
        }

        let width = CGFloat(image.width), height = CGFloat(image.height)
        let faces = (landmarks.results ?? []).filter { $0.boundingBox.width * width >= 40 }
        result.faces = faces.count
        result.closedEyes = faces.filter { face in
            guard let marks = face.landmarks, let left = marks.leftEye, let right = marks.rightEye else { return false }
            let box = CGSize(width: face.boundingBox.width * width, height: face.boundingBox.height * height)
            return (openness(left, face: box) + openness(right, face: box)) / 2 < 0.16
        }.count
        result.faceQuality = (quality.results ?? []).compactMap { $0.faceCaptureQuality.map(Double.init) }.max()

        // Onde medir a nitidez: nas caras, senão no objeto principal, senão no centro.
        var region: CGRect
        if !faces.isEmpty {
            region = faces.map(\.boundingBox).reduce(CGRect.null) { $0.union($1) }.insetBy(dx: -0.03, dy: -0.03)
        } else if let objects = saliency.results?.first?.salientObjects, !objects.isEmpty {
            region = objects.map(\.boundingBox).reduce(CGRect.null) { $0.union($1) }
        } else {
            region = CGRect(x: 0.2, y: 0.2, width: 0.6, height: 0.6)
        }
        region = region.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        result.sharpness = sharpness(of: image, normalizedRegion: region)

        let exposure = exposure(of: image)
        result.brightness = exposure.brightness
        result.clippedHighlights = exposure.highlights
        result.clippedShadows = exposure.shadows

        if let observation = featurePrint.results?.first {
            result.featurePrint = try? NSKeyedArchiver.archivedData(withRootObject: observation, requiringSecureCoding: true)
        }
        if #available(macOS 15.0, *) {
            if let scores = try? await CalculateImageAestheticsScoresRequest().perform(on: image) {
                result.aesthetics = Double(scores.overallScore)
                result.isUtility = scores.isUtility
            }
        }
        return result
    }

    /// Altura/largura do olho, em píxeis (os pontos vêm normalizados à caixa da cara).
    private static func openness(_ eye: VNFaceLandmarkRegion2D, face: CGSize) -> Double {
        let points = eye.normalizedPoints
        guard let minX = points.map(\.x).min(), let maxX = points.map(\.x).max(),
              let minY = points.map(\.y).min(), let maxY = points.map(\.y).max() else { return 1 }
        let eyeWidth = (maxX - minX) * face.width
        return eyeWidth > 0 ? Double((maxY - minY) * face.height / eyeWidth) : 1
    }

    /// Variância do Laplaciano (0…255) na região, que no Vision tem a origem em baixo à esquerda.
    static func sharpness(of image: CGImage, normalizedRegion region: CGRect) -> Double {
        let w = CGFloat(image.width), h = CGFloat(image.height)
        let rect = CGRect(x: region.minX * w, y: (1 - region.maxY) * h, width: region.width * w, height: region.height * h).integral
        guard rect.width >= 16, rect.height >= 16, let crop = image.cropping(to: rect) else { return 0 }
        let scale = min(1, 512 / CGFloat(max(crop.width, crop.height)))
        let cw = max(Int(CGFloat(crop.width) * scale), 8), ch = max(Int(CGFloat(crop.height) * scale), 8)
        guard let gray = grayPixels(crop, width: cw, height: ch) else { return 0 }
        var sum = 0.0, squares = 0.0, count = 0.0
        for y in 1..<(ch - 1) {
            for x in 1..<(cw - 1) {
                let i = y * cw + x
                let laplacian = 4 * gray[i] - gray[i - 1] - gray[i + 1] - gray[i - cw] - gray[i + cw]
                sum += laplacian
                squares += laplacian * laplacian
                count += 1
            }
        }
        guard count > 0 else { return 0 }
        let mean = sum / count
        return squares / count - mean * mean
    }

    static func exposure(of image: CGImage) -> (brightness: Double, highlights: Double, shadows: Double) {
        let scale = min(1, 256 / CGFloat(max(image.width, image.height)))
        let w = max(Int(CGFloat(image.width) * scale), 1), h = max(Int(CGFloat(image.height) * scale), 1)
        guard let gray = grayPixels(image, width: w, height: h) else { return (0.5, 0, 0) }
        let count = Double(gray.count)
        return (gray.reduce(0, +) / count / 255,
                Double(gray.filter { $0 >= 250 }.count) / count,
                Double(gray.filter { $0 <= 5 }.count) / count)
    }

    private static func grayPixels(_ image: CGImage, width: Int, height: Int) -> [Double]? {
        var bytes = [UInt8](repeating: 0, count: width * height)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                          space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? bytes.map(Double.init) : nil
    }
}

/// Distâncias entre impressões digitais do Vision, com cada observação descodificada uma só vez.
final class FeaturePrintDistances {
    private var decoded: [UUID: VNFeaturePrintObservation?] = [:]

    func distance(_ a: CullCandidate, _ b: CullCandidate) -> Float? {
        guard let first = observation(a), let second = observation(b) else { return nil }
        var value: Float = 0
        return (try? first.computeDistance(&value, to: second)) != nil ? value : nil
    }

    private func observation(_ candidate: CullCandidate) -> VNFeaturePrintObservation? {
        if let cached = decoded[candidate.id] { return cached }
        let observation = candidate.assessment.featurePrint.flatMap {
            try? NSKeyedUnarchiver.unarchivedObject(ofClass: VNFeaturePrintObservation.self, from: $0)
        }
        decoded[candidate.id] = observation
        return observation
    }
}

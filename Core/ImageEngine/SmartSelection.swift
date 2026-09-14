import CoreImage
import CoreImage.CIFilterBuiltins
import Vision

/// Seleções automáticas com o Vision, no próprio Mac (sem rede): o sujeito principal e o objeto num ponto.
/// A análise é feita sobre a foto sem ajustes e fica em cache, por isso mexer nos sliders não a repete.
final class SmartSelection: @unchecked Sendable {
    static let shared = SmartSelection()

    private struct Analysis {
        let observation: VNInstanceMaskObservation?
        let handler: VNImageRequestHandler
    }

    private let lock = NSLock()
    /// O Vision não garante chamadas em paralelo sobre o mesmo pedido.
    private let visionLock = NSLock()
    private var cache: [String: Analysis] = [:]
    private var order: [String] = []
    private var personCache: [String: CIImage?] = [:]
    private var personOrder: [String] = []

    /// Máscara do sujeito principal (branco = sujeito) com a extensão de `image`; `nil` se não houver nenhum.
    func subjectMask(for image: CIImage) -> CIImage? {
        guard let analysis = analysis(for: image), let observation = analysis.observation,
              !observation.allInstances.isEmpty else { return nil }
        return mask(observation, analysis.handler, instances: observation.allInstances, extent: image.extent)
    }

    /// Máscara do objeto no ponto (normalizado, origem em cima à esquerda). Procura à volta se o clique cair ao lado.
    func objectMask(for image: CIImage, at point: CurvePoint) -> CIImage? {
        guard let analysis = analysis(for: image), let observation = analysis.observation else { return nil }
        let label = visionLock.withLock { Self.label(in: observation.instanceMask, at: point, searchRadius: 0.025) }
        guard label > 0 else { return nil }
        return mask(observation, analysis.handler, instances: IndexSet(integer: label), extent: image.extent)
    }

    private func analysis(for image: CIImage) -> Analysis? {
        let e = image.extent
        guard !e.isInfinite, e.width >= 16, e.height >= 16 else { return nil }
        let key = Self.fingerprint(image)
        if let hit = lock.withLock({ cache[key] }) { return hit }

        guard let cgImage = Self.analysisImage(image) else { return nil }
        let handler = VNImageRequestHandler(cgImage: cgImage)
        let request = VNGenerateForegroundInstanceMaskRequest()
        let observation: VNInstanceMaskObservation? = visionLock.withLock {
            (try? handler.perform([request])) != nil ? request.results?.first : nil
        }
        let analysis = Analysis(observation: observation, handler: handler)
        lock.withLock {
            cache[key] = analysis
            order.append(key)
            if order.count > 4 { cache[order.removeFirst()] = nil }
        }
        return analysis
    }

    private func mask(_ observation: VNInstanceMaskObservation, _ handler: VNImageRequestHandler, instances: IndexSet, extent e: CGRect) -> CIImage? {
        guard let buffer = visionLock.withLock({ try? observation.generateScaledMaskForImage(forInstances: instances, from: handler) }) else { return nil }
        return Self.grayMask(CIImage(cvPixelBuffer: buffer), extent: e)
    }

    /// Máscara das pessoas (branco = pessoa) com a extensão de `image`; `nil` se não houver ninguém.
    func personMask(for image: CIImage) -> CIImage? {
        let e = image.extent
        guard !e.isInfinite, e.width >= 16, e.height >= 16 else { return nil }
        let key = Self.fingerprint(image)
        if let hit = lock.withLock({ personCache[key] }) { return hit }

        var mask: CIImage?
        if let cgImage = Self.analysisImage(image) {
            let request = VNGeneratePersonSegmentationRequest()
            request.qualityLevel = .accurate
            request.outputPixelFormat = kCVPixelFormatType_OneComponent8
            let buffer: CVPixelBuffer? = visionLock.withLock {
                (try? VNImageRequestHandler(cgImage: cgImage).perform([request])) != nil ? request.results?.first?.pixelBuffer : nil
            }
            // Sem ninguém na foto, o Vision devolve uma máscara vazia.
            mask = buffer.map { Self.grayMask(CIImage(cvPixelBuffer: $0), extent: e) }.flatMap { Self.isEmpty($0) ? nil : $0 }
        }
        lock.withLock {
            personCache[key] = .some(mask)
            personOrder.append(key)
            if personOrder.count > 4 { personCache[personOrder.removeFirst()] = nil }
        }
        return mask
    }

    /// A foto reduzida a 1024 px, como o Vision a vê.
    private static func analysisImage(_ image: CIImage) -> CGImage? {
        let e = image.extent
        let renderer = ImageRenderer.shared
        let scale = min(1024 / max(e.width, e.height), 1)
        let size = CGSize(width: (e.width * scale).rounded(.down), height: (e.height * scale).rounded(.down))
        let scaled = image
            .transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        return renderer.context.createCGImage(scaled, from: CGRect(origin: .zero, size: size), format: .RGBA8, colorSpace: renderer.sRGB)
    }

    /// Buffer de um só canal → cinzento opaco com a extensão pedida, como as outras máscaras.
    private static func grayMask(_ raw: CIImage, extent e: CGRect) -> CIImage {
        let r = raw.extent
        guard r.width > 0, r.height > 0 else { return CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: e) }
        return raw
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 1, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 1, y: 0, z: 0, w: 0),
                "inputBVector": CIVector(x: 1, y: 0, z: 0, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            ])
            .transformed(by: CGAffineTransform(scaleX: e.width / r.width, y: e.height / r.height))
            .transformed(by: CGAffineTransform(translationX: e.minX, y: e.minY))
            .cropped(to: e)
    }

    private static func isEmpty(_ mask: CIImage) -> Bool {
        let maximum = mask.applyingFilter("CIAreaMaximum", parameters: [kCIInputExtentKey: CIVector(cgRect: mask.extent)])
        var pixel = [UInt8](repeating: 0, count: 4)
        ImageRenderer.shared.context.render(maximum, toBitmap: &pixel, rowBytes: 4,
                                            bounds: CGRect(origin: maximum.extent.origin, size: CGSize(width: 1, height: 1)), format: .RGBA8, colorSpace: nil)
        return pixel[0] < 128
    }

    private static func label(in buffer: CVPixelBuffer, at point: CurvePoint, searchRadius: Double) -> Int {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return 0 }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        let cx = Int(point.x * Double(width)), cy = Int(point.y * Double(height))
        let reach = max(Int(searchRadius * Double(max(width, height))), 1)
        var best = 0, bestDistance = Int.max
        for dy in -reach...reach {
            for dx in -reach...reach {
                let x = cx + dx, y = cy + dy
                guard x >= 0, x < width, y >= 0, y < height else { continue }
                let value = Int(bytes[y * bytesPerRow + x])
                let distance = dx * dx + dy * dy
                if value > 0, distance < bestDistance {
                    best = value
                    bestDistance = distance
                }
            }
        }
        return best
    }

    /// Impressão digital barata do conteúdo (8×8 píxeis + tamanho), para reutilizar análises caras.
    static func fingerprint(_ image: CIImage) -> String {
        let e = image.extent
        let renderer = ImageRenderer.shared
        let f = CIFilter.lanczosScaleTransform()
        f.inputImage = image.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY)).clampedToExtent()
        f.scale = Float(8 / max(e.height, 1))
        f.aspectRatio = Float(e.height / max(e.width, 1))
        var bytes = [UInt8](repeating: 0, count: 8 * 8 * 4)
        if let small = f.outputImage {
            renderer.context.render(small, toBitmap: &bytes, rowBytes: 32, bounds: CGRect(x: 0, y: 0, width: 8, height: 8), format: .RGBA8, colorSpace: renderer.sRGB)
        }
        return "\(Int(e.width))x\(Int(e.height))@\(Int(e.minX)),\(Int(e.minY)):" + bytes.map { String(format: "%02x", $0 >> 3) }.joined()
    }
}

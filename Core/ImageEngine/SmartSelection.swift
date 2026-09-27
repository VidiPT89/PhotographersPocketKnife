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
        /// Onde há gente (troncos e rostos), normalizado com origem em cima à esquerda.
        let people: [CGRect]
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
        // Uma cabeça também se solta pelo pescoço, mas quem clica numa cabeça quer tirar a pessoa. Só vale a
        // peça quando não é gente — a bola, um cartaz, uma bandeirola. A segmentação de pessoas não serve
        // para o saber (marca a bancada inteira e até a bola), nem a pose ou o rosto, que falham num
        // jogador de costas ou de pernas para o ar; o tronco detectado apanha esses casos.
        if let part = visionLock.withLock({ Self.part(of: observation.instanceMask, label: label, at: point) }),
           !analysis.people.contains(where: { $0.contains(part.centre) }) {
            return Self.grayMask(part.image, extent: image.extent)
                .clampedToExtent().applyingGaussianBlur(sigma: 1).cropped(to: image.extent)
        }
        return mask(observation, analysis.handler, instances: IndexSet(integer: label), extent: image.extent)
    }

    /// O Vision junta muitas vezes num só objecto tudo o que se toca: a bola presa à bota, a bota ao
    /// jogador, o jogador ao do lado. Clicar na bola apagava então o primeiro plano inteiro.
    ///
    /// Aqui procura-se a parte clicada ligada ao resto por um *gargalo*: abre-se a máscara (erosão e
    /// depois dilatação com o mesmo raio), o que corta ligações mais estreitas do que o raio, e fica a
    /// peça onde caiu o clique. Só se aceita se for bem mais pequena do que o todo — clicar numa pessoa
    /// soltava-lhe os braços com o mesmo método, e aí o que se quer é a pessoa inteira.
    private struct Part {
        let pixels: [Bool]
        let width: Int
        let height: Int

        /// Centro de massa, normalizado com origem em cima à esquerda.
        var centre: CGPoint {
            var sx = 0, sy = 0, n = 0
            for i in pixels.indices where pixels[i] {
                sx += i % width; sy += i / width; n += 1
            }
            guard n > 0 else { return CGPoint(x: -1, y: -1) }
            return CGPoint(x: (Double(sx) / Double(n) + 0.5) / Double(width), y: (Double(sy) / Double(n) + 0.5) / Double(height))
        }

        var image: CIImage {
            let gray = pixels.map { $0 ? UInt8(255) : 0 }
            return CIImage(bitmapData: Data(gray), bytesPerRow: width, size: CGSize(width: width, height: height),
                           format: .L8, colorSpace: nil)
        }
    }

    private static func part(of buffer: CVPixelBuffer, label: Int, at point: CurvePoint) -> Part? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        var inside = [Bool](repeating: false, count: width * height)
        for y in 0..<height {
            for x in 0..<width { inside[y * width + x] = Int(bytes[y * bytesPerRow + x]) == label }
        }
        let area = inside.lazy.filter { $0 }.count
        guard area > 0 else { return nil }
        let cx = min(Int(point.x * Double(width)), width - 1), cy = min(Int(point.y * Double(height)), height - 1)

        let depth = distance(to: inside.map { !$0 }, width: width, height: height)
        for fraction in [0.015, 0.025, 0.035, 0.045] {
            let radius = Float(fraction * Double(max(width, height)))
            let core = depth.map { $0 >= radius }
            // O clique pode cair numa zona fina que a erosão tirou; vale o ponto do núcleo mais perto.
            guard let seed = nearest(in: core, to: (cx, cy), reach: Int(radius) + 2, width: width, height: height) else { break }
            let piece = component(of: core, from: seed, width: width, height: height)
            let reach = distance(to: piece, width: width, height: height)
            var result = [Bool](repeating: false, count: width * height)
            var count = 0
            for i in 0..<result.count where inside[i] && reach[i] <= radius + 1 {
                result[i] = true
                count += 1
            }
            guard count * 10 < area * 3 else { continue }
            return Part(pixels: result, width: width, height: height)
        }
        return nil
    }

    /// Distância (chamfer 3-4, em píxeis) de cada ponto ao conjunto `targets`.
    private static func distance(to targets: [Bool], width: Int, height: Int) -> [Float] {
        let far = Float(width + height) * 2
        var d = targets.map { $0 ? Float(0) : far }
        func relax(_ i: Int, _ j: Int, _ cost: Float) { if d[j] + cost < d[i] { d[i] = d[j] + cost } }
        for y in 0..<height {
            for x in 0..<width {
                let i = y * width + x
                if x > 0 { relax(i, i - 1, 1) }
                if y > 0 {
                    relax(i, i - width, 1)
                    if x > 0 { relax(i, i - width - 1, 1.4) }
                    if x < width - 1 { relax(i, i - width + 1, 1.4) }
                }
            }
        }
        for y in stride(from: height - 1, through: 0, by: -1) {
            for x in stride(from: width - 1, through: 0, by: -1) {
                let i = y * width + x
                if x < width - 1 { relax(i, i + 1, 1) }
                if y < height - 1 {
                    relax(i, i + width, 1)
                    if x < width - 1 { relax(i, i + width + 1, 1.4) }
                    if x > 0 { relax(i, i + width - 1, 1.4) }
                }
            }
        }
        return d
    }

    private static func nearest(in set: [Bool], to p: (Int, Int), reach: Int, width: Int, height: Int) -> Int? {
        var best: Int?, bestDistance = Int.max
        for dy in -reach...reach {
            for dx in -reach...reach {
                let x = p.0 + dx, y = p.1 + dy
                guard x >= 0, x < width, y >= 0, y < height, set[y * width + x] else { continue }
                if dx * dx + dy * dy < bestDistance { best = y * width + x; bestDistance = dx * dx + dy * dy }
            }
        }
        return best
    }

    private static func component(of set: [Bool], from seed: Int, width: Int, height: Int) -> [Bool] {
        var out = [Bool](repeating: false, count: set.count)
        var stack = [seed]
        out[seed] = true
        while let i = stack.popLast() {
            let x = i % width, y = i / width
            for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)] {
                guard nx >= 0, nx < width, ny >= 0, ny < height else { continue }
                let j = ny * width + nx
                if set[j], !out[j] { out[j] = true; stack.append(j) }
            }
        }
        return out
    }

    private func analysis(for image: CIImage) -> Analysis? {
        let e = image.extent
        guard !e.isInfinite, e.width >= 16, e.height >= 16 else { return nil }
        let key = Self.fingerprint(image)
        if let hit = lock.withLock({ cache[key] }) { return hit }

        guard let cgImage = Self.analysisImage(image) else { return nil }
        let handler = VNImageRequestHandler(cgImage: cgImage)
        let request = VNGenerateForegroundInstanceMaskRequest()
        let bodies = VNDetectHumanRectanglesRequest()
        let faces = VNDetectFaceRectanglesRequest()
        let observation: VNInstanceMaskObservation? = visionLock.withLock {
            (try? handler.perform([request, bodies, faces])) != nil ? request.results?.first : nil
        }
        let people = ((bodies.results ?? []).map(\.boundingBox) + (faces.results ?? []).map(\.boundingBox)).map {
            CGRect(x: $0.minX, y: 1 - $0.maxY, width: $0.width, height: $0.height)
        }
        let analysis = Analysis(observation: observation, handler: handler, people: people)
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
        // Um clique exatamente na margem (1,0) daria `width`, fora do buffer.
        let cx = min(Int(point.x * Double(width)), width - 1)
        let cy = min(Int(point.y * Double(height)), height - 1)
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

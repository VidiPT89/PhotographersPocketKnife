import CoreImage
import CoreImage.CIFilterBuiltins

/// Remove objetos: junta as zonas pintadas e os objetos clicados numa só máscara e preenche-a com o `Inpainter`.
/// As correspondências são calculadas sobre a foto sem ajustes e ficam em cache: mexer nos sliders só volta a copiar píxeis.
final class ObjectRemover: @unchecked Sendable {
    static let shared = ObjectRemover()
    /// Lado maior da região onde são *procuradas* as correspondências: equilíbrio entre qualidade e tempo de resposta.
    static let workingSide: CGFloat = 1100
    /// Lado maior a que a textura é *copiada*. A procura pode correr em pequeno, a cópia não: ampliar o resultado
    /// de 512 px para uma região de 4000 px era o que fazia a remoção parecer um borrão por cima do objeto.
    static let maxFillSide: CGFloat = 2048

    private struct Solution {
        let region: CGRect
        let width: Int
        let height: Int
        let hole: [Bool]
        let field: Inpainter.Field
        /// Resolução a que a textura é copiada: a da região, até ao tecto do `maxFillSide`.
        let fillWidth: Int
        let fillHeight: Int
        let blendMask: CIImage
    }

    /// Preenchimento generativo já feito sobre a foto sem ajustes.
    private struct Generated {
        let filled: CIImage
        let mask: CIImage
        let bounds: CGRect
    }

    /// Esquece as soluções guardadas. A bancada de ensaio precisa disto para medir outra afinação.
    func clearCaches() {
        lock.withLock {
            cache = [:]; order = []
            generatedCache = [:]; generatedOrder = []
        }
    }

    private let lock = NSLock()
    private var cache: [String: Solution] = [:]
    private var order: [String] = []
    private var generatedCache: [String: Generated] = [:]
    private var generatedOrder: [String] = []

    /// `adjust` leva os ajustes da receita a uma imagem sem ajustes, e é por ele que o preenchimento
    /// generativo, feito sobre `reference`, fica com a cor de `image`.
    func apply(_ removals: [Removal], to image: CIImage, reference: CIImage,
               adjust: (CIImage) -> CIImage = { $0 }) -> CIImage {
        let e = image.extent
        guard !removals.isEmpty, !e.isInfinite, e.width >= 16, e.height >= 16 else { return image }
        if let generated = generative(removals, to: image, reference: reference, adjust: adjust) { return generated }
        guard
        let solution = solution(for: removals, reference: reference),
              let current = Self.pixels(of: image, region: solution.region, width: solution.fillWidth, height: solution.fillHeight),
              let patch = Self.image(from: Inpainter.fill(current, hole: solution.hole, field: solution.field), region: solution.region)
        else { return image }
        return patch
            .applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: image, kCIInputMaskImageKey: solution.blendMask])
            .cropped(to: e)
    }

    /// Caminho generativo, quando o modelo está instalado: inventa o que estava por baixo em vez de copiar.
    /// Devolve `nil` se o modelo não estiver lá ou falhar, e nesse caso segue o motor por cópia.
    ///
    /// A máscara vai **alargada**. Uma pincelada apertada deixa metade de uma letra de fora, e o modelo,
    /// ao ser-lhe pedido que preencha só o resto, reconstrói a continuidade com o que sobrou — ou seja,
    /// volta a desenhar a letra. Não é falha do modelo: é o modelo a fazer o que se lhe pede.
    ///
    /// O modelo corre **uma vez**, sobre a foto sem ajustes, e o resultado fica em cache. Corria dentro de
    /// cada render e cada toque num slider custava de novo quase um segundo. Os ajustes chegam ao
    /// preenchimento passando-o pelos mesmos ajustes, só na zona dele.
    private func generative(_ removals: [Removal], to image: CIImage, reference: CIImage,
                            adjust: (CIImage) -> CIImage) -> CIImage? {
        guard GenerativeInpainter.shared.isReady else { return nil }
        let e = image.extent
        let key = Self.key(for: removals, reference: reference)
        let generated: Generated
        if let hit = lock.withLock({ generatedCache[key] }) {
            generated = hit
        } else {
            guard let holeMask = Self.holeMask(for: removals, reference: reference),
                  let bounds = Self.boundingBox(of: holeMask, extent: e) else { return nil }
            // Margem proporcional à espessura do traço, não ao seu comprimento: o que interessa é não deixar
            // a berma do objecto de fora. Uma pincelada que corta um objecto ao meio faz o modelo reconstruir
            // a continuidade com o que sobrou — numa camisola, volta a desenhar as letras. Mas alargar de mais
            // puxa para dentro coisas que não se querem apagar, e aí o buraco é preenchido com elas.
            let grow = min(max(min(bounds.width, bounds.height) * GenerativeInpainter.Tuning.strokeMargin, 6), 20)
            let widened = holeMask.clampedToExtent()
                .applyingFilter("CIMorphologyMaximum", parameters: [kCIInputRadiusKey: grow])
                .cropped(to: e)
            // Junta suave: sem isto via-se a fronteira exacta da máscara.
            let soft = widened.clampedToExtent().applyingGaussianBlur(sigma: 1.5).cropped(to: e)
            let grown = bounds.insetBy(dx: -grow, dy: -grow)
            guard let invented = GenerativeInpainter.shared.fill(reference, mask: soft, bounds: grown) else { return nil }
            // O modelo trabalhou a `side` px sobre a janela maior; numa exportação isso é muito menos do
            // que a foto, e o detalhe vem da própria foto.
            let widest = GenerativeInpainter.windows(for: grown, in: e).map { max($0.width, $0.height) }.max() ?? 1
            let modelScale = CGFloat(GenerativeInpainter.side) / max(widest, 1)
            let filled = GenerativeDetail.sharpen(invented, reference: reference, mask: soft, bounds: grown,
                                                  modelScale: modelScale) ?? invented
            generated = Generated(filled: filled, mask: soft, bounds: grown)
            lock.withLock {
                generatedCache[key] = generated
                generatedOrder.append(key)
                if generatedOrder.count > 3 { generatedCache[generatedOrder.removeFirst()] = nil }
            }
        }
        // Margem para os filtros com raio (nitidez, claridade) terem vizinhança verdadeira na berma.
        let zone = generated.bounds.insetBy(dx: -8, dy: -8).intersection(e)
        let context = zone.insetBy(dx: -64, dy: -64).intersection(e)
        let coloured = adjust(generated.filled.cropped(to: context)).cropped(to: zone)
        let result = coloured
            .applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: image,
                                                            kCIInputMaskImageKey: generated.mask.cropped(to: zone)])
            .cropped(to: e)
        return GenerativeGrain.matching(result, original: image, mask: generated.mask, around: zone)
    }

    private static func key(for removals: [Removal], reference: CIImage) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return SmartSelection.fingerprint(reference) + "|" + String(decoding: (try? encoder.encode(removals)) ?? Data(), as: UTF8.self)
    }

    private func solution(for removals: [Removal], reference: CIImage) -> Solution? {
        let key = Self.key(for: removals, reference: reference)
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

        // A cópia é feita na resolução da própria região, com um tecto para não gastar memória sem fim
        // numa exportação de 45 MP. Nunca abaixo da resolução da procura.
        let fillScale = min(Self.maxFillSide / max(region.width, region.height), 1)
        let fillWidth = max(Int(region.width * fillScale), width)
        let fillHeight = max(Int(region.height * fillScale), height)
        // A junta acompanha a resolução da cópia: com textura nítida, esborratar a margem dava-a a ver.
        let pixelSize = Double(region.width) / Double(fillWidth)
        let blendMask = holeMask.clampedToExtent().applyingGaussianBlur(sigma: max(pixelSize, 1) * 1.2).cropped(to: e)

        let solution = Solution(region: region, width: width, height: height, hole: hole, field: field,
                                fillWidth: fillWidth, fillHeight: fillHeight, blendMask: blendMask)
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
            if let words = wordsTouched(by: raster.image, in: reference) { add(words) }
        }
        for point in removals.compactMap(\.objectPoint) {
            guard let object = SmartSelection.shared.objectMask(for: reference, at: point) else { continue }
            // Alarga um pouco para levar também os contornos e a sombra colada ao objeto.
            let grow = min(max(e.width, e.height) * 0.006, 40)
            add(object.clampedToExtent().applyingFilter("CIMorphologyMaximum", parameters: [kCIInputRadiusKey: grow]).cropped(to: e))
            // A sombra projectada vai com ele, com margem para a berma difusa (penumbra). Proporcional à
            // sombra, não à foto: numa panorâmica, 2 % da foto engolia o que estava na água ao lado.
            if let shadow = CastShadow.mask(for: object, in: reference) {
                add(shadow.clampedToExtent().applyingFilter("CIMorphologyMaximum", parameters: [kCIInputRadiusKey: grow]).cropped(to: e))
            }
        }
        return combined?.cropped(to: e)
    }

    /// Uma pincelada sobre um nome quase nunca o cobre todo: fica o topo das letras de fora, e o modelo, com
    /// meia letra à vista, volta a desenhá-la. Foi a queixa que mais se repetiu. Aqui, cada palavra que a
    /// pincelada cobre em pelo menos um quinto passa a ir inteira, com margem para as bermas das letras.
    static func wordsTouched(by stroke: CIImage, in reference: CIImage) -> CIImage? {
        let words = SmartSelection.shared.words(in: reference)
        guard !words.isEmpty else { return nil }
        let e = reference.extent
        let scale = min(1024 / max(e.width, e.height), 1)
        let width = max(Int(e.width * scale), 1), height = max(Int(e.height * scale), 1)
        guard let painted = pixels(of: stroke, region: e, width: width, height: height) else { return nil }

        var chosen: [[CGPoint]] = []
        for word in words {
            let corners = word.map { CGPoint(x: $0.x * CGFloat(width), y: $0.y * CGFloat(height)) }
            let xs = corners.map(\.x), ys = corners.map(\.y)
            let minX = max(Int(xs.min()!), 0), maxX = min(Int(xs.max()!.rounded(.up)), width - 1)
            let minY = max(Int(ys.min()!), 0), maxY = min(Int(ys.max()!.rounded(.up)), height - 1)
            guard minX <= maxX, minY <= maxY else { continue }
            var inside = 0, covered = 0
            for y in minY...maxY {
                for x in minX...maxX where contains(corners, CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5)) {
                    inside += 1
                    if painted.pixels[(y * width + x) * 3] > 0.5 { covered += 1 }
                }
            }
            if inside > 0, covered * 5 >= inside { chosen.append(corners) }
        }
        guard !chosen.isEmpty,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return nil }
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(gray: 1, alpha: 1)
        for corners in chosen {
            // Margem pequena: a caixa do Vision já apanha as letras, e o caminho generativo ainda alarga a
            // máscara por cima disto. Com um terço da altura, as duas margens somadas comiam as riscas ao lado
            // e o modelo inventava riscas novas.
            let across = CGPoint(x: corners[1].x - corners[0].x, y: corners[1].y - corners[0].y)
            let down = CGPoint(x: corners[3].x - corners[0].x, y: corners[3].y - corners[0].y)
            let tall = hypot(down.x, down.y), long = max(hypot(across.x, across.y), 1)
            let pad = tall / 10
            let u = CGPoint(x: across.x / long * pad, y: across.y / long * pad)
            let v = CGPoint(x: down.x / max(tall, 1) * pad, y: down.y / max(tall, 1) * pad)
            let grown = [(-1.0, -1.0), (1.0, -1.0), (1.0, 1.0), (-1.0, 1.0)].enumerated().map { index, sign in
                CGPoint(x: corners[index].x + sign.0 * u.x + sign.1 * v.x, y: corners[index].y + sign.0 * u.y + sign.1 * v.y)
            }
            // A grelha tem a linha 0 em cima; o contexto desenha com y a crescer para cima.
            context.addLines(between: grown.map { CGPoint(x: $0.x, y: CGFloat(height) - $0.y) })
            context.closePath()
            context.fillPath()
        }
        guard let cg = context.makeImage() else { return nil }
        return CIImage(cgImage: cg)
            .transformed(by: CGAffineTransform(scaleX: e.width / CGFloat(width), y: e.height / CGFloat(height)))
            .transformed(by: CGAffineTransform(translationX: e.minX, y: e.minY))
            .clampedToExtent().applyingGaussianBlur(sigma: 1).cropped(to: e)
    }

    /// Ponto dentro de um quadrilátero convexo, em qualquer sentido de percurso.
    private static func contains(_ polygon: [CGPoint], _ p: CGPoint) -> Bool {
        var sign: CGFloat = 0
        for i in polygon.indices {
            let a = polygon[i], b = polygon[(i + 1) % polygon.count]
            let cross = (b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x)
            if cross != 0 {
                if sign == 0 { sign = cross } else if (cross > 0) != (sign > 0) { return false }
            }
        }
        return true
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

    /// Prepara a foto para os cliques de remoção antes de haver algum: codifica-a com o SAM se estiver
    /// instalado. Sem isto o primeiro clique esperava os segundos da preparação.
    func prepareObjectSelection(url: URL, recipe: EditRecipe, maxPixel: Int) {
        guard SegmentAnything.shared.isReady,
              let base = previewBase(url: url, maxPixel: maxPixel, lensCorrection: recipe.lensCorrection) else { return }
        SegmentAnything.shared.prepare(referenceImage(recipe, input: CIImage(cgImage: base), applyCrop: true))
    }
}

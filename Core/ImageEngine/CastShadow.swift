import CoreImage

/// A sombra que um objecto projecta no chão. Tirar um cão da praia e deixar a sombra dele na areia é o que
/// mais denuncia uma remoção; a selecção do objecto (Vision ou SAM) não a apanha, porque não é o objecto.
///
/// Uma sombra reconhece-se por três coisas, e só as três juntas:
/// - é bem mais **escura** do que o chão à volta (luz directa tapada: em linear, menos de ~65 %);
/// - escurece **todos os canais** sem ficar mais quente do que o chão (ao sol, a sombra é azulada: só a luz
///   do céu a ilumina) — um objecto vermelho ou castanho escuro não passa;
/// - está **colada** ao objecto, nos sítios onde ele toca o chão, e fica à altura do chão (o quarto de
///   baixo do objecto para baixo). Cresce-se a partir daí só por píxeis com as duas primeiras marcas, por
///   isso a sombra de outra coisa ali perto não entra.
/// E fica de fora tudo o que o Vision diz ser objecto: outra pessoa encostada, por escura que seja.
///
/// Só corre onde uma sombra se lê sem dúvida — chão liso e luz dura, de berma nítida. Na água, na terra com
/// ervas ou com luz difusa não tira nada: preferível deixar uma sombra do que apagar o que lá estava.
enum CastShadow {
    /// Lado maior da grelha de análise, na zona à volta do objecto.
    static let side = 384

    /// Máscara da sombra de `object` (branco = objecto) em `photoImage`, ou `nil` se não houver nenhuma clara.
    ///
    /// Analisa-se só a zona à volta do objecto, com resolução própria: com a foto inteira a 512 px, um
    /// surfista numa panorâmica eram 46 píxeis da grelha, e a "sombra" encontrada era a risca de uma onda.
    static func mask(for object: CIImage, in photoImage: CIImage) -> CIImage? {
        let whole = photoImage.extent
        guard let bounds = bounds(of: object, in: whole) else { return nil }
        // A sombra pode ir até à altura do objecto para qualquer lado.
        let reach = max(bounds.width, bounds.height)
        let e = bounds.insetBy(dx: -reach, dy: -reach).intersection(whole).integral
        let scale = CGFloat(side) / max(e.width, e.height)
        let w = max(Int(e.width * scale), 8), h = max(Int(e.height * scale), 8)
        guard let photo = ObjectRemover.pixels(of: photoImage, region: e, width: w, height: h),
              let objectPixels = ObjectRemover.pixels(of: object, region: e, width: w, height: h) else { return nil }
        let isObject = (0..<(w * h)).map { objectPixels.pixels[$0 * 3] > 0.5 }
        let objectArea = isObject.lazy.filter { $0 }.count
        guard objectArea >= 64 else { return nil }
        // Os **outros** objectos do primeiro plano ficam de fora: são coisas, não sombras. A instância do
        // Vision que contém o objecto não conta — às vezes o Vision cola a sombra ao objecto que a projecta.
        var isThing = [Bool](repeating: false, count: w * h)
        if let vision = SmartSelection.shared.instanceLabels(for: photoImage) {
            func label(_ i: Int) -> UInt8 {
                let px = (e.minX - whole.minX + (CGFloat(i % w) + 0.5) / scale) / whole.width
                let py = (whole.maxY - e.maxY + (CGFloat(i / w) + 0.5) / scale) / whole.height
                let vx = min(max(Int(px * CGFloat(vision.width)), 0), vision.width - 1)
                let vy = min(max(Int(py * CGFloat(vision.height)), 0), vision.height - 1)
                return vision.labels[vy * vision.width + vx]
            }
            var under = [Int](repeating: 0, count: 256)
            for i in 0..<(w * h) where isObject[i] { under[Int(label(i))] += 1 }
            for i in 0..<(w * h) {
                let l = Int(label(i))
                isThing[i] = l > 0 && under[l] * 10 < objectArea
            }
        }

        let luma = (0..<(w * h)).map { i -> Float in
            0.2126 * photo.pixels[i * 3] + 0.7152 * photo.pixels[i * 3 + 1] + 0.0722 * photo.pixels[i * 3 + 2]
        }
        // Chão de referência em cada ponto: média local do que não é objecto nem escuro. Duas passagens —
        // na primeira a própria sombra puxa a média para baixo; na segunda já fica de fora.
        let radius = max(Int(sqrt(Double(objectArea)) * 0.8), 6)
        var excluded = (0..<(w * h)).map { isObject[$0] || isThing[$0] }
        var ground = localMean(photo.pixels, excluding: excluded, width: w, height: h, radius: radius)
        for _ in 0..<2 {
            for i in 0..<(w * h) where !isObject[i] && !isThing[i] {
                excluded[i] = luma[i] < 0.65 * lumaOf(ground, i)
            }
            ground = localMean(photo.pixels, excluding: excluded, width: w, height: h, radius: radius)
        }

        // Uma sombra no chão começa onde o objecto toca o chão e fica a essa altura ou abaixo. Sem isto, as
        // cavas escuras entre a espuma, à altura da cintura de um surfista, passavam por sombra.
        var top = h, bottom = -1
        for i in 0..<(w * h) where isObject[i] { top = min(top, i / w); bottom = max(bottom, i / w) }
        let groundLine = bottom - max((bottom - top) / 4, 1)

        // Só em chão liso. Na água agitada ou na terra com ervas, as cavas e os torrões escuros parecem
        // sombra e o crescimento atravessava-os até levar o que estava ao lado. Medido como variação local do
        // brilho do chão (desvio a dividir pela média, em caixas de 9×9): areia 0,12; água 0,21 a 0,23;
        // terra com ervas 0,21. É também no chão liso que uma sombra sem dono se vê.
        guard groundTexture(luma, usable: (0..<(w * h)).map { $0 / w >= groundLine && !excluded[$0] },
                            width: w, height: h) < 0.17 else { return nil }

        func shadowLike(_ i: Int) -> Bool {
            guard i / w >= groundLine, !isObject[i], !isThing[i] else { return false }
            let floor = lumaOf(ground, i)
            guard floor > 1e-4, luma[i] < 0.65 * floor else { return false }
            // A cor de uma sombra ao sol **não** é a do chão: só a luz do céu a ilumina, e fica azulada — na
            // areia da praia de teste, r 0,02 g 0,03 b 0,05 contra r 0,39 g 0,36 b 0,29. O que se mantém é
            // que escurece todos os canais e não fica mais quente do que o chão: o azul, relativamente ao
            // vermelho, nunca desce. Um objecto vermelho ou castanho escuro falha aqui.
            let r = max(photo.pixels[i * 3], 0), b = max(photo.pixels[i * 3 + 2], 0)
            let gr = max(ground[i * 3], 1e-4), gb = max(ground[i * 3 + 2], 1e-4)
            for c in 0..<3 where max(photo.pixels[i * 3 + c], 0) > 0.8 * max(ground[i * 3 + c], 1e-4) { return false }
            return (b + 0.005) / (r + 0.005) >= 0.9 * (gb / gr)
        }

        // Sementes: píxeis parecidos com sombra encostados ao objecto (a 2 píxeis da grelha).
        var inShadow = [Bool](repeating: false, count: w * h)
        var stack: [Int] = []
        for y in 0..<h {
            for x in 0..<w where isObject[y * w + x] {
                for dy in -2...2 {
                    for dx in -2...2 {
                        let nx = x + dx, ny = y + dy
                        guard nx >= 0, nx < w, ny >= 0, ny < h else { continue }
                        let j = ny * w + nx
                        if !inShadow[j], shadowLike(j) { inShadow[j] = true; stack.append(j) }
                    }
                }
            }
        }
        while let i = stack.popLast() {
            let x = i % w, y = i / w
            for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)] {
                guard nx >= 0, nx < w, ny >= 0, ny < h else { continue }
                let j = ny * w + nx
                if !inShadow[j], shadowLike(j) { inShadow[j] = true; stack.append(j) }
            }
        }
        let shadowArea = inShadow.lazy.filter { $0 }.count
        // Nem migalhas (menos de 5 % do objecto: ruído encostado a um pé, a risca de uma onda) nem uma sombra
        // maior do que duas vezes o objecto — isso já
        // é a sombra de uma árvore ou de um prédio, que não é deste objecto.
        guard shadowArea * 20 >= objectArea, shadowArea <= objectArea * 2 else { return nil }
        // Uma sombra de sol tem a berma nítida; o fundo desfocado atrás de uma bola no ar escurece aos poucos.
        // Nitidez = gradiente na berma a dividir pelo salto de brilho (≈ 1 / largura da penumbra, na grelha).
        // Medido: sombra do cão na areia 0,65; fundo desfocado atrás da bola 0,20; sombra difusa sob o sapo 0,29.
        guard edgeSharpness(inShadow, luma: luma, floor: { lumaOf(ground, $0) },
                            skip: { isObject[$0] || isThing[$0] }, width: w, height: h) >= 0.45 else { return nil }

        let gray = inShadow.map { $0 ? UInt8(255) : 0 }
        return CIImage(bitmapData: Data(gray), bytesPerRow: w, size: CGSize(width: w, height: h), format: .L8, colorSpace: nil)
            .transformed(by: CGAffineTransform(scaleX: e.width / CGFloat(w), y: e.height / CGFloat(h)))
            .transformed(by: CGAffineTransform(translationX: e.minX, y: e.minY))
            .clampedToExtent().applyingGaussianBlur(sigma: 1 / scale).cropped(to: e)
            .composited(over: CIImage(color: .black).cropped(to: whole))
    }

    /// Rectângulo do objecto na foto, a partir de uma grelha grosseira.
    private static func bounds(of mask: CIImage, in e: CGRect) -> CGRect? {
        let n = 256
        let scale = CGFloat(n) / max(e.width, e.height)
        let w = max(Int(e.width * scale), 1), h = max(Int(e.height * scale), 1)
        guard let grid = ObjectRemover.pixels(of: mask, region: e, width: w, height: h) else { return nil }
        var minX = w, minY = h, maxX = -1, maxY = -1
        for y in 0..<h {
            for x in 0..<w where grid.pixels[(y * w + x) * 3] > 0.5 {
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= 0 else { return nil }
        // A linha 0 da grelha é o topo; em Core Image o y cresce para cima.
        return CGRect(x: e.minX + CGFloat(minX) / scale, y: e.maxY - CGFloat(maxY + 1) / scale,
                      width: CGFloat(maxX - minX + 1) / scale, height: CGFloat(maxY - minY + 1) / scale)
    }

    /// Mediana, na berma de `region`, do gradiente do brilho a dividir pelo salto até ao chão.
    private static func edgeSharpness(_ region: [Bool], luma: [Float], floor: (Int) -> Float, skip: (Int) -> Bool,
                                      width w: Int, height h: Int) -> Float {
        var ratios: [Float] = []
        for y in 1..<(h - 1) {
            for x in 1..<(w - 1) {
                let i = y * w + x
                guard region[i], [i - 1, i + 1, i - w, i + w].contains(where: { !region[$0] && !skip($0) }) else { continue }
                let step = floor(i) - luma[i]
                guard step > 1e-3 else { continue }
                let gx = (luma[i + 1] - luma[i - 1]) / 2, gy = (luma[i + w] - luma[i - w]) / 2
                ratios.append((gx * gx + gy * gy).squareRoot() / step)
            }
        }
        guard !ratios.isEmpty else { return 0 }
        ratios.sort()
        return ratios[ratios.count / 2]
    }

    /// Mediana, em caixas de 9×9, do desvio do brilho a dividir pela média, só com os pontos utilizáveis.
    private static func groundTexture(_ luma: [Float], usable: [Bool], width w: Int, height h: Int) -> Float {
        var values: [Float] = []
        for by in stride(from: 0, to: h - 8, by: 9) {
            for bx in stride(from: 0, to: w - 8, by: 9) {
                var sum: Float = 0, squares: Float = 0, n: Float = 0
                for y in by..<(by + 9) {
                    for x in bx..<(bx + 9) where usable[y * w + x] {
                        sum += luma[y * w + x]; squares += luma[y * w + x] * luma[y * w + x]; n += 1
                    }
                }
                guard n > 40 else { continue }
                let mean = sum / n
                values.append(max(squares / n - mean * mean, 0).squareRoot() / max(mean, 1e-4))
            }
        }
        guard !values.isEmpty else { return .infinity }
        values.sort()
        return values[values.count / 2]
    }

    private static func lumaOf(_ rgb: [Float], _ i: Int) -> Float {
        0.2126 * rgb[i * 3] + 0.7152 * rgb[i * 3 + 1] + 0.0722 * rgb[i * 3 + 2]
    }

    /// Média de cada ponto numa caixa de raio `radius`, só com os pontos não excluídos (somas integrais).
    private static func localMean(_ rgb: [Float], excluding excluded: [Bool], width w: Int, height h: Int, radius r: Int) -> [Float] {
        var integral = [Double](repeating: 0, count: (w + 1) * (h + 1) * 4)
        for y in 0..<h {
            var row = [Double](repeating: 0, count: 4)
            for x in 0..<w {
                let i = y * w + x
                if !excluded[i] {
                    row[0] += Double(rgb[i * 3]); row[1] += Double(rgb[i * 3 + 1]); row[2] += Double(rgb[i * 3 + 2]); row[3] += 1
                }
                for c in 0..<4 { integral[((y + 1) * (w + 1) + x + 1) * 4 + c] = integral[(y * (w + 1) + x + 1) * 4 + c] + row[c] }
            }
        }
        var out = [Float](repeating: 0, count: w * h * 3)
        for y in 0..<h {
            let y0 = max(y - r, 0), y1 = min(y + r, h - 1) + 1
            for x in 0..<w {
                let x0 = max(x - r, 0), x1 = min(x + r, w - 1) + 1
                func sum(_ c: Int) -> Double {
                    integral[(y1 * (w + 1) + x1) * 4 + c] - integral[(y0 * (w + 1) + x1) * 4 + c]
                        - integral[(y1 * (w + 1) + x0) * 4 + c] + integral[(y0 * (w + 1) + x0) * 4 + c]
                }
                let n = sum(3)
                guard n > 0 else { continue }
                for c in 0..<3 { out[(y * w + x) * 3 + c] = Float(sum(c) / n) }
            }
        }
        return out
    }
}

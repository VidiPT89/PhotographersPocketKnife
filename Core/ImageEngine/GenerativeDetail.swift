import CoreImage

/// Nitidez para os preenchimentos grandes.
///
/// A LaMa trabalha a 800 px. Um objecto que ocupa 3000 px numa exportação é inventado a um quarto da
/// resolução e ampliado, e o preenchimento sai liso ao lado de uma foto nítida. O grão acrescentado
/// disfarça o ruído, mas não a falta de detalhe: numa bancada, as caras continuam borradas.
///
/// Aqui a LaMa decide **o quê** e a própria foto dá **o detalhe**. À resolução a que a LaMa trabalhou,
/// cada ponto do buraco procura na parte verdadeira da foto o patch mais parecido com o que a LaMa
/// inventou (PatchMatch guiado). Essas correspondências copiam textura real na resolução final, com a
/// cópia do `Inpainter`, e do resultado só se aproveita o detalhe fino: a forma e a cor continuam a ser as
/// da LaMa. Assim um patch mal escolhido não traz uma mancha de outra cor, só grão de outro sítio.
///
/// Comparar à resolução da LaMa é o que evita o colapso descrito no `Inpainter`: a essa escala o guia é
/// tão nítido como as origens, e um guia liso não puxa para origens lisas.
enum GenerativeDetail {
    /// Abaixo disto a LaMa já trabalhou quase à resolução da foto e não há detalhe a recuperar.
    static let minimumGain: CGFloat = 1.3
    /// Tecto da resolução a que o detalhe é copiado. Com 2048 ou 4096 uma zona de 7680 px ficava com o
    /// detalhe copiado a metade ou menos, e o grão mais fino — o que se vê a 100 % — perdia-se. Na CPU só
    /// ficam a zona e a cópia (≈ 120 MB cada a 8K); o resto das contas corre na GPU.
    static let maxDetailSide: CGFloat = 8192

    /// `filled` é `reference` já com o buraco preenchido pela LaMa, que trabalhou numa escala de
    /// `modelScale` (píxeis do modelo por píxel da foto). Devolve `filled` com detalhe verdadeiro no buraco,
    /// ou `nil` se não houver ganho ou não houver de onde copiar.
    static func sharpen(_ filled: CIImage, reference: CIImage, mask: CIImage, bounds: CGRect,
                        modelScale: CGFloat) -> CIImage? {
        let e = reference.extent
        guard modelScale > 0, 1 / modelScale >= minimumGain else { return nil }
        // Contexto à volta, para haver origens, sem levar a foto inteira para memória.
        let margin = max(bounds.width, bounds.height) * 0.35
        let region = bounds.insetBy(dx: -margin, dy: -margin).intersection(e).integral
        guard region.width >= 32, region.height >= 32 else { return nil }

        // A procura corre à escala da LaMa, com um tecto: acima de ~480 px o custo cresce sem mudar a escolha,
        // porque a cópia é feita depois na resolução final de qualquer maneira.
        let matchScale = min(modelScale, 480 / max(region.width, region.height))
        let fieldWidth = max(Int(region.width * matchScale), 16), fieldHeight = max(Int(region.height * matchScale), 16)
        guard let source = ObjectRemover.pixels(of: reference, region: region, width: fieldWidth, height: fieldHeight),
              let guide = ObjectRemover.pixels(of: filled, region: region, width: fieldWidth, height: fieldHeight),
              let holePixels = ObjectRemover.pixels(of: mask, region: region, width: fieldWidth, height: fieldHeight)
        else { return nil }
        let hole = (0..<(fieldWidth * fieldHeight)).map { holePixels.pixels[$0 * 3] > 0.5 }
        let field = solveGuided(source, guide: guide, hole: hole)
        guard !field.targets.isEmpty else { return nil }

        let detailScale = min(maxDetailSide / max(region.width, region.height), 1)
        let width = max(Int(region.width * detailScale), fieldWidth), height = max(Int(region.height * detailScale), fieldHeight)
        guard let current = ObjectRemover.pixels(of: reference, region: region, width: width, height: height),
              let copy = ObjectRemover.image(from: Inpainter.fill(current, hole: hole, field: field), region: region)
        else { return nil }
        // Detalhe da cópia = o que ela tem acima da resolução da LaMa: a cópia menos a cópia desfocada à escala
        // de um píxel do modelo. Soma-se à LaMa na GPU, sem trazer mais imagens deste tamanho para a CPU.
        let smooth = copy.clampedToExtent().applyingGaussianBlur(sigma: Double(0.6 / modelScale)).cropped(to: region)
        let detailed = sum(sum(filled.cropped(to: region), copy), negated(smooth)).cropped(to: region)
        return detailed
            .applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: filled,
                                                            kCIInputMaskImageKey: mask.cropped(to: region)])
            .cropped(to: e)
    }

    /// `a + b` exacto. A composição por adição soma também o alfa (duas imagens opacas dão 2) e a matriz
    /// a seguir recebe a cor já dividida por esse alfa; multiplicar por 2 e repor o alfa a 1 desfaz isso.
    private static func sum(_ a: CIImage, _ b: CIImage) -> CIImage {
        a.applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: b])
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 2, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: 2, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 2, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            ])
    }

    /// `−a`, opaca: o `CIColorMatrix` mantém valores negativos num contexto de vírgula flutuante.
    private static func negated(_ a: CIImage) -> CIImage {
        a.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: -1, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: -1, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: -1, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 1),
        ])
    }

    /// PatchMatch (Barnes et al., 2009) com um guia completo: para cada píxel do buraco, a origem fora do
    /// buraco cujo patch em `image` mais se parece com o patch em volta do píxel em `guide`.
    static func solveGuided(_ image: Inpainter.Image, guide: Inpainter.Image, hole: [Bool], radius: Int = 4) -> Inpainter.Field {
        let w = image.width, h = image.height, r = radius
        let empty = Inpainter.Field(width: w, height: h, targets: [], sources: [])
        guard image.pixels.count == w * h * 3, guide.pixels.count == w * h * 3, hole.count == w * h,
              w > 2 * r + 2, h > 2 * r + 2 else { return empty }

        // Origens válidas: patches inteiros fora do buraco.
        var integral = [Int32](repeating: 0, count: (w + 1) * (h + 1))
        for y in 0..<h {
            var row: Int32 = 0
            for x in 0..<w {
                if hole[y * w + x] { row += 1 }
                integral[(y + 1) * (w + 1) + x + 1] = integral[y * (w + 1) + x + 1] + row
            }
        }
        var valid = [Bool](repeating: false, count: w * h)
        var sources: [Int32] = []
        for y in r..<(h - r) {
            for x in r..<(w - r) {
                let holes = integral[(y + r + 1) * (w + 1) + x + r + 1] - integral[(y - r) * (w + 1) + x + r + 1]
                    - integral[(y + r + 1) * (w + 1) + x - r] + integral[(y - r) * (w + 1) + x - r]
                if holes == 0 { valid[y * w + x] = true; sources.append(Int32(y * w + x)) }
            }
        }
        let targets = (0..<(w * h)).filter { hole[$0] }
        guard !sources.isEmpty, !targets.isEmpty else { return empty }

        // Distância com um em cada dois píxeis do patch: metade do trabalho, quase a mesma escolha.
        var offsets: [Int] = []  // (dx, dy) seguidos
        for dy in stride(from: -r, through: r, by: 2) {
            for dx in stride(from: -r, through: r, by: 2) { offsets.append(dx); offsets.append(dy) }
        }
        var rng = SplitMix64(state: 0xD37A_11ED)
        var best = [Int32](repeating: 0, count: w * h)
        var cost = [Float](repeating: .infinity, count: w * h)
        let sourceCount = UInt64(sources.count)

        guide.pixels.withUnsafeBufferPointer { gp in
        image.pixels.withUnsafeBufferPointer { ip in
        offsets.withUnsafeBufferPointer { off in
        valid.withUnsafeBufferPointer { validp in
        hole.withUnsafeBufferPointer { holep in
        best.withUnsafeMutableBufferPointer { bestp in
        cost.withUnsafeMutableBufferPointer { costp in
            func distance(_ t: Int, _ s: Int, _ limit: Float) -> Float {
                let tx = t % w, ty = t / w, sx = s % w, sy = s / w
                var total: Float = 0
                var k = 0
                while k < off.count {
                    let dx = off[k], dy = off[k + 1]
                    k += 2
                    let gx = min(max(tx + dx, 0), w - 1), gy = min(max(ty + dy, 0), h - 1)
                    let g = (gy * w + gx) * 3, o = ((sy + dy) * w + sx + dx) * 3
                    let a = gp[g] - ip[o], b = gp[g + 1] - ip[o + 1], c = gp[g + 2] - ip[o + 2]
                    total += a * a + b * b + c * c
                    if total >= limit { return total }
                }
                return total
            }
            for t in targets {
                let s = Int(sources[Int(rng.next() % sourceCount)])
                bestp[t] = Int32(s)
                costp[t] = distance(t, s, .infinity)
            }
            for iteration in 0..<3 {
                let forward = iteration % 2 == 0
                let step = forward ? -1 : 1
                for k in 0..<targets.count {
                    let t = targets[forward ? k : targets.count - 1 - k]
                    let x = t % w, y = t / w
                    @inline(__always) func consider(_ s: Int) {
                        guard s >= 0, s < w * h, validp[s] else { return }
                        let d = distance(t, s, costp[t])
                        if d < costp[t] { costp[t] = d; bestp[t] = Int32(s) }
                    }
                    // Propagação: o vizinho já tratado nesta passagem, deslocado de volta para aqui.
                    if x + step >= 0, x + step < w, holep[t + step] { consider(Int(bestp[t + step]) - step) }
                    if y + step >= 0, y + step < h, holep[t + step * w] { consider(Int(bestp[t + step * w]) - step * w) }
                    // Procura aleatória em raios cada vez menores à volta da melhor até agora.
                    var reach = max(w, h) / 2
                    while reach >= 1 {
                        let b = Int(bestp[t])
                        let nx = b % w + Int(rng.next() % UInt64(2 * reach + 1)) - reach
                        let ny = b / w + Int(rng.next() % UInt64(2 * reach + 1)) - reach
                        if nx >= 0, nx < w, ny >= 0, ny < h { consider(ny * w + nx) }
                        reach /= 2
                    }
                }
            }
        }}}}}}}
        return Inpainter.Field(width: w, height: h, targets: targets.map { Int32($0) }, sources: targets.map { best[$0] })
    }
}

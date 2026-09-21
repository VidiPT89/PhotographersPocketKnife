import Foundation

/// Preenche uma zona com textura copiada da própria imagem: preenchimento exemplar por camadas
/// (Criminisi et al., 2004), com a procura rápida do PatchMatch (Barnes et al., 2009) à mistura.
///
/// A zona é preenchida de fora para dentro. Em cada passo, os píxeis que já têm vizinhos resolvidos
/// procuram o patch mais parecido **usando só píxeis verdadeiros** e copiam-no inteiro. Nunca se faz média
/// e nunca se compara contra a estimativa: é isso que separa isto de uma mancha da cor média.
///
/// A tentativa anterior (EM com votação, Wexler et al., 2007) colapsava. A média dos patches alisava a zona,
/// um alvo liso passava a emparelhar melhor com uma origem lisa do que com textura, e a iteração seguinte
/// escolhia origens ainda mais lisas. Media-se 5e-10 de energia de gradiente dentro do buraco contra 1e-2 fora:
/// uma mancha perfeitamente lisa. Dar peso à votação por semelhança não resolveu, porque o problema estava
/// no emparelhamento e não na média.
enum Inpainter {
    struct Image: Sendable {
        var width: Int
        var height: Int
        /// RGB, três valores por píxel, linha 0 em cima.
        var pixels: [Float]
    }

    /// Correspondências finais: o centro de cada patch que toca a zona e o centro do patch de onde vem a textura.
    struct Field: Sendable {
        let width: Int
        let height: Int
        let targets: [Int32]
        let sources: [Int32]
    }

    /// Meio-lado do patch, proporcional à zona a preencher.
    ///
    /// Um tamanho fixo não serve as duas pontas. Com 11×11 um buraco de 96×96 era preenchido por 247
    /// cópias de ~37 píxeis cada, vindas de 247 sítios diferentes: numa textura com ruído ninguém dá por
    /// isso, mas num fundo liso — uma bancada, um céu, pele — lê-se como sujidade fina. Poucas cópias
    /// grandes ficam bem; muitas cópias pequenas nunca ficam.
    ///
    /// O custo mantém-se: um patch maior custa mais a comparar mas preenche proporcionalmente mais de
    /// uma vez, por isso o trabalho por píxel preenchido é quase o mesmo.
    static func radius(forHoleOf pixels: Int) -> Int {
        min(max(Int(Double(pixels).squareRoot() / 4), 6), 32)
    }

    static func solve(_ image: Image, hole: [Bool]) -> Field {
        let w = image.width, h = image.height
        let empty = Field(width: w, height: h, targets: [], sources: [])
        guard image.pixels.count == w * h * 3, hole.count == w * h,
              hole.contains(true), hole.contains(false) else { return empty }

        let holeCount = hole.reduce(0) { $0 + ($1 ? 1 : 0) }
        // Numa região estreita o patch tem de caber: sem isto não sobrava nenhuma origem válida.
        let radius = min(Self.radius(forHoleOf: holeCount), (min(w, h) - 1) / 2 - 1)
        guard radius >= 2 else { return empty }

        // Origens possíveis: só patches inteiramente fora da zona. Copiar do que já foi preenchido
        // deixaria o erro multiplicar-se para dentro.
        var valid = [Bool](repeating: false, count: w * h)
        var validSources: [Int32] = []
        var integral = [Int32](repeating: 0, count: (w + 1) * (h + 1))
        for y in 0..<h {
            var row: Int32 = 0
            for x in 0..<w {
                if hole[y * w + x] { row += 1 }
                integral[(y + 1) * (w + 1) + x + 1] = integral[y * (w + 1) + x + 1] + row
            }
        }
        func holes(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int) -> Int32 {
            let ax = max(x0, 0), ay = max(y0, 0), bx = min(x1, w - 1) + 1, by = min(y1, h - 1) + 1
            return integral[by * (w + 1) + bx] - integral[ay * (w + 1) + bx]
                 - integral[by * (w + 1) + ax] + integral[ay * (w + 1) + ax]
        }
        for y in radius..<(h - radius) {
            for x in radius..<(w - radius) where holes(x - radius, y - radius, x + radius, y + radius) == 0 {
                valid[y * w + x] = true
                validSources.append(Int32(y * w + x))
            }
        }
        guard !validSources.isEmpty else { return empty }

        var known = hole.map { !$0 }
        var pixels = image.pixels
        var sourceOf = [Int32](repeating: -1, count: w * h)
        var rng = SplitMix64(state: 0x5EED_CAFE)
        var remaining = holeCount

        while remaining > 0 {
            let layer = boundary(known: known, hole: hole, width: w, height: h)
            guard !layer.isEmpty else { break }
            // Primeiro os que têm mais contexto resolvido à volta: são os que decidem a textura com
            // mais informação, e o que eles escolhem guia quem vem atrás.
            let ordered = layer
                .map { (index: $0, context: knownCount($0, known: known, width: w, height: h, radius: radius)) }
                .sorted { $0.context > $1.context }
            // Uma cópia por vizinhança em cada camada: sem isto, as cópias seguintes só preenchiam as
            // lascas que sobravam das anteriores, cada uma vinda de outro sítio. Numa textura com ruído
            // ninguém dava por isso; num fundo liso lia-se como sujidade fina.
            var claimed = [Bool](repeating: false, count: w * h)
            for entry in ordered where !known[Int(entry.index)] && !claimed[Int(entry.index)] {
                let t = Int(entry.index)
                let cx = t % w, cy = t / w
                for dy in -radius...radius {
                    let yy = cy + dy
                    guard yy >= 0, yy < h else { continue }
                    for dx in -radius...radius {
                        let xx = cx + dx
                        if xx >= 0, xx < w { claimed[yy * w + xx] = true }
                    }
                }
                let source = bestSource(t, pixels: pixels, known: known, sourceOf: sourceOf,
                                        valid: valid, validSources: validSources, width: w, height: h,
                                        radius: radius, rng: &rng)
                remaining -= paste(source, into: t, pixels: &pixels, known: &known,
                                   sourceOf: &sourceOf, width: w, height: h, radius: radius)
            }
        }

        var targets: [Int32] = []
        var sources: [Int32] = []
        targets.reserveCapacity(w * h - validSources.count)
        for i in 0..<(w * h) where hole[i] && sourceOf[i] >= 0 {
            targets.append(Int32(i))
            sources.append(sourceOf[i])
        }
        guard !targets.isEmpty else { return empty }
        return Field(width: w, height: h, targets: targets, sources: sources)
    }

    /// Píxeis ainda por resolver que já têm um vizinho resolvido: a camada seguinte a preencher.
    private static func boundary(known: [Bool], hole: [Bool], width w: Int, height h: Int) -> [Int32] {
        var layer: [Int32] = []
        for y in 0..<h {
            for x in 0..<w where !known[y * w + x] {
                let i = y * w + x
                if (x > 0 && known[i - 1]) || (x < w - 1 && known[i + 1])
                    || (y > 0 && known[i - w]) || (y < h - 1 && known[i + w]) {
                    layer.append(Int32(i))
                }
            }
        }
        return layer
    }

    private static func knownCount(_ t: Int32, known: [Bool], width w: Int, height h: Int, radius: Int) -> Int {
        let tx = Int(t) % w, ty = Int(t) / w
        var n = 0
        for dy in -radius...radius {
            let y = ty + dy
            guard y >= 0, y < h else { continue }
            for dx in -radius...radius {
                let x = tx + dx
                if x >= 0, x < w, known[y * w + x] { n += 1 }
            }
        }
        return n
    }

    /// Copia o patch de origem para os píxeis do alvo que ainda faltam. Devolve quantos ficaram resolvidos.
    private static func paste(_ s: Int, into t: Int, pixels: inout [Float], known: inout [Bool],
                              sourceOf: inout [Int32], width w: Int, height h: Int, radius: Int) -> Int {
        let tx = t % w, ty = t / w, sx = s % w, sy = s / w
        var filled = 0
        for dy in -radius...radius {
            let ay = ty + dy, by = sy + dy
            guard ay >= 0, ay < h, by >= 0, by < h else { continue }
            for dx in -radius...radius {
                let ax = tx + dx, bx = sx + dx
                guard ax >= 0, ax < w, bx >= 0, bx < w else { continue }
                let a = ay * w + ax
                guard !known[a] else { continue }
                let b = by * w + bx
                pixels[a * 3] = pixels[b * 3]
                pixels[a * 3 + 1] = pixels[b * 3 + 1]
                pixels[a * 3 + 2] = pixels[b * 3 + 2]
                known[a] = true
                sourceOf[a] = Int32(b)
                filled += 1
            }
        }
        return filled
    }

    /// Melhor origem para o patch centrado em `t`, comparando **só os píxeis já resolvidos**: propagação a
    /// partir do que os vizinhos escolheram, depois tentativas aleatórias e um afinamento à volta da melhor.
    private static func bestSource(_ t: Int, pixels: [Float], known: [Bool], sourceOf: [Int32],
                                   valid: [Bool], validSources: [Int32], width w: Int, height h: Int,
                                   radius: Int, rng: inout SplitMix64) -> Int {
        let tx = t % w, ty = t / w
        var best = Int(validSources[Int(rng.next() % UInt64(validSources.count))])
        var bestCost = Float.greatestFiniteMagnitude

        pixels.withUnsafeBufferPointer { px in
            known.withUnsafeBufferPointer { kn in
                func consider(_ candidate: Int) {
                    guard candidate >= 0, candidate < w * h, valid[candidate] else { return }
                    let cost = partialDistance(px, kn, w, h, t, candidate, radius)
                    if cost < bestCost {
                        bestCost = cost
                        best = candidate
                    }
                }
                consider(best)
                // O que os vizinhos já resolvidos usaram, deslocado para aqui: é o que mantém a textura contínua.
                for (dx, dy) in [(-1, 0), (1, 0), (0, -1), (0, 1), (-2, 0), (2, 0), (0, -2), (0, 2)] {
                    let nx = tx + dx, ny = ty + dy
                    guard nx >= 0, nx < w, ny >= 0, ny < h else { continue }
                    let s = Int(sourceOf[ny * w + nx])
                    guard s >= 0 else { continue }
                    let cx = s % w - dx, cy = s / w - dy
                    guard cx >= 0, cx < w, cy >= 0, cy < h else { continue }
                    consider(cy * w + cx)
                }
                for _ in 0..<24 {
                    consider(Int(validSources[Int(rng.next() % UInt64(validSources.count))]))
                }
                var reach = max(w, h) / 2
                while reach >= 1 {
                    let cx = min(max(best % w + Int(rng.next() % UInt64(2 * reach + 1)) - reach, 0), w - 1)
                    let cy = min(max(best / w + Int(rng.next() % UInt64(2 * reach + 1)) - reach, 0), h - 1)
                    consider(cy * w + cx)
                    reach /= 2
                }
            }
        }
        return best
    }

    /// Diferença média entre dois patches contando **apenas** os píxeis do alvo que já estão resolvidos.
    /// Comparar contra píxeis por resolver era o que fazia o algoritmo perseguir a sua própria estimativa.
    @inline(__always)
    private static func partialDistance(_ px: UnsafeBufferPointer<Float>, _ known: UnsafeBufferPointer<Bool>,
                                        _ w: Int, _ h: Int, _ t: Int, _ s: Int, _ radius: Int) -> Float {
        let tx = t % w, ty = t / w, sx = s % w, sy = s / w
        var total: Float = 0
        var samples = 0
        for dy in -radius...radius {
            let ay = ty + dy, by = sy + dy
            guard ay >= 0, ay < h, by >= 0, by < h else { continue }
            for dx in -radius...radius {
                let ax = tx + dx, bx = sx + dx
                guard ax >= 0, ax < w, bx >= 0, bx < w, known[ay * w + ax] else { continue }
                let a = (ay * w + ax) * 3, b = (by * w + bx) * 3
                let d0 = px[a] - px[b], d1 = px[a + 1] - px[b + 1], d2 = px[a + 2] - px[b + 2]
                total += d0 * d0 + d1 * d1 + d2 * d2
                samples += 1
            }
        }
        return samples > 0 ? total / Float(samples) : 0
    }

    /// Aplica as correspondências a uma imagem da mesma região (ex. depois de mexer nos sliders). A imagem
    /// pode ser maior do que o campo: a procura corre numa versão reduzida, mas a cópia é feita na resolução
    /// que vem — copiar em pequeno e ampliar depois entregava um borrão em vez de textura.
    ///
    /// Em ambos os casos o deslocamento é **interpolado entre os vizinhos**, nunca escolhido pelo mais próximo.
    /// Dentro de um patch os vizinhos concordam e a cópia é exacta, sem perder nitidez; só na junta entre dois
    /// patches é que discordam, e aí as duas texturas cruzam-se em vez de deixarem um degrau. Sem isto o
    /// preenchimento sai aos quadrados: numa textura com ruído ninguém dá por eles, mas num fundo desfocado
    /// — uma bancada, um céu, pele — cada junta é uma aresta onde não devia haver nenhuma.
    static func fill(_ image: Image, hole: [Bool], field: Field) -> Image {
        guard !field.targets.isEmpty, hole.count == field.width * field.height,
              image.pixels.count == image.width * image.height * 3,
              image.width >= field.width, image.height >= field.height else { return image }
        let fw = field.width, fh = field.height
        var sourceOf = [Int32](repeating: -1, count: fw * fh)
        for k in 0..<field.targets.count { sourceOf[Int(field.targets[k])] = field.sources[k] }
        return image.width == fw && image.height == fh
            ? nativeFill(image, hole: hole, sourceOf: sourceOf)
            : upscaledFill(image, hole: hole, sourceOf: sourceOf, fieldWidth: fw, fieldHeight: fh)
    }

    /// Meio-lado da janela onde os deslocamentos são misturados. Mais estreita do que o patch, para a junta
    /// desaparecer sem levar consigo a textura de dentro do patch.
    private static let blendReach = 4

    private static func nativeFill(_ image: Image, hole: [Bool], sourceOf: [Int32]) -> Image {
        let w = image.width, h = image.height
        var pixels = image.pixels
        image.pixels.withUnsafeBufferPointer { px in
            for y in 0..<h {
                for x in 0..<w where hole[y * w + x] {
                    var r: Float = 0, g: Float = 0, b: Float = 0, total: Float = 0
                    for dy in -blendReach...blendReach {
                        let ny = min(max(y + dy, 0), h - 1)
                        for dx in -blendReach...blendReach {
                            let nx = min(max(x + dx, 0), w - 1)
                            let s = Int(sourceOf[ny * w + nx])
                            guard s >= 0 else { continue }
                            // Deslocamento do vizinho, aplicado à *nossa* posição.
                            let ax = min(max(x + s % w - nx, 0), w - 1)
                            let ay = min(max(y + s / w - ny, 0), h - 1)
                            let weight: Float = 1 / Float(1 + dx * dx + dy * dy)
                            let a = (ay * w + ax) * 3
                            r += px[a] * weight; g += px[a + 1] * weight; b += px[a + 2] * weight
                            total += weight
                        }
                    }
                    guard total > 0 else { continue }
                    let o = (y * w + x) * 3
                    pixels[o] = r / total; pixels[o + 1] = g / total; pixels[o + 2] = b / total
                }
            }
        }
        return Image(width: w, height: h, pixels: pixels)
    }

    private static func upscaledFill(_ image: Image, hole: [Bool], sourceOf: [Int32],
                                     fieldWidth fw: Int, fieldHeight fh: Int) -> Image {
        let w = image.width, h = image.height
        let toField = (x: Double(fw) / Double(w), y: Double(fh) / Double(h))
        let toImage = (x: Double(w) / Double(fw), y: Double(h) / Double(fh))
        var pixels = image.pixels
        image.pixels.withUnsafeBufferPointer { px in
            for y in 0..<h {
                let fyExact = (Double(y) + 0.5) * toField.y - 0.5
                let fy0 = Int(floor(fyExact))
                let ty = Float(fyExact - Double(fy0))
                for x in 0..<w {
                    let fxExact = (Double(x) + 0.5) * toField.x - 0.5
                    let fx0 = Int(floor(fxExact))
                    let tx = Float(fxExact - Double(fx0))
                    let nearest = min(max(fy0 + (ty > 0.5 ? 1 : 0), 0), fh - 1) * fw
                        + min(max(fx0 + (tx > 0.5 ? 1 : 0), 0), fw - 1)
                    guard hole[nearest] else { continue }

                    var r: Float = 0, g: Float = 0, b: Float = 0, total: Float = 0
                    for (cx, cy, weight) in [(fx0, fy0, (1 - tx) * (1 - ty)), (fx0 + 1, fy0, tx * (1 - ty)),
                                             (fx0, fy0 + 1, (1 - tx) * ty), (fx0 + 1, fy0 + 1, tx * ty)] {
                        guard weight > 0 else { continue }
                        let qx = min(max(cx, 0), fw - 1), qy = min(max(cy, 0), fh - 1)
                        let s = Int(sourceOf[qy * fw + qx])
                        guard s >= 0 else { continue }
                        let dx = Int((Double(s % fw - qx) * toImage.x).rounded())
                        let dy = Int((Double(s / fw - qy) * toImage.y).rounded())
                        let ax = min(max(x + dx, 0), w - 1), ay = min(max(y + dy, 0), h - 1)
                        let a = (ay * w + ax) * 3
                        r += px[a] * weight; g += px[a + 1] * weight; b += px[a + 2] * weight
                        total += weight
                    }
                    guard total > 0 else { continue }
                    let o = (y * w + x) * 3
                    pixels[o] = r / total; pixels[o + 1] = g / total; pixels[o + 2] = b / total
                }
            }
        }
        return Image(width: w, height: h, pixels: pixels)
    }

}

/// Gerador pseudo-aleatório determinista (o mesmo resultado em cada render).
private struct SplitMix64 {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

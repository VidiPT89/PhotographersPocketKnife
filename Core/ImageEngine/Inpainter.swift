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

    /// Patches de 7×7.
    static let radius = 3

    static func solve(_ image: Image, hole: [Bool]) -> Field {
        let w = image.width, h = image.height
        let empty = Field(width: w, height: h, targets: [], sources: [])
        guard w > 2 * radius, h > 2 * radius,
              image.pixels.count == w * h * 3, hole.count == w * h,
              hole.contains(true), hole.contains(false) else { return empty }

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
        var remaining = hole.reduce(0) { $0 + ($1 ? 1 : 0) }

        while remaining > 0 {
            let layer = boundary(known: known, hole: hole, width: w, height: h)
            guard !layer.isEmpty else { break }
            // Primeiro os que têm mais contexto resolvido à volta: são os que decidem a textura com
            // mais informação, e o que eles escolhem guia quem vem atrás.
            let ordered = layer
                .map { (index: $0, context: knownCount($0, known: known, width: w, height: h)) }
                .sorted { $0.context > $1.context }
            for entry in ordered where !known[Int(entry.index)] {
                let t = Int(entry.index)
                let source = bestSource(t, pixels: pixels, known: known, sourceOf: sourceOf,
                                        valid: valid, validSources: validSources, width: w, height: h, rng: &rng)
                remaining -= paste(source, into: t, pixels: &pixels, known: &known,
                                   sourceOf: &sourceOf, width: w, height: h)
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

    private static func knownCount(_ t: Int32, known: [Bool], width w: Int, height h: Int) -> Int {
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
                              sourceOf: inout [Int32], width w: Int, height h: Int) -> Int {
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
                                   rng: inout SplitMix64) -> Int {
        let tx = t % w, ty = t / w
        var best = Int(validSources[Int(rng.next() % UInt64(validSources.count))])
        var bestCost = Float.greatestFiniteMagnitude

        pixels.withUnsafeBufferPointer { px in
            known.withUnsafeBufferPointer { kn in
                func consider(_ candidate: Int) {
                    guard candidate >= 0, candidate < w * h, valid[candidate] else { return }
                    let cost = partialDistance(px, kn, w, h, t, candidate)
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
                                        _ w: Int, _ h: Int, _ t: Int, _ s: Int) -> Float {
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

    /// Aplica as correspondências a uma imagem da mesma região (ex. depois de mexer nos sliders). A imagem pode
    /// ser maior do que o campo: as correspondências são procuradas numa versão reduzida, mas a cópia é feita na
    /// resolução que vem — copiar em pequeno e ampliar depois entregava um borrão em vez de textura.
    /// Cada píxel copia o centro do seu patch de origem: a média dos patches deixaria a textura esborratada.
    static func fill(_ image: Image, hole: [Bool], field: Field) -> Image {
        guard !field.targets.isEmpty, hole.count == field.width * field.height,
              image.pixels.count == image.width * image.height * 3,
              image.width >= field.width, image.height >= field.height else { return image }
        if image.width == field.width, image.height == field.height {
            var pixels = image.pixels
            for k in 0..<field.targets.count {
                let t = Int(field.targets[k])
                guard hole[t] else { continue }
                let s = Int(field.sources[k])
                pixels[t * 3] = image.pixels[s * 3]
                pixels[t * 3 + 1] = image.pixels[s * 3 + 1]
                pixels[t * 3 + 2] = image.pixels[s * 3 + 2]
            }
            return Image(width: image.width, height: image.height, pixels: pixels)
        }
        return upscaledFill(image, hole: hole, field: field)
    }

    /// Cópia na resolução nativa a partir de um campo calculado em pequeno: o que se amplia é o *deslocamento*
    /// de cada patch, não os píxeis. Píxeis vizinhos que caem no mesmo ponto do campo herdam o mesmo deslocamento,
    /// por isso o que é copiado é um bocado contínuo de textura verdadeira.
    ///
    /// O deslocamento cresce na mesma proporção nos dois eixos, portanto a origem ampliada cai dentro do píxel de
    /// origem que o `PatchMatch` escolheu (± 1). Como esse só foi aceite com um patch inteiro fora da zona, o
    /// arredondamento nunca chega a ir buscar píxeis ao objeto que está a ser removido.
    private static func upscaledFill(_ image: Image, hole: [Bool], field: Field) -> Image {
        let fw = field.width, fh = field.height
        var sourceOf = [Int32](repeating: -1, count: fw * fh)
        for k in 0..<field.targets.count { sourceOf[Int(field.targets[k])] = field.sources[k] }

        let w = image.width, h = image.height
        let toField = (x: Double(fw) / Double(w), y: Double(fh) / Double(h))
        let toImage = (x: Double(w) / Double(fw), y: Double(h) / Double(fh))
        var pixels = image.pixels
        image.pixels.withUnsafeBufferPointer { px in
            for y in 0..<h {
                let fy = min(Int(Double(y) * toField.y), fh - 1)
                for x in 0..<w {
                    let fx = min(Int(Double(x) * toField.x), fw - 1)
                    let t = fy * fw + fx
                    guard hole[t] else { continue }
                    let s = Int(sourceOf[t])
                    guard s >= 0 else { continue }
                    let dx = Int((Double(s % fw - fx) * toImage.x).rounded())
                    let dy = Int((Double(s / fw - fy) * toImage.y).rounded())
                    let ax = min(max(x + dx, 0), w - 1), ay = min(max(y + dy, 0), h - 1)
                    let a = (ay * w + ax) * 3, b = (y * w + x) * 3
                    pixels[b] = px[a]; pixels[b + 1] = px[a + 1]; pixels[b + 2] = px[a + 2]
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

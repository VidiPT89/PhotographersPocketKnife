import Foundation

/// Preenche uma zona com textura copiada da própria imagem: PatchMatch (Barnes et al., 2009) em várias escalas,
/// com votação de patches (Wexler et al., 2007). Corre no CPU sobre uma região já reduzida.
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
        let empty = Field(width: image.width, height: image.height, targets: [], sources: [])
        guard image.width > 2 * radius, image.height > 2 * radius,
              image.pixels.count == image.width * image.height * 3, hole.count == image.width * image.height,
              hole.contains(true), hole.contains(false) else { return empty }
        var rng = SplitMix64(state: 0x5EED_CAFE)

        // Pirâmide: os níveis pequenos resolvem a estrutura, os grandes o detalhe.
        var levels = [Level(width: image.width, height: image.height, pixels: image.pixels, hole: hole)]
        while let last = levels.last, min(last.width, last.height) >= 48, levels.count < 6 {
            let next = last.downsampled()
            guard next.hole.contains(false), next.hole.contains(true) else { break }
            levels.append(next)
        }

        var previous: (level: Level, geometry: Geometry, sources: [Int32])?
        for depth in stride(from: levels.count - 1, through: 0, by: -1) {
            var level = levels[depth]
            if let previous {
                level.upsampleFill(from: previous.level)
            } else {
                level.diffuseFill()
            }
            let geometry = Geometry(level: level)
            guard !geometry.targets.isEmpty, !geometry.validSources.isEmpty else { return empty }
            var sources = geometry.initialSources(level: level, previous: previous.map { ($0.level, $0.geometry, $0.sources) }, rng: &rng)
            let coarsest = previous == nil
            let emIterations = coarsest ? 6 : (depth == 0 ? 2 : 3)
            for _ in 0..<emIterations {
                patchMatch(level, geometry, sources: &sources, iterations: coarsest ? 4 : 2, rng: &rng)
                level.vote(targets: geometry.targets, sources: sources)
            }
            previous = (level, geometry, sources)
        }
        guard let previous else { return empty }
        return Field(width: image.width, height: image.height, targets: previous.geometry.targets, sources: previous.sources)
    }

    /// Aplica as correspondências a uma imagem com o mesmo tamanho (ex. a mesma região depois de mexer nos sliders).
    /// No resultado final cada píxel copia o centro do seu patch de origem: a média dos patches deixaria a textura esborratada.
    static func fill(_ image: Image, hole: [Bool], field: Field) -> Image {
        guard field.width == image.width, field.height == image.height, !field.targets.isEmpty,
              hole.count == image.width * image.height else { return image }
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

    // MARK: PatchMatch

    private static func patchMatch(_ level: Level, _ geometry: Geometry, sources: inout [Int32], iterations: Int, rng: inout SplitMix64) {
        let w = level.width, h = level.height
        let count = geometry.targets.count
        level.pixels.withUnsafeBufferPointer { px in
            var costs = (0..<count).map { distance(px, w, h, Int(geometry.targets[$0]), Int(sources[$0])) }
            for iteration in 0..<iterations {
                let forward = iteration % 2 == 0
                let step = forward ? 1 : -1
                for n in 0..<count {
                    let k = forward ? n : count - 1 - n
                    let t = Int(geometry.targets[k])
                    let tx = t % w, ty = t / w
                    var best = Int(sources[k])
                    var bestCost = costs[k]

                    func consider(_ candidate: Int) {
                        guard candidate != best, geometry.valid[candidate] else { return }
                        let cost = distance(px, w, h, t, candidate)
                        if cost < bestCost {
                            best = candidate
                            bestCost = cost
                        }
                    }

                    // Propagação: o vizinho já tratado sugere a origem ao lado da dele.
                    let nx = tx - step
                    if nx >= 0, nx < w {
                        let neighbour = geometry.targetIndex[ty * w + nx]
                        if neighbour >= 0 {
                            let s = Int(sources[Int(neighbour)])
                            let sx = s % w + step
                            if sx >= 0, sx < w { consider(s - s % w + sx) }
                        }
                    }
                    let ny = ty - step
                    if ny >= 0, ny < h {
                        let neighbour = geometry.targetIndex[ny * w + tx]
                        if neighbour >= 0 {
                            let s = Int(sources[Int(neighbour)])
                            let sy = s / w + step
                            if sy >= 0, sy < h { consider(sy * w + s % w) }
                        }
                    }

                    // Procura aleatória em janelas cada vez mais pequenas à volta da melhor origem.
                    var reach = max(w, h)
                    while reach >= 1 {
                        let cx = min(max(best % w + Int(rng.next() % UInt64(2 * reach + 1)) - reach, 0), w - 1)
                        let cy = min(max(best / w + Int(rng.next() % UInt64(2 * reach + 1)) - reach, 0), h - 1)
                        consider(cy * w + cx)
                        reach /= 2
                    }
                    consider(Int(geometry.validSources[Int(rng.next() % UInt64(geometry.validSources.count))]))

                    sources[k] = Int32(best)
                    costs[k] = bestCost
                }
            }
        }
    }

    /// Diferença média (RGB ao quadrado) entre dois patches, ignorando o que sai da imagem.
    @inline(__always)
    private static func distance(_ px: UnsafeBufferPointer<Float>, _ w: Int, _ h: Int, _ t: Int, _ s: Int) -> Float {
        let tx = t % w, ty = t / w, sx = s % w, sy = s / w
        var total: Float = 0
        var samples = 0
        for dy in -radius...radius {
            let ay = ty + dy, by = sy + dy
            guard ay >= 0, ay < h, by >= 0, by < h else { continue }
            for dx in -radius...radius {
                let ax = tx + dx, bx = sx + dx
                guard ax >= 0, ax < w, bx >= 0, bx < w else { continue }
                let a = (ay * w + ax) * 3, b = (by * w + bx) * 3
                let d0 = px[a] - px[b], d1 = px[a + 1] - px[b + 1], d2 = px[a + 2] - px[b + 2]
                total += d0 * d0 + d1 * d1 + d2 * d2
                samples += 1
            }
        }
        return samples > 0 ? total / Float(samples) : .greatestFiniteMagnitude
    }

    // MARK: Níveis

    private struct Level {
        let width: Int
        let height: Int
        var pixels: [Float]
        let hole: [Bool]

        /// Metade do tamanho; um píxel é zona se qualquer um dos quatro o for.
        func downsampled() -> Level {
            let w = max(width / 2, 1), h = max(height / 2, 1)
            var out = [Float](repeating: 0, count: w * h * 3)
            var outHole = [Bool](repeating: false, count: w * h)
            for y in 0..<h {
                for x in 0..<w {
                    var sum: (Float, Float, Float) = (0, 0, 0)
                    var known: Float = 0
                    var anyHole = false
                    for dy in 0..<2 {
                        for dx in 0..<2 {
                            let i = min(y * 2 + dy, height - 1) * width + min(x * 2 + dx, width - 1)
                            if hole[i] {
                                anyHole = true
                            } else {
                                sum.0 += pixels[i * 3]; sum.1 += pixels[i * 3 + 1]; sum.2 += pixels[i * 3 + 2]
                                known += 1
                            }
                        }
                    }
                    let o = y * w + x
                    outHole[o] = anyHole
                    if known > 0 {
                        out[o * 3] = sum.0 / known; out[o * 3 + 1] = sum.1 / known; out[o * 3 + 2] = sum.2 / known
                    }
                }
            }
            return Level(width: w, height: h, pixels: out, hole: outHole)
        }

        /// Ponto de partida no nível mais pequeno: a zona enche-se a partir das margens e é suavizada.
        mutating func diffuseFill() {
            var known = hole.map { !$0 }
            var changed = true
            while changed {
                changed = false
                var updates: [(Int, Float, Float, Float)] = []
                for y in 0..<height {
                    for x in 0..<width where !known[y * width + x] {
                        var sum: (Float, Float, Float) = (0, 0, 0)
                        var n: Float = 0
                        for dy in -1...1 {
                            for dx in -1...1 {
                                let nx = x + dx, ny = y + dy
                                guard nx >= 0, nx < width, ny >= 0, ny < height, known[ny * width + nx] else { continue }
                                let j = (ny * width + nx) * 3
                                sum.0 += pixels[j]; sum.1 += pixels[j + 1]; sum.2 += pixels[j + 2]
                                n += 1
                            }
                        }
                        if n > 0 { updates.append((y * width + x, sum.0 / n, sum.1 / n, sum.2 / n)) }
                    }
                }
                for (i, r, g, b) in updates {
                    pixels[i * 3] = r; pixels[i * 3 + 1] = g; pixels[i * 3 + 2] = b
                    known[i] = true
                    changed = true
                }
            }
            for _ in 0..<10 {
                for y in 0..<height {
                    for x in 0..<width where hole[y * width + x] {
                        var sum: (Float, Float, Float) = (0, 0, 0)
                        var n: Float = 0
                        for (dx, dy) in [(-1, 0), (1, 0), (0, -1), (0, 1)] {
                            let nx = x + dx, ny = y + dy
                            guard nx >= 0, nx < width, ny >= 0, ny < height else { continue }
                            let j = (ny * width + nx) * 3
                            sum.0 += pixels[j]; sum.1 += pixels[j + 1]; sum.2 += pixels[j + 2]
                            n += 1
                        }
                        let i = (y * width + x) * 3
                        pixels[i] = sum.0 / n; pixels[i + 1] = sum.1 / n; pixels[i + 2] = sum.2 / n
                    }
                }
            }
        }

        /// Estimativa inicial vinda do nível anterior (mais pequeno).
        mutating func upsampleFill(from coarse: Level) {
            for y in 0..<height {
                for x in 0..<width where hole[y * width + x] {
                    let c = (min(y / 2, coarse.height - 1) * coarse.width + min(x / 2, coarse.width - 1)) * 3
                    let i = (y * width + x) * 3
                    pixels[i] = coarse.pixels[c]; pixels[i + 1] = coarse.pixels[c + 1]; pixels[i + 2] = coarse.pixels[c + 2]
                }
            }
        }

        /// Cada píxel da zona fica com a média do que os patches que o cobrem propõem.
        mutating func vote(targets: [Int32], sources: [Int32]) {
            let w = width, h = height, r = Inpainter.radius
            var accumulated = [Float](repeating: 0, count: w * h * 3)
            var weights = [Float](repeating: 0, count: w * h)
            pixels.withUnsafeBufferPointer { px in
                for k in 0..<targets.count {
                    let t = Int(targets[k]), s = Int(sources[k])
                    let tx = t % w, ty = t / w, sx = s % w, sy = s / w
                    for dy in -r...r {
                        let ay = ty + dy, by = sy + dy
                        guard ay >= 0, ay < h, by >= 0, by < h else { continue }
                        for dx in -r...r {
                            let ax = tx + dx, bx = sx + dx
                            guard ax >= 0, ax < w, bx >= 0, bx < w else { continue }
                            let a = ay * w + ax
                            guard hole[a] else { continue }
                            let b = (by * w + bx) * 3
                            accumulated[a * 3] += px[b]; accumulated[a * 3 + 1] += px[b + 1]; accumulated[a * 3 + 2] += px[b + 2]
                            weights[a] += 1
                        }
                    }
                }
            }
            for i in 0..<(w * h) where hole[i] && weights[i] > 0 {
                pixels[i * 3] = accumulated[i * 3] / weights[i]
                pixels[i * 3 + 1] = accumulated[i * 3 + 1] / weights[i]
                pixels[i * 3 + 2] = accumulated[i * 3 + 2] / weights[i]
            }
        }
    }

    /// Que píxeis precisam de origem (alvos) e que patches podem servir de origem (sem nada da zona).
    private struct Geometry {
        let targets: [Int32]
        /// Posição em `targets` de cada píxel, ou -1.
        let targetIndex: [Int32]
        let valid: [Bool]
        let validSources: [Int32]

        init(level: Level) {
            let w = level.width, h = level.height, r = Inpainter.radius
            var integral = [Int32](repeating: 0, count: (w + 1) * (h + 1))
            for y in 0..<h {
                var row: Int32 = 0
                for x in 0..<w {
                    if level.hole[y * w + x] { row += 1 }
                    integral[(y + 1) * (w + 1) + x + 1] = integral[y * (w + 1) + x + 1] + row
                }
            }
            func holes(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int) -> Int32 {
                let ax = max(x0, 0), ay = max(y0, 0), bx = min(x1, w - 1) + 1, by = min(y1, h - 1) + 1
                return integral[by * (w + 1) + bx] - integral[ay * (w + 1) + bx] - integral[by * (w + 1) + ax] + integral[ay * (w + 1) + ax]
            }

            var targets: [Int32] = []
            var targetIndex = [Int32](repeating: -1, count: w * h)
            var valid = [Bool](repeating: false, count: w * h)
            var validSources: [Int32] = []
            for y in 0..<h {
                for x in 0..<w {
                    let i = y * w + x
                    if holes(x - r, y - r, x + r, y + r) > 0 {
                        targetIndex[i] = Int32(targets.count)
                        targets.append(Int32(i))
                    } else if x >= r, y >= r, x < w - r, y < h - r {
                        valid[i] = true
                        validSources.append(Int32(i))
                    }
                }
            }
            if validSources.isEmpty {
                // Zona demasiado grande para haver patches inteiros: aceita qualquer píxel conhecido.
                for i in 0..<(w * h) where !level.hole[i] {
                    valid[i] = true
                    validSources.append(Int32(i))
                }
            }
            self.targets = targets
            self.targetIndex = targetIndex
            self.valid = valid
            self.validSources = validSources
        }

        /// Começa pelas correspondências do nível anterior (ampliadas); o resto é aleatório.
        func initialSources(level: Level, previous: (level: Level, geometry: Geometry, sources: [Int32])?, rng: inout SplitMix64) -> [Int32] {
            let w = level.width
            return targets.map { t in
                let tx = Int(t) % w, ty = Int(t) / w
                if let previous {
                    let pw = previous.level.width
                    let px = min(tx / 2, pw - 1), py = min(ty / 2, previous.level.height - 1)
                    let k = previous.geometry.targetIndex[py * pw + px]
                    if k >= 0 {
                        let s = Int(previous.sources[Int(k)])
                        let sx = (s % pw) * 2 + tx % 2, sy = (s / pw) * 2 + ty % 2
                        if sx < w, sy < level.height, valid[sy * w + sx] { return Int32(sy * w + sx) }
                    }
                }
                return validSources[Int(rng.next() % UInt64(validSources.count))]
            }
        }
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

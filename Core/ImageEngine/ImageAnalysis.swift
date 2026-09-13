import CoreGraphics

/// Hash perceptual (dHash) para detetar duplicados e quase-duplicados (ex. rajadas).
enum PerceptualHash {
    static func dHash(_ image: CGImage) -> UInt64 {
        let width = 9, height = 8
        var pixels = [UInt8](repeating: 0, count: width * height)
        pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        var hash: UInt64 = 0
        for y in 0..<height {
            for x in 0..<(width - 1) {
                hash <<= 1
                if pixels[y * width + x] > pixels[y * width + x + 1] { hash |= 1 }
            }
        }
        return hash
    }

    static func distance(_ a: UInt64, _ b: UInt64) -> Int {
        (a ^ b).nonzeroBitCount
    }

    /// Agrupa itens com distância ≤ threshold. Só devolve grupos com 2+ elementos.
    static func groups<ID: Hashable>(_ items: [(id: ID, hash: UInt64)], threshold: Int) -> [ID: Int] {
        var parent = Array(items.indices)
        func find(_ i: Int) -> Int {
            var i = i
            while parent[i] != i {
                parent[i] = parent[parent[i]]
                i = parent[i]
            }
            return i
        }
        for i in items.indices {
            for j in (i + 1)..<items.count where distance(items[i].hash, items[j].hash) <= threshold {
                let a = find(i), b = find(j)
                if a != b { parent[b] = a }
            }
        }
        var members: [Int: [Int]] = [:]
        for i in items.indices { members[find(i), default: []].append(i) }

        var result: [ID: Int] = [:]
        var group = 0
        for root in members.keys.sorted() {
            guard let indices = members[root], indices.count > 1 else { continue }
            for i in indices { result[items[i].id] = group }
            group += 1
        }
        return result
    }
}

struct HistogramData: Sendable, Equatable {
    var red: [Float]
    var green: [Float]
    var blue: [Float]
    var luma: [Float]
    /// Fração de píxeis com sombras a preto puro / altas luzes a branco (recorte).
    var clippedShadows: Float = 0
    var clippedHighlights: Float = 0

    static let clippingThreshold: Float = 0.001
}

/// Overlay de recorte: altas luzes a vermelho, sombras a azul (como no Lightroom).
enum ClippingOverlay {
    static func make(from image: CGImage) -> CGImage? {
        let width = image.width, height = image.height
        guard width > 0, height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var source = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = source.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }

        var overlay = [UInt8](repeating: 0, count: width * height * 4)
        for i in stride(from: 0, to: source.count, by: 4) {
            let r = source[i], g = source[i + 1], b = source[i + 2]
            if r >= 254 || g >= 254 || b >= 254 {
                overlay[i] = 230; overlay[i + 1] = 30; overlay[i + 2] = 40; overlay[i + 3] = 230
            } else if r <= 1, g <= 1, b <= 1 {
                overlay[i] = 30; overlay[i + 1] = 110; overlay[i + 2] = 240; overlay[i + 3] = 230
            }
        }
        return overlay.withUnsafeMutableBytes { buffer in
            CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
        }
    }
}

enum Histogram {
    static func compute(_ image: CGImage, maxSide: Int = 256) -> HistogramData {
        let scale = min(1, Double(maxSide) / Double(max(image.width, image.height, 1)))
        let width = max(1, Int(Double(image.width) * scale))
        let height = max(1, Int(Double(image.height) * scale))
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }

        var r = [Float](repeating: 0, count: 256), g = r, b = r, l = r
        var shadowsClipped: Float = 0, highlightsClipped: Float = 0
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let red = pixels[i], green = pixels[i + 1], blue = pixels[i + 2]
            if red >= 254 || green >= 254 || blue >= 254 { highlightsClipped += 1 }
            if red <= 1, green <= 1, blue <= 1 { shadowsClipped += 1 }
            r[Int(red)] += 1
            g[Int(green)] += 1
            b[Int(blue)] += 1
            let luma = 0.2126 * Float(red) + 0.7152 * Float(green) + 0.0722 * Float(blue)
            l[min(255, Int(luma))] += 1
        }
        let peak = max(r.max() ?? 1, g.max() ?? 1, b.max() ?? 1, l.max() ?? 1, 1)
        // Raiz quadrada para os picos não esmagarem o resto do gráfico.
        func normalize(_ bins: [Float]) -> [Float] { bins.map { ($0 / peak).squareRoot() } }
        let total = Float(max(pixels.count / 4, 1))
        return HistogramData(
            red: normalize(r), green: normalize(g), blue: normalize(b), luma: normalize(l),
            clippedShadows: shadowsClipped / total, clippedHighlights: highlightsClipped / total
        )
    }
}

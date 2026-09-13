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
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let red = pixels[i], green = pixels[i + 1], blue = pixels[i + 2]
            r[Int(red)] += 1
            g[Int(green)] += 1
            b[Int(blue)] += 1
            let luma = 0.2126 * Float(red) + 0.7152 * Float(green) + 0.0722 * Float(blue)
            l[min(255, Int(luma))] += 1
        }
        let peak = max(r.max() ?? 1, g.max() ?? 1, b.max() ?? 1, l.max() ?? 1, 1)
        // Raiz quadrada para os picos não esmagarem o resto do gráfico.
        func normalize(_ bins: [Float]) -> [Float] { bins.map { ($0 / peak).squareRoot() } }
        return HistogramData(red: normalize(r), green: normalize(g), blue: normalize(b), luma: normalize(l))
    }
}

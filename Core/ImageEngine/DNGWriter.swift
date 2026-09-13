import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins

/// Escreve um DNG linear (RGB 16 bits, "LinearRaw") com a imagem já editada.
/// O ImageIO lê DNG mas não o escreve, por isso o ficheiro é montado aqui à mão, com a estrutura
/// dos conversores da Adobe: IFD0 = pré-visualização 8 bits; SubIFD = dados lineares de 16 bits.
/// Nota: o ImageIO só reconhece DNG com tamanho realista (ficheiros minúsculos são lidos como TIFF).
enum DNGWriter {
    enum WriteError: LocalizedError {
        case render
        var errorDescription: String? { "Cannot render DNG" }
    }

    static func write(_ image: CIImage, context: CIContext, to url: URL, camera: String?) throws {
        let extent = image.extent.integral
        let width = Int(extent.width), height = Int(extent.height)
        guard width > 0, height > 0 else { throw WriteError.render }

        let rawData = try linearPixels(image, extent: extent, context: context)
        let preview = try previewPixels(image, extent: extent, context: context)
        let model = camera ?? "PhotographersPocketKnife"

        let ifd0: [TIFFEntry] = [
            .long(254, [1]), // pré-visualização
            .long(256, [UInt32(preview.width)]),
            .long(257, [UInt32(preview.height)]),
            .short(258, [8, 8, 8]),
            .short(259, [1]),
            .short(262, [2]),
            .ascii(271, "PhotographersPocketKnife"),
            .ascii(272, model),
            .long(273, [0]),
            .short(274, [1]),
            .short(277, [3]),
            .long(278, [UInt32(preview.height)]),
            .long(279, [UInt32(preview.data.count)]),
            .short(284, [1]),
            .ascii(305, "PhotographersPocketKnife"),
            .ascii(306, dateString()),
            .long(330, [0]), // SubIFDs
            .bytes(50706, [1, 4, 0, 0]),
            .bytes(50707, [1, 1, 0, 0]),
            .ascii(50708, model),
            .srational(50721, xyzToLinearSRGB), // ColorMatrix1
            .rational(50727, [(1, 1), (1, 1), (1, 1)]), // AnalogBalance
            .rational(50728, [(1, 1), (1, 1), (1, 1)]), // AsShotNeutral
            .srational(50730, [0]), // BaselineExposure
            .rational(50731, [(1, 1)]), // BaselineNoise
            .rational(50732, [(1, 1)]), // BaselineSharpness
            .rational(50734, [(1, 1)]), // LinearResponseLimit
            .rational(50739, [(1, 1)]), // ShadowScale
            .short(50778, [21]), // CalibrationIlluminant1 = D65
        ]
        let raw: [TIFFEntry] = [
            .long(254, [0]),
            .long(256, [UInt32(width)]),
            .long(257, [UInt32(height)]),
            .short(258, [16, 16, 16]),
            .short(259, [1]),
            .short(262, [34892]), // LinearRaw
            .long(273, [0]),
            .short(277, [3]),
            .long(278, [UInt32(height)]),
            .long(279, [UInt32(rawData.count)]),
            .short(284, [1]),
            .short(50713, [1, 1]), // BlackLevelRepeatDim
            .long(50714, [0, 0, 0]), // BlackLevel
            .long(50717, [65535, 65535, 65535]), // WhiteLevel
            .rational(50718, [(1, 1), (1, 1)]), // DefaultScale
            .long(50719, [0, 0]), // DefaultCropOrigin
            .long(50720, [UInt32(width), UInt32(height)]), // DefaultCropSize
            .rational(50780, [(1, 1)]), // BestQualityScale
            .long(50829, [0, 0, UInt32(height), UInt32(width)]), // ActiveArea
        ]

        try TIFFBuilder.build(ifds: [ifd0, raw], strips: [preview.data, rawData]).write(to: url, options: .atomic)
    }

    /// RGB linear de 16 bits, linha 0 = topo.
    private static func linearPixels(_ image: CIImage, extent: CGRect, context: CIContext) throws -> Data {
        let width = Int(extent.width), height = Int(extent.height)
        guard let linear = CGColorSpace(name: CGColorSpace.linearSRGB),
              let rendered = context.createCGImage(image, from: extent, format: .RGBA16, colorSpace: linear) else {
            throw WriteError.render
        }
        var rgba = [UInt16](repeating: 0, count: width * height * 4)
        let drawn = rgba.withUnsafeMutableBytes { buffer -> Bool in
            guard let bitmap = CGContext(
                data: buffer.baseAddress, width: width, height: height,
                bitsPerComponent: 16, bytesPerRow: width * 8, space: linear,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue
            ) else { return false }
            bitmap.draw(rendered, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { throw WriteError.render }

        var data = Data(count: width * height * 6)
        data.withUnsafeMutableBytes { out in
            let dst = out.bindMemory(to: UInt16.self)
            for p in 0..<(width * height) {
                dst[p * 3] = rgba[p * 4].littleEndian
                dst[p * 3 + 1] = rgba[p * 4 + 1].littleEndian
                dst[p * 3 + 2] = rgba[p * 4 + 2].littleEndian
            }
        }
        return data
    }

    /// Pré-visualização sRGB de 8 bits com o lado maior ≤ 256 px.
    private static func previewPixels(_ image: CIImage, extent: CGRect, context: CIContext) throws -> (data: Data, width: Int, height: Int) {
        let scale = min(1, 256 / max(extent.width, extent.height))
        let width = max(1, Int((extent.width * scale).rounded()))
        let height = max(1, Int((extent.height * scale).rounded()))
        guard let sRGB = CGColorSpace(name: CGColorSpace.sRGB),
              let rendered = context.createCGImage(image, from: extent, format: .RGBA8, colorSpace: sRGB) else {
            throw WriteError.render
        }
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = rgba.withUnsafeMutableBytes { buffer -> Bool in
            guard let bitmap = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            bitmap.interpolationQuality = .high
            bitmap.draw(rendered, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { throw WriteError.render }
        var data = Data(capacity: width * height * 3)
        for p in 0..<(width * height) {
            data.append(contentsOf: [rgba[p * 4], rgba[p * 4 + 1], rgba[p * 4 + 2]])
        }
        return (data, width, height)
    }

    private static func dateString() -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: Date())
        return String(format: "%04d:%02d:%02d %02d:%02d:%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
    }

    /// Inversa da matriz sRGB→XYZ (D65).
    private static let xyzToLinearSRGB: [Double] = [
        3.2404542, -1.5371385, -0.4985314,
        -0.9692660, 1.8760108, 0.0415560,
        0.0556434, -0.2040259, 1.0572252,
    ]
}

private struct TIFFEntry {
    let tag: UInt16
    let type: UInt16
    let count: UInt32
    var value: Data

    static func bytes(_ tag: UInt16, _ values: [UInt8]) -> TIFFEntry {
        TIFFEntry(tag: tag, type: 1, count: UInt32(values.count), value: Data(values))
    }

    static func ascii(_ tag: UInt16, _ string: String) -> TIFFEntry {
        let data = Data(string.utf8) + Data([0])
        return TIFFEntry(tag: tag, type: 2, count: UInt32(data.count), value: data)
    }

    static func short(_ tag: UInt16, _ values: [UInt16]) -> TIFFEntry {
        var data = Data()
        values.forEach { data.appendLE($0) }
        return TIFFEntry(tag: tag, type: 3, count: UInt32(values.count), value: data)
    }

    static func long(_ tag: UInt16, _ values: [UInt32]) -> TIFFEntry {
        var data = Data()
        values.forEach { data.appendLE($0) }
        return TIFFEntry(tag: tag, type: 4, count: UInt32(values.count), value: data)
    }

    static func rational(_ tag: UInt16, _ values: [(UInt32, UInt32)]) -> TIFFEntry {
        var data = Data()
        values.forEach { data.appendLE($0.0); data.appendLE($0.1) }
        return TIFFEntry(tag: tag, type: 5, count: UInt32(values.count), value: data)
    }

    static func srational(_ tag: UInt16, _ values: [Double]) -> TIFFEntry {
        var data = Data()
        values.forEach {
            data.appendLE(UInt32(bitPattern: Int32(($0 * 10_000).rounded())))
            data.appendLE(UInt32(10_000))
        }
        return TIFFEntry(tag: tag, type: 10, count: UInt32(values.count), value: data)
    }
}

/// Monta um TIFF little-endian: IFD0 (com SubIFDs a apontar para os restantes IFDs), dados extra e strips no fim.
private enum TIFFBuilder {
    static func build(ifds input: [[TIFFEntry]], strips: [Data]) -> Data {
        var ifds = input.map { $0.sorted { $0.tag < $1.tag } }

        // 1.ª passagem: posições de cada IFD, dos valores com mais de 4 bytes e das strips.
        var position = 8
        var ifdOffsets: [Int] = []
        var extraOffsets: [[Int: Int]] = []
        for ifd in ifds {
            ifdOffsets.append(position)
            position += 2 + ifd.count * 12 + 4
            var offsets: [Int: Int] = [:]
            for (index, entry) in ifd.enumerated() where entry.value.count > 4 {
                offsets[index] = position
                position += entry.value.count + entry.value.count % 2
            }
            extraOffsets.append(offsets)
        }
        var stripOffsets: [Int] = []
        for strip in strips {
            stripOffsets.append(position)
            position += strip.count
        }

        // 2.ª passagem: preenche StripOffsets e SubIFDs (valores LONG inline, não mudam o layout).
        for k in ifds.indices {
            for i in ifds[k].indices {
                if ifds[k][i].tag == 273 { ifds[k][i] = .long(273, [UInt32(stripOffsets[k])]) }
                if ifds[k][i].tag == 330 { ifds[k][i] = .long(330, ifdOffsets.dropFirst().map { UInt32($0) }) }
            }
        }

        var file = Data([0x49, 0x49, 42, 0])
        file.appendLE(UInt32(8))
        for k in ifds.indices {
            file.appendLE(UInt16(ifds[k].count))
            for (index, entry) in ifds[k].enumerated() {
                file.appendLE(entry.tag)
                file.appendLE(entry.type)
                file.appendLE(entry.count)
                if let offset = extraOffsets[k][index] {
                    file.appendLE(UInt32(offset))
                } else {
                    file.append(entry.value + Data(count: 4 - entry.value.count))
                }
            }
            file.appendLE(UInt32(0)) // SubIFDs não fazem parte da cadeia principal
            for (index, entry) in ifds[k].enumerated() where extraOffsets[k][index] != nil {
                file.append(entry.value)
                if entry.value.count % 2 == 1 { file.append(0) }
            }
        }
        strips.forEach { file.append($0) }
        return file
    }
}

private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}

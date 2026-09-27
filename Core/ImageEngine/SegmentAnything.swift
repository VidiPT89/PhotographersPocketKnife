import CoreImage
import CoreML
import Foundation

/// Seleção por clique com o SAM 2.1 (Meta, Apache-2.0), na conversão para Core ML feita pela Apple.
///
/// O Vision junta num só objecto tudo o que se toca: numa jogada, os jogadores e a bola eram uma peça, e
/// clicar num tirava todos. O SAM segmenta *o que está debaixo do clique* e devolve três leituras — uma
/// parte pequena, uma parte maior, o objecto inteiro —, com bermas justas. Quem escolhe entre elas é o
/// `SmartSelection`, que sabe se o clique caiu numa pessoa.
///
/// São três modelos (93 MB no total), descarregados uma vez para Application Support como a LaMa. O
/// codificador de imagem corre uma vez por foto (~1 a 3 s) e fica em cache; cada clique depois são ms.
final class SegmentAnything: @unchecked Sendable {
    static let shared = SegmentAnything()

    /// Revisão fixa do repositório: um modelo que mudasse por baixo mudaria as selecções sem aviso.
    static let source = "https://huggingface.co/apple/coreml-sam2.1-small/resolve/883f5787eb0be35ce6965907a8bc1f5320a5a02e/"
    static let names = ["SAM2_1SmallImageEncoderFLOAT16", "SAM2_1SmallPromptEncoderFLOAT16", "SAM2_1SmallMaskDecoderFLOAT16"]
    private static let files = ["Manifest.json", "Data/com.apple.CoreML/model.mlmodel", "Data/com.apple.CoreML/weights/weight.bin"]
    static let downloadBytes: Int64 = 93_600_000
    /// Lado da imagem que o codificador recebe, e da grelha das máscaras que o descodificador devolve.
    static let side = 1024
    static let maskSide = 256

    enum SegmentError: LocalizedError {
        case downloadFailed

        var errorDescription: String? { "Could not download the model" }
    }

    /// Uma leitura do clique: a máscara na extensão da foto, a nota que o modelo lhe dá e a grelha 256×256
    /// (linha 0 em cima) para comparar com outras máscaras.
    struct Candidate {
        let mask: CIImage
        let score: Float
        let grid: [Bool]
        var area: Int { grid.lazy.filter { $0 }.count }
    }

    private struct Models {
        let encoder: MLModel
        let prompt: MLModel
        let decoder: MLModel
    }

    private let lock = NSLock()
    private var loaded: Models?
    private var embeddingKey: String?
    private var embedding: MLFeatureProvider?

    static var directory: URL { GenerativeInpainter.supportDirectory.appendingPathComponent("SAM2", isDirectory: true) }
    private static func compiledURL(_ name: String) -> URL { directory.appendingPathComponent("\(name).mlmodelc", isDirectory: true) }

    var isInstalled: Bool { Self.names.allSatisfy { FileManager.default.fileExists(atPath: Self.compiledURL($0).path) } }

    var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "selection.segmentAnything") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "selection.segmentAnything") }
    }

    var isReady: Bool { isInstalled && isEnabled }

    func remove() {
        lock.withLock { loaded = nil; embedding = nil; embeddingKey = nil }
        try? FileManager.default.removeItem(at: Self.directory)
    }

    // MARK: Instalação

    /// Descarrega e compila os três modelos. `progress` vai de 0 a 1.
    func install(progress: @Sendable @escaping (Double) -> Void) async throws {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("ppk-sam-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: work) }
        var received: Int64 = 0
        for name in Self.names {
            for file in Self.files {
                guard let url = URL(string: Self.source + "\(name).mlpackage/" + file) else { throw SegmentError.downloadFailed }
                let destination = work.appendingPathComponent("\(name).mlpackage/\(file)")
                try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                let (temporary, response) = try await URLSession.shared.download(from: url)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw SegmentError.downloadFailed }
                try fm.moveItem(at: temporary, to: destination)
                received += Int64((try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                progress(min(Double(received) / Double(Self.downloadBytes), 1) * 0.9)
            }
        }
        try fm.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        for name in Self.names {
            // Compilar deixa o modelo pronto a carregar; sem isto pagava-se a compilação em cada arranque.
            let compiled = try await MLModel.compileModel(at: work.appendingPathComponent("\(name).mlpackage"))
            if fm.fileExists(atPath: Self.compiledURL(name).path) { try? fm.removeItem(at: Self.compiledURL(name)) }
            try fm.moveItem(at: compiled, to: Self.compiledURL(name))
        }
        progress(1)
    }

    // MARK: Utilização

    private func models() -> Models? {
        lock.withLock {
            if let loaded { return loaded }
            guard isInstalled else { return nil }
            let configuration = MLModelConfiguration()
            configuration.computeUnits = .cpuAndGPU
            guard let encoder = try? MLModel(contentsOf: Self.compiledURL(Self.names[0]), configuration: configuration),
                  let prompt = try? MLModel(contentsOf: Self.compiledURL(Self.names[1]), configuration: configuration),
                  let decoder = try? MLModel(contentsOf: Self.compiledURL(Self.names[2]), configuration: configuration)
            else { return nil }
            loaded = Models(encoder: encoder, prompt: prompt, decoder: decoder)
            return loaded
        }
    }

    /// As três leituras do objecto no ponto (normalizado, origem em cima à esquerda), ou `nil` se o
    /// modelo não estiver instalado ou falhar.
    func candidates(for image: CIImage, at point: CurvePoint) -> [Candidate]? {
        let e = image.extent
        guard isReady, !e.isInfinite, e.width >= 16, e.height >= 16, let models = models(),
              let embedding = embedding(of: image, with: models.encoder) else { return nil }
        guard let points = try? MLMultiArray(shape: [1, 1, 2], dataType: .float32),
              let labels = try? MLMultiArray(shape: [1, 1], dataType: .int32) else { return nil }
        points[0] = NSNumber(value: min(max(point.x, 0), 1) * Double(Self.side))
        points[1] = NSNumber(value: min(max(point.y, 0), 1) * Double(Self.side))
        labels[0] = 1
        guard let prompt = try? models.prompt.prediction(from: MLDictionaryFeatureProvider(dictionary: ["points": points, "labels": labels])),
              let sparse = prompt.featureValue(for: "sparse_embeddings"), let dense = prompt.featureValue(for: "dense_embeddings"),
              let imageEmbedding = embedding.featureValue(for: "image_embedding"),
              let s0 = embedding.featureValue(for: "feats_s0"), let s1 = embedding.featureValue(for: "feats_s1"),
              let decoded = try? models.decoder.prediction(from: MLDictionaryFeatureProvider(dictionary: [
                  "image_embedding": imageEmbedding, "feats_s0": s0, "feats_s1": s1,
                  "sparse_embedding": sparse, "dense_embedding": dense,
              ])),
              let masks = decoded.featureValue(for: "low_res_masks")?.multiArrayValue,
              let scores = decoded.featureValue(for: "scores")?.multiArrayValue else { return nil }

        let n = Self.maskSide
        let strides = masks.strides.map(\.intValue)
        return (0..<min(masks.shape[1].intValue, 3)).map { k in
            var logits = [Float](repeating: 0, count: n * n)
            let base = masks.dataPointer
            for y in 0..<n {
                for x in 0..<n {
                    let i = k * strides[1] + y * strides[2] + x * strides[3]
                    logits[y * n + x] = masks.dataType == .float16
                        ? Self.float(half: base.load(fromByteOffset: i * 2, as: UInt16.self))
                        : base.load(fromByteOffset: i * 4, as: Float.self)
                }
            }
            return Candidate(mask: Self.mask(from: logits, extent: e), score: scores[[0, k] as [NSNumber]].floatValue,
                             grid: logits.map { $0 > 0 })
        }
    }

    /// Codificação da foto, guardada para os cliques seguintes na mesma foto.
    private func embedding(of image: CIImage, with encoder: MLModel) -> MLFeatureProvider? {
        let key = SmartSelection.fingerprint(image)
        if let hit = lock.withLock({ embeddingKey == key ? embedding : nil }) { return hit }
        let e = image.extent
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, Self.side, Self.side, kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
        guard let buffer else { return nil }
        // A foto inteira esticada para o quadrado do modelo, em sRGB como os ficheiros com que ele aprendeu.
        let squared = image
            .transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
            .transformed(by: CGAffineTransform(scaleX: CGFloat(Self.side) / e.width, y: CGFloat(Self.side) / e.height))
        ImageRenderer.shared.context.render(squared, to: buffer, bounds: CGRect(x: 0, y: 0, width: Self.side, height: Self.side),
                                            colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        guard let result = try? encoder.prediction(from: MLDictionaryFeatureProvider(dictionary: ["image": MLFeatureValue(pixelBuffer: buffer)]))
        else { return nil }
        lock.withLock { embeddingKey = key; embedding = result }
        return result
    }

    /// Meia precisão (IEEE 754 binário16) para `Float`, sem depender do `Float16`, que o alvo da app não tem.
    static func float(half bits: UInt16) -> Float {
        let sign = UInt32(bits & 0x8000) << 16
        let exponent = UInt32(bits >> 10) & 0x1F
        let mantissa = UInt32(bits & 0x3FF)
        if exponent == 0 {
            return (sign != 0 ? -1 : 1) * Float(mantissa) * powf(2, -24)  // subnormal
        }
        if exponent == 31 { return Float(bitPattern: sign | 0x7F80_0000 | (mantissa << 13)) }
        return Float(bitPattern: sign | ((exponent + 112) << 23) | (mantissa << 13))
    }

    /// Logits 256×256 → máscara na extensão da foto. Amplia-se o logit, não a máscara já cortada, e só
    /// depois se corta em zero: a berma fica onde o modelo a pôs em vez de aos degraus de 256.
    private static func mask(from logits: [Float], extent e: CGRect) -> CIImage {
        let n = maskSide
        var rgba = [Float](repeating: 1, count: n * n * 4)
        for i in 0..<(n * n) { rgba[i * 4] = logits[i]; rgba[i * 4 + 1] = logits[i]; rgba[i * 4 + 2] = logits[i] }
        let raw = CIImage(bitmapData: rgba.withUnsafeBufferPointer { Data(buffer: $0) }, bytesPerRow: n * 16,
                          size: CGSize(width: n, height: n), format: .RGBAf, colorSpace: nil)
        return raw
            .transformed(by: CGAffineTransform(scaleX: e.width / CGFloat(n), y: e.height / CGFloat(n)))
            .transformed(by: CGAffineTransform(translationX: e.minX, y: e.minY))
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 4, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 4, y: 0, z: 0, w: 0),
                "inputBVector": CIVector(x: 4, y: 0, z: 0, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputBiasVector": CIVector(x: 0.5, y: 0.5, z: 0.5, w: 1),
            ])
            .applyingFilter("CIColorClamp")
            .cropped(to: e)
    }
}

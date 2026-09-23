import CoreImage
import CoreML
import Foundation

/// Preenchimento generativo: em vez de copiar textura de outro sítio da foto, **inventa** o que estava por
/// baixo do que foi apagado. É a LaMa (Suvorov et al., WACV 2022) convertida para Core ML, a correr no Mac.
///
/// O `Inpainter` por cópia continua a existir e é instantâneo — serve bem céu, relva ou uma bancada
/// desfocada. Este entra onde aquele nunca poderia chegar: texto, riscas, rostos, linhas rectas. Copiar
/// escolhe o que melhor encaixa com a vizinhança, e apagar metade de um nome tem as outras letras por
/// vizinhança; é por isso que elas voltavam.
///
/// O modelo (99 MB, Apache-2.0) não vem no repositório nem na app: é descarregado uma vez e guardado em
/// Application Support.
final class GenerativeInpainter: @unchecked Sendable {
    static let shared = GenerativeInpainter()

    /// Esta conversão da LaMa tem tamanho fixo, ao contrário do modelo original que aceita qualquer
    /// resolução. Trabalha-se numa janela quadrada à volta da zona e cola-se de volta.
    static let side = 800
    static let downloadURL = URL(string: "https://huggingface.co/Jia-Liu/big-lama-coreml/resolve/main/big-lama-coreml.zip")!
    static let downloadBytes: Int64 = 94_000_000

    enum InpaintError: LocalizedError {
        case unpackFailed
        case modelMissing

        var errorDescription: String? {
            switch self {
            case .unpackFailed: "Could not unpack the model"
            case .modelMissing: "The model is not installed"
            }
        }
    }

    private let lock = NSLock()
    private var loaded: MLModel?

    static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("PhotographersPocketKnife/Models", isDirectory: true)
    }

    static var modelURL: URL { supportDirectory.appendingPathComponent("LaMa.mlmodelc", isDirectory: true) }

    var isInstalled: Bool { FileManager.default.fileExists(atPath: Self.modelURL.path) }

    func installedBytes() -> Int64 {
        guard let e = FileManager.default.enumerator(at: Self.modelURL, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in e {
            total += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    func remove() {
        lock.withLock { loaded = nil }
        try? FileManager.default.removeItem(at: Self.modelURL)
    }

    // MARK: Instalação

    /// Descarrega, descompacta e compila o modelo. `progress` vai de 0 a 1.
    func install(progress: @Sendable @escaping (Double) -> Void) async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: Self.supportDirectory, withIntermediateDirectories: true)
        let work = fm.temporaryDirectory.appendingPathComponent("ppk-lama-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }

        let zip = work.appendingPathComponent("model.zip")
        try await download(to: zip, progress: { progress($0 * 0.85) })

        // O `unzip` do sistema chega e evita trazer uma dependência só para isto.
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        unzip.arguments = ["-q", "-o", zip.path, "-d", work.path]
        try unzip.run()
        unzip.waitUntilExit()
        progress(0.9)

        guard let package = fm.enumerator(at: work, includingPropertiesForKeys: nil)?
            .compactMap({ $0 as? URL })
            .first(where: { $0.pathExtension == "mlpackage" }) else { throw InpaintError.unpackFailed }

        // Compilar deixa o modelo pronto a carregar; sem isto pagava-se a compilação em cada arranque.
        let compiled = try await MLModel.compileModel(at: package)
        if fm.fileExists(atPath: Self.modelURL.path) { try? fm.removeItem(at: Self.modelURL) }
        try fm.moveItem(at: compiled, to: Self.modelURL)
        progress(1)
    }

    private func download(to destination: URL, progress: @Sendable @escaping (Double) -> Void) async throws {
        let (bytes, response) = try await URLSession.shared.bytes(from: Self.downloadURL)
        let expected = response.expectedContentLength > 0 ? response.expectedContentLength : Self.downloadBytes
        var data = Data()
        data.reserveCapacity(Int(expected))
        var lastReported = 0.0
        for try await byte in bytes {
            data.append(byte)
            let done = Double(data.count) / Double(expected)
            if done - lastReported > 0.01 {
                lastReported = done
                progress(min(done, 1))
            }
        }
        try data.write(to: destination)
    }

    // MARK: Utilização

    private func model() -> MLModel? {
        lock.withLock {
            if let loaded { return loaded }
            guard isInstalled else { return nil }
            let configuration = MLModelConfiguration()
            configuration.computeUnits = .all
            loaded = try? MLModel(contentsOf: Self.modelURL, configuration: configuration)
            return loaded
        }
    }

    /// Com o modelo instalado, dá para o desligar: o motor por cópia é instantâneo e chega para céu,
    /// relva ou uma bancada desfocada, enquanto este leva perto de um segundo.
    var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: Keys.enabled) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Keys.enabled) }
    }

    var isReady: Bool { isInstalled && isEnabled }

    private enum Keys {
        static let enabled = "removal.generative"
    }

    /// Preenche `bounds` (na extensão de `image`) com conteúdo inventado. `mask` é branco onde apagar.
    /// Devolve `nil` se o modelo não estiver instalado ou algo correr mal — quem chama volta ao motor por cópia.
    func fill(_ image: CIImage, mask: CIImage, bounds: CGRect) -> CIImage? {
        let e = image.extent
        guard let model = model(), !e.isInfinite, bounds.width >= 2, bounds.height >= 2 else { return nil }

        // Janela quadrada com contexto à volta da zona: o modelo precisa de ver o que a rodeia para
        // inventar algo que continue a foto.
        let padding = max(bounds.width, bounds.height)
        let windowSide = min(max(bounds.width, bounds.height) + padding * 2, min(e.width, e.height))
        let originX = min(max(bounds.midX - windowSide / 2, e.minX), e.maxX - windowSide)
        let originY = min(max(bounds.midY - windowSide / 2, e.minY), e.maxY - windowSide)
        let window = CGRect(x: originX, y: originY, width: windowSide, height: windowSide).integral

        let side = Self.side
        guard let photo = Self.samples(of: image, region: window, side: side),
              let holes = Self.samples(of: mask, region: window, side: side) else { return nil }

        guard let input = try? MLMultiArray(shape: [1, 3, NSNumber(value: side), NSNumber(value: side)], dataType: .float32),
              let holeInput = try? MLMultiArray(shape: [1, 1, NSNumber(value: side), NSNumber(value: side)], dataType: .float32)
        else { return nil }

        let plane = side * side
        input.withUnsafeMutableBufferPointer(ofType: Float.self) { buffer, _ in
            for i in 0..<plane {
                buffer[i] = photo[i * 4]
                buffer[plane + i] = photo[i * 4 + 1]
                buffer[2 * plane + i] = photo[i * 4 + 2]
            }
        }
        holeInput.withUnsafeMutableBufferPointer(ofType: Float.self) { buffer, _ in
            for i in 0..<plane { buffer[i] = holes[i * 4] > 0.5 ? 1 : 0 }
        }

        guard let features = try? MLDictionaryFeatureProvider(dictionary: ["image": input, "mask": holeInput]),
              let prediction = try? model.prediction(from: features),
              let output = prediction.featureValue(for: "output")?.multiArrayValue else { return nil }

        var rgba = [Float](repeating: 1, count: plane * 4)
        output.withUnsafeBufferPointer(ofType: Float.self) { buffer in
            // A entrada vai em 0…1 mas a saída desta conversão vem em 0…255. Confirma-se pela amplitude
            // em vez de se assumir: outra conversão do mesmo modelo pode devolver 0…1.
            var peak: Float = 0
            for i in 0..<min(buffer.count, plane * 3) { peak = max(peak, abs(buffer[i])) }
            let divisor: Float = peak > 2 ? 255 : 1
            for i in 0..<plane {
                rgba[i * 4] = min(max(buffer[i] / divisor, 0), 1)
                rgba[i * 4 + 1] = min(max(buffer[plane + i] / divisor, 0), 1)
                rgba[i * 4 + 2] = min(max(buffer[2 * plane + i] / divisor, 0), 1)
            }
        }

        let data = rgba.withUnsafeBufferPointer { Data(buffer: $0) }
        guard let patch = CIImage(bitmapData: data, bytesPerRow: side * 16,
                                  size: CGSize(width: side, height: side), format: .RGBAf,
                                  colorSpace: CGColorSpaceCreateDeviceRGB()) as CIImage? else { return nil }
        // O bitmap tem a linha 0 em cima; em Core Image o y cresce para cima.
        let placed = patch
            .transformed(by: CGAffineTransform(scaleX: window.width / CGFloat(side), y: -window.height / CGFloat(side)))
            .transformed(by: CGAffineTransform(translationX: window.minX, y: window.maxY))
        return placed.cropped(to: window)
    }

    /// Região reduzida a `side`×`side`, em RGBA de vírgula flutuante, linha 0 em cima.
    private static func samples(of image: CIImage, region: CGRect, side: Int) -> [Float]? {
        guard region.width > 0, region.height > 0 else { return nil }
        let local = image.cropped(to: region)
            .transformed(by: CGAffineTransform(translationX: -region.minX, y: -region.minY))
            .clampedToExtent()
        let f = CIFilter(name: "CILanczosScaleTransform")
        f?.setValue(local, forKey: kCIInputImageKey)
        f?.setValue(CGFloat(side) / region.height, forKey: kCIInputScaleKey)
        f?.setValue((CGFloat(side) / region.width) / (CGFloat(side) / region.height), forKey: kCIInputAspectRatioKey)
        guard let scaled = f?.outputImage else { return nil }
        var rgba = [Float](repeating: 0, count: side * side * 4)
        ImageRenderer.shared.context.render(scaled, toBitmap: &rgba, rowBytes: side * 16,
                                            bounds: CGRect(x: 0, y: 0, width: side, height: side),
                                            format: .RGBAf, colorSpace: CGColorSpaceCreateDeviceRGB())
        // O `render` devolve a linha 0 em baixo; o modelo espera-a em cima.
        var flipped = [Float](repeating: 0, count: rgba.count)
        for row in 0..<side {
            let from = (side - 1 - row) * side * 4
            for i in 0..<(side * 4) { flipped[row * side * 4 + i] = rgba[from + i] }
        }
        return flipped
    }
}

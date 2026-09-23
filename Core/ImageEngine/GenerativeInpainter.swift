import CoreImage
import CoreML
import ImageIO
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

    /// Devolve `image` com a zona branca de `mask` preenchida com conteúdo inventado, ou `nil` se o modelo
    /// não estiver instalado ou falhar — e nesse caso quem chama volta ao motor por cópia.
    ///
    /// Uma zona maior do que uma janela do modelo é preenchida em várias janelas encadeadas: cada uma
    /// trabalha já sobre o resultado da anterior, para não haver degrau entre elas. Sem isto, tudo o que
    /// caísse fora da primeira janela ficava por preencher — numa selecção de objecto que apanha o primeiro
    /// plano inteiro, sobravam as silhuetas por tocar.
    func fill(_ image: CIImage, mask: CIImage, bounds: CGRect) -> CIImage? {
        let e = image.extent
        guard model() != nil, !e.isInfinite, bounds.width >= 2, bounds.height >= 2 else { return nil }

        // Contexto à volta da zona: o modelo precisa de ver o que a rodeia para inventar algo que continue
        // a foto. Uma janela grande de mais passa a ter o buraco a ocupar quase tudo e devolve uma mancha.
        let target = max(bounds.width, bounds.height) * 3
        let windowSide = min(max(target, 64), min(e.width, e.height))
        // As janelas são distribuídas **centradas na zona**. Encostar a primeira ao canto do buraco
        // deixava-o na margem da janela, sem contexto de um dos lados, e o modelo tem de ver o que rodeia
        // a zona pelos quatro lados para inventar algo que continue a foto.
        let step = windowSide * 0.55
        let spanX = max(bounds.width - windowSide, 0), spanY = max(bounds.height - windowSide, 0)
        let columns = max(Int(ceil(spanX / step)) + 1, 1)
        let rows = max(Int(ceil(spanY / step)) + 1, 1)
        guard columns * rows <= 24 else { return nil }
        let strideX = columns > 1 ? spanX / CGFloat(columns - 1) : 0
        let strideY = rows > 1 ? spanY / CGFloat(rows - 1) : 0

        let single = rows == 1 && columns == 1
        var working = image
        for row in 0..<rows {
            for column in 0..<columns {
                let centreX = bounds.midX - spanX / 2 + CGFloat(column) * strideX
                let centreY = bounds.midY - spanY / 2 + CGFloat(row) * strideY
                let originX = min(max(centreX - windowSide / 2, e.minX), e.maxX - windowSide)
                let originY = min(max(centreY - windowSide / 2, e.minY), e.maxY - windowSide)
                let window = CGRect(x: originX, y: originY, width: windowSide, height: windowSide).integral
                guard let patch = patch(for: working, mask: mask, window: window) else { continue }
                // Só o que é buraco *dentro desta janela* é substituído; o resto fica para as outras.
                // A máscara esbate-se na margem da janela para as janelas se cruzarem em vez de encostarem:
                // cada uma inventa conteúdo diferente para a mesma textura, e um corte a direito deixaria
                // uma risca visível entre elas.
                let localMask = single ? mask.cropped(to: window)
                    : mask.applyingFilter("CIMultiplyCompositing",
                                          parameters: [kCIInputBackgroundImageKey: Self.taper(window)])
                        .cropped(to: window)
                working = patch
                    .applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: working,
                                                                    kCIInputMaskImageKey: localMask])
                    .cropped(to: e)
            }
        }
        return working
    }

    /// Janela branca no meio que se desvanece na margem, para cruzar com a janela do lado.
    private static func taper(_ window: CGRect) -> CIImage {
        let margin = min(window.width, window.height) * 0.12
        return CIImage(color: .white)
            .cropped(to: window.insetBy(dx: margin, dy: margin))
            .applyingGaussianBlur(sigma: margin * 0.6)
            .cropped(to: window)
    }

    /// Uma passagem do modelo sobre uma janela quadrada.
    private func patch(for image: CIImage, mask: CIImage, window: CGRect) -> CIImage? {
        guard let model = model() else { return nil }
        let side = Self.side
        guard let photo = Self.samples(of: image, region: window, side: side),
              let holes = Self.samples(of: mask, region: window, side: side) else { return nil }
        // Janela sem nada para apagar: não vale a pena acordar o modelo.
        guard (0..<(side * side)).contains(where: { holes[$0 * 4] > 0.5 }) else { return nil }

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
        Self.debugDump(photo, holes, side: side)

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
        Self.debugDump(rgba, holes, side: side, names: ("model_output", "model_mask"))

        let data = rgba.withUnsafeBufferPointer { Data(buffer: $0) }
        // O modelo trabalha em sRGB, e é preciso dizê-lo ao Core Image nos dois sentidos.
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let raw = CIImage(bitmapData: data, bytesPerRow: side * 16,
                                size: CGSize(width: side, height: side), format: .RGBAf,
                                colorSpace: space) as CIImage? else { return nil }
        return raw
            .transformed(by: CGAffineTransform(scaleX: window.width / CGFloat(side), y: window.height / CGFloat(side)))
            .transformed(by: CGAffineTransform(translationX: window.minX, y: window.minY))
            .cropped(to: window)
    }

    /// Diagnóstico: escreve o que o modelo recebe, para se poder olhar em vez de adivinhar a orientação.
    static func debugDump(_ photo: [Float], _ holes: [Float], side: Int,
                          names: (String, String) = ("model_input", "model_mask")) {
        guard let dir = ProcessInfo.processInfo.environment["PPK_MODEL_DUMP"] else { return }
        for (name, source) in [(names.0, photo), (names.1, holes)] {
            var bytes = [UInt8](repeating: 255, count: side * side * 4)
            for i in 0..<(side * side) {
                for c in 0..<3 { bytes[i * 4 + c] = UInt8(min(max(source[i * 4 + c], 0), 1) * 255) }
            }
            guard let provider = CGDataProvider(data: Data(bytes) as CFData),
                  let image = CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32,
                                      bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                      provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
                  let dest = CGImageDestinationCreateWithURL(
                    URL(fileURLWithPath: dir).appendingPathComponent("\(name).png") as CFURL,
                    "public.png" as CFString, 1, nil) else { continue }
            CGImageDestinationAddImage(dest, image, nil)
            CGImageDestinationFinalize(dest)
        }
    }

    /// Região reduzida a `side`×`side`, em RGBA de vírgula flutuante, na orientação em que o modelo a espera.
    ///
    /// Aqui não se inverte nada, e isso é deliberado: o `render(toBitmap:)` já entrega a linha de cima
    /// primeiro, e o `CIImage(bitmapData:)` lê-a da mesma maneira. Eu tinha assumido o contrário e
    /// invertido as linhas — a geometria continuava certa porque invertia outra vez à saída, mas o modelo
    /// recebia a foto ao contrário. A LaMa aprendeu com fotos direitas; virada, devolve borrões.
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
                                            format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        return rgba
    }
}

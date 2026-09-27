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
        let windows = Self.windows(for: bounds, in: e)
        guard !windows.isEmpty else { return nil }

        let single = windows.count == 1
        var working = image
        var filledAny = false
        for window in windows {
            guard let patch = patch(for: working, mask: mask, window: window) else { continue }
            filledAny = true
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
        // Sem nenhuma janela preenchida, devolver a foto intacta deixava a remoção a não fazer nada, em
        // silêncio, e ficava em cache; assim segue o motor por cópia.
        return filledAny ? working : nil
    }

    /// Onde o modelo vai olhar. Há dois casos, e confundi-los era o que dava manchas:
    ///
    /// - **Zona compacta ou grande** (um objecto, uma pessoa): uma só janela com a zona e bastante contexto
    ///   à volta, mesmo que isso signifique reduzir mais. A LaMa inventa bem uma bancada inteira quando vê
    ///   a bancada; em janelas encadeadas que são quase só buraco, cada uma via apenas o borrão da
    ///   anterior e o resultado era uma mancha escura.
    /// - **Traço fino e comprido** (um fio, uma linha no chão): várias janelas ao longo do traço, cada uma
    ///   com o traço estreito no meio e contexto de sobra dos dois lados, para não perder resolução.
    ///
    /// As janelas não precisam de ser quadradas: o `samples` estica-as para o tamanho do modelo e o
    /// `patch` desfaz o esticão, e a LaMa aguenta bem uma proporção até ~2:1.
    static func windows(for bounds: CGRect, in e: CGRect) -> [CGRect] {
        let long = max(bounds.width, bounds.height), short = min(bounds.width, bounds.height)
        let limit = min(e.width, e.height)

        // Traço fino: janelas quadradas ao longo dele, quando cabem várias e o traço é mesmo estreito.
        let tileSide = min(max(short * 4, 384), limit)
        if long > tileSide * 1.5, short * 3 < tileSide {
            let step = tileSide * 0.55
            let spanX = max(bounds.width - tileSide, 0), spanY = max(bounds.height - tileSide, 0)
            let columns = Int(ceil(spanX / step)) + 1, rows = Int(ceil(spanY / step)) + 1
            if columns * rows <= 24 {
                let strideX = columns > 1 ? spanX / CGFloat(columns - 1) : 0
                let strideY = rows > 1 ? spanY / CGFloat(rows - 1) : 0
                var out: [CGRect] = []
                for row in 0..<rows {
                    for column in 0..<columns {
                        let centre = CGPoint(x: bounds.midX - spanX / 2 + CGFloat(column) * strideX,
                                             y: bounds.midY - spanY / 2 + CGFloat(row) * strideY)
                        out.append(fit(CGSize(width: tileSide, height: tileSide), centredOn: centre, in: e))
                    }
                }
                return out
            }
        }

        // Uma só janela: a zona a ocupar mais ou menos um terço de cada lado, com um mínimo para haver
        // contexto mesmo numa pinta pequena.
        var width = max(bounds.width * 2.6, long * 1.6, 96)
        var height = max(bounds.height * 2.6, long * 1.6, 96)
        width = min(width, e.width); height = min(height, e.height)
        // Proporção limitada: esticar de mais deforma o que o modelo vê.
        if width > height * 2 { height = min(width / 2, e.height) }
        if height > width * 2 { width = min(height / 2, e.width) }
        return [fit(CGSize(width: width, height: height), centredOn: CGPoint(x: bounds.midX, y: bounds.midY), in: e)]
    }

    /// Rectângulo de `size` centrado em `centre`, empurrado para dentro da imagem.
    private static func fit(_ size: CGSize, centredOn centre: CGPoint, in e: CGRect) -> CGRect {
        let w = min(size.width, e.width), h = min(size.height, e.height)
        let x = min(max(centre.x - w / 2, e.minX), e.maxX - w)
        let y = min(max(centre.y - h / 2, e.minY), e.maxY - h)
        return CGRect(x: x, y: y, width: w, height: h).integral.intersection(e)
    }

    /// O modelo trabalha reduzido e devolve uma zona lisa, sem o grão da foto — é isso que denuncia um
    /// preenchimento mesmo quando a forma está certa. Mede-se quanto grão há à volta e quanto há no que
    /// foi inventado, e junta-se a diferença.
    ///
    /// Tudo se mede e aplica só em `bounds` (a zona do buraco) com uma margem: isto corre em cada render
    /// da pré-visualização, e medir a foto inteira custava por nada.
    static func matchingGrain(_ filled: CIImage, original: CIImage, mask: CIImage, around bounds: CGRect) -> CIImage {
        let whole = filled.extent
        let e = bounds.insetBy(dx: -40, dy: -40).intersection(whole).integral
        guard !e.isEmpty else { return filled }
        let hole = mask.cropped(to: e)
        // Anel à volta do buraco: é daí que vem a medida do grão que a foto tem.
        let grown = hole.clampedToExtent().applyingFilter("CIMorphologyMaximum", parameters: [kCIInputRadiusKey: 24]).cropped(to: e)
        let ring = hole.applyingFilter("CIColorInvert")
            .applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: grown])
            .cropped(to: e)
        guard let around = grainVariance(of: original.cropped(to: e), in: ring),
              let inside = grainVariance(of: filled.cropped(to: e), in: hole) else { return filled }
        let missing = max(around - inside, 0).squareRoot()
        guard missing > 0.002 else { return filled }

        // Ruído de luminância à escala do píxel, média zero. O gerador do Core Image é uniforme em 0…1,
        // de desvio 1/√12; escala-se para o desvio que falta.
        let gain = missing * 12.0.squareRoot()
        let noise = CIFilter(name: "CIRandomGenerator")!.outputImage!
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: gain, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: gain, y: 0, z: 0, w: 0),
                "inputBVector": CIVector(x: gain, y: 0, z: 0, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputBiasVector": CIVector(x: -gain / 2, y: -gain / 2, z: -gain / 2, w: 0),
            ])
            .cropped(to: e)
        let grainy = filled.cropped(to: e).applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: noise])
            .cropped(to: e)
        return grainy.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: filled,
                                                                    kCIInputMaskImageKey: hole])
            .cropped(to: whole)
    }

    /// Variância do detalhe fino (imagem menos a sua versão desfocada) ponderada por `weights`.
    private static func grainVariance(of image: CIImage, in weights: CIImage) -> Double? {
        let e = image.extent
        let blurred = image.clampedToExtent().applyingGaussianBlur(sigma: 1.5).cropped(to: e)
        let fine = blurred.applyingFilter("CIDifferenceBlendMode", parameters: [kCIInputBackgroundImageKey: image]).cropped(to: e)
        let squared = fine.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: fine])
        let weighted = squared.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: weights]).cropped(to: e)
        let total = average(weighted), share = average(weights)
        guard share > 0.0005 else { return nil }
        return total / share
    }

    private static func average(_ image: CIImage) -> Double {
        let mean = image.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: image.extent)])
        var pixel = [Float](repeating: 0, count: 4)
        ImageRenderer.shared.context.render(mean, toBitmap: &pixel, rowBytes: 16,
                                            bounds: CGRect(origin: mean.extent.origin, size: CGSize(width: 1, height: 1)),
                                            format: .RGBAf, colorSpace: nil)
        return Double(pixel[1])
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

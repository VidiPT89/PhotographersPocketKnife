import CoreImage
import CoreImage.CIFilterBuiltins

/// Grão para o preenchimento generativo. O modelo inventa a forma certa mas devolve-a lisa, e uma zona lisa
/// no meio de uma foto com grão lê-se como retoque mesmo quando tudo o resto está bem.
enum GenerativeGrain {
    /// O modelo trabalha reduzido e devolve uma zona lisa, sem o grão da foto — é isso que denuncia um
    /// preenchimento mesmo quando a forma está certa. Mede-se quanto grão há à volta e quanto há no que
    /// foi inventado, e junta-se a diferença.
    ///
    /// Tudo se mede e aplica só em `bounds` (a zona do buraco) com uma margem: isto corre em cada render
    /// da pré-visualização, e medir a foto inteira custava por nada.
    static func matching(_ filled: CIImage, original: CIImage, mask: CIImage, around bounds: CGRect) -> CIImage {
        let whole = filled.extent
        let e = bounds.insetBy(dx: -40, dy: -40).intersection(whole).integral
        guard !e.isEmpty else { return filled }
        let hole = mask.cropped(to: e)
        // Anel à volta do buraco: é daí que vem a medida do grão que a foto tem.
        let grown = hole.clampedToExtent().applyingFilter("CIMorphologyMaximum", parameters: [kCIInputRadiusKey: 24]).cropped(to: e)
        let ring = hole.applyingFilter("CIColorInvert")
            .applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: grown])
            .cropped(to: e)
        // Mede-se e junta-se em sRGB, onde a amplitude corresponde ao grão que se vê. Em linear as sombras
        // quase não têm amplitude: numa bancada escura faltava 0,0019 e o limite era 0,002, e o grão nunca
        // chegava a ser acrescentado.
        func perceptual(_ image: CIImage) -> CIImage { image.cropped(to: e).applyingFilter("CILinearToSRGBToneCurve") }
        guard let around = grainVariance(of: perceptual(original), in: ring),
              let inside = grainVariance(of: perceptual(filled), in: hole) else { return filled }
        let missing = max(around - inside, 0).squareRoot()
        guard GenerativeInpainter.Tuning.grain, missing > 0.002 else { return filled }

        // Ruído de luminância à escala do píxel, média zero: misturar a zona um pouco mais escura com ela um
        // pouco mais clara, com o ruído (em 0…1, média ½) como máscara, dá exactamente
        // `zona + ganho × (ruído − ½)`. Somar o ruído directamente não servia: o do `CIRandomGenerator` com
        // alfa 0 é anulado pela pré-multiplicação e o grão nunca chegava à imagem — medido, era sempre zero.
        let gain = missing / noiseTile.deviation
        func shifted(_ image: CIImage, _ amount: Double) -> CIImage {
            image.applyingFilter("CIColorMatrix", parameters: ["inputBiasVector": CIVector(x: amount, y: amount, z: amount, w: 0)])
        }
        let tiled = CIFilter.affineTile()
        tiled.inputImage = noiseTile.image
        tiled.transform = .identity
        guard let noise = tiled.outputImage?.cropped(to: e) else { return filled }
        let grainy = shifted(perceptual(filled), gain / 2)
            .applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: shifted(perceptual(filled), -gain / 2),
                                                            kCIInputMaskImageKey: noise])
            .applyingFilter("CISRGBToneCurveToLinear")
            .cropped(to: e)
        return grainy.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: filled,
                                                                    kCIInputMaskImageKey: hole])
            .cropped(to: whole)
    }

    /// Ruído em 0…1, igual nos três canais, num ladrilho de 256 px: determinista, para a mesma remoção dar o
    /// mesmo grão em cada render. É a média 3×3 de ruído uniforme, não o uniforme puro: o grão de uma foto
    /// verdadeira é ligeiramente correlacionado entre vizinhos, e ruído branco lia-se como pontos soltos,
    /// sujidade, por cima de uma zona lisa.
    private static let noiseTile: (image: CIImage, deviation: Double) = {
        let side = 256
        var state: UInt64 = 0x6A11_7E55
        var white = [Float](repeating: 0, count: side * side)
        for i in white.indices {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            white[i] = Float(state >> 40) / Float(1 << 24)
        }
        func at(_ values: [Float], _ x: Int, _ y: Int) -> Float { values[((y + side) % side) * side + (x + side) % side] }
        var smooth = [Float](repeating: 0, count: side * side)
        for y in 0..<side {
            for x in 0..<side {
                var total: Float = 0
                for dy in -1...1 { for dx in -1...1 { total += at(white, x + dx, y + dy) } }
                smooth[y * side + x] = total / 9
            }
        }
        // O desvio que conta é o da mesma medida com que o grão em falta é medido — o ruído menos a sua versão
        // desfocada a σ 1,5 —, não o total: um ruído correlacionado tem menos energia nessa banda e, acertado
        // pelo total, ficava grão por pôr.
        let kernel = (-4...4).map { Float(exp(-Double($0 * $0) / (2 * 1.5 * 1.5))) }
        let norm = kernel.reduce(0, +)
        var across = [Float](repeating: 0, count: side * side), blurred = across
        for y in 0..<side { for x in 0..<side { across[y * side + x] = (-4...4).reduce(0) { $0 + kernel[$1 + 4] * at(smooth, x + $1, y) } / norm } }
        for y in 0..<side { for x in 0..<side { blurred[y * side + x] = (-4...4).reduce(0) { $0 + kernel[$1 + 4] * at(across, x, y + $1) } / norm } }
        var squares = 0.0
        var pixels = [Float](repeating: 1, count: side * side * 4)
        for i in smooth.indices {
            pixels[i * 4] = smooth[i]; pixels[i * 4 + 1] = smooth[i]; pixels[i * 4 + 2] = smooth[i]
            let fine = Double(smooth[i] - blurred[i])
            squares += fine * fine
        }
        let image = CIImage(bitmapData: pixels.withUnsafeBufferPointer { Data(buffer: $0) }, bytesPerRow: side * 16,
                            size: CGSize(width: side, height: side), format: .RGBAf, colorSpace: nil)
        return (image, (squares / Double(side * side)).squareRoot())
    }()

    /// Nível de grão sob `weights`: a variância **local** do detalhe fino (imagem menos a sua versão
    /// desfocada) em cada ponto, e dessas o percentil 25. A média servia mal: uma aresta no anel à volta
    /// do buraco — o contorno de uma duna, o aro de uma bicicleta — contava como grão, e um céu liso
    /// recebia ruído a mais 25 a 100 vezes o que tinha.
    private static func grainVariance(of image: CIImage, in weights: CIImage) -> Double? {
        let e = image.extent
        let blurred = image.clampedToExtent().applyingGaussianBlur(sigma: 1.5).cropped(to: e)
        let fine = blurred.applyingFilter("CIDifferenceBlendMode", parameters: [kCIInputBackgroundImageKey: image]).cropped(to: e)
        let squared = fine.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: fine])
        let local = squared.clampedToExtent().applyingGaussianBlur(sigma: 6).cropped(to: e)
        // Um mapa de variância local é liso: medi-lo reduzido não perde nada.
        let scale = min(256 / max(e.width, e.height), 1)
        let width = max(Int(e.width * scale), 1), height = max(Int(e.height * scale), 1)
        guard let variance = ObjectRemover.pixels(of: local, region: e, width: width, height: height),
              let weight = ObjectRemover.pixels(of: weights, region: e, width: width, height: height) else { return nil }
        var values: [Float] = []
        for i in 0..<(width * height) where weight.pixels[i * 3] > 0.5 {
            values.append((variance.pixels[i * 3] + variance.pixels[i * 3 + 1] + variance.pixels[i * 3 + 2]) / 3)
        }
        guard values.count >= 16 else { return nil }
        values.sort()
        return Double(values[values.count / 4])
    }
}

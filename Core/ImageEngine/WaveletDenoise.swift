import CoreImage
import CoreImage.CIFilterBuiltins

/// Redução de ruído por wavelets (sem IA): a imagem é separada em bandas de detalhe e as oscilações pequenas,
/// que são grão, encolhem; as grandes, que são arestas e textura, ficam. Corre no GPU pelo Core Image.
enum WaveletDenoise {
    /// Limiares por banda (da mais fina à mais larga), em valores sRGB 0…1, para força 1.
    static let thresholds: [CGFloat] = [0.07, 0.04, 0.02, 0.01]

    static func suggestedStrength(iso: Int?) -> Double {
        guard let iso else { return 0.5 }
        switch iso {
        case ..<1000: return 0.25
        case ..<2000: return 0.4
        case ..<4000: return 0.55
        case ..<8000: return 0.7
        default: return 0.85
        }
    }

    static func apply(_ input: CIImage, strength: Double) -> CIImage {
        let amount = CGFloat(min(max(strength, 0), 1))
        guard amount > 0 else { return input }
        let extent = input.extent

        // O grão vê-se nos tons percebidos: trabalha-se em sRGB e volta-se ao espaço linear no fim.
        let gamma = CIFilter.linearToSRGBToneCurve()
        gamma.inputImage = input.clampedToExtent()
        var current = gamma.outputImage ?? input.clampedToExtent()
        var details: CIImage?
        for (level, threshold) in thresholds.enumerated() {
            let blurred = current.applyingGaussianBlur(sigma: pow(2, Double(level)))
            let band = sum(current, matrix(blurred, scale: -1))
            // Soft threshold: s(d) = max(d − t, 0) − max(−d − t, 0).
            let limit = threshold * amount
            let upper = clamp01(matrix(band, scale: 1, bias: -limit))
            let lower = clamp01(matrix(band, scale: -1, bias: -limit))
            let shrunk = sum(upper, matrix(lower, scale: -1))
            details = details.map { sum($0, shrunk) } ?? shrunk
            current = blurred
        }
        let restored = details.map { sum(current, $0) } ?? current
        let linear = CIFilter.sRGBToneCurveToLinear()
        linear.inputImage = restored
        return (linear.outputImage ?? restored).cropped(to: extent)
    }

    /// `rgb × scale + bias`, alfa sempre 1 (valores negativos mantêm-se no espaço de trabalho em vírgula flutuante).
    static func matrix(_ image: CIImage, scale: CGFloat, bias: CGFloat = 0) -> CIImage {
        let filter = CIFilter.colorMatrix()
        filter.inputImage = image
        filter.rVector = CIVector(x: scale, y: 0, z: 0, w: 0)
        filter.gVector = CIVector(x: 0, y: scale, z: 0, w: 0)
        filter.bVector = CIVector(x: 0, y: 0, z: scale, w: 0)
        filter.aVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        filter.biasVector = CIVector(x: bias, y: bias, z: bias, w: 1)
        return filter.outputImage ?? image
    }

    /// Soma de duas imagens opacas. A composição por adição soma também o alfa (fica 2);
    /// a matriz desfaz a pré-multiplicação (÷2), multiplica por 2 e repõe o alfa a 1.
    static func sum(_ a: CIImage, _ b: CIImage) -> CIImage {
        let add = CIFilter.additionCompositing()
        add.inputImage = a
        add.backgroundImage = b
        return matrix(add.outputImage ?? a, scale: 2)
    }

    private static func clamp01(_ image: CIImage) -> CIImage {
        let filter = CIFilter.colorClamp()
        filter.inputImage = image
        filter.minComponents = CIVector(x: 0, y: 0, z: 0, w: 1)
        filter.maxComponents = CIVector(x: 1, y: 1, z: 1, w: 1)
        return filter.outputImage ?? image
    }
}

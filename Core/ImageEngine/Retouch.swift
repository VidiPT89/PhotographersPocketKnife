import CoreImage
import CoreImage.CIFilterBuiltins

/// Retoque de retratos: pele mais suave e fundo desfocado, com as pessoas detetadas pelo Vision.
enum Retouch {
    static func apply(_ r: EditRecipe, to image: CIImage, reference: CIImage) -> CIImage {
        guard r.skinSmoothing > 0 || r.backgroundBlur > 0 else { return image }
        let person = SmartSelection.shared.personMask(for: reference) ?? SmartSelection.shared.subjectMask(for: reference)
        return apply(r, to: image, personMask: person)
    }

    static func apply(_ r: EditRecipe, to image: CIImage, personMask: CIImage?) -> CIImage {
        let e = image.extent
        guard let personMask, !e.isInfinite else { return image }
        let side = Double(max(e.width, e.height))
        var result = image

        if r.backgroundBlur > 0 {
            let blurred = image.clampedToExtent().applyingGaussianBlur(sigma: side * 0.012 * min(r.backgroundBlur, 1)).cropped(to: e)
            let mask = personMask.clampedToExtent().applyingGaussianBlur(sigma: side * 0.002).cropped(to: e)
            // Pessoa nítida por cima do fundo desfocado.
            result = image
                .applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: blurred, kCIInputMaskImageKey: mask])
                .cropped(to: e)
        }

        if r.skinSmoothing > 0 {
            let strength = CGFloat(min(r.skinSmoothing, 1) * 0.85)
            let skin = skinMask(of: result)
                .applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: personMask])
                .clampedToExtent().applyingGaussianBlur(sigma: side * 0.002).cropped(to: e)
                .applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: strength, y: 0, z: 0, w: 0),
                    "inputGVector": CIVector(x: 0, y: strength, z: 0, w: 0),
                    "inputBVector": CIVector(x: 0, y: 0, z: strength, w: 0),
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
                ])
            let smooth = result.clampedToExtent().applyingGaussianBlur(sigma: side * 0.0035).cropped(to: e)
            result = smooth
                .applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: result, kCIInputMaskImageKey: skin])
                .cropped(to: e)
        }
        return result
    }

    /// Probabilidade de cada píxel ser pele (tons em YCbCr), através de uma LUT 3D.
    static func skinMask(of image: CIImage) -> CIImage {
        let f = CIFilter.colorCubeWithColorSpace()
        f.inputImage = image
        f.cubeDimension = Float(skinCubeSize)
        f.cubeData = skinCube
        f.colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
        return (f.outputImage ?? image).cropped(to: image.extent)
    }

    private static let skinCubeSize = 32

    private static let skinCube: Data = {
        let n = skinCubeSize
        func band(_ value: Float, _ low: Float, _ high: Float, soft: Float) -> Float {
            if value < low - soft || value > high + soft { return 0 }
            if value < low { return (value - (low - soft)) / soft }
            if value > high { return ((high + soft) - value) / soft }
            return 1
        }
        var values = [Float]()
        values.reserveCapacity(n * n * n * 4)
        for b in 0..<n {
            for g in 0..<n {
                for r in 0..<n {
                    let red = Float(r) / Float(n - 1), green = Float(g) / Float(n - 1), blue = Float(b) / Float(n - 1)
                    let y = 0.299 * red + 0.587 * green + 0.114 * blue
                    let cb = -0.1687 * red - 0.3313 * green + 0.5 * blue + 0.5
                    let cr = 0.5 * red - 0.4187 * green - 0.0813 * blue + 0.5
                    let p = band(cr, 0.54, 0.66, soft: 0.03) * band(cb, 0.32, 0.47, soft: 0.03) * band(y, 0.15, 0.95, soft: 0.05)
                    values += [p, p, p, 1]
                }
            }
        }
        return values.withUnsafeBufferPointer { Data(buffer: $0) }
    }()
}

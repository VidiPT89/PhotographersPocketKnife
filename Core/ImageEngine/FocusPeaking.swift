import Foundation
import CoreGraphics

/// Focus peaking: pinta a laranja as arestas nítidas, para ver num relance onde está o foco.
enum FocusPeaking {
    /// Máscara RGBA do mesmo enquadramento da imagem; transparente onde não há nitidez.
    static func overlay(for image: CGImage, maxPixel: Int = 1600, threshold: Double = 18) -> CGImage? {
        let scale = min(1, Double(maxPixel) / Double(max(image.width, image.height)))
        let width = max(Int(Double(image.width) * scale), 5)
        let height = max(Int(Double(image.height) * scale), 5)
        guard let gray = grayscale(image, width: width, height: height) else { return nil }

        // Média 3×3 antes do Laplaciano, para o ruído de ISO alto não acender tudo.
        var blurred = gray
        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                let i = y * width + x
                blurred[i] = (gray[i - width - 1] + gray[i - width] + gray[i - width + 1]
                    + gray[i - 1] + gray[i] + gray[i + 1]
                    + gray[i + width - 1] + gray[i + width] + gray[i + width + 1]) / 9
            }
        }

        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for y in 2..<(height - 2) {
            for x in 2..<(width - 2) {
                let i = y * width + x
                let laplacian = abs(4 * blurred[i] - blurred[i - 1] - blurred[i + 1] - blurred[i - width] - blurred[i + width])
                guard laplacian > threshold else { continue }
                pixels[i * 4] = 255
                pixels[i * 4 + 1] = 122
                pixels[i * 4 + 2] = 0
                pixels[i * 4 + 3] = 255
            }
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    /// Fração de píxeis marcados (0…1).
    static func coverage(_ overlay: CGImage) -> Double {
        guard let data = overlay.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return 0 }
        let count = overlay.width * overlay.height
        var marked = 0
        for i in 0..<count where bytes[i * 4 + 3] > 0 { marked += 1 }
        return Double(marked) / Double(max(count, 1))
    }

    private static func grayscale(_ image: CGImage, width: Int, height: Int) -> [Double]? {
        var bytes = [UInt8](repeating: 0, count: width * height)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                          space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? bytes.map(Double.init) : nil
    }
}

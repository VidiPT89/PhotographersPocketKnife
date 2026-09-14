import Foundation
import ImageIO
import CryptoKit
import UniformTypeIdentifiers

/// CGImage é imutável; este invólucro permite passá-la entre tarefas.
struct SendableImage: @unchecked Sendable {
    let cgImage: CGImage
}

/// Cache de thumbnails em memória + disco. Nunca carrega o RAW completo quando há JPEG embutido suficiente.
final class ThumbnailCache: @unchecked Sendable {
    static let shared = ThumbnailCache()

    private let memory = NSCache<NSString, CGImage>()
    private let directory: URL

    init(directory: URL? = nil) {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        self.directory = directory ?? caches.appendingPathComponent("PhotographersPocketKnife/Thumbnails", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
        memory.countLimit = 800
    }

    func memoryHit(for url: URL, maxPixel: Int) -> SendableImage? {
        memory.object(forKey: cacheKey(url, maxPixel) as NSString).map(SendableImage.init)
    }

    func thumbnail(for url: URL, maxPixel: Int) -> SendableImage? {
        let key = cacheKey(url, maxPixel)
        if let image = memory.object(forKey: key as NSString) {
            return SendableImage(cgImage: image)
        }
        let file = directory.appendingPathComponent(key).appendingPathExtension("jpg")
        if let source = CGImageSourceCreateWithURL(file as CFURL, nil),
           let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
            memory.setObject(image, forKey: key as NSString)
            return SendableImage(cgImage: image)
        }
        guard let image = Diagnostics.shared.measure(.thumbnail, { Self.generate(url: url, maxPixel: maxPixel) }) else { return nil }
        memory.setObject(image, forKey: key as NSString)
        if let destination = CGImageDestinationCreateWithURL(file as CFURL, UTType.jpeg.identifier as CFString, 1, nil) {
            CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
            CGImageDestinationFinalize(destination)
        }
        return SendableImage(cgImage: image)
    }

    func diskUsage() -> Int64 {
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            total += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    func clearDisk() {
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        memory.removeAllObjects()
    }

    static func generate(url: URL, maxPixel: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        func make(always: Bool) -> CGImage? {
            let options: [CFString: Any] = [
                always ? kCGImageSourceCreateThumbnailFromImageAlways : kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixel,
                kCGImageSourceCreateThumbnailWithTransform: true,
            ]
            return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        }
        // Primeiro o preview embutido (rápido); se for pequeno demais, descodifica a imagem.
        if let fast = make(always: false), max(fast.width, fast.height) >= maxPixel / 2 {
            return fast
        }
        return make(always: true)
    }

    private func cacheKey(_ url: URL, _ maxPixel: Int) -> String {
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)?.timeIntervalSince1970 ?? 0
        let digest = SHA256.hash(data: Data("\(url.path)|\(modified)|\(maxPixel)".utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

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
    private let memoryPressure = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .global(qos: .utility))

    init(directory: URL? = nil) {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        self.directory = directory ?? caches.appendingPathComponent("PhotographersPocketKnife/Thumbnails", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
        // Limite por bytes: 800 pré-visualizações de 1600 px passariam dos 6 GB.
        memory.totalCostLimit = 512 << 20
        memoryPressure.setEventHandler { [weak self] in self?.memory.removeAllObjects() }
        memoryPressure.resume()
        // O cache em disco nunca encolhia sozinho: alguns trabalhos seguidos enchiam dezenas de GB
        // até alguém carregar em "Limpar cache". A arrumação é feita uma vez, fora do arranque.
        let folder = self.directory
        DispatchQueue.global(qos: .background).async { Self.prune(folder, maxBytes: Self.diskLimit) }
    }

    /// Tecto do cache em disco. Chega para uma sessão grande e ainda assim não toma conta do disco.
    static let diskLimit: Int64 = 4 << 30

    /// Apaga as miniaturas mais antigas até ficar abaixo do tecto. A ordem vem da data de modificação:
    /// a chave do cache inclui a data da foto, por isso cada ficheiro é escrito de novo quando a foto muda,
    /// e a data de acesso não é de fiar (muitos volumes montam com `noatime`).
    static func prune(_ directory: URL, maxBytes: Int64) {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        guard let files = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys) else { return }
        let entries = files.compactMap { url -> (url: URL, size: Int64, used: Date)? in
            guard let values = try? url.resourceValues(forKeys: Set(keys)), let size = values.fileSize else { return nil }
            return (url, Int64(size), values.contentModificationDate ?? .distantPast)
        }
        var total = entries.reduce(Int64(0)) { $0 + $1.size }
        guard total > maxBytes else { return }
        for entry in entries.sorted(by: { $0.used < $1.used }) {
            guard total > maxBytes else { break }
            if (try? fm.removeItem(at: entry.url)) != nil { total -= entry.size }
        }
    }

    private func store(_ image: CGImage, forKey key: String) {
        memory.setObject(image, forKey: key as NSString, cost: image.bytesPerRow * image.height)
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
        // Verificar antes: abrir um ficheiro que não existe enche a consola de erros do ImageIO.
        if FileManager.default.fileExists(atPath: file.path),
           let source = CGImageSourceCreateWithURL(file as CFURL, nil),
           let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
            store(image, forKey: key)
            return SendableImage(cgImage: image)
        }
        guard let image = Diagnostics.shared.measure(.thumbnail, { Self.generate(url: url, maxPixel: maxPixel) }) else { return nil }
        store(image, forKey: key)
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

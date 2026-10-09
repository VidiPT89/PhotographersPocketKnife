import Foundation
import SwiftData

/// Pares RAW+JPEG: o mesmo disparo gravado em dois ficheiros com o mesmo nome, na mesma pasta.
enum PhotoPairs {
    /// Pasta e nome sem extensão, sem distinguir maiúsculas (`IMG_0001.CR3` e `img_0001.jpg` são o mesmo disparo).
    static func key(_ path: String) -> String {
        (path as NSString).deletingPathExtension.lowercased()
    }

    /// Para cada RAW com gémeos não RAW, os ids desses gémeos.
    /// Corre a cada tecla na grelha, por isso compara extensões sem criar `URL`s.
    static func twins(_ items: [(id: UUID, path: String)]) -> [UUID: [UUID]] {
        func isRaw(_ path: String) -> Bool { PhotoImporter.rawExtensions.contains((path as NSString).pathExtension.lowercased()) }
        var raws: [String: UUID] = [:]
        for item in items where isRaw(item.path) {
            raws[key(item.path)] = item.id
        }
        var result: [UUID: [UUID]] = [:]
        for item in items where !isRaw(item.path) {
            if let raw = raws[key(item.path)] { result[raw, default: []].append(item.id) }
        }
        return result
    }

    @MainActor
    static func twins(in photos: [Photo]) -> [UUID: [UUID]] {
        twins(photos.map { (id: $0.id, path: $0.path) })
    }
}

extension CatalogService {
    /// Reaponta as fotos de uma pasta que mudou de sítio (disco externo com outro nome, cartão copiado
    /// para outro lado). Inclui as subpastas e só mexe nas fotos cujo ficheiro existe no novo sítio.
    @discardableResult
    static func relink(from oldFolder: URL, to newFolder: URL, in context: ModelContext,
                       fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> Int {
        let oldPrefix = oldFolder.standardizedFileURL.path.trimmingSuffix("/") + "/"
        let newPrefix = newFolder.standardizedFileURL.path.trimmingSuffix("/") + "/"
        guard oldPrefix != newPrefix, let photos = try? context.fetch(FetchDescriptor<Photo>()) else { return 0 }
        var moved = 0
        for photo in photos where photo.path.hasPrefix(oldPrefix) {
            let candidate = newPrefix + photo.path.dropFirst(oldPrefix.count)
            guard fileExists(candidate) else { continue }
            photo.path = candidate
            moved += 1
        }
        if moved > 0 { try? context.save() }
        return moved
    }
}

private extension String {
    func trimmingSuffix(_ suffix: String) -> String {
        hasSuffix(suffix) && count > suffix.count ? String(dropLast(suffix.count)) : self
    }
}

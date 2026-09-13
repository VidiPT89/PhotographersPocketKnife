import Foundation
import SwiftData

enum PhotoImporter {
    static let nonRawExtensions: Set<String> = ["jpg", "jpeg", "png", "tif", "tiff", "heic", "heif"]
    static let rawExtensions: Set<String> = [
        "dng", "cr2", "cr3", "crw", "nef", "nrw", "arw", "srf", "sr2", "raf",
        "orf", "rw2", "pef", "srw", "3fr", "iiq", "rwl", "x3f",
    ]
    static let supportedExtensions = nonRawExtensions.union(rawExtensions)

    struct Options: Sendable {
        var copyDestination: URL?
        var subfolderByDate = true
    }

    static func isSupported(_ url: URL) -> Bool { supportedExtensions.contains(url.pathExtension.lowercased()) }
    static func isRaw(_ url: URL) -> Bool { rawExtensions.contains(url.pathExtension.lowercased()) }

    static func imageFiles(in folder: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }
        var files: [URL] = []
        for case let url as URL in enumerator where isSupported(url) {
            files.append(url)
        }
        return files.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    /// Lê (e opcionalmente copia) todas as fotos de uma pasta ou cartão.
    static func run(folder: URL, options: Options, progress: @Sendable (Int, Int) -> Void) throws -> [ImportedPhotoInfo] {
        try run(files: imageFiles(in: folder), options: options, progress: progress)
    }

    static func run(files: [URL], options: Options, progress: @Sendable (Int, Int) -> Void) throws -> [ImportedPhotoInfo] {
        let fm = FileManager.default
        let files = files.filter(isSupported)
        var result: [ImportedPhotoInfo] = []
        result.reserveCapacity(files.count)

        for (index, file) in files.enumerated() {
            var target = file
            if let destination = options.copyDestination {
                let info = MetadataReader.basicInfo(for: file)
                var dir = destination
                if options.subfolderByDate {
                    dir.appendPathComponent(dayString(info.captureDate ?? Date()), isDirectory: true)
                }
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                let candidate = dir.appendingPathComponent(file.lastPathComponent)
                if sameFileAlreadyCopied(file, candidate) {
                    target = candidate
                } else {
                    target = uniqueURL(candidate)
                    try fm.copyItem(at: file, to: target)
                    let sidecar = MetadataWriter.sidecarURL(for: file)
                    if fm.fileExists(atPath: sidecar.path) {
                        try? fm.copyItem(at: sidecar, to: MetadataWriter.sidecarURL(for: target))
                    }
                }
            }
            result.append(MetadataReader.basicInfo(for: target))
            progress(index + 1, files.count)
        }
        return result
    }

    static func dayString(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    static func uniqueURL(_ url: URL) -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return url }
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        let dir = url.deletingLastPathComponent()
        var n = 1
        while true {
            let candidate = dir.appendingPathComponent("\(base)-\(n)").appendingPathExtension(ext)
            if !fm.fileExists(atPath: candidate.path) { return candidate }
            n += 1
        }
    }

    private static func sameFileAlreadyCopied(_ source: URL, _ target: URL) -> Bool {
        let keys: Set<URLResourceKey> = [.fileSizeKey]
        guard let a = try? source.resourceValues(forKeys: keys).fileSize,
              let b = try? target.resourceValues(forKeys: keys).fileSize else { return false }
        return a == b
    }
}

@MainActor
enum CatalogService {
    /// Insere as fotos novas (ignora caminhos que já estão no catálogo).
    @discardableResult
    static func insert(_ infos: [ImportedPhotoInfo], session: String, into context: ModelContext) -> Int {
        let existing = Set(((try? context.fetch(FetchDescriptor<Photo>())) ?? []).map(\.path))
        var added = 0
        for info in infos where !existing.contains(info.url.path) {
            context.insert(Photo(info: info, sessionName: session))
            added += 1
        }
        try? context.save()
        return added
    }

    /// Remove do catálogo sem apagar os ficheiros do disco.
    static func remove(_ photos: [Photo], from context: ModelContext) {
        photos.forEach(context.delete)
        try? context.save()
    }
}

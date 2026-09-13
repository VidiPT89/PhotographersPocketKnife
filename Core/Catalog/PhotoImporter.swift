import Foundation
import SwiftData

enum ImportError: LocalizedError {
    case checksumMismatch(String)

    var errorDescription: String? {
        switch self {
        case .checksumMismatch(let name): "Checksum mismatch: \(name)"
        }
    }
}

enum PhotoImporter {
    static let nonRawExtensions: Set<String> = ["jpg", "jpeg", "png", "tif", "tiff", "heic", "heif"]
    static let rawExtensions: Set<String> = [
        "dng", "cr2", "cr3", "crw", "nef", "nrw", "arw", "srf", "sr2", "raf",
        "orf", "rw2", "pef", "srw", "3fr", "iiq", "rwl", "x3f",
    ]
    static let supportedExtensions = nonRawExtensions.union(rawExtensions)

    struct Options: Sendable {
        var copyDestination: URL?
        /// Cria subpastas com `folderTemplate` dentro do destino.
        var subfolderByDate = true
        var folderTemplate = "{date}"
        var event = ""
        /// Segundo destino (backup simultâneo).
        var backupDestination: URL?
        /// Compara o SHA-256 do original com cada cópia.
        var verifyChecksum = false
    }

    struct Result: Sendable {
        var infos: [ImportedPhotoInfo]
        /// Ficheiros que falharam a cópia ou a verificação.
        var failures: [String]
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
        try runReporting(files: files, options: options, progress: progress).infos
    }

    static func runReporting(files: [URL], options: Options, progress: @Sendable (Int, Int) -> Void) throws -> Result {
        let files = files.filter(isSupported)
        var infos: [ImportedPhotoInfo] = []
        var failures: [String] = []
        infos.reserveCapacity(files.count)

        for (index, file) in files.enumerated() {
            defer { progress(index + 1, files.count) }
            var target = file
            if let destination = options.copyDestination {
                let relative = options.subfolderByDate
                    ? IngestTemplate.path(options.folderTemplate, date: MetadataReader.basicInfo(for: file).captureDate ?? Date(), event: options.event, isRaw: isRaw(file))
                    : ""
                do {
                    target = try copy(file, into: destination.appendingPathComponent(relative, isDirectory: true), verify: options.verifyChecksum)
                    if let backup = options.backupDestination {
                        _ = try copy(file, into: backup.appendingPathComponent(relative, isDirectory: true), verify: options.verifyChecksum)
                    }
                } catch {
                    failures.append(file.lastPathComponent)
                    continue
                }
            }
            var info = MetadataReader.basicInfo(for: target)
            info.sidecar = PPKSidecar.read(for: target)
            infos.append(info)
        }
        return Result(infos: infos, failures: failures)
    }

    private static func copy(_ file: URL, into directory: URL, verify: Bool) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let candidate = directory.appendingPathComponent(file.lastPathComponent)
        if sameFileAlreadyCopied(file, candidate) {
            if !verify { return candidate }
            if try FileChecksum.sha256(of: file) == FileChecksum.sha256(of: candidate) { return candidate }
        }
        let target = uniqueURL(candidate)
        try fm.copyItem(at: file, to: target)
        for (source, destination) in [
            (MetadataWriter.sidecarURL(for: file), MetadataWriter.sidecarURL(for: target)),
            (PPKSidecar.url(for: file), PPKSidecar.url(for: target)),
        ] where fm.fileExists(atPath: source.path) {
            try? fm.copyItem(at: source, to: destination)
        }
        if verify, try FileChecksum.sha256(of: file) != FileChecksum.sha256(of: target) {
            try? fm.removeItem(at: target)
            throw ImportError.checksumMismatch(file.lastPathComponent)
        }
        return target
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
    /// Insere as fotos novas (ignora caminhos que já estão no catálogo) e aplica `.ppk` encontrados.
    @discardableResult
    static func insert(_ infos: [ImportedPhotoInfo], session: String, into context: ModelContext) -> Int {
        let existing = Set(((try? context.fetch(FetchDescriptor<Photo>())) ?? []).map(\.path))
        var added = 0
        for info in infos where !existing.contains(info.url.path) {
            let photo = Photo(info: info, sessionName: session)
            if let sidecar = info.sidecar {
                photo.rating = min(max(sidecar.rating, 0), 5)
                photo.flagRaw = min(max(sidecar.flag, -1), 1)
                photo.colorLabel = ColorLabel(name: sidecar.label)
                if let develop = sidecar.develop, !develop.isIdentity {
                    photo.recipeData = try? JSONEncoder().encode(develop)
                }
            }
            context.insert(photo)
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

    static func sidecars(for photos: [Photo]) -> [(url: URL, sidecar: PPKSidecar)] {
        photos.map { photo in
            (photo.url, PPKSidecar(
                file: photo.fileName,
                rating: photo.rating,
                label: "\(photo.colorLabel)",
                flag: photo.flagRaw,
                develop: photo.recipeData.flatMap { try? JSONDecoder().decode(EditRecipe.self, from: $0) }
            ))
        }
    }
}

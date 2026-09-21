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

    /// Lê (e opcionalmente copia) as fotos. A cópia é sequencial (evita corridas nos nomes únicos);
    /// a leitura de metadados corre em paralelo e mantém a ordem original.
    static func runReporting(files: [URL], options: Options, progress: @Sendable (Int, Int) -> Void) throws -> Result {
        let files = files.filter(isSupported)
        var targets: [URL] = []
        var failures: [String] = []
        targets.reserveCapacity(files.count)

        if let destination = options.copyDestination {
            for (index, file) in files.enumerated() {
                defer { progress(index + 1, files.count) }
                let relative = options.subfolderByDate
                    ? IngestTemplate.path(options.folderTemplate, date: MetadataReader.basicInfo(for: file).captureDate ?? Date(), event: options.event, isRaw: isRaw(file))
                    : ""
                do {
                    targets.append(try copy(file, into: destination.appendingPathComponent(relative, isDirectory: true), verify: options.verifyChecksum))
                    if let backup = options.backupDestination {
                        _ = try copy(file, into: backup.appendingPathComponent(relative, isDirectory: true), verify: options.verifyChecksum)
                    }
                } catch {
                    failures.append(file.lastPathComponent)
                }
            }
        } else {
            targets = files
        }

        let copied = options.copyDestination != nil
        let inputs = targets
        let results = OrderedResults<ImportedPhotoInfo>(count: inputs.count)
        DispatchQueue.concurrentPerform(iterations: inputs.count) { index in
            let target = inputs[index]
            var info = Diagnostics.shared.measure(.importFile) { MetadataReader.basicInfo(for: target) }
            info.sidecar = PPKSidecar.read(for: target) ?? MetadataReader.xmpClassification(for: target)
            let done = results.set(info, at: index)
            if !copied { progress(done, inputs.count) }
        }
        return Result(infos: results.values, failures: failures)
    }

    private static func copy(_ file: URL, into directory: URL, verify: Bool) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let candidate = directory.appendingPathComponent(file.lastPathComponent)
        if sameFileAlreadyCopied(file, candidate),
           try !verify || FileChecksum.sha256(of: file) == FileChecksum.sha256(of: candidate) {
            copySidecars(from: file, to: candidate)
            return candidate
        }
        let target = uniqueURL(candidate)
        try fm.copyItem(at: file, to: target)
        copySidecars(from: file, to: target)
        if verify, try FileChecksum.sha256(of: file) != FileChecksum.sha256(of: target) {
            try? fm.removeItem(at: target)
            throw ImportError.checksumMismatch(file.lastPathComponent)
        }
        return target
    }

    /// Os sidecars são copiados também quando a foto já estava no destino: o cartão pode trazer
    /// classificações ou revelações mais recentes do que a cópia anterior. Mas o que está no destino
    /// só é substituído se o do cartão for mesmo mais recente — senão, uma reimportação apagaria a
    /// classificação feita aqui na app depois da primeira cópia.
    private static func copySidecars(from file: URL, to target: URL) {
        let fm = FileManager.default
        for (source, destination) in [
            (MetadataWriter.sidecarURL(for: file), MetadataWriter.sidecarURL(for: target)),
            (PPKSidecar.url(for: file), PPKSidecar.url(for: target)),
        ] where source != destination && fm.fileExists(atPath: source.path) {
            if fm.fileExists(atPath: destination.path) {
                guard let new = modificationDate(of: source), let old = modificationDate(of: destination),
                      new > old else { continue }
                try? fm.removeItem(at: destination)
            }
            try? fm.copyItem(at: source, to: destination)
        }
    }

    private static func modificationDate(of url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
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

    /// Sem verificação de checksum, o tamanho sozinho deixaria passar dois ficheiros diferentes com o mesmo
    /// número de bytes, por isso a data de modificação (que a cópia preserva) também tem de coincidir.
    private static func sameFileAlreadyCopied(_ source: URL, _ target: URL) -> Bool {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey]
        guard let a = try? source.resourceValues(forKeys: keys),
              let b = try? target.resourceValues(forKeys: keys),
              let sizeA = a.fileSize, let sizeB = b.fileSize, sizeA == sizeB,
              let dateA = a.contentModificationDate, let dateB = b.contentModificationDate else { return false }
        return abs(dateA.timeIntervalSince(dateB)) < 1
    }
}

/// Resultados escritos por várias threads, cada uma na sua posição.
private final class OrderedResults<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var slots: [Value?]
    private var filled = 0

    init(count: Int) {
        slots = Array(repeating: nil, count: count)
    }

    /// Devolve quantas posições já estão preenchidas.
    func set(_ value: Value, at index: Int) -> Int {
        lock.withLock {
            slots[index] = value
            filled += 1
            return filled
        }
    }

    var values: [Value] {
        lock.withLock { slots.compactMap { $0 } }
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

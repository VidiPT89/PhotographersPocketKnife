import Foundation
import ImageIO

/// Campos IPTC editáveis em lote. Campos vazios não são alterados.
struct IPTCFields: Codable, Equatable, Sendable {
    var title = ""
    var caption = ""
    var creator = ""
    var copyright = ""
    var keywords = ""
    var city = ""
    var country = ""

    var keywordList: [String] {
        keywords.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    var isEmpty: Bool {
        [title, caption, creator, copyright, city, country].allSatisfy(\.isEmpty) && keywordList.isEmpty
    }
}

enum MetadataError: LocalizedError {
    case unreadable(URL)
    case cannotWrite(URL)

    var errorDescription: String? {
        switch self {
        case .unreadable(let url): "Cannot read \(url.lastPathComponent)"
        case .cannotWrite(let url): "Cannot write metadata to \(url.lastPathComponent)"
        }
    }
}

enum MetadataWriter {
    static func sidecarURL(for url: URL) -> URL {
        url.deletingPathExtension().appendingPathExtension("xmp")
    }

    /// Escreve sem recomprimir a imagem. Em RAW usa um ficheiro .xmp ao lado (sidecar).
    static func write(_ fields: IPTCFields, to url: URL) throws {
        try update(url) { apply(fields, to: $0) }
    }

    /// `xmp:Rating` e `xmp:Label`, que o Lightroom e o Bridge leem (só a pedido, para não poluir as pastas).
    static func writeRating(_ rating: Int, label: ColorLabel, to url: URL) throws {
        try update(url) { metadata in
            CGImageMetadataSetValueWithPath(metadata, nil, "xmp:Rating" as CFString, NSNumber(value: min(max(rating, 0), 5)))
            if let name = label.xmpName {
                CGImageMetadataSetValueWithPath(metadata, nil, "xmp:Label" as CFString, name as CFString)
            }
        }
    }

    private static func update(_ url: URL, _ body: (CGMutableImageMetadata) -> Void) throws {
        if PhotoImporter.isRaw(url) {
            try writeSidecar(for: url, body)
            return
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let type = CGImageSourceGetType(source) else { throw MetadataError.unreadable(url) }

        let metadata = CGImageMetadataCreateMutable()
        body(metadata)

        let temp = url.deletingLastPathComponent().appendingPathComponent(".ppk-\(UUID().uuidString)-\(url.lastPathComponent)")
        guard let destination = CGImageDestinationCreateWithURL(temp as CFURL, type, 1, nil) else {
            throw MetadataError.cannotWrite(url)
        }
        let options = [
            kCGImageDestinationMetadata: metadata,
            kCGImageDestinationMergeMetadata: true,
        ] as CFDictionary
        guard CGImageDestinationCopyImageSource(destination, source, options, nil) else {
            try? FileManager.default.removeItem(at: temp)
            throw MetadataError.cannotWrite(url)
        }
        _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
    }

    static func readMetadata(for url: URL) -> CGImageMetadata? {
        let sidecar = sidecarURL(for: url)
        if PhotoImporter.isRaw(url), let data = try? Data(contentsOf: sidecar) {
            return CGImageMetadataCreateFromXMPData(data as CFData)
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCopyMetadataAtIndex(source, 0, nil)
    }

    private static func writeSidecar(for url: URL, _ body: (CGMutableImageMetadata) -> Void) throws {
        let sidecar = sidecarURL(for: url)
        let metadata: CGMutableImageMetadata
        if let data = try? Data(contentsOf: sidecar),
           let existing = CGImageMetadataCreateFromXMPData(data as CFData),
           let copy = CGImageMetadataCreateMutableCopy(existing) {
            metadata = copy
        } else {
            metadata = CGImageMetadataCreateMutable()
        }
        body(metadata)
        guard let xmp = CGImageMetadataCreateXMPData(metadata, nil) else { throw MetadataError.cannotWrite(url) }
        try (xmp as Data).write(to: sidecar, options: .atomic)
    }

    private static func apply(_ fields: IPTCFields, to metadata: CGMutableImageMetadata) {
        func setArray(_ name: String, _ type: CGImageMetadataType, _ values: [String]) {
            let dc = kCGImageMetadataNamespaceDublinCore, prefix = kCGImageMetadataPrefixDublinCore
            guard let tag = CGImageMetadataTagCreate(dc, prefix, name as CFString, type, values as CFArray) else { return }
            CGImageMetadataSetTagWithPath(metadata, nil, "\(prefix):\(name)" as CFString, tag)
        }
        // Com uma string simples, o ImageIO cria o texto alternativo (x-default) nos campos dc:title/description/rights.
        // Criar a tag .alternateText a partir de um dicionário grava um rdf:Alt vazio.
        func setString(_ path: String, _ value: String) {
            guard !value.isEmpty else { return }
            CGImageMetadataSetValueWithPath(metadata, nil, path as CFString, value as CFString)
        }
        setString("dc:title", fields.title)
        setString("dc:description", fields.caption)
        setString("dc:rights", fields.copyright)
        setString("photoshop:City", fields.city)
        setString("photoshop:Country", fields.country)
        if !fields.creator.isEmpty { setArray("creator", .arrayOrdered, [fields.creator]) }
        if !fields.keywordList.isEmpty { setArray("subject", .arrayUnordered, fields.keywordList) }
    }
}

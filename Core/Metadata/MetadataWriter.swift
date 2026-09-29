import Foundation
import ImageIO

/// Campos IPTC editáveis, os mesmos do "IPTC Info" do Photo Mechanic. Em lote, campos vazios não são alterados.
struct IPTCFields: Codable, Equatable, Sendable {
    var headline = ""
    var title = ""
    var caption = ""
    var usageTerms = ""
    /// `yyyy-MM-ddTHH:mm:ss`, como o `photoshop:DateCreated`.
    var dateCreated = ""
    var captionWriter = ""
    var keywords = ""
    var creator = ""
    var creatorTitle = ""
    var credit = ""
    var source = ""
    var copyright = ""
    var instructions = ""
    var jobID = ""
    var sublocation = ""
    var city = ""
    var state = ""
    var country = ""
    var countryCode = ""

    /// Todos os campos de texto, pela ordem da janela.
    // Constantes; os key paths só não são marcados Sendable.
    nonisolated(unsafe) static let textPaths: [WritableKeyPath<IPTCFields, String>] = [
        \.headline, \.title, \.caption, \.usageTerms, \.dateCreated, \.captionWriter, \.keywords, \.creator, \.creatorTitle, \.credit, \.source,
        \.copyright, \.instructions, \.jobID, \.sublocation, \.city, \.state, \.country, \.countryCode,
    ]

    /// Chave de tradução do rótulo de cada campo.
    nonisolated(unsafe) static let labelKeys: [(String, WritableKeyPath<IPTCFields, String>)] = [
        ("meta.headline", \.headline), ("meta.title", \.title), ("meta.caption", \.caption),
        ("meta.usageTerms", \.usageTerms), ("meta.dateCreated", \.dateCreated),
        ("meta.captionWriter", \.captionWriter), ("meta.keywords", \.keywords), ("meta.creator", \.creator),
        ("meta.creatorTitle", \.creatorTitle), ("meta.credit", \.credit), ("meta.source", \.source),
        ("meta.copyright", \.copyright), ("meta.instructions", \.instructions), ("meta.jobID", \.jobID),
        ("meta.sublocation", \.sublocation), ("meta.city", \.city), ("meta.state", \.state),
        ("meta.country", \.country), ("meta.countryCode", \.countryCode),
    ]

    init() {}

    /// Modelos gravados por versões anteriores não têm os campos novos.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func text(_ key: CodingKeys) throws -> String { try container.decodeIfPresent(String.self, forKey: key) ?? "" }
        headline = try text(.headline)
        title = try text(.title)
        caption = try text(.caption)
        usageTerms = try text(.usageTerms)
        dateCreated = try text(.dateCreated)
        captionWriter = try text(.captionWriter)
        keywords = try text(.keywords)
        creator = try text(.creator)
        creatorTitle = try text(.creatorTitle)
        credit = try text(.credit)
        source = try text(.source)
        copyright = try text(.copyright)
        instructions = try text(.instructions)
        jobID = try text(.jobID)
        sublocation = try text(.sublocation)
        city = try text(.city)
        state = try text(.state)
        country = try text(.country)
        countryCode = try text(.countryCode)
    }

    /// `photoshop:DateCreated` aceita só a data, ou data e hora com ou sem fuso.
    static func date(from text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        for format in ["yyyy-MM-dd'T'HH:mm:ssXXXXX", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mmXXXXX", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }

    static func text(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return formatter.string(from: date)
    }

    /// Como fica em `Photo.keywords` (nil sem palavras-chave).
    var catalogKeywords: String? {
        keywordList.isEmpty ? nil : keywordList.joined(separator: ", ")
    }

    var keywordList: [String] {
        keywords.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    var isEmpty: Bool {
        Self.textPaths.filter { $0 != \.keywords }.allSatisfy { self[keyPath: $0].isEmpty } && keywordList.isEmpty
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

    static let iptcCoreNamespace = "http://iptc.org/std/Iptc4xmpCore/1.0/xmlns/"

    /// Escreve sem recomprimir a imagem. Em RAW usa um ficheiro .xmp ao lado (sidecar).
    /// Com `clearEmpty`, um campo vazio apaga o que o ficheiro tinha (edição foto a foto).
    static func write(_ fields: IPTCFields, to url: URL, clearEmpty: Bool = false) throws {
        try update(url) { metadata, merging in apply(fields, to: metadata, clearEmpty: clearEmpty, merging: merging) }
    }

    /// `xmp:Rating` e `xmp:Label`, que o Lightroom e o Bridge leem (só a pedido, para não poluir as pastas).
    static func writeRating(_ rating: Int, label: ColorLabel, to url: URL) throws {
        try update(url) { metadata, _ in
            CGImageMetadataSetValueWithPath(metadata, nil, "xmp:Rating" as CFString, NSNumber(value: min(max(rating, 0), 5)))
            if let name = label.xmpName {
                CGImageMetadataSetValueWithPath(metadata, nil, "xmp:Label" as CFString, name as CFString)
            }
        }
    }

    /// `merging` é verdadeiro quando os valores se juntam aos do ficheiro; aí apagar exige `kCFNull`.
    private static func update(_ url: URL, _ body: (CGMutableImageMetadata, Bool) -> Void) throws {
        if PhotoImporter.isRaw(url) {
            try writeSidecar(for: url, body)
            return
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let type = CGImageSourceGetType(source) else { throw MetadataError.unreadable(url) }

        let metadata = CGImageMetadataCreateMutable()
        body(metadata, true)

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

    /// Um modelo de file info como ficheiro .xmp (o formato dos stationery pads do Photo Mechanic).
    static func xmpData(for fields: IPTCFields) -> Data? {
        let metadata = CGImageMetadataCreateMutable()
        apply(fields, to: metadata, clearEmpty: false, merging: false)
        return CGImageMetadataCreateXMPData(metadata, nil) as Data?
    }

    static func readMetadata(for url: URL) -> CGImageMetadata? {
        let sidecar = sidecarURL(for: url)
        if PhotoImporter.isRaw(url), let data = try? Data(contentsOf: sidecar) {
            return CGImageMetadataCreateFromXMPData(data as CFData)
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCopyMetadataAtIndex(source, 0, nil)
    }

    private static func writeSidecar(for url: URL, _ body: (CGMutableImageMetadata, Bool) -> Void) throws {
        let sidecar = sidecarURL(for: url)
        let metadata: CGMutableImageMetadata
        if let data = try? Data(contentsOf: sidecar),
           let existing = CGImageMetadataCreateFromXMPData(data as CFData),
           let copy = CGImageMetadataCreateMutableCopy(existing) {
            metadata = copy
        } else {
            metadata = CGImageMetadataCreateMutable()
        }
        body(metadata, false)
        guard let xmp = CGImageMetadataCreateXMPData(metadata, nil) else { throw MetadataError.cannotWrite(url) }
        try (xmp as Data).write(to: sidecar, options: .atomic)
    }

    private static func apply(_ fields: IPTCFields, to metadata: CGMutableImageMetadata, clearEmpty: Bool, merging: Bool) {
        CGImageMetadataRegisterNamespaceForPrefix(metadata, iptcCoreNamespace as CFString, "Iptc4xmpCore" as CFString, nil)
        func clear(_ path: String) {
            guard clearEmpty else { return }
            if merging {
                CGImageMetadataSetValueWithPath(metadata, nil, path as CFString, kCFNull)
            } else {
                CGImageMetadataRemoveTagWithPath(metadata, nil, path as CFString)
            }
        }
        func setArray(_ name: String, _ type: CGImageMetadataType, _ values: [String]) {
            let dc = kCGImageMetadataNamespaceDublinCore, prefix = kCGImageMetadataPrefixDublinCore
            guard !values.isEmpty else { return clear("\(prefix):\(name)") }
            guard let tag = CGImageMetadataTagCreate(dc, prefix, name as CFString, type, values as CFArray) else { return }
            CGImageMetadataSetTagWithPath(metadata, nil, "\(prefix):\(name)" as CFString, tag)
        }
        // Com uma string simples, o ImageIO cria o texto alternativo (x-default) nos campos dc:title/description/rights.
        // Criar a tag .alternateText a partir de um dicionário grava um rdf:Alt vazio.
        func setString(_ path: String, _ value: String) {
            guard !value.isEmpty else { return clear(path) }
            CGImageMetadataSetValueWithPath(metadata, nil, path as CFString, value as CFString)
        }
        for (path, keyPath) in xmpPaths { setString(path, fields[keyPath: keyPath]) }
        setArray("creator", .arrayOrdered, fields.creator.isEmpty ? [] : [fields.creator])
        setArray("subject", .arrayUnordered, fields.keywordList)
    }

    /// Campos de texto simples e onde vivem no XMP (os mesmos caminhos que o Photo Mechanic e o Lightroom usam).
    nonisolated(unsafe) static let xmpPaths: [(String, WritableKeyPath<IPTCFields, String>)] = [
        ("photoshop:Headline", \.headline),
        ("dc:title", \.title),
        ("dc:description", \.caption),
        ("xmpRights:UsageTerms", \.usageTerms),
        ("photoshop:DateCreated", \.dateCreated),
        ("photoshop:CaptionWriter", \.captionWriter),
        ("photoshop:AuthorsPosition", \.creatorTitle),
        ("photoshop:Credit", \.credit),
        ("photoshop:Source", \.source),
        ("dc:rights", \.copyright),
        ("photoshop:Instructions", \.instructions),
        ("photoshop:TransmissionReference", \.jobID),
        ("Iptc4xmpCore:Location", \.sublocation),
        ("photoshop:City", \.city),
        ("photoshop:State", \.state),
        ("photoshop:Country", \.country),
        ("Iptc4xmpCore:CountryCode", \.countryCode),
    ]
}

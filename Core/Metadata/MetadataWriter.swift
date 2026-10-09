import Foundation
import ImageIO

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

    /// Espaços de nomes que o ImageIO não conhece à partida.
    static let extraNamespaces = [
        "Iptc4xmpCore": "http://iptc.org/std/Iptc4xmpCore/1.0/xmlns/",
        "Iptc4xmpExt": "http://iptc.org/std/Iptc4xmpExt/2008-02-29/",
    ]

    private static func namespace(for prefix: String) -> CFString? {
        switch prefix {
        case "dc": kCGImageMetadataNamespaceDublinCore
        case "photoshop": kCGImageMetadataNamespacePhotoshop
        case "xmpRights": kCGImageMetadataNamespaceXMPRights
        default: extraNamespaces[prefix] as CFString?
        }
    }

    /// Escreve sem recomprimir a imagem. Em RAW usa um ficheiro .xmp ao lado (sidecar).
    /// Com `clearEmpty`, um campo vazio apaga o que o ficheiro tinha (edição foto a foto).
    static func write(_ fields: IPTCFields, to url: URL, clearEmpty: Bool = false) throws {
        try update(url) { metadata, merging in apply(fields, to: metadata, clearEmpty: clearEmpty, merging: merging) }
    }

    /// `xmp:Rating` e `xmp:Label`, que o Lightroom e o Bridge leem (só a pedido, para não poluir as pastas).
    static func writeRating(_ rating: Int, label: ColorLabel, to url: URL) throws {
        try update(url) { metadata, merging in
            CGImageMetadataSetValueWithPath(metadata, nil, "xmp:Rating" as CFString, NSNumber(value: min(max(rating, 0), 5)))
            if let name = label.xmpName {
                CGImageMetadataSetValueWithPath(metadata, nil, "xmp:Label" as CFString, name as CFString)
            } else if merging {
                CGImageMetadataSetValueWithPath(metadata, nil, "xmp:Label" as CFString, kCFNull)
            } else {
                CGImageMetadataRemoveTagWithPath(metadata, nil, "xmp:Label" as CFString)
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
        if FileManager.default.fileExists(atPath: sidecar.path) {
            // Não tratar um XMP ilegível como se não existisse: pode conter ajustes de outra app.
            let data = try Data(contentsOf: sidecar)
            guard let existing = CGImageMetadataCreateFromXMPData(data as CFData),
                  let copy = CGImageMetadataCreateMutableCopy(existing) else {
                throw MetadataError.unreadable(sidecar)
            }
            metadata = copy
        } else {
            metadata = CGImageMetadataCreateMutable()
        }
        body(metadata, false)
        guard let xmp = CGImageMetadataCreateXMPData(metadata, nil) else { throw MetadataError.cannotWrite(url) }
        try (xmp as Data).write(to: sidecar, options: .atomic)
    }

    private static func apply(_ fields: IPTCFields, to metadata: CGMutableImageMetadata, clearEmpty: Bool, merging: Bool) {
        for (prefix, namespace) in extraNamespaces {
            CGImageMetadataRegisterNamespaceForPrefix(metadata, namespace as CFString, prefix as CFString, nil)
        }
        func clear(_ path: String) {
            guard clearEmpty else { return }
            if merging {
                CGImageMetadataSetValueWithPath(metadata, nil, path as CFString, kCFNull)
            } else if let dot = path.firstIndex(of: ".") {
                removeStructField(String(path[..<dot]), String(path[path.index(after: dot)...]))
            } else {
                CGImageMetadataRemoveTagWithPath(metadata, nil, path as CFString)
            }
        }
        // O ImageIO rebenta (CFRelease) a apagar um campo dentro de uma estrutura; reescreve-se a estrutura sem ele.
        func removeStructField(_ parent: String, _ child: String) {
            guard let tag = CGImageMetadataCopyTagWithPath(metadata, nil, parent as CFString),
                  var fields = CGImageMetadataTagCopyValue(tag) as? [String: AnyObject] else { return }
            let name = child.split(separator: ":").last.map(String.init) ?? child
            fields.removeValue(forKey: name)
            fields.removeValue(forKey: child)
            CGImageMetadataRemoveTagWithPath(metadata, nil, parent as CFString)
            guard !fields.isEmpty,
                  let namespace = CGImageMetadataTagCopyNamespace(tag), let prefix = CGImageMetadataTagCopyPrefix(tag),
                  let structName = CGImageMetadataTagCopyName(tag),
                  let rebuilt = CGImageMetadataTagCreate(namespace, prefix, structName, .structure, fields as CFDictionary)
            else { return }
            CGImageMetadataSetTagWithPath(metadata, nil, parent as CFString, rebuilt)
        }
        for spec in IPTCFields.specs {
            let value = fields[keyPath: spec.path].trimmingCharacters(in: .whitespacesAndNewlines)
            switch spec.kind {
            case .text:
                // Com uma string simples, o ImageIO cria o texto alternativo (x-default) nos campos dc:title/description/rights.
                // Criar a tag .alternateText a partir de um dicionário grava um rdf:Alt vazio.
                guard !value.isEmpty else { clear(spec.xmp); continue }
                CGImageMetadataSetValueWithPath(metadata, nil, spec.xmp as CFString, value as CFString)
            case .bag, .seq:
                // O autor é um só nome (pode ter vírgulas); as outras listas separam-se por vírgulas.
                let values = spec.kind == .seq ? (value.isEmpty ? [] : [value]) : IPTCFields.list(value)
                let parts = spec.xmp.split(separator: ":", maxSplits: 1).map(String.init)
                guard !values.isEmpty else { clear(spec.xmp); continue }
                guard parts.count == 2, let namespace = namespace(for: parts[0]),
                      let tag = CGImageMetadataTagCreate(namespace, parts[0] as CFString, parts[1] as CFString,
                                                         spec.kind == .seq ? .arrayOrdered : .arrayUnordered, values as CFArray)
                else { continue }
                CGImageMetadataSetTagWithPath(metadata, nil, spec.xmp as CFString, tag)
            }
        }
    }
}

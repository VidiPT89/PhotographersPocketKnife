import CoreGraphics
import Foundation
import Vision

/// Palavras-chave automáticas: o Vision classifica a cena, no próprio Mac. Vocabulário em inglês, como nas agências.
enum AutoKeywords {
    static func suggest(for image: CGImage, limit: Int = 8) -> [String] {
        let request = VNClassifyImageRequest()
        guard (try? VNImageRequestHandler(cgImage: image).perform([request])) != nil else { return [] }
        return (request.results ?? [])
            .filter { $0.confidence >= 0.1 && $0.hasMinimumRecall(0.01, forPrecision: 0.9) }
            .sorted { $0.confidence > $1.confidence }
            .prefix(limit)
            .map { $0.identifier.replacingOccurrences(of: "_", with: " ") }
    }

    static func suggest(url: URL, limit: Int = 8) -> [String] {
        guard let thumbnail = ThumbnailCache.shared.thumbnail(for: url, maxPixel: 512) else { return [] }
        return suggest(for: thumbnail.cgImage, limit: limit)
    }

    static func existing(for url: URL) -> [String] {
        guard let metadata = MetadataWriter.readMetadata(for: url),
              let text = MetadataReader.xmpString(metadata, "dc:subject") else { return [] }
        return text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Junta sem repetir (sem distinguir maiúsculas), com as que já existiam primeiro.
    static func merged(_ existing: [String], _ new: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for keyword in existing + new {
            let key = keyword.trimmingCharacters(in: .whitespaces).lowercased()
            if !key.isEmpty, seen.insert(key).inserted { result.append(keyword) }
        }
        return result
    }

    /// Sugere, junta com as existentes e grava no ficheiro (num XMP ao lado, nos RAW). Devolve a lista final.
    static func apply(to url: URL) throws -> [String] {
        let keywords = merged(existing(for: url), suggest(url: url))
        guard !keywords.isEmpty else { return [] }
        var fields = IPTCFields()
        fields.keywords = keywords.joined(separator: ", ")
        try MetadataWriter.write(fields, to: url)
        return keywords
    }
}

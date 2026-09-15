import Foundation
import CryptoKit

/// Ficheiro `.ppk` (JSON) ao lado da foto: a classificação e a revelação sobrevivem mesmo sem o catálogo.
struct PPKSidecar: Codable, Equatable, Sendable {
    var version = 1
    var file: String
    var rating: Int
    var label: String
    var flag: Int
    var develop: EditRecipe?

    /// `DSC_4821.NEF` → `DSC_4821.NEF.ppk` (não colide com pares RAW + JPEG).
    static func url(for photo: URL) -> URL {
        photo.appendingPathExtension("ppk")
    }

    static func read(for photo: URL) -> PPKSidecar? {
        guard let data = try? Data(contentsOf: url(for: photo)) else { return nil }
        return try? JSONDecoder().decode(PPKSidecar.self, from: data)
    }

    func write(for photo: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: Self.url(for: photo), options: .atomic)
    }
}

extension ColorLabel {
    /// Nome usado em `xmp:Label` (Lightroom/Bridge).
    var xmpName: String? {
        switch self {
        case .none: nil
        case .red: "Red"
        case .yellow: "Yellow"
        case .green: "Green"
        case .blue: "Blue"
        case .purple: "Purple"
        }
    }

    init(name: String) {
        self = ColorLabel.allCases.first { "\($0)" == name.lowercased() } ?? .none
    }
}

enum FileChecksum {
    /// SHA-256 do ficheiro completo, lido em blocos de 4 MB.
    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Estrutura de pastas na importação, ex. `{year}/{date}_{event}/{type}` → `2026/2026-09-13_Estoril-Benfica/RAW`.
enum IngestTemplate {
    static let tokens = ["{year}", "{month}", "{day}", "{date}", "{event}", "{type}"]

    static func path(_ template: String, date: Date, event: String, isRaw: Bool) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        let year = String(format: "%04d", c.year ?? 0)
        let month = String(format: "%02d", c.month ?? 0)
        let day = String(format: "%02d", c.day ?? 0)
        let resolved = template
            .replacingOccurrences(of: "{date}", with: "\(year)-\(month)-\(day)")
            .replacingOccurrences(of: "{year}", with: year)
            .replacingOccurrences(of: "{month}", with: month)
            .replacingOccurrences(of: "{day}", with: day)
            .replacingOccurrences(of: "{event}", with: RenameTemplate.sanitize(event).replacingOccurrences(of: " ", with: "-"))
            .replacingOccurrences(of: "{type}", with: isRaw ? "RAW" : "JPEG")
        return resolved
            .split(separator: "/")
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " _-")) }
            .filter { !$0.isEmpty }
            .joined(separator: "/")
    }
}

/// Legendas e títulos com variáveis, resolvidos por foto (essencial para desporto e imprensa).
enum CaptionTemplate {
    static let tokens = ["{date}", "{event}", "{camera}", "{city}", "{country}", "{creator}", "{filename}", "{seq}", "{players}"]

    struct Context: Sendable {
        var date: Date?
        var event = ""
        var camera: String?
        var city = ""
        var country = ""
        var creator = ""
        var fileName = ""
        var sequence = 1
        /// Jogadores reconhecidos pelo número da camisola e pelo plantel.
        var players = ""
    }

    static func usesPlayers(_ text: String) -> Bool { text.contains("{players}") }

    /// `Ronaldo`, `Ronaldo e Pepe`, `Ronaldo, Pepe e Bruno`.
    static func joinNames(_ names: [String], and: String) -> String {
        guard names.count > 1, let last = names.last else { return names.first ?? "" }
        return names.dropLast().joined(separator: ", ") + and + last
    }

    static func resolve(_ text: String, _ context: Context) -> String {
        guard text.contains("{") else { return text }
        let values: [String: String] = [
            "{date}": context.date?.formatted(date: .long, time: .omitted) ?? "",
            "{event}": context.event,
            "{camera}": context.camera ?? "",
            "{city}": context.city,
            "{country}": context.country,
            "{creator}": context.creator,
            "{filename}": context.fileName,
            "{seq}": String(context.sequence),
            "{players}": context.players,
        ]
        var result = text
        for (token, value) in values {
            result = result.replacingOccurrences(of: token, with: value)
        }
        while result.contains("  ") {
            result = result.replacingOccurrences(of: "  ", with: " ")
        }
        return result.trimmingCharacters(in: .whitespaces)
    }
}

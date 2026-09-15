import Foundation

/// Substituições de código ao estilo do Photo Mechanic: ficheiro de texto com colunas separadas por tabulação
/// (`7<TAB>Cristiano Ronaldo<TAB>Ronaldo`). Na legenda, `=7=` dá a 2.ª coluna e `=7#2=` a 3.ª.
struct CodeReplacements: Equatable, Sendable {
    private(set) var entries: [String: [String]] = [:]
    private var folded: [String: [String]] = [:]

    var count: Int { entries.count }
    var isEmpty: Bool { entries.isEmpty }

    static func parse(_ text: String) -> CodeReplacements {
        var result = CodeReplacements()
        for line in text.components(separatedBy: .newlines) {
            let columns = line.components(separatedBy: "\t").map { $0.trimmingCharacters(in: .whitespaces) }
            guard columns.count >= 2, let code = columns.first, !code.isEmpty else { continue }
            var values = Array(columns.dropFirst())
            while values.last?.isEmpty == true { values.removeLast() }
            guard !values.isEmpty, result.entries[code] == nil else { continue }
            result.entries[code] = values
            if result.folded[code.lowercased()] == nil { result.folded[code.lowercased()] = values }
        }
        return result
    }

    func value(for token: String) -> String? {
        let parts = token.split(separator: "#", maxSplits: 1).map(String.init)
        guard let code = parts.first else { return nil }
        let index = parts.count > 1 ? (Int(parts[1]) ?? 0) : 1
        guard let values = entries[code] ?? folded[code.lowercased()], index >= 1, index <= values.count else { return nil }
        return values[index - 1]
    }

    /// Troca cada `=código=` conhecido; o resto do texto (incluindo `=` soltos) fica igual.
    func apply(_ text: String, delimiter: Character = "=") -> String {
        guard !entries.isEmpty, text.contains(delimiter) else { return text }
        var result = ""
        var index = text.startIndex
        while index < text.endIndex {
            if text[index] == delimiter, let close = text[text.index(after: index)...].firstIndex(of: delimiter) {
                let token = text[text.index(after: index)..<close]
                if !token.isEmpty, token.count <= 64, !token.contains(where: \.isWhitespace), let value = value(for: String(token)) {
                    result += value
                    index = text.index(after: close)
                    continue
                }
            }
            result.append(text[index])
            index = text.index(after: index)
        }
        return result
    }

    func apply(to fields: IPTCFields, delimiter: Character = "=") -> IPTCFields {
        var result = fields
        let paths: [WritableKeyPath<IPTCFields, String>] = [\.title, \.caption, \.creator, \.copyright, \.keywords, \.city, \.country]
        for path in paths {
            result[keyPath: path] = apply(result[keyPath: path], delimiter: delimiter)
        }
        return result
    }
}

/// O ficheiro carregado fica guardado nas preferências, para continuar a funcionar se o original mudar de sítio.
enum CodeReplacementStore {
    private static let textKey = "codeReplacements.text"
    private static let nameKey = "codeReplacements.fileName"
    static let delimiterKey = "codeReplacements.delimiter"

    static var fileName: String? { UserDefaults.standard.string(forKey: nameKey) }

    static func load() -> CodeReplacements {
        CodeReplacements.parse(UserDefaults.standard.string(forKey: textKey) ?? "")
    }

    static func save(text: String?, fileName: String?) {
        UserDefaults.standard.set(text, forKey: textKey)
        UserDefaults.standard.set(fileName, forKey: nameKey)
    }

    /// Ficheiros antigos do Photo Mechanic podem vir em Mac Roman ou Latin-1.
    static func readText(_ url: URL) throws -> String {
        for encoding in [String.Encoding.utf8, .macOSRoman, .isoLatin1] {
            if let text = try? String(contentsOf: url, encoding: encoding) { return text }
        }
        return try String(contentsOf: url, encoding: .utf8)
    }
}

import Foundation

/// O que o assistente propõe para o file info, a partir das notas ditadas. Só se aplica depois de o fotógrafo ver a proposta.
struct FileInfoProposal: Equatable, Sendable {
    var headline = ""
    var caption = ""
    var event = ""
    var sublocation = ""
    var city = ""
    var country = ""
    var people: [String] = []
    var keywords: [String] = []

    struct Entry: Identifiable {
        let spec: IPTCFieldSpec
        let value: String
        var id: String { spec.name }
    }

    /// Os campos com valor, pela ordem da ficha.
    var entries: [Entry] {
        let values: [String: String] = [
            "headline": headline, "caption": caption, "event": event, "sublocation": sublocation,
            "city": city, "country": country,
            "personShown": Self.clean(people).joined(separator: ", "),
            "keywords": Self.clean(keywords).joined(separator: ", "),
        ]
        return IPTCFields.specs.compactMap { spec in
            guard let value = values[spec.name]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
            return Entry(spec: spec, value: value)
        }
    }

    var isEmpty: Bool { entries.isEmpty }

    /// Por cima dos campos atuais; as palavras-chave e as pessoas juntam-se às que já lá estavam.
    func applied(to fields: IPTCFields) -> (fields: IPTCFields, changed: Set<String>) {
        var result = fields, changed = Set<String>()
        for entry in entries {
            var value = entry.value
            if entry.spec.kind != .text {
                value = AutoKeywords.merged(IPTCFields.list(fields[keyPath: entry.spec.path]), IPTCFields.list(value)).joined(separator: ", ")
            }
            guard value != fields[keyPath: entry.spec.path] else { continue }
            result[keyPath: entry.spec.path] = value
            changed.insert(entry.spec.name)
        }
        return (result, changed)
    }

    /// As instruções fixas do modelo: só factos das notas, nada inventado.
    static func instructions(portuguese: Bool) -> String {
        """
        You write IPTC metadata for news and sports photographs.
        Use only facts stated in the photographer's notes or in the photo details.
        Never invent names, scores, places, dates or numbers. Leave a field empty when the notes do not state it.
        Write in \(portuguese ? "European Portuguese (Portugal)" : "English"), in news agency style: present tense; who, what, where, when.
        """
    }

    /// O pedido: as notas ditadas e o que a app já sabe da fotografia.
    static func prompt(notes: String, date: Date?, camera: String?, fields: IPTCFields, sceneKeywords: [String]) -> String {
        var details: [String] = []
        if let date { details.append("Date taken: \(IPTCFields.text(from: date))") }
        if let camera, !camera.isEmpty { details.append("Camera: \(camera)") }
        for (label, value) in [("Event", fields.event), ("Place", fields.sublocation), ("City", fields.city), ("Country", fields.country)] where !value.isEmpty {
            details.append("\(label): \(value)")
        }
        if !sceneKeywords.isEmpty { details.append("Detected in the image: \(sceneKeywords.joined(separator: ", "))") }
        return """
        Photographer's notes:
        \(notes.trimmingCharacters(in: .whitespacesAndNewlines))

        Photo details:
        \(details.isEmpty ? "none" : details.joined(separator: "\n"))
        """
    }

    private static func clean(_ list: [String]) -> [String] {
        AutoKeywords.merged([], list.flatMap { IPTCFields.list($0) })
    }
}

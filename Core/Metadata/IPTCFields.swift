import Foundation

/// O file info de uma foto: os campos do "IPTC Info" completo do Photo Mechanic.
/// Em lote, campos vazios não são alterados; foto a foto, um campo vazio apaga o valor.
struct IPTCFields: Codable, Equatable, Sendable {
    // Descrição
    var headline = ""
    var caption = ""
    var captionWriter = ""
    var title = ""
    var keywords = ""
    var category = ""
    var supplementalCategories = ""
    var urgency = ""
    var genre = ""
    var event = ""
    var personShown = ""
    var scene = ""
    var subjectCode = ""
    // Créditos e direitos
    var creator = ""
    var creatorTitle = ""
    var credit = ""
    var source = ""
    var copyright = ""
    /// `True` (com direitos), `False` (domínio público) ou vazio (desconhecido).
    var copyrightStatus = ""
    var copyrightURL = ""
    var usageTerms = ""
    // Local e data
    /// `yyyy-MM-ddTHH:mm:ss`, como o `photoshop:DateCreated`.
    var dateCreated = ""
    var sublocation = ""
    var city = ""
    var state = ""
    var country = ""
    var countryCode = ""
    // Trabalho
    var instructions = ""
    var jobID = ""
    // Contacto do autor
    var contactAddress = ""
    var contactCity = ""
    var contactState = ""
    var contactPostalCode = ""
    var contactCountry = ""
    var contactPhone = ""
    var contactEmail = ""
    var contactWebsite = ""

    init() {}

    /// Gravado como um dicionário `nome: valor`; modelos antigos sem os campos novos continuam a abrir.
    init(from decoder: Decoder) throws {
        let saved = try decoder.singleValueContainer().decode([String: String].self)
        for spec in Self.specs { self[keyPath: spec.path] = saved[spec.name] ?? "" }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(Dictionary(uniqueKeysWithValues: Self.specs.map { ($0.name, self[keyPath: $0.path]) }))
    }

    /// Como fica em `Photo.keywords` (nil sem palavras-chave).
    var catalogKeywords: String? {
        keywordList.isEmpty ? nil : keywordList.joined(separator: ", ")
    }

    var keywordList: [String] { Self.list(keywords) }

    /// O texto do file info que a pesquisa encontra (legenda, headline, evento, pessoas, local…), em minúsculas.
    var searchText: String {
        [headline, title, caption, event, personShown, category, supplementalCategories, creator, credit,
         sublocation, city, state, country, jobID]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
            .lowercased()
    }

    var isEmpty: Bool {
        Self.specs.allSatisfy { spec in spec.kind == .text ? self[keyPath: spec.path].isEmpty : Self.list(self[keyPath: spec.path]).isEmpty }
    }

    static func list(_ text: String) -> [String] {
        text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    // MARK: Datas

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

    /// `{date}`, `{filename}`, `{seq}`… na headline, no título e na legenda, resolvidos para uma foto.
    mutating func resolveVariables(_ context: CaptionTemplate.Context) {
        headline = CaptionTemplate.resolve(headline, context)
        title = CaptionTemplate.resolve(title, context)
        caption = CaptionTemplate.resolve(caption, context)
    }

    func resolvingVariables(_ context: CaptionTemplate.Context) -> IPTCFields {
        var copy = self
        copy.resolveVariables(context)
        return copy
    }

    // MARK: Várias fotos

    /// Os valores iguais em todas as fotos, e os nomes dos campos que diferem (mostrados como "vários valores").
    static func common(_ all: [IPTCFields]) -> (fields: IPTCFields, mixed: Set<String>) {
        var fields = IPTCFields(), mixed = Set<String>()
        guard let first = all.first else { return (fields, mixed) }
        for spec in specs {
            let value = first[keyPath: spec.path]
            if all.allSatisfy({ $0[keyPath: spec.path] == value }) {
                fields[keyPath: spec.path] = value
            } else {
                mixed.insert(spec.name)
            }
        }
        return (fields, mixed)
    }

    /// Esta foto com os campos `changed` trocados pelos de `edits`; o resto fica como estava.
    func replacing(_ changed: [IPTCFieldSpec], from edits: IPTCFields) -> IPTCFields {
        var result = self
        for spec in changed { result[keyPath: spec.path] = edits[keyPath: spec.path] }
        return result
    }
}

enum IPTCGroup: String, CaseIterable, Sendable {
    case description, credits, location, workflow, contact
    var labelKey: String { "fileInfo.group.\(rawValue)" }
}

/// Um campo, onde vive no XMP e como se edita.
struct IPTCFieldSpec: @unchecked Sendable, Identifiable {
    enum Kind: Sendable { case text, bag, seq }
    enum Control: Sendable { case line, box(Int), date, urgency, copyrightStatus }

    /// Nome gravado nos modelos; o rótulo é `meta.<nome>`.
    let name: String
    /// `prefixo:Nome`, ou `prefixo:Estrutura.prefixo:Campo` no contacto do autor.
    let xmp: String
    let path: WritableKeyPath<IPTCFields, String>
    let group: IPTCGroup
    var kind = Kind.text
    var control = Control.line

    var id: String { name }
    var labelKey: String { "meta.\(name)" }

    /// Texto escrito à mão, onde as substituições de código (=7=) fazem sentido; endereços e valores fixos ficam de fora.
    var isFreeText: Bool {
        switch control {
        case .line, .box: !["copyrightURL", "contactEmail", "contactWebsite"].contains(name)
        case .date, .urgency, .copyrightStatus: false
        }
    }
}

extension IPTCFields {
    private static let contact = "Iptc4xmpCore:CreatorContactInfo.Iptc4xmpCore:"

    /// Os mesmos caminhos XMP que o Photo Mechanic, o Lightroom e o Photoshop usam.
    static let specs: [IPTCFieldSpec] = [
        .init(name: "headline", xmp: "photoshop:Headline", path: \.headline, group: .description, control: .box(2)),
        .init(name: "caption", xmp: "dc:description", path: \.caption, group: .description, control: .box(7)),
        .init(name: "captionWriter", xmp: "photoshop:CaptionWriter", path: \.captionWriter, group: .description),
        .init(name: "title", xmp: "dc:title", path: \.title, group: .description),
        .init(name: "keywords", xmp: "dc:subject", path: \.keywords, group: .description, kind: .bag, control: .box(2)),
        .init(name: "category", xmp: "photoshop:Category", path: \.category, group: .description),
        .init(name: "supplementalCategories", xmp: "photoshop:SupplementalCategories", path: \.supplementalCategories, group: .description, kind: .bag),
        .init(name: "urgency", xmp: "photoshop:Urgency", path: \.urgency, group: .description, control: .urgency),
        .init(name: "genre", xmp: "Iptc4xmpCore:IntellectualGenre", path: \.genre, group: .description),
        .init(name: "event", xmp: "Iptc4xmpExt:Event", path: \.event, group: .description),
        .init(name: "personShown", xmp: "Iptc4xmpExt:PersonInImage", path: \.personShown, group: .description, kind: .bag),
        .init(name: "scene", xmp: "Iptc4xmpCore:Scene", path: \.scene, group: .description, kind: .bag),
        .init(name: "subjectCode", xmp: "Iptc4xmpCore:SubjectCode", path: \.subjectCode, group: .description, kind: .bag),

        .init(name: "creator", xmp: "dc:creator", path: \.creator, group: .credits, kind: .seq),
        .init(name: "creatorTitle", xmp: "photoshop:AuthorsPosition", path: \.creatorTitle, group: .credits),
        .init(name: "credit", xmp: "photoshop:Credit", path: \.credit, group: .credits),
        .init(name: "source", xmp: "photoshop:Source", path: \.source, group: .credits),
        .init(name: "copyright", xmp: "dc:rights", path: \.copyright, group: .credits, control: .box(2)),
        .init(name: "copyrightStatus", xmp: "xmpRights:Marked", path: \.copyrightStatus, group: .credits, control: .copyrightStatus),
        .init(name: "copyrightURL", xmp: "xmpRights:WebStatement", path: \.copyrightURL, group: .credits),
        .init(name: "usageTerms", xmp: "xmpRights:UsageTerms", path: \.usageTerms, group: .credits, control: .box(2)),

        .init(name: "dateCreated", xmp: "photoshop:DateCreated", path: \.dateCreated, group: .location, control: .date),
        .init(name: "sublocation", xmp: "Iptc4xmpCore:Location", path: \.sublocation, group: .location),
        .init(name: "city", xmp: "photoshop:City", path: \.city, group: .location),
        .init(name: "state", xmp: "photoshop:State", path: \.state, group: .location),
        .init(name: "country", xmp: "photoshop:Country", path: \.country, group: .location),
        .init(name: "countryCode", xmp: "Iptc4xmpCore:CountryCode", path: \.countryCode, group: .location),

        .init(name: "instructions", xmp: "photoshop:Instructions", path: \.instructions, group: .workflow, control: .box(2)),
        .init(name: "jobID", xmp: "photoshop:TransmissionReference", path: \.jobID, group: .workflow),

        .init(name: "contactAddress", xmp: contact + "CiAdrExtadr", path: \.contactAddress, group: .contact),
        .init(name: "contactCity", xmp: contact + "CiAdrCity", path: \.contactCity, group: .contact),
        .init(name: "contactState", xmp: contact + "CiAdrRegion", path: \.contactState, group: .contact),
        .init(name: "contactPostalCode", xmp: contact + "CiAdrPcode", path: \.contactPostalCode, group: .contact),
        .init(name: "contactCountry", xmp: contact + "CiAdrCtry", path: \.contactCountry, group: .contact),
        .init(name: "contactPhone", xmp: contact + "CiTelWork", path: \.contactPhone, group: .contact),
        .init(name: "contactEmail", xmp: contact + "CiEmailWork", path: \.contactEmail, group: .contact),
        .init(name: "contactWebsite", xmp: contact + "CiUrlWork", path: \.contactWebsite, group: .contact),
    ]
}

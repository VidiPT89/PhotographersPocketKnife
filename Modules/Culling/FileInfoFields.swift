import SwiftUI

/// Os últimos valores de cada campo, para o ▾ ao lado dele (como no Photo Mechanic).
enum FieldHistory {
    private static let key = "fileInfo.history"
    private static let limit = 12

    static func values(for field: String) -> [String] {
        (UserDefaults.standard.dictionary(forKey: key) as? [String: [String]])?[field] ?? []
    }

    static func remember(_ fields: IPTCFields) {
        var all = UserDefaults.standard.dictionary(forKey: key) as? [String: [String]] ?? [:]
        for (field, path) in IPTCFields.labelKeys where path != \.dateCreated {
            let value = fields[keyPath: path].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { continue }
            var list = all[field] ?? []
            list.removeAll { $0 == value }
            list.insert(value, at: 0)
            all[field] = Array(list.prefix(limit))
        }
        UserDefaults.standard.set(all, forKey: key)
    }
}

/// Uma linha do IPTC Info: rótulo, caixa de texto e o ▾ com os valores recentes.
struct FileInfoRow: View {
    @Environment(AppState.self) private var app
    let key: String
    @Binding var text: String
    var lines = 1

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(app.t(key) + ":")
                .font(Typography.caption)
                .foregroundStyle(Palette.textSecondary)
                .frame(width: 150, alignment: .leading)
                .padding(.top, 4)
            if lines > 1 {
                TextEditor(text: $text)
                    .font(Typography.body)
                    .scrollContentBackground(.hidden)
                    .padding(4)
                    .frame(height: CGFloat(lines) * 17 + 10)
                    .background(Palette.panel, in: RoundedRectangle(cornerRadius: 5))
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(Palette.separator))
                    .accessibilityLabel(app.t(key))
            } else {
                TextField("", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel(app.t(key))
            }
            Menu {
                let recent = FieldHistory.values(for: key)
                if recent.isEmpty {
                    Text(app.t("fileInfo.noRecent"))
                } else {
                    ForEach(recent, id: \.self) { value in
                        Button(value.count > 60 ? String(value.prefix(60)) + "…" : value) { text = value }
                    }
                }
            } label: {
                Image(systemName: "chevron.down.square")
            }
            .menuIndicator(.hidden)
            .buttonStyle(.borderless)
            .fixedSize()
            .padding(.top, 3)
            .hint(app.t("fileInfo.recent"))
        }
    }
}

/// Os campos em secções de formulário, para a janela de metadados em lote.
struct IPTCFormSections: View {
    @Environment(AppState.self) private var app
    @Binding var fields: IPTCFields

    var body: some View {
        Section(app.t("fileInfo.description")) {
            field("meta.headline", \.headline)
            field("meta.title", \.title)
            TextField(app.t("meta.caption"), text: $fields.caption, axis: .vertical).lineLimit(3...6)
            field("meta.captionWriter", \.captionWriter)
            field("meta.keywords", \.keywords)
        }
        Section(app.t("fileInfo.credits")) {
            field("meta.creator", \.creator)
            field("meta.creatorTitle", \.creatorTitle)
            field("meta.credit", \.credit)
            field("meta.source", \.source)
            field("meta.copyright", \.copyright)
            field("meta.usageTerms", \.usageTerms)
            field("meta.instructions", \.instructions)
            field("meta.jobID", \.jobID)
        }
        Section(app.t("fileInfo.location")) {
            field("meta.sublocation", \.sublocation)
            field("meta.city", \.city)
            field("meta.state", \.state)
            field("meta.country", \.country)
            field("meta.countryCode", \.countryCode)
        }
    }

    private func field(_ key: String, _ path: WritableKeyPath<IPTCFields, String>) -> some View {
        TextField(app.t(key), text: Binding(get: { fields[keyPath: path] }, set: { fields[keyPath: path] = $0 }))
    }
}

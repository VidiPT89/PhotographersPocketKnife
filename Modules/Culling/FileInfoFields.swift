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
        for spec in IPTCFields.specs {
            switch spec.control {
            case .line, .box: remember(fields[keyPath: spec.path], for: spec.name, in: &all)
            case .date, .urgency, .copyrightStatus: continue
            }
        }
        UserDefaults.standard.set(all, forKey: key)
    }

    private static func remember(_ text: String, for field: String, in all: inout [String: [String]]) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        var list = all[field] ?? []
        list.removeAll { $0 == value }
        list.insert(value, at: 0)
        all[field] = Array(list.prefix(limit))
    }
}

/// Uma linha do IPTC Info: rótulo, controlo e, nos campos de texto, o ▾ com os valores recentes.
/// `mixed` é para várias fotos com valores diferentes neste campo.
struct FileInfoRow: View {
    @Environment(AppState.self) private var app
    let spec: IPTCFieldSpec
    @Binding var text: String
    var mixed = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(app.t(spec.labelKey) + ":")
                .font(Typography.caption)
                .foregroundStyle(Palette.textSecondary)
                .frame(width: 160, alignment: .leading)
                .padding(.top, 4)
            control
        }
    }

    @ViewBuilder
    private var control: some View {
        switch spec.control {
        case .urgency, .copyrightStatus:
            IPTCPicker(spec: spec, text: $text, mixed: mixed)
        case .box(let lines):
            TextEditor(text: $text)
                .font(Typography.body)
                .scrollContentBackground(.hidden)
                .padding(4)
                .frame(height: CGFloat(lines) * 17 + 10)
                .background(Palette.panel, in: RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Palette.separator))
                .overlay(alignment: .topLeading) {
                    if mixed, text.isEmpty {
                        Text(app.t("fileInfo.mixed")).italic().foregroundStyle(Palette.textSecondary).padding(8).allowsHitTesting(false)
                    }
                }
                .accessibilityLabel(app.t(spec.labelKey))
            recentMenu
        case .line, .date:
            TextField("", text: $text, prompt: mixed ? Text(app.t("fileInfo.mixed")).italic() : nil)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel(app.t(spec.labelKey))
            recentMenu
        }
    }

    private var recentMenu: some View {
        Menu {
            let recent = FieldHistory.values(for: spec.name)
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

/// Urgência (1 a 8) e estado do copyright, que só aceitam valores fixos.
struct IPTCPicker: View {
    @Environment(AppState.self) private var app
    let spec: IPTCFieldSpec
    @Binding var text: String
    var mixed = false

    var body: some View {
        Picker("", selection: $text) {
            if case .urgency = spec.control {
                Text(mixed ? app.t("fileInfo.mixed") : "—").tag("")
                ForEach(1...8, id: \.self) { level in
                    Text(label(level)).tag("\(level)")
                }
            } else {
                Text(mixed ? app.t("fileInfo.mixed") : app.t("fileInfo.status.unknown")).tag("")
                Text(app.t("fileInfo.status.copyrighted")).tag("True")
                Text(app.t("fileInfo.status.publicDomain")).tag("False")
            }
        }
        .labelsHidden()
        .fixedSize()
        .accessibilityLabel(app.t(spec.labelKey))
    }

    private func label(_ level: Int) -> String {
        switch level {
        case 1: "1 · " + app.t("fileInfo.urgency.high")
        case 8: "8 · " + app.t("fileInfo.urgency.low")
        default: "\(level)"
        }
    }
}

/// Os campos em secções de formulário, para a janela de metadados em lote.
struct IPTCFormSections: View {
    @Environment(AppState.self) private var app
    @Binding var fields: IPTCFields

    var body: some View {
        ForEach(IPTCGroup.allCases, id: \.self) { group in
            Section(app.t(group.labelKey)) {
                ForEach(IPTCFields.specs.filter { $0.group == group && $0.name != "dateCreated" }) { spec in
                    field(spec)
                }
            }
        }
    }

    @ViewBuilder
    private func field(_ spec: IPTCFieldSpec) -> some View {
        let text = Binding(get: { fields[keyPath: spec.path] }, set: { fields[keyPath: spec.path] = $0 })
        switch spec.control {
        case .urgency, .copyrightStatus:
            LabeledContent(app.t(spec.labelKey)) { IPTCPicker(spec: spec, text: text) }
        case .box(let lines):
            TextField(app.t(spec.labelKey), text: text, axis: .vertical).lineLimit(min(lines, 2)...max(lines, 2))
        case .line, .date:
            TextField(app.t(spec.labelKey), text: text)
        }
    }
}

import SwiftUI

/// O "IPTC Info" do Photo Mechanic: campos à esquerda, a foto à direita.
/// Com várias fotos escolhidas, "Todas juntas" grava os mesmos campos em todas; "Uma a uma" percorre-as.
struct FileInfoSheet: View {
    @Environment(AppState.self) var app
    @Environment(\.dismiss) var dismiss
    let photos: [Photo]

    @State var index: Int
    @State var together: Bool
    @State var fields = IPTCFields()
    @State var original = IPTCFields()
    /// Campos com valores diferentes entre as fotos (só em "Todas juntas").
    @State var mixed: Set<String> = []
    /// "Hora de captura" em "Todas juntas": cada foto recebe a sua.
    @State var perPhotoCaptureTime = false
    @State var isLoading = true
    @State var isSaving = false
    /// Passo à espera da resposta a "Guardar alterações?".
    @State var pendingStep: FileInfoStep?
    @State var message: String?
    @State var codes = CodeReplacements()
    @AppStorage(CodeReplacementStore.delimiterKey) var delimiter = "="

    init(photos: [Photo], start: Int = 0, together: Bool = false) {
        self.photos = photos
        _index = State(initialValue: min(max(start, 0), max(photos.count - 1, 0)))
        _together = State(initialValue: together && photos.count > 1)
    }

    var photo: Photo? { photos.indices.contains(index) ? photos[index] : nil }
    var delimiterCharacter: Character { delimiter.first ?? "=" }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                ScrollView { fieldList.padding(14) }
                    .frame(width: 620)
                    .background(Palette.panel, in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Palette.separator))
                    .disabled(isLoading)
                sidePanel
            }
            .padding(12)
            Divider()
            bottomBar
        }
        .frame(width: 1100, height: 800)
        // Como no Photo Mechanic: ao fechar o código (=7=) o texto é logo trocado.
        .onChange(of: fields.caption) { _, value in replaceCodes(value, \.caption) }
        .onChange(of: fields.headline) { _, value in replaceCodes(value, \.headline) }
        .onChange(of: fields.title) { _, value in replaceCodes(value, \.title) }
        .onAppear { codes = CodeReplacementStore.load() }
        // Esc dentro de uma caixa de texto fechava a janela sem passar pelo Cancelar (e sem perguntar).
        .interactiveDismissDisabled(hasChanges)
        .onExitCommand { request(.close) }
        .confirmationDialog(app.t("fileInfo.unsaved"), isPresented: Binding(get: { pendingStep != nil }, set: { if !$0 { pendingStep = nil } })) {
            if let step = pendingStep {
                Button(app.t("fileInfo.save")) { pendingStep = nil; commit(then: step) }
                Button(app.t("fileInfo.discard"), role: .destructive) { pendingStep = nil; perform(step) }
                Button(app.t("common.cancel"), role: .cancel) { pendingStep = nil }
            }
        } message: {
            Text(app.t("fileInfo.unsavedHint"))
        }
        .task(id: "\(together)|\(photo?.id.uuidString ?? "")") { await load() }
    }

    // MARK: Campos

    private var fieldList: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(IPTCGroup.allCases, id: \.self) { group in
                Text(app.t(group.labelKey).uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(Palette.textSecondary)
                    .padding(.top, group == .description ? 0 : 10)
                ForEach(IPTCFields.specs.filter { $0.group == group }) { spec in
                    if case .date = spec.control {
                        dateRow(spec)
                    } else {
                        FileInfoRow(spec: spec, text: binding(spec), mixed: mixed.contains(spec.name) && fields[keyPath: spec.path].isEmpty)
                    }
                }
            }
        }
    }

    private func binding(_ spec: IPTCFieldSpec) -> Binding<String> {
        Binding(get: { fields[keyPath: spec.path] }, set: { fields[keyPath: spec.path] = $0 })
    }

    private func dateRow(_ spec: IPTCFieldSpec) -> some View {
        HStack(spacing: 8) {
            Text(app.t(spec.labelKey) + ":")
                .font(Typography.caption)
                .foregroundStyle(Palette.textSecondary)
                .frame(width: 160, alignment: .leading)
            DatePicker("", selection: Binding(
                get: { IPTCFields.date(from: fields.dateCreated) ?? photo?.captureDate ?? Date() },
                set: { fields.dateCreated = IPTCFields.text(from: $0); perPhotoCaptureTime = false }
            ), displayedComponents: [.date, .hourAndMinute])
            .labelsHidden()
            .disabled(perPhotoCaptureTime)
            .accessibilityLabel(app.t(spec.labelKey))
            if together {
                Toggle(app.t("fileInfo.captureTimeEach"), isOn: $perPhotoCaptureTime)
            } else {
                Button(app.t("fileInfo.captureTime")) {
                    if let date = photo?.captureDate { fields.dateCreated = IPTCFields.text(from: date) }
                }
                .disabled(photo?.captureDate == nil)
            }
            if together, mixed.contains(spec.name), fields.dateCreated.isEmpty, !perPhotoCaptureTime {
                Text(app.t("fileInfo.mixed")).italic().font(Typography.caption).foregroundStyle(Palette.textSecondary)
            }
            Spacer()
        }
    }

    // MARK: Foto e navegação

    private var sidePanel: some View {
        VStack(spacing: 12) {
            if photos.count > 1 {
                Picker("", selection: Binding(get: { together }, set: { request(.mode(together: $0)) })) {
                    Text(String(format: app.t("fileInfo.together"), photos.count)).tag(true)
                    Text(app.t("fileInfo.oneByOne")).tag(false)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .disabled(isSaving)
            }
            preview
            example
            if together {
                Text(String(format: app.t("fileInfo.togetherHint"), photos.count))
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textSecondary)
                    .multilineTextAlignment(.center)
            } else if let photo {
                VStack(spacing: 2) {
                    Text(photo.fileName)
                        .font(Typography.body.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(String(format: app.t("fileInfo.position"), index + 1, photos.count))
                        .font(Typography.caption)
                        .foregroundStyle(Palette.textSecondary)
                }
            }
            buttons
            if isSaving { ProgressView().controlSize(.small) }
            if let message {
                Text(message).font(Typography.caption).foregroundStyle(Brand.error)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    /// Uma foto, ou as primeiras quatro em mosaico quando se preenchem todas juntas.
    private var preview: some View {
        ZStack {
            Color.black
            if together {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 4), GridItem(.flexible(), spacing: 4)], spacing: 4) {
                    ForEach(photos.prefix(4)) { photo in
                        ThumbnailView(url: photo.url, maxPixel: 480, recipeData: photo.recipeData, fit: true).frame(height: 150)
                    }
                }
                .padding(8)
            } else if let photo {
                ThumbnailView(url: photo.url, maxPixel: 1200, recipeData: photo.recipeData, fit: true)
            }
        }
        .frame(height: 320)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var buttons: some View {
        Grid(horizontalSpacing: 8, verticalSpacing: 8) {
            if !together {
                GridRow {
                    Button { commit(then: .go(index - 1)) } label: { Label(app.t("fileInfo.savePrevious"), systemImage: "arrow.left") }
                        .keyboardShortcut("[", modifiers: .command)
                        .disabled(index == 0)
                    Button { commit(then: .go(index + 1)) } label: { Label(app.t("fileInfo.saveNext"), systemImage: "arrow.right") }
                        .keyboardShortcut("]", modifiers: .command)
                        .disabled(index >= photos.count - 1)
                }
                GridRow {
                    Button { request(.go(index - 1)) } label: { Image(systemName: "arrow.left").frame(maxWidth: .infinity) }
                        .disabled(index == 0)
                        .hint(app.t("fileInfo.previous"))
                    Button { request(.go(index + 1)) } label: { Image(systemName: "arrow.right").frame(maxWidth: .infinity) }
                        .disabled(index >= photos.count - 1)
                        .hint(app.t("fileInfo.next"))
                }
            }
            GridRow {
                Button(app.t("fileInfo.copy")) { app.culling.fileInfoClipboard = fields }
                Button(app.t("fileInfo.paste")) { app.culling.fileInfoClipboard.map(merge) }
                    .disabled(app.culling.fileInfoClipboard == nil)
            }
        }
        .controlSize(.large)
        .disabled(isLoading || isSaving)
        .frame(width: 320)
    }

    private var bottomBar: some View {
        HStack(spacing: 8) {
            Group {
                Button(app.t("fileInfo.clear")) { clear() }
                Menu(app.t("fileInfo.load")) {
                    Button(app.t("fileInfo.loadFile")) { loadTemplate() }
                    let templates = captionTemplates
                    if !templates.isEmpty {
                        Section(app.t("fileInfo.captionTemplates")) {
                            ForEach(templates, id: \.self) { template in
                                Button(template.name) {
                                    fields.title = template.title
                                    fields.caption = template.caption
                                }
                            }
                        }
                    }
                }
                .fixedSize()
                Button(app.t("fileInfo.saveTemplate")) { saveTemplate() }
                Menu(app.t("fileInfo.stationeryPad")) {
                    Button(app.t("fileInfo.stationeryApply")) { stationeryPad.map(merge) }
                        .disabled(stationeryPad == nil)
                    Button(app.t("fileInfo.stationerySave")) { saveStationeryPad() }
                }
                .fixedSize()
                .hint(app.t("fileInfo.stationeryPadHint"))
                codesMenu
                Menu(app.t("fileInfo.variables")) {
                    ForEach(CaptionTemplate.tokens, id: \.self) { token in
                        Button(token) { fields.caption += (fields.caption.isEmpty || fields.caption.hasSuffix(" ") ? "" : " ") + token }
                    }
                    Divider()
                    Text(app.t(codes.isEmpty ? "metadata.playersNeedsRoster" : "metadata.playersHint"))
                }
                .fixedSize()
            }
            .disabled(isLoading || photos.isEmpty)
            Spacer()
            Button(app.t("common.cancel")) { request(.close) }
                .keyboardShortcut(.cancelAction)
            Button(together ? String(format: app.t("metadata.applyTo"), photos.count) : "OK") { commit(then: .close) }
            .keyboardShortcut(.defaultAction)
            .disabled(isLoading || isSaving || photos.isEmpty)
        }
        .padding(12)
    }

    /// Ficheiro de substituições de código (=7=), como no Photo Mechanic.
    private var codesMenu: some View {
        Menu(app.t("codes.title")) {
            Text(CodeReplacementStore.fileName.map { String(format: app.t("codes.loaded"), $0, codes.count) } ?? app.t("codes.none"))
            Button(app.t("codes.load")) { loadCodes() }
            if !codes.isEmpty {
                Button(app.t("codes.remove")) { removeCodes() }
            }
            Picker(app.t("codes.delimiter"), selection: $delimiter) {
                ForEach(Array(Set(["=", "\\", "/", "#", "%", delimiter])).sorted(), id: \.self) { Text($0).tag($0) }
            }
            Divider()
            Text(app.t("codes.hint"))
        }
        .fixedSize()
    }

    /// Como fica a legenda (ou a headline) com as variáveis, na foto em foco.
    @ViewBuilder
    private var example: some View {
        let text = fields.caption.contains("{") ? fields.caption : fields.headline
        if text.contains("{"), let photo {
            let values = codes.apply(to: fields, delimiter: delimiterCharacter)
            let sample = values.resolvingVariables(context(for: photo, index: index, values: values))
            Text(app.t("import.example") + ": " + (fields.caption.contains("{") ? sample.caption : sample.headline))
                .font(Typography.caption)
                .foregroundStyle(Palette.textSecondary)
                .lineLimit(3)
                .multilineTextAlignment(.center)
        }
    }
}

import SwiftUI
import UniformTypeIdentifiers

/// O "IPTC Info" do Photo Mechanic: o file info de cada foto, uma a uma, com o que já tem gravado.
/// Campos à esquerda, a foto à direita, "Guardar e →" para passar à seguinte.
struct FileInfoSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    let photos: [Photo]

    @State private var index: Int
    @State private var fields = IPTCFields()
    @State private var original = IPTCFields()
    @State private var isLoading = true
    @State private var isSaving = false
    @State private var message: String?
    @State private var codes = CodeReplacements()
    @AppStorage(CodeReplacementStore.delimiterKey) private var delimiter = "="

    init(photos: [Photo], start: Int = 0) {
        self.photos = photos
        _index = State(initialValue: min(max(start, 0), max(photos.count - 1, 0)))
    }

    private var photo: Photo? { photos.indices.contains(index) ? photos[index] : nil }
    private var delimiterCharacter: Character { delimiter.first ?? "=" }
    private static let xmpType = UTType(filenameExtension: "xmp") ?? .xml

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                ScrollView { fieldList.padding(14) }
                    .frame(width: 590)
                    .background(Palette.panel, in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Palette.separator))
                    .disabled(isLoading)
                sidePanel
            }
            .padding(12)
            Divider()
            bottomBar
        }
        .frame(width: 1080, height: 780)
        // Como no Photo Mechanic: ao fechar o código (=7=) o texto é logo trocado.
        .onChange(of: fields.caption) { _, value in replaceCodes(value, \.caption) }
        .onChange(of: fields.headline) { _, value in replaceCodes(value, \.headline) }
        .onChange(of: fields.title) { _, value in replaceCodes(value, \.title) }
        .onAppear { codes = CodeReplacementStore.load() }
        .task(id: photo?.id) { await load() }
    }

    // MARK: Campos

    private var fieldList: some View {
        VStack(alignment: .leading, spacing: 8) {
            row("meta.headline", \.headline, lines: 2)
            row("meta.caption", \.caption, lines: 7)
            row("meta.usageTerms", \.usageTerms, lines: 2)
            row("meta.title", \.title)
            row("meta.creator", \.creator)
            row("meta.copyright", \.copyright, lines: 2)
            row("meta.credit", \.credit)
            dateRow
            row("meta.city", \.city)
            row("meta.sublocation", \.sublocation)
            row("meta.state", \.state)
            row("meta.country", \.country)
            row("meta.countryCode", \.countryCode)
            row("meta.instructions", \.instructions, lines: 2)
            Divider().padding(.vertical, 4)
            row("meta.keywords", \.keywords, lines: 2)
            row("meta.captionWriter", \.captionWriter)
            row("meta.creatorTitle", \.creatorTitle)
            row("meta.source", \.source)
            row("meta.jobID", \.jobID)
        }
    }

    private func row(_ key: String, _ path: WritableKeyPath<IPTCFields, String>, lines: Int = 1) -> some View {
        FileInfoRow(key: key, text: Binding(get: { fields[keyPath: path] }, set: { fields[keyPath: path] = $0 }), lines: lines)
    }

    private var dateRow: some View {
        HStack(spacing: 8) {
            Text(app.t("meta.dateCreated") + ":")
                .font(Typography.caption)
                .foregroundStyle(Palette.textSecondary)
                .frame(width: 150, alignment: .leading)
            DatePicker("", selection: Binding(
                get: { IPTCFields.date(from: fields.dateCreated) ?? photo?.captureDate ?? Date() },
                set: { fields.dateCreated = IPTCFields.text(from: $0) }
            ), displayedComponents: [.date, .hourAndMinute])
            .labelsHidden()
            .accessibilityLabel(app.t("meta.dateCreated"))
            Button(app.t("fileInfo.captureTime")) {
                if let date = photo?.captureDate { fields.dateCreated = IPTCFields.text(from: date) }
            }
            .disabled(photo?.captureDate == nil)
            Spacer()
        }
    }

    // MARK: Foto e navegação

    private var sidePanel: some View {
        VStack(spacing: 12) {
            ZStack {
                Color.black
                if let photo {
                    ThumbnailView(url: photo.url, maxPixel: 1200, recipeData: photo.recipeData, fit: true)
                }
            }
            .frame(height: 340)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            if let photo {
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
            Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                GridRow {
                    Button { save(then: index - 1) } label: { Label(app.t("fileInfo.savePrevious"), systemImage: "arrow.left") }
                        .keyboardShortcut("[", modifiers: .command)
                        .disabled(index == 0)
                    Button { save(then: index + 1) } label: { Label(app.t("fileInfo.saveNext"), systemImage: "arrow.right") }
                        .keyboardShortcut("]", modifiers: .command)
                        .disabled(index >= photos.count - 1)
                }
                GridRow {
                    Button { index -= 1 } label: { Image(systemName: "arrow.left").frame(maxWidth: .infinity) }
                        .disabled(index == 0)
                        .hint(app.t("fileInfo.previous"))
                    Button { index += 1 } label: { Image(systemName: "arrow.right").frame(maxWidth: .infinity) }
                        .disabled(index >= photos.count - 1)
                        .hint(app.t("fileInfo.next"))
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
            if isSaving { ProgressView().controlSize(.small) }
            if let message {
                Text(message).font(Typography.caption).foregroundStyle(Brand.error)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var bottomBar: some View {
        HStack(spacing: 8) {
            Button(app.t("fileInfo.clear")) { clear() }
            Button(app.t("fileInfo.load")) { loadTemplate() }
            Button(app.t("fileInfo.saveTemplate")) { saveTemplate() }
            Button(app.t("fileInfo.stationeryPad")) { stationeryPad.map(merge) }
                .disabled(stationeryPad == nil)
                .hint(app.t("fileInfo.stationeryPadHint"))
            Menu(app.t("fileInfo.variables")) {
                ForEach(CaptionTemplate.tokens.filter { $0 != "{players}" }, id: \.self) { token in
                    Button(token) { fields.caption += (fields.caption.isEmpty || fields.caption.hasSuffix(" ") ? "" : " ") + token }
                }
            }
            .fixedSize()
            Spacer()
            Button(app.t("common.cancel")) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("OK") { save(then: nil) }
                .keyboardShortcut(.defaultAction)
                .disabled(isLoading || isSaving)
        }
        .disabled(isLoading)
        .padding(12)
    }

    // MARK: Ações

    /// O que ficou gravado na janela de metadados em lote.
    private var stationeryPad: IPTCFields? {
        UserDefaults.standard.data(forKey: MetadataSheet.storageKey)
            .flatMap { try? JSONDecoder().decode(IPTCFields.self, from: $0) }
            .flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Junta os campos preenchidos de `other` aos atuais.
    private func merge(_ other: IPTCFields) {
        for path in IPTCFields.textPaths where !other[keyPath: path].isEmpty {
            fields[keyPath: path] = other[keyPath: path]
        }
    }

    private func clear() {
        fields = IPTCFields()
        if let date = photo?.captureDate { fields.dateCreated = IPTCFields.text(from: date) }
    }

    private func replaceCodes(_ value: String, _ path: WritableKeyPath<IPTCFields, String>) {
        let replaced = codes.apply(value, delimiter: delimiterCharacter)
        if replaced != value { fields[keyPath: path] = replaced }
    }

    private func loadTemplate() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [Self.xmpType, .xml]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let data = try? Data(contentsOf: url), let loaded = MetadataReader.iptcFields(xmpData: data), !loaded.isEmpty else {
            message = app.t("fileInfo.templateEmpty")
            return
        }
        merge(loaded)
        message = nil
    }

    private func saveTemplate() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [Self.xmpType]
        panel.nameFieldStringValue = "\(app.t("fileInfo.title")).xmp"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var template = fields
        template.dateCreated = ""
        do {
            guard let data = MetadataWriter.xmpData(for: template) else { throw MetadataError.cannotWrite(url) }
            try data.write(to: url, options: .atomic)
        } catch {
            message = error.localizedDescription
        }
    }

    private func load() async {
        guard let photo else { return }
        let url = photo.url
        isLoading = true
        var read = await Task.detached(priority: .userInitiated) { MetadataReader.iptcFields(for: url) }.value
        guard !Task.isCancelled else { return }
        // Como a "Capture Time" do Photo Mechanic: sem data gravada, propõe a da captura.
        if read.dateCreated.isEmpty, let date = photo.captureDate { read.dateCreated = IPTCFields.text(from: date) }
        fields = read
        original = read
        message = nil
        isLoading = false
    }

    /// Grava a foto atual (se mudou) e passa a `target`; com `nil`, fecha.
    private func save(then target: Int?) {
        guard let photo else { return dismiss() }
        var resolved = codes.apply(to: fields, delimiter: delimiterCharacter)
        let context = CaptionTemplate.Context(
            date: photo.captureDate, camera: photo.camera, city: resolved.city, country: resolved.country,
            creator: resolved.creator, fileName: photo.fileName, sequence: index + 1
        )
        for path in [\IPTCFields.headline, \.title, \.caption] {
            resolved[keyPath: path] = CaptionTemplate.resolve(resolved[keyPath: path], context)
        }
        let values = resolved
        guard values != original else { return move(to: target) }
        let url = photo.url
        isSaving = true
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Result { try MetadataWriter.write(values, to: url, clearEmpty: true) }
            }.value
            isSaving = false
            switch result {
            case .success:
                photo.keywords = values.catalogKeywords
                app.culling.metadataRevision += 1
                FieldHistory.remember(values)
                if target == nil { app.showToast(app.t("toast.fileInfo"), icon: "info.circle.fill") }
                move(to: target)
            case .failure(let error):
                message = error.localizedDescription
            }
        }
    }

    private func move(to target: Int?) {
        guard let target, photos.indices.contains(target) else { return dismiss() }
        index = target
    }
}

import SwiftUI

/// "IPTC Info" do Photo Mechanic: o file info de cada foto, uma a uma, com o que já tem gravado.
/// Ao passar à seguinte, as alterações da atual ficam gravadas.
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

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Form {
                IPTCFormSections(fields: $fields)
                if let message { Text(message).foregroundStyle(Brand.error) }
            }
            .formStyle(.grouped)
            .disabled(isLoading)
            buttons
        }
        .frame(width: 560, height: 800)
        // Como no Photo Mechanic: ao fechar o código (=7=) o texto é logo trocado.
        .onChange(of: fields.caption) { _, value in replaceCodes(value, \.caption) }
        .onChange(of: fields.headline) { _, value in replaceCodes(value, \.headline) }
        .onChange(of: fields.title) { _, value in replaceCodes(value, \.title) }
        .onAppear { codes = CodeReplacementStore.load() }
        .task(id: photo?.id) { await load() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            if let photo {
                ThumbnailView(url: photo.url, maxPixel: 320, fit: true)
                    .frame(width: 96, height: 72)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                VStack(alignment: .leading, spacing: 2) {
                    Text(photo.fileName)
                        .font(Typography.body.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(String(format: app.t("fileInfo.position"), index + 1, photos.count))
                        .font(Typography.caption)
                        .foregroundStyle(Palette.textSecondary)
                }
            }
            Spacer()
        }
        .padding(16)
    }

    private var buttons: some View {
        HStack {
            Button { go(to: index - 1) } label: { Label(app.t("fileInfo.previous"), systemImage: "chevron.left") }
                .keyboardShortcut("[", modifiers: .command)
                .disabled(index == 0 || isSaving)
            Button { go(to: index + 1) } label: { Label(app.t("fileInfo.next"), systemImage: "chevron.right") }
                .keyboardShortcut("]", modifiers: .command)
                .disabled(index >= photos.count - 1 || isSaving)
            if isSaving { ProgressView().controlSize(.small) }
            Spacer()
            Button(app.t("common.cancel")) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button(app.t("fileInfo.save")) { go(to: nil) }
                .keyboardShortcut(.defaultAction)
                .disabled(isLoading || isSaving)
        }
        .padding(16)
    }

    private func replaceCodes(_ value: String, _ path: WritableKeyPath<IPTCFields, String>) {
        let replaced = codes.apply(value, delimiter: delimiterCharacter)
        if replaced != value { fields[keyPath: path] = replaced }
    }

    private func load() async {
        guard let url = photo?.url else { return }
        isLoading = true
        let read = await Task.detached(priority: .userInitiated) { MetadataReader.iptcFields(for: url) }.value
        guard !Task.isCancelled else { return }
        fields = read
        original = read
        message = nil
        isLoading = false
    }

    /// Grava a foto atual (se mudou) e passa a `target`; com `nil`, fecha.
    private func go(to target: Int?) {
        guard let photo else { return dismiss() }
        let url = photo.url
        let values = codes.apply(to: fields, delimiter: delimiterCharacter)
        guard values != original else { return move(to: target) }
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

/// Os campos do IPTC Info, agrupados como no Photo Mechanic. Usados foto a foto e em lote.
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

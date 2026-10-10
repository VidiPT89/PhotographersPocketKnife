import SwiftUI
import UniformTypeIdentifiers

/// O que fazer depois de guardar (ou descartar) as alterações.
enum FileInfoStep: Equatable {
    case go(Int), mode(together: Bool), close
}

/// Ler, gravar, modelos e códigos do File Info.
extension FileInfoSheet {
    private static let xmpType = UTType(filenameExtension: "xmp") ?? .xml
    /// A chave antiga da janela de lote, para o Stationery Pad que lá ficou gravado continuar a aparecer.
    static let stationeryKey = "metadata.lastFields"
    private static let captionTemplatesKey = "metadata.captionTemplates"

    /// Modelos de legenda da antiga janela de lote.
    struct CaptionTemplateItem: Codable, Hashable {
        var name: String
        var title: String
        var caption: String
    }

    var hasChanges: Bool { fields != original || perPhotoCaptureTime }

    // MARK: Modelos, Stationery Pad e códigos

    var stationeryPad: IPTCFields? {
        UserDefaults.standard.data(forKey: Self.stationeryKey)
            .flatMap { try? JSONDecoder().decode(IPTCFields.self, from: $0) }
            .flatMap { $0.isEmpty ? nil : $0 }
    }

    func saveStationeryPad() {
        var pad = fields
        pad.dateCreated = ""
        UserDefaults.standard.set(try? JSONEncoder().encode(pad), forKey: Self.stationeryKey)
        app.showToast(app.t("fileInfo.stationerySaved"), icon: "square.and.pencil")
    }

    var captionTemplates: [CaptionTemplateItem] {
        UserDefaults.standard.data(forKey: Self.captionTemplatesKey)
            .flatMap { try? JSONDecoder().decode([CaptionTemplateItem].self, from: $0) } ?? []
    }

    /// Junta os campos preenchidos de `other` aos atuais.
    func merge(_ other: IPTCFields) {
        for spec in IPTCFields.specs where !other[keyPath: spec.path].isEmpty {
            fields[keyPath: spec.path] = other[keyPath: spec.path]
        }
    }

    func clear() {
        fields = IPTCFields()
        if !together, let date = photo?.captureDate { fields.dateCreated = IPTCFields.text(from: date) }
    }

    func replaceCodes(_ value: String, _ path: WritableKeyPath<IPTCFields, String>) {
        let replaced = codes.apply(value, delimiter: delimiterCharacter)
        if replaced != value { fields[keyPath: path] = replaced }
    }

    func loadCodes() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText, .tabSeparatedText, .commaSeparatedText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let text = try CodeReplacementStore.readText(url)
            let parsed = CodeReplacements.parse(text)
            guard !parsed.isEmpty else {
                message = app.t("codes.empty")
                return
            }
            CodeReplacementStore.save(text: text, fileName: url.lastPathComponent)
            codes = parsed
            message = nil
        } catch {
            message = error.localizedDescription
        }
    }

    func removeCodes() {
        CodeReplacementStore.save(text: nil, fileName: nil)
        codes = CodeReplacements()
    }

    func loadTemplate() {
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

    func saveTemplate() {
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

    // MARK: Ler

    func load() async {
        isLoading = true
        message = nil
        if together {
            let urls = photos.map(\.url)
            let all = await Task.detached(priority: .userInitiated) { urls.map(MetadataReader.iptcFields(for:)) }.value
            guard !Task.isCancelled else { return }
            let common = IPTCFields.common(all)
            fields = common.fields
            original = common.fields
            mixed = common.mixed
        } else {
            guard let photo else { isLoading = false; return }
            let url = photo.url
            var read = await Task.detached(priority: .userInitiated) { MetadataReader.iptcFields(for: url) }.value
            guard !Task.isCancelled else { return }
            // Como a "Capture Time" do Photo Mechanic: sem data gravada, propõe a da captura.
            if read.dateCreated.isEmpty, let date = photo.captureDate { read.dateCreated = IPTCFields.text(from: date) }
            fields = read
            original = read
            mixed = []
        }
        perPhotoCaptureTime = false
        isLoading = false
    }

    // MARK: Navegar e gravar

    /// Com alterações por gravar, pergunta primeiro; senão avança logo.
    func request(_ step: FileInfoStep) {
        if hasChanges { pendingStep = step } else { perform(step) }
    }

    func perform(_ step: FileInfoStep) {
        switch step {
        case .go(let target): if photos.indices.contains(target) { index = target }
        case .mode(let value): together = value
        case .close: dismiss()
        }
    }

    /// Grava (se houver alterações) e depois faz `step`.
    func commit(then step: FileInfoStep) {
        together ? saveAll(then: step) : saveCurrent(then: step)
    }

    func context(for photo: Photo, index: Int, values: IPTCFields) -> CaptionTemplate.Context {
        CaptionTemplate.Context(
            date: photo.captureDate, event: values.event, camera: photo.camera, city: values.city, country: values.country,
            creator: values.creator, fileName: photo.fileName, sequence: index + 1
        )
    }

    private func saveCurrent(then step: FileInfoStep) {
        guard let photo else { return perform(step) }
        let edited = codes.apply(to: fields, delimiter: delimiterCharacter)
        guard edited != original else { return perform(step) }
        let url = photo.url, context = context(for: photo, index: index, values: edited)
        let roster = codes, and = app.t("list.and")
        isSaving = true
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> Result<IPTCFields, Error> in
                var values = edited
                FileInfoWriter.resolve(&values, context, url: url, roster: roster, and: and)
                return Result { try MetadataWriter.write(values, to: url, clearEmpty: true); return values }
            }.value
            isSaving = false
            switch result {
            case .success(let values):
                photo.updateFileInfo(values)
                app.culling.metadataRevision += 1
                FieldHistory.remember(edited)
                if step == .close { app.showToast(app.t("toast.fileInfo"), icon: "info.circle.fill") }
                original = fields
                perform(step)
            case .failure(let error):
                message = error.localizedDescription
            }
        }
    }

    /// "Todas juntas": em cada foto troca só os campos alterados aqui; o resto do file info dela fica.
    private func saveAll(then step: FileInfoStep) {
        let edited = codes.apply(to: fields, delimiter: delimiterCharacter)
        let changed = IPTCFields.specs.filter { edited[keyPath: $0.path] != original[keyPath: $0.path] }
        guard !changed.isEmpty || perPhotoCaptureTime else { return perform(step) }
        let captureTime = perPhotoCaptureTime, roster = codes, and = app.t("list.and")
        let jobs = photos.enumerated().map { index, photo in
            (id: photo.id, url: photo.url, captureDate: photo.captureDate, context: context(for: photo, index: index, values: edited))
        }
        isSaving = true
        Task {
            let saved = await Task.detached(priority: .userInitiated) { () -> [UUID: IPTCFields] in
                var saved: [UUID: IPTCFields] = [:]
                for job in jobs {
                    var values = MetadataReader.iptcFields(for: job.url).replacing(changed, from: edited)
                    FileInfoWriter.resolve(&values, job.context, url: job.url, roster: roster, and: and)
                    if captureTime, let date = job.captureDate { values.dateCreated = IPTCFields.text(from: date) }
                    if (try? MetadataWriter.write(values, to: job.url, clearEmpty: true)) != nil { saved[job.id] = values }
                }
                return saved
            }.value
            isSaving = false
            for photo in photos { if let values = saved[photo.id] { photo.updateFileInfo(values) } }
            app.culling.metadataRevision += 1
            FieldHistory.remember(edited)
            guard saved.count == jobs.count else {
                message = String(format: app.t("metadata.failures"), jobs.count - saved.count)
                return
            }
            app.showToast(app.t("toast.metadata", count: saved.count), icon: "info.circle.fill")
            original = fields
            perPhotoCaptureTime = false
            perform(step)
        }
    }
}

/// O trabalho de gravar que corre fora da thread principal.
enum FileInfoWriter {
    /// Variáveis por foto e `{players}`: o número da camisola lido na foto, trocado pelo nome no plantel carregado.
    static func resolve(_ values: inout IPTCFields, _ context: CaptionTemplate.Context, url: URL, roster: CodeReplacements, and: String) {
        var context = context
        if !roster.isEmpty, CaptionTemplate.usesPlayers(values.headline + values.title + values.caption),
           let image = ThumbnailCache.shared.thumbnail(for: url, maxPixel: 2400)?.cgImage {
            context.players = CaptionTemplate.joinNames(JerseyNumbers.players(JerseyNumbers.detect(in: image), roster: roster), and: and)
        }
        values.resolveVariables(context)
    }
}

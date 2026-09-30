import SwiftUI
import UniformTypeIdentifiers

/// Ler, gravar e modelos do File Info.
extension FileInfoSheet {
    private static let xmpType = UTType(filenameExtension: "xmp") ?? .xml

    /// O que ficou gravado na janela de metadados em lote.
    var stationeryPad: IPTCFields? {
        UserDefaults.standard.data(forKey: MetadataSheet.storageKey)
            .flatMap { try? JSONDecoder().decode(IPTCFields.self, from: $0) }
            .flatMap { $0.isEmpty ? nil : $0 }
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
            perPhotoCaptureTime = false
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
        isLoading = false
    }

    private func context(for photo: Photo, index: Int, values: IPTCFields) -> CaptionTemplate.Context {
        CaptionTemplate.Context(
            date: photo.captureDate, event: values.event, camera: photo.camera, city: values.city, country: values.country,
            creator: values.creator, fileName: photo.fileName, sequence: index + 1
        )
    }

    /// Grava a foto atual (se mudou) e passa a `target`; com `nil`, fecha.
    func save(then target: Int?) {
        guard let photo else { return dismiss() }
        var resolved = codes.apply(to: fields, delimiter: delimiterCharacter)
        resolved.resolveVariables(context(for: photo, index: index, values: resolved))
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

    /// "Todas juntas": em cada foto troca só os campos alterados aqui; o resto do file info dela fica.
    func saveAll() {
        let edited = codes.apply(to: fields, delimiter: delimiterCharacter)
        let changed = IPTCFields.specs.filter { edited[keyPath: $0.path] != original[keyPath: $0.path] }
        guard !changed.isEmpty || perPhotoCaptureTime else { return dismiss() }
        let captureTime = perPhotoCaptureTime
        let jobs = photos.enumerated().map { index, photo in
            (id: photo.id, url: photo.url, captureDate: photo.captureDate, context: context(for: photo, index: index, values: edited))
        }
        isSaving = true
        Task {
            let saved = await Task.detached(priority: .userInitiated) { () -> [UUID: String?] in
                var saved: [UUID: String?] = [:]
                for job in jobs {
                    var values = MetadataReader.iptcFields(for: job.url).replacing(changed, from: edited)
                    values.resolveVariables(job.context)
                    if captureTime, let date = job.captureDate { values.dateCreated = IPTCFields.text(from: date) }
                    if (try? MetadataWriter.write(values, to: job.url, clearEmpty: true)) != nil {
                        saved[job.id] = values.catalogKeywords
                    }
                }
                return saved
            }.value
            isSaving = false
            for photo in photos { if let keywords = saved[photo.id] { photo.keywords = keywords } }
            app.culling.metadataRevision += 1
            FieldHistory.remember(edited)
            if saved.count == jobs.count {
                app.showToast(String(format: app.t("toast.metadata"), saved.count), icon: "info.circle.fill")
                dismiss()
            } else {
                message = String(format: app.t("metadata.failures"), jobs.count - saved.count)
            }
        }
    }

    private func move(to target: Int?) {
        guard let target, photos.indices.contains(target) else { return dismiss() }
        index = target
    }
}

import SwiftUI
import SwiftData

struct ImportSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    let folder: URL

    @State private var session = ""
    @State private var copyFiles = false
    @State private var destination: URL?
    @State private var byDate = true
    @AppStorage("import.folderTemplate") private var folderTemplate = "{year}/{date}_{event}/{type}"
    @AppStorage("import.verify") private var verify = true
    @State private var useBackup = false
    @State private var backup: URL?

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    LabeledContent(app.t("import.source"), value: folder.path)
                    TextField(app.t("import.session"), text: $session)
                    Toggle(app.t("import.copy"), isOn: $copyFiles.animation(Motion.snappy))
                }
                if copyFiles {
                    Section {
                        folderPicker(app.t("import.destination"), url: $destination)
                        Toggle(app.t("import.useTemplate"), isOn: $byDate.animation(Motion.snappy))
                        if byDate {
                            TextField(app.t("import.template"), text: $folderTemplate)
                            Text(app.t("rename.tokens") + " " + IngestTemplate.tokens.joined(separator: " "))
                                .font(Typography.caption)
                                .foregroundStyle(Palette.textSecondary)
                            LabeledContent(app.t("import.example"), value: IngestTemplate.path(folderTemplate, date: Date(), event: session, isRaw: true))
                        }
                    }
                    Section {
                        Toggle(app.t("import.verify"), isOn: $verify)
                        Toggle(app.t("import.backup"), isOn: $useBackup.animation(Motion.snappy))
                        if useBackup {
                            folderPicker(app.t("import.backupDestination"), url: $backup)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            SheetButtons(
                confirmTitle: app.t("culling.import"),
                confirmDisabled: copyFiles && (destination == nil || (useBackup && backup == nil))
            ) {
                start()
            }
        }
        .frame(width: 520)
        .onAppear { session = folder.lastPathComponent }
    }

    private func folderPicker(_ title: String, url: Binding<URL?>) -> some View {
        LabeledContent(title) {
            HStack {
                Text(url.wrappedValue?.path ?? "—").lineLimit(1).truncationMode(.middle)
                Button(app.t("common.choose")) {
                    url.wrappedValue = FilePanels.chooseFolder(prompt: app.t("common.choose"))
                }
            }
        }
    }

    private func start() {
        let name = session.trimmingCharacters(in: .whitespaces).isEmpty ? folder.lastPathComponent : session
        let options = PhotoImporter.Options(
            copyDestination: copyFiles ? destination : nil,
            subfolderByDate: byDate,
            folderTemplate: folderTemplate,
            event: name,
            backupDestination: copyFiles && useBackup ? backup : nil,
            verifyChecksum: copyFiles && verify
        )
        let culling = app.culling
        let context = context
        let app = app
        Task {
            await culling.importFolder(folder, options: options, session: name, context: context)
            if culling.lastImportFailures > 0 {
                app.showToast(String(format: app.t("toast.importFailures"), culling.lastImportCount ?? 0, culling.lastImportFailures), icon: "exclamationmark.triangle.fill")
            } else {
                app.showToast(String(format: app.t("toast.imported"), culling.lastImportCount ?? 0), icon: "photo.stack")
            }
        }
        dismiss()
    }
}

struct RenameSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    let photos: [Photo]

    @AppStorage("rename.template") private var template = "{date}_{seq}_{event}"
    @State private var event = ""
    @State private var start = 1
    @State private var error: String?

    private var plans: [BatchRenamer.Plan] {
        BatchRenamer.plan(
            photos.map { BatchRenamer.Item(url: $0.url, date: $0.captureDate, camera: $0.camera) },
            template: template, event: event, start: start
        )
    }

    var body: some View {
        let plans = plans
        let conflicts = BatchRenamer.conflicts(plans)
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField(app.t("rename.template"), text: $template)
                    Text(app.t("rename.tokens") + " " + RenameTemplate.tokens.joined(separator: " "))
                        .font(Typography.caption).foregroundStyle(Palette.textSecondary)
                    TextField(app.t("rename.event"), text: $event)
                    Stepper("\(app.t("rename.start")): \(start)", value: $start, in: 0...99_999)
                }
                Section(String(format: app.t("rename.preview"), photos.count)) {
                    ForEach(Array(plans.prefix(6).enumerated()), id: \.offset) { _, plan in
                        HStack {
                            Text(plan.from.lastPathComponent).foregroundStyle(Palette.textSecondary)
                            Image(systemName: "arrow.right").foregroundStyle(Brand.orange)
                            Text(plan.to.lastPathComponent)
                        }
                        .font(Typography.caption)
                        .lineLimit(1)
                    }
                }
                if !conflicts.isEmpty {
                    Label(String(format: app.t("rename.conflicts"), conflicts.count), systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(Brand.error)
                }
                if let error {
                    Text(error).foregroundStyle(Brand.error)
                }
            }
            .formStyle(.grouped)
            SheetButtons(confirmTitle: app.t("rename.apply"), confirmDisabled: !conflicts.isEmpty || photos.isEmpty) {
                apply(plans)
            }
        }
        .frame(width: 520, height: 480)
    }

    private func apply(_ plans: [BatchRenamer.Plan]) {
        do {
            try BatchRenamer.apply(plans)
            for (photo, plan) in zip(photos, plans) {
                photo.path = plan.to.path
                photo.fileName = plan.to.lastPathComponent
            }
            try? context.save()
            app.showToast(String(format: app.t("toast.renamed"), plans.count), icon: "character.cursor.ibeam")
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct MetadataSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    let photos: [Photo]

    @State private var fields = IPTCFields()
    @State private var isWriting = false
    @State private var message: String?
    @State private var event = ""
    @State private var templates: [SavedCaption] = []
    @State private var templateName = ""
    @State private var codes = CodeReplacements()
    @State private var codesFile: String?
    @AppStorage(CodeReplacementStore.delimiterKey) private var delimiter = "="

    private var delimiterCharacter: Character { delimiter.first ?? "=" }

    private static let storageKey = "metadata.lastFields"
    private static let templatesKey = "metadata.captionTemplates"

    struct SavedCaption: Codable, Hashable, Identifiable {
        var id: String { name }
        var name: String
        var title: String
        var caption: String
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section(app.t("metadata.templates")) {
                    HStack {
                        Menu(app.t("metadata.loadTemplate")) {
                            ForEach(templates) { template in
                                Button(template.name) {
                                    fields.title = template.title
                                    fields.caption = template.caption
                                }
                            }
                        }
                        .disabled(templates.isEmpty)
                        TextField(app.t("metadata.templateName"), text: $templateName)
                        Button(app.t("presets.save")) { saveTemplate() }
                            .disabled(templateName.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    TextField(app.t("metadata.event"), text: $event)
                    Text(app.t("rename.tokens") + " " + CaptionTemplate.tokens.joined(separator: " "))
                        .font(Typography.caption)
                        .foregroundStyle(Palette.textSecondary)
                    if CaptionTemplate.usesPlayers(fields.title + fields.caption) {
                        Label(app.t(codes.isEmpty ? "metadata.playersNeedsRoster" : "metadata.playersHint"),
                              systemImage: codes.isEmpty ? "exclamationmark.triangle.fill" : "person.text.rectangle")
                            .font(Typography.caption)
                            .foregroundStyle(codes.isEmpty ? Brand.burntYellow : Palette.textSecondary)
                    }
                    if let first = photos.first, !(fields.caption + fields.title).isEmpty {
                        let values = codes.apply(to: fields, delimiter: delimiterCharacter)
                        LabeledContent(app.t("import.example"), value: CaptionTemplate.resolve(values.caption.isEmpty ? values.title : values.caption, context(for: first, index: 0, values: values)))
                    }
                }
                Section(app.t("codes.title")) {
                    HStack {
                        Text(codesFile.map { String(format: app.t("codes.loaded"), $0, codes.count) } ?? app.t("codes.none"))
                            .foregroundStyle(codesFile == nil ? Palette.textSecondary : Palette.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button(app.t("codes.load")) { loadCodes() }
                        if codesFile != nil {
                            Button(app.t("codes.remove")) {
                                CodeReplacementStore.save(text: nil, fileName: nil)
                                codes = CodeReplacements()
                                codesFile = nil
                            }
                        }
                    }
                    TextField(app.t("codes.delimiter"), text: Binding(get: { delimiter }, set: { delimiter = String($0.suffix(1)) }))
                    Text(app.t("codes.hint"))
                        .font(Typography.caption)
                        .foregroundStyle(Palette.textSecondary)
                }
                Section(String(format: app.t("metadata.applyTo"), photos.count)) {
                    TextField(app.t("meta.title"), text: $fields.title)
                    TextField(app.t("meta.caption"), text: $fields.caption, axis: .vertical).lineLimit(2...4)
                    TextField(app.t("meta.creator"), text: $fields.creator)
                    TextField(app.t("meta.copyright"), text: $fields.copyright)
                    TextField(app.t("meta.keywords"), text: $fields.keywords)
                    TextField(app.t("meta.city"), text: $fields.city)
                    TextField(app.t("meta.country"), text: $fields.country)
                }
                Text(app.t("metadata.hint")).font(Typography.caption).foregroundStyle(Palette.textSecondary)
                if let message { Text(message).foregroundStyle(Brand.error) }
            }
            .formStyle(.grouped)
            SheetButtons(confirmTitle: app.t("metadata.apply"), confirmDisabled: fields.isEmpty || isWriting, isWorking: isWriting) {
                apply()
            }
        }
        .frame(width: 540, height: 780)
        // Como no Photo Mechanic: ao fechar o código (=7=) o texto é logo trocado.
        .onChange(of: fields.caption) { _, value in
            let replaced = codes.apply(value, delimiter: delimiterCharacter)
            if replaced != value { fields.caption = replaced }
        }
        .onChange(of: fields.title) { _, value in
            let replaced = codes.apply(value, delimiter: delimiterCharacter)
            if replaced != value { fields.title = replaced }
        }
        .onAppear {
            codes = CodeReplacementStore.load()
            codesFile = codes.isEmpty ? nil : CodeReplacementStore.fileName
            if let data = UserDefaults.standard.data(forKey: Self.storageKey),
               let saved = try? JSONDecoder().decode(IPTCFields.self, from: data) {
                fields = saved
            }
            if let data = UserDefaults.standard.data(forKey: Self.templatesKey),
               let saved = try? JSONDecoder().decode([SavedCaption].self, from: data) {
                templates = saved
            }
        }
    }

    private func context(for photo: Photo, index: Int, values: IPTCFields) -> CaptionTemplate.Context {
        CaptionTemplate.Context(
            date: photo.captureDate, event: event, camera: photo.camera, city: values.city,
            country: values.country, creator: values.creator, fileName: photo.fileName, sequence: index + 1
        )
    }

    private func loadCodes() {
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
            codesFile = url.lastPathComponent
            message = nil
        } catch {
            message = error.localizedDescription
        }
    }

    private func saveTemplate() {
        let name = templateName.trimmingCharacters(in: .whitespaces)
        templates.removeAll { $0.name == name }
        templates.append(SavedCaption(name: name, title: fields.title, caption: fields.caption))
        UserDefaults.standard.set(try? JSONEncoder().encode(templates), forKey: Self.templatesKey)
        templateName = ""
    }

    private func apply() {
        // Legenda e título resolvidos por foto ({date}, {event}, {seq}…).
        // Primeiro os códigos (=7=), depois as variáveis por foto.
        let values = codes.apply(to: fields, delimiter: delimiterCharacter)
        let jobs = photos.enumerated().map { index, photo in
            (url: photo.url, context: context(for: photo, index: index, values: values))
        }
        // {players}: número da camisola lido em cada foto + nome do plantel carregado.
        let roster = codes
        let and = app.t("list.and")
        let needsPlayers = CaptionTemplate.usesPlayers(values.title + values.caption) && !roster.isEmpty
        UserDefaults.standard.set(try? JSONEncoder().encode(fields), forKey: Self.storageKey)
        isWriting = true
        Task {
            let failures = await Task.detached(priority: .userInitiated) {
                jobs.filter { job in
                    var context = job.context
                    if needsPlayers, let image = ThumbnailCache.shared.thumbnail(for: job.url, maxPixel: 2400)?.cgImage {
                        context.players = CaptionTemplate.joinNames(JerseyNumbers.players(JerseyNumbers.detect(in: image), roster: roster), and: and)
                    }
                    var resolved = values
                    resolved.title = CaptionTemplate.resolve(values.title, context)
                    resolved.caption = CaptionTemplate.resolve(values.caption, context)
                    return (try? MetadataWriter.write(resolved, to: job.url)) == nil
                }.count
            }.value
            isWriting = false
            if failures == 0 {
                app.showToast(String(format: app.t("toast.metadata"), jobs.count), icon: "tag.fill")
                dismiss()
            } else {
                message = String(format: app.t("metadata.failures"), failures)
            }
        }
    }
}

struct SheetButtons: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    let confirmTitle: String
    var confirmDisabled = false
    var isWorking = false
    let onConfirm: () -> Void

    var body: some View {
        HStack {
            if isWorking { ProgressView().controlSize(.small) }
            Spacer()
            Button(app.t("common.cancel")) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button(confirmTitle, action: onConfirm)
                .keyboardShortcut(.defaultAction)
                .disabled(confirmDisabled)
        }
        .padding(16)
    }
}

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

    var body: some View {
        VStack(spacing: 0) {
            Form {
                LabeledContent(app.t("import.source"), value: folder.path)
                TextField(app.t("import.session"), text: $session)
                Toggle(app.t("import.copy"), isOn: $copyFiles)
                if copyFiles {
                    LabeledContent(app.t("import.destination")) {
                        HStack {
                            Text(destination?.path ?? "—").lineLimit(1).truncationMode(.middle)
                            Button(app.t("common.choose")) {
                                destination = FilePanels.chooseFolder(prompt: app.t("common.choose"))
                            }
                        }
                    }
                    Toggle(app.t("import.byDate"), isOn: $byDate)
                }
            }
            .formStyle(.grouped)
            SheetButtons(confirmTitle: app.t("culling.import"), confirmDisabled: copyFiles && destination == nil) {
                start()
            }
        }
        .frame(width: 480)
        .onAppear { session = folder.lastPathComponent }
    }

    private func start() {
        let options = PhotoImporter.Options(copyDestination: copyFiles ? destination : nil, subfolderByDate: byDate)
        let name = session.trimmingCharacters(in: .whitespaces).isEmpty ? folder.lastPathComponent : session
        let culling = app.culling
        let context = context
        let app = app
        Task {
            await culling.importFolder(folder, options: options, session: name, context: context)
            app.showToast(String(format: app.t("toast.imported"), culling.lastImportCount ?? 0), icon: "photo.stack")
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

    private static let storageKey = "metadata.lastFields"

    var body: some View {
        VStack(spacing: 0) {
            Form {
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
        .frame(width: 480, height: 520)
        .onAppear {
            if let data = UserDefaults.standard.data(forKey: Self.storageKey),
               let saved = try? JSONDecoder().decode(IPTCFields.self, from: data) {
                fields = saved
            }
        }
    }

    private func apply() {
        let urls = photos.map(\.url)
        let fields = fields
        UserDefaults.standard.set(try? JSONEncoder().encode(fields), forKey: Self.storageKey)
        isWriting = true
        Task {
            let failures = await Task.detached(priority: .userInitiated) {
                urls.filter { (try? MetadataWriter.write(fields, to: $0)) == nil }.count
            }.value
            isWriting = false
            if failures == 0 {
                app.showToast(String(format: app.t("toast.metadata"), urls.count), icon: "tag.fill")
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

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

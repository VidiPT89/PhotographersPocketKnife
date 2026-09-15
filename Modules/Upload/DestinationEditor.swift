import SwiftUI
import SwiftData
import AppKit

@MainActor
enum DestinationTester {
    /// Testa a ligação e guarda o resultado no destino (aparece como ponto de estado nas listas).
    @discardableResult
    static func run(_ destination: UploadDestination, context: ModelContext) async -> Bool {
        let command = TransferCommand.test(destination.endpoint())
        var failure: String?
        do {
            try await CurlProcess(executable: command.executable, environment: command.environment)
                .run(arguments: command.arguments, config: command.input)
        } catch {
            failure = error.localizedDescription
        }
        destination.lastTestedAt = Date()
        destination.lastTestError = failure
        try? context.save()
        return failure == nil
    }
}

struct DestinationEditor: View {
    @Environment(AppState.self) private var app
    @Environment(\.modelContext) private var context
    @Bindable var destination: UploadDestination
    @Query private var records: [UploadRecord]
    @AppStorage(DestinationDefaults.key) private var defaultIDString = ""

    @State private var password = ""
    @State private var quickAddress = ""
    @State private var isTesting = false

    var body: some View {
        let isS3 = destination.transferProtocol == .s3
        let issues = DestinationValidation.issues(
            transferProtocol: destination.transferProtocol, host: destination.host, port: destination.port,
            username: destination.username, bucket: destination.bucket, template: destination.remoteFolderTemplate
        )
        Form {
            Section(app.t("destination.section.general")) {
                TextField(app.t("destination.name"), text: $destination.name)
                Picker(app.t("destination.protocol"), selection: Binding(
                    get: { destination.transferProtocol },
                    set: { newValue in
                        if destination.port == destination.transferProtocol.defaultPort { destination.port = newValue.defaultPort }
                        destination.transferProtocol = newValue
                    }
                )) {
                    ForEach(TransferProtocol.allCases) { Label($0.displayName, systemImage: $0.symbol).tag($0) }
                }
                Toggle(app.t("destination.default"), isOn: Binding(
                    get: { defaultIDString == destination.id.uuidString },
                    set: { defaultIDString = $0 ? destination.id.uuidString : "" }
                ))
            }

            Section {
                if !isS3 {
                    HStack {
                        TextField(app.t("destination.quickAddress"), text: $quickAddress, prompt: Text("sftp://user@server:22/photos"))
                            .onSubmit(applyQuickAddress)
                        Button(app.t("destination.fill"), action: applyQuickAddress)
                            .disabled(DestinationAddress.parse(quickAddress) == nil)
                    }
                }
                TextField(isS3 ? app.t("destination.endpoint") : app.t("destination.host"), text: $destination.host)
                TextField(app.t("destination.port"), value: $destination.port, format: .number.grouping(.never))
                TextField(isS3 ? app.t("destination.accessKey") : app.t("destination.username"), text: $destination.username)
                SecureField(isS3 ? app.t("destination.secretKey") : app.t("destination.password"), text: $password)
                if isS3 {
                    TextField(app.t("destination.bucket"), text: $destination.bucket)
                    TextField(app.t("destination.region"), text: $destination.region)
                }
                if destination.transferProtocol == .sftp {
                    Toggle(app.t("destination.trustHost"), isOn: $destination.trustUnknownHostKey)
                }
                ForEach(issues, id: \.key) { issue in
                    Label(issue.argument.map { String(format: app.t(issue.key), $0) } ?? app.t(issue.key), systemImage: "exclamationmark.triangle.fill")
                        .font(Typography.caption)
                        .foregroundStyle(Brand.burntYellow)
                }
            } header: {
                Text(app.t("destination.section.connection"))
            } footer: {
                Text(app.t("destination.keychainHint"))
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textSecondary)
            }

            Section(app.t("destination.remoteFolder")) {
                TextField(app.t("destination.remoteFolder"), text: $destination.remoteFolderTemplate)
                HStack(spacing: 6) {
                    Text(app.t("destination.insertToken"))
                        .font(Typography.caption)
                        .foregroundStyle(Palette.textSecondary)
                    ForEach(RemotePath.tokens, id: \.self) { token in
                        Button(token) { insert(token) }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                    }
                }
                LabeledContent(app.t("destination.example"), value: exampleFolder)
                LabeledContent(app.t("destination.address")) {
                    HStack(spacing: 6) {
                        Text(exampleAddress)
                            .textSelection(.enabled)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button { copyAddress() } label: { Image(systemName: "doc.on.doc") }
                            .buttonStyle(.borderless)
                            .help(app.t("destination.copyAddress"))
                    }
                }
            }

            Section(app.t("destination.section.test")) {
                HStack(spacing: 8) {
                    Button(app.t("destination.test")) { test() }
                        .disabled(destination.host.isEmpty || isTesting)
                    if isTesting { ProgressView().controlSize(.small) }
                    Spacer()
                    testResult
                }
            }

            Section(app.t("destination.section.stats")) {
                let stats = DestinationStats.compute(
                    records.map { .init(destinationID: $0.destinationID, destinationName: $0.destinationName, success: $0.success, bytes: $0.bytes, date: $0.date) },
                    id: destination.id, name: destination.name
                )
                LabeledContent(app.t("destination.stats.files"), value: "\(stats.uploaded)")
                LabeledContent(app.t("destination.stats.failed"), value: "\(stats.failed)")
                LabeledContent(app.t("destination.stats.size"), value: ByteCountFormatter.string(fromByteCount: stats.bytes, countStyle: .file))
                LabeledContent(app.t("destination.stats.last"),
                               value: stats.lastUpload?.formatted(date: .abbreviated, time: .shortened) ?? app.t("destination.stats.never"))
            }
        }
        .formStyle(.grouped)
        .onAppear { password = Keychain.password(account: destination.id.uuidString) ?? "" }
        .onChange(of: password) { _, newValue in Keychain.setPassword(newValue, account: destination.id.uuidString) }
        .onDisappear { try? context.save() }
    }

    @ViewBuilder
    private var testResult: some View {
        switch destination.testStatus {
        case .untested:
            Text(app.t("destination.untested")).foregroundStyle(Palette.textSecondary)
        case .ok(let date):
            Label(String(format: app.t("destination.testedOK"), date.formatted(date: .abbreviated, time: .shortened)), systemImage: "checkmark.circle.fill")
                .foregroundStyle(Brand.success)
        case .failed(let date, let message):
            VStack(alignment: .trailing, spacing: 2) {
                Label(message, systemImage: "xmark.octagon.fill")
                    .foregroundStyle(Brand.error)
                    .lineLimit(3)
                Text(date.formatted(date: .abbreviated, time: .shortened))
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textSecondary)
            }
        }
    }

    private var exampleFolder: String {
        RemotePath.folder(template: destination.remoteFolderTemplate, date: Date(), event: "Evento")
    }

    private var exampleAddress: String {
        CurlCommand.url(destination.endpoint(password: ""), remotePath: RemotePath.join(exampleFolder, "IMG_0001.jpg"))
    }

    private func insert(_ token: String) {
        let template = destination.remoteFolderTemplate
        destination.remoteFolderTemplate = template.isEmpty || template.hasSuffix("/") ? template + token : template + "/" + token
    }

    private func applyQuickAddress() {
        guard let parsed = DestinationAddress.parse(quickAddress) else { return }
        destination.transferProtocol = parsed.transferProtocol
        destination.host = parsed.host
        destination.port = parsed.port
        if !parsed.username.isEmpty { destination.username = parsed.username }
        if let secret = parsed.password, !secret.isEmpty { password = secret }
        if let folder = parsed.folder { destination.remoteFolderTemplate = folder }
        quickAddress = ""
        app.showToast(app.t("destination.filled"), icon: "wand.and.stars")
    }

    private func copyAddress() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(exampleAddress, forType: .string)
        app.showToast(app.t("destination.copied"), icon: "doc.on.doc.fill")
    }

    private func test() {
        isTesting = true
        Task {
            await DestinationTester.run(destination, context: context)
            isTesting = false
        }
    }
}

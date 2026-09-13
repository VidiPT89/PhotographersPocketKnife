import SwiftUI
import SwiftData

struct DestinationsView: View {
    @Environment(AppState.self) private var app
    @Environment(\.modelContext) private var context
    @Query(sort: \UploadDestination.createdAt) private var destinations: [UploadDestination]
    @State private var selectedID: UUID?

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                List(destinations, selection: $selectedID) { destination in
                    Label(destination.name.isEmpty ? "—" : destination.name, systemImage: "server.rack")
                        .tag(destination.id)
                }
                HStack {
                    Button {
                        let destination = UploadDestination(name: app.t("destination.new"))
                        context.insert(destination)
                        try? context.save()
                        selectedID = destination.id
                    } label: { Image(systemName: "plus") }
                    Button {
                        guard let destination = destinations.first(where: { $0.id == selectedID }) else { return }
                        Keychain.deletePassword(account: destination.id.uuidString)
                        context.delete(destination)
                        try? context.save()
                        selectedID = nil
                    } label: { Image(systemName: "minus") }
                    .disabled(selectedID == nil)
                    Spacer()
                }
                .buttonStyle(.borderless)
                .padding(8)
            }
            .frame(width: 220)
            Divider()
            if let destination = destinations.first(where: { $0.id == selectedID }) {
                DestinationEditor(destination: destination)
                    .id(destination.id)
            } else {
                EmptyModuleView(systemImage: "server.rack", title: app.t("destination.select"), subtitle: app.t("destination.hint"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { selectedID = selectedID ?? destinations.first?.id }
    }
}

struct DestinationEditor: View {
    @Environment(AppState.self) private var app
    @Environment(\.modelContext) private var context
    @Bindable var destination: UploadDestination

    @State private var password = ""
    @State private var testState: TestState = .idle

    enum TestState: Equatable {
        case idle, testing, ok
        case failed(String)
    }

    var body: some View {
        let isS3 = destination.transferProtocol == .s3
        Form {
            Section {
                TextField(app.t("destination.name"), text: $destination.name)
                Picker(app.t("destination.protocol"), selection: Binding(
                    get: { destination.transferProtocol },
                    set: { newValue in
                        if destination.port == destination.transferProtocol.defaultPort { destination.port = newValue.defaultPort }
                        destination.transferProtocol = newValue
                    }
                )) {
                    ForEach(TransferProtocol.allCases) { Text($0.displayName).tag($0) }
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
            }
            Section {
                TextField(app.t("destination.remoteFolder"), text: $destination.remoteFolderTemplate)
                Text(app.t("rename.tokens") + " " + RemotePath.tokens.joined(separator: " "))
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textSecondary)
                LabeledContent(app.t("destination.example"), value: RemotePath.folder(template: destination.remoteFolderTemplate, date: Date(), event: "Evento"))
            }
            Section {
                HStack {
                    Button(app.t("destination.test")) { test() }
                        .disabled(destination.host.isEmpty || testState == .testing)
                    switch testState {
                    case .idle: EmptyView()
                    case .testing: ProgressView().controlSize(.small)
                    case .ok: Label(app.t("destination.testOK"), systemImage: "checkmark.circle.fill").foregroundStyle(Brand.success)
                    case .failed(let message): Label(message, systemImage: "xmark.octagon.fill").foregroundStyle(Brand.error)
                    }
                }
                Text(app.t("destination.keychainHint"))
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textSecondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { password = Keychain.password(account: destination.id.uuidString) ?? "" }
        .onChange(of: password) { _, newValue in Keychain.setPassword(newValue, account: destination.id.uuidString) }
        .onDisappear { try? context.save() }
    }

    private func test() {
        let endpoint = TransferEndpoint(
            transferProtocol: destination.transferProtocol,
            host: destination.host,
            port: destination.port,
            username: destination.username,
            password: password,
            bucket: destination.bucket,
            region: destination.region,
            trustUnknownHostKey: destination.trustUnknownHostKey
        )
        testState = .testing
        Task {
            do {
                let command = TransferCommand.test(endpoint)
                try await CurlProcess(executable: command.executable, environment: command.environment)
                    .run(arguments: command.arguments, config: command.input)
                testState = .ok
            } catch {
                testState = .failed(error.localizedDescription)
            }
        }
    }
}

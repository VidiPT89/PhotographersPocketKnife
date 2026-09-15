import SwiftUI
import SwiftData

struct DestinationsView: View {
    @Environment(AppState.self) private var app
    @Environment(\.modelContext) private var context
    @Query(sort: \UploadDestination.name) private var destinations: [UploadDestination]
    @AppStorage(DestinationDefaults.key) private var defaultIDString = ""
    @State private var selectedID: UUID?
    @State private var search = ""
    @State private var pendingDelete: UploadDestination?
    @State private var testingIDs: Set<UUID> = []

    private var selected: UploadDestination? { destinations.first { $0.id == selectedID } }

    private var filtered: [UploadDestination] {
        let needle = search.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return destinations }
        return destinations.filter {
            $0.name.localizedCaseInsensitiveContains(needle) || $0.host.localizedCaseInsensitiveContains(needle)
                || $0.transferProtocol.displayName.localizedCaseInsensitiveContains(needle)
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                TextField(app.t("destination.search"), text: $search)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .padding(8)
                List(filtered, selection: $selectedID) { destination in
                    DestinationListRow(
                        destination: destination,
                        isDefault: destination.id.uuidString == defaultIDString,
                        isTesting: testingIDs.contains(destination.id)
                    )
                    .tag(destination.id)
                    .contextMenu { menu(for: destination) }
                }
                Divider()
                HStack(spacing: 12) {
                    Menu {
                        ForEach(TransferProtocol.allCases) { transferProtocol in
                            Button(transferProtocol.displayName, systemImage: transferProtocol.symbol) { add(transferProtocol) }
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .frame(width: 22)
                    .help(app.t("destination.new"))
                    Button { pendingDelete = selected } label: { Image(systemName: "minus") }
                        .disabled(selected == nil)
                        .help(app.t("destination.delete"))
                    Spacer()
                    Button { testAll() } label: { Image(systemName: "bolt.horizontal.circle") }
                        .disabled(destinations.isEmpty || !testingIDs.isEmpty)
                        .help(app.t("destination.testAll"))
                }
                .buttonStyle(.borderless)
                .padding(8)
            }
            .frame(width: 260)
            Divider()
            if let destination = selected {
                DestinationEditor(destination: destination)
                    .id(destination.id)
            } else {
                EmptyModuleView(systemImage: "server.rack", title: app.t("destination.select"), subtitle: app.t("destination.hint"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { selectedID = selectedID ?? DestinationDefaults.preferredID(among: destinations.map(\.id)) }
        .confirmationDialog(
            pendingDelete.map { String(format: app.t("destination.deleteConfirm"), $0.name) } ?? "",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            presenting: pendingDelete
        ) { destination in
            Button(app.t("destination.deleteButton"), role: .destructive) { delete(destination) }
        } message: { _ in
            Text(app.t("destination.deleteMessage"))
        }
    }

    @ViewBuilder
    private func menu(for destination: UploadDestination) -> some View {
        Button(app.t("destination.test"), systemImage: "bolt.horizontal") { test(destination) }
            .disabled(destination.host.isEmpty || testingIDs.contains(destination.id))
        if destination.id.uuidString == defaultIDString {
            Button(app.t("destination.removeDefault"), systemImage: "star.slash") { defaultIDString = "" }
        } else {
            Button(app.t("destination.makeDefault"), systemImage: "star") { defaultIDString = destination.id.uuidString }
        }
        Button(app.t("destination.duplicate"), systemImage: "plus.square.on.square") { duplicate(destination) }
        Divider()
        Button(app.t("destination.delete"), systemImage: "trash", role: .destructive) { pendingDelete = destination }
    }

    private func add(_ transferProtocol: TransferProtocol) {
        let isFirst = destinations.isEmpty
        let destination = UploadDestination(name: app.t("destination.new"), transferProtocol: transferProtocol)
        context.insert(destination)
        try? context.save()
        if isFirst { defaultIDString = destination.id.uuidString }
        search = ""
        selectedID = destination.id
    }

    private func duplicate(_ source: UploadDestination) {
        let name = DestinationDefaults.copyName(source.name, suffix: app.t("destination.copySuffix"), existing: destinations.map(\.name))
        let copy = UploadDestination(name: name, transferProtocol: source.transferProtocol)
        copy.host = source.host
        copy.port = source.port
        copy.username = source.username
        copy.remoteFolderTemplate = source.remoteFolderTemplate
        copy.bucket = source.bucket
        copy.region = source.region
        copy.trustUnknownHostKey = source.trustUnknownHostKey
        if let password = Keychain.password(account: source.id.uuidString) {
            Keychain.setPassword(password, account: copy.id.uuidString)
        }
        context.insert(copy)
        try? context.save()
        search = ""
        selectedID = copy.id
    }

    private func delete(_ destination: UploadDestination) {
        if destination.id.uuidString == defaultIDString { defaultIDString = "" }
        if selectedID == destination.id { selectedID = destinations.first { $0.id != destination.id }?.id }
        Keychain.deletePassword(account: destination.id.uuidString)
        context.delete(destination)
        try? context.save()
    }

    private func test(_ destination: UploadDestination) {
        testingIDs.insert(destination.id)
        Task {
            await DestinationTester.run(destination, context: context)
            testingIDs.remove(destination.id)
        }
    }

    private func testAll() {
        let targets = destinations.filter { !$0.host.isEmpty }
        testingIDs = Set(targets.map(\.id))
        Task {
            // Todos em paralelo; cada ponto de estado atualiza assim que o seu teste acaba.
            let tests = targets.map { destination in
                Task {
                    let ok = await DestinationTester.run(destination, context: context)
                    testingIDs.remove(destination.id)
                    return ok
                }
            }
            var passed = 0
            for test in tests {
                if await test.value { passed += 1 }
            }
            app.showToast(String(format: app.t("destination.testAllDone"), passed, targets.count),
                          icon: passed == targets.count ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
        }
    }
}

struct DestinationListRow: View {
    let destination: UploadDestination
    let isDefault: Bool
    let isTesting: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: destination.transferProtocol.symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Brand.orange)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(destination.name.isEmpty ? "—" : destination.name)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    if isDefault {
                        Image(systemName: "star.fill").font(.system(size: 9)).foregroundStyle(Brand.burntYellow)
                    }
                }
                Text(destination.addressLabel)
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 4)
            Text(destination.transferProtocol.displayName)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Palette.textSecondary)
            DestinationStatusDot(status: destination.testStatus, isTesting: isTesting)
        }
        .padding(.vertical, 2)
    }
}

/// Ponto verde/vermelho/cinzento com o resultado do último teste de ligação.
struct DestinationStatusDot: View {
    @Environment(AppState.self) private var app
    let status: DestinationTestStatus
    var isTesting = false

    var body: some View {
        Group {
            if isTesting {
                ProgressView().controlSize(.mini)
            } else {
                Circle().fill(color).frame(width: 7, height: 7)
            }
        }
        .frame(width: 14)
        .help(helpText)
    }

    private var color: Color {
        switch status {
        case .untested: Palette.textSecondary.opacity(0.35)
        case .ok: Brand.success
        case .failed: Brand.error
        }
    }

    private var helpText: String {
        switch status {
        case .untested: app.t("destination.untested")
        case .ok(let date): String(format: app.t("destination.testedOK"), date.formatted(date: .abbreviated, time: .shortened))
        case .failed(let date, let message): String(format: app.t("destination.testedFailed"), date.formatted(date: .abbreviated, time: .shortened), message)
        }
    }
}

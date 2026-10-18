import SwiftUI
import SwiftData

struct MobileDelivery: View {
    @Environment(AppState.self) private var app
    @Environment(\.modelContext) private var context
    @Query(sort: \UploadDestination.name) private var destinations: [UploadDestination]
    @Query(sort: \UploadRecord.date, order: .reverse) private var history: [UploadRecord]
    let photos: [Photo]
    @State private var editing: UploadDestination?
    @State private var adding = false
    @State private var showHistory = false
    @State private var confirmSend: UploadDestination?
    @State private var search = ""
    @State private var deleting: UploadDestination?
    @AppStorage(DestinationDefaults.key) private var defaultID = ""
    @State private var shares: SharedFiles?
    var body: some View {
        List {
            Section(app.m("Destinations", "Destinos")) {
                ForEach(destinations.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.host.localizedCaseInsensitiveContains(search) }) { destination in
                    HStack {
                        Button { editing = destination } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Label(destination.name, systemImage: destination.transferProtocol.symbol)
                                if defaultID == destination.id.uuidString { Text(app.m("Default", "Predefinido")).font(.caption).foregroundStyle(.orange) }
                                Text(destination.addressLabel).font(.caption).foregroundStyle(.secondary)
                                if let error = destination.lastTestError { Text(error).font(.caption2).foregroundStyle(.red).lineLimit(2) }
                            }
                        }.buttonStyle(.plain).accessibilityIdentifier("destination-\(destination.name)")
                        Spacer()
                        Button { confirmSend = destination } label: { Image(systemName: "paperplane").frame(width: 44, height: 44) }.disabled(photos.isEmpty)
                    }
                    .contextMenu {
                        Button(app.m("Use as default", "Usar como predefinido")) { defaultID = destination.id.uuidString }
                        Button(app.m("Duplicate", "Duplicar")) { duplicate(destination) }
                        Button(app.m("Delete destination", "Apagar destino"), role: .destructive) { deleting = destination }
                    }
                }
                Button(app.m("Add destination", "Adicionar destino"), systemImage: "plus") { adding = true }
            }
            Section(app.m("Transfer queue", "Fila de envios")) {
                if !app.transfers.items.isEmpty {
                    ProgressView(value: app.transfers.overallProgress)
                    HStack {
                        Button(app.m("Retry failed", "Repetir falhados")) { app.transfers.retryFailed() }.disabled(app.transfers.failedCount == 0)
                        Spacer()
                        Button(app.m("Clear completed", "Limpar concluídos")) { app.transfers.clearFinished() }.disabled(app.transfers.completedCount == 0)
                    }
                }
                HStack {
                    Button(app.transfers.isPaused ? app.m("Resume", "Retomar") : app.m("Pause", "Pausar")) {
                        if app.transfers.isPaused { app.transfers.resume() } else { app.transfers.pause() }
                    }
                    Spacer()
                    Text(app.m("Keep the app open during transfers.", "Mantém a app aberta durante os envios.")).font(.caption).foregroundStyle(.secondary)
                }
                ForEach(app.transfers.items) { item in
                    VStack(alignment: .leading) {
                        Text(item.fileURL.lastPathComponent).font(.callout)
                        Text(item.destinationName).font(.caption).foregroundStyle(.secondary)
                        ProgressView(value: item.progress)
                        HStack {
                            Text(status(item.status)).font(.caption)
                            Spacer()
                            if case .failed = item.status { Button(app.m("Retry", "Repetir")) { app.transfers.retry(item) } }
                        }
                    }
                }.onDelete { offsets in
                    let removing = offsets.compactMap { app.transfers.items.indices.contains($0) ? app.transfers.items[$0] : nil }
                    removing.forEach(app.transfers.remove)
                }
                if let error = app.transfers.persistenceError { Text(error).foregroundStyle(.red) }
            }
            Section {
                Toggle(app.m("Show history", "Mostrar histórico"), isOn: $showHistory)
                if showHistory {
                    Button(app.m("Export history CSV", "Exportar histórico CSV")) { exportCSV() }
                    ForEach(history.filter { search.isEmpty || $0.fileName.localizedCaseInsensitiveContains(search) || $0.destinationName.localizedCaseInsensitiveContains(search) }) { record in
                        VStack(alignment: .leading) {
                            Label(record.fileName, systemImage: record.success ? "checkmark.circle" : "exclamationmark.circle")
                            Text("\(record.destinationName) · \(record.date.formatted())").font(.caption).foregroundStyle(.secondary)
                            if let error = record.errorMessage { Text(error).font(.caption).foregroundStyle(.red) }
                        }
                    }
                }
            }
        }
        .navigationTitle(app.t("module.upload"))
        .confirmationDialog(app.m("Delete this destination?", "Apagar este destino?"), isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button(app.m("Delete", "Apagar"), role: .destructive) {
                if let destination = deleting {
                    let id = destination.id.uuidString
                    context.delete(destination)
                    do {
                        try context.save()
                        if !Keychain.setPasswords([id: "", "privatekey:\(id)": ""]) {
                            app.showToast(app.m("Destination removed, but its saved credentials could not be deleted.", "Destino removido, mas não foi possível apagar as credenciais guardadas."))
                        }
                        if defaultID == id { defaultID = "" }
                    } catch { app.showToast(error.localizedDescription) }
                    deleting = nil
                }
            }
        }
        .searchable(text: $search)
        .sheet(isPresented: $adding) { NavigationStack { MobileDestination(destination: nil) } }
        .sheet(item: $editing) { destination in NavigationStack { MobileDestination(destination: destination) } }
        .sheet(item: $shares) { ShareFiles(urls: $0.urls) }
        .confirmationDialog(app.m("Send selected originals?", "Enviar os originais selecionados?"), isPresented: Binding(get: { confirmSend != nil }, set: { if !$0 { confirmSend = nil } })) {
            if let destination = confirmSend {
                Button(app.m("Send \(photos.count) photographs to \(destination.name)", "Enviar \(photos.count) fotografias para \(destination.name)")) {
                    app.transfers.enqueue(files: photos.map(\.url), destination: destination, event: photos.first?.sessionName ?? "", sources: Dictionary(uniqueKeysWithValues: photos.map { ($0.url, $0.id) }))
                    confirmSend = nil
                }
            }
        }
    }
    private func duplicate(_ source: UploadDestination) {
        let copy = UploadDestination(name: DestinationDefaults.copyName(source.name, suffix: app.m("copy", "cópia"), existing: destinations.map(\.name)), transferProtocol: source.transferProtocol)
        copy.host = source.host; copy.port = source.port; copy.username = source.username
        copy.remoteFolderTemplate = source.remoteFolderTemplate; copy.bucket = source.bucket; copy.region = source.region
        copy.trustUnknownHostKey = source.trustUnknownHostKey
        guard Keychain.setPasswords([
            copy.id.uuidString: Keychain.password(account: source.id.uuidString) ?? "",
            "privatekey:\(copy.id)": Keychain.password(account: "privatekey:\(source.id)") ?? ""
        ]) else { app.showToast(app.m("Unable to copy credentials securely.", "Não foi possível copiar as credenciais em segurança.")); return }
        context.insert(copy)
        do { try context.save() } catch { app.showToast(error.localizedDescription) }
    }
    private func status(_ status: TransferStatus) -> String {
        switch status {
        case .pending: app.m("Pending", "Pendente")
        case .running: app.m("Uploading", "A enviar")
        case .waitingRetry: app.m("Waiting to retry", "A aguardar nova tentativa")
        case .done: app.m("Delivered", "Entregue")
        case .failed(let error): error
        }
    }
    private func exportCSV() {
        let csv = UploadReport.csv(history.map { .init(date: $0.date, fileName: $0.fileName,
            destination: $0.destinationName, remotePath: $0.remotePath, bytes: $0.bytes,
            success: $0.success, error: $0.errorMessage) })
        do {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("UploadHistory.csv")
            try csv.write(to: url, atomically: true, encoding: .utf8)
            shares = SharedFiles(urls: [url])
        } catch { app.showToast(error.localizedDescription) }
    }
}

struct MobileDestination: View {
    @Environment(AppState.self) private var app
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    let destination: UploadDestination?
    @State private var name = ""
    @State private var protocolKind: TransferProtocol = .sftp
    @State private var host = ""
    @State private var port = 22
    @State private var username = ""
    @State private var password = ""
    @State private var folder = "/photos/{date}/{event}"
    @State private var bucket = ""
    @State private var region = "us-east-1"
    @State private var trustNew = false
    @State private var privateKey: String?
    @State private var keyPicker = false
    @State private var message: String?
    @State private var testing = false
    @State private var loaded = false
    @State private var connection: CurlProcess?
    private var valid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        DestinationValidation.issues(transferProtocol: protocolKind, host: host, port: port, username: username, bucket: bucket, template: folder).isEmpty
    }
    private var endpoint: TransferEndpoint { .init(transferProtocol: protocolKind, host: host, port: port, username: username, password: password, bucket: bucket, region: region, trustUnknownHostKey: trustNew, sshPrivateKey: privateKey) }
    var body: some View {
        Form {
            TextField(app.m("Name", "Nome"), text: $name)
            Picker(app.m("Protocol", "Protocolo"), selection: Binding(get: { protocolKind }, set: { protocolKind = $0; port = $0.defaultPort })) { ForEach(TransferProtocol.allCases) { Text($0.displayName).tag($0) } }
            TextField(app.m("Host or HTTPS endpoint", "Servidor ou endereço HTTPS"), text: $host).textInputAutocapitalization(.never).autocorrectionDisabled()
            TextField(app.m("Port", "Porta"), value: $port, format: .number).keyboardType(.numberPad)
            TextField(app.m("Username / access key", "Utilizador / chave de acesso"), text: $username).textInputAutocapitalization(.never).autocorrectionDisabled()
            SecureField(app.m("Password / secret key", "Palavra-passe / chave secreta"), text: $password)
            TextField(app.m("Remote folder", "Pasta remota"), text: $folder).textInputAutocapitalization(.never).autocorrectionDisabled()
            Text(RemotePath.tokens.joined(separator: " ")).font(.caption)
            if protocolKind == .s3 { TextField("Bucket", text: $bucket); TextField(app.m("Region", "Região"), text: $region) }
            if protocolKind == .sftp {
                Button(privateKey == nil ? app.m("Import OpenSSH private key", "Importar chave privada OpenSSH") : app.m("Replace private key", "Substituir chave privada")) { keyPicker = true }
                if privateKey != nil { Button(app.m("Use password instead", "Usar palavra-passe")) { privateKey = nil } }
                Text(app.m("Ed25519 and RSA keys are kept in Keychain. For encrypted keys, enter the passphrase in the password field.", "As chaves Ed25519 e RSA ficam no Porta-chaves. Para chaves cifradas, introduz a frase de acesso no campo da palavra-passe.")).font(.caption)
                Toggle(app.m("Trust server on first connection", "Confiar no servidor na primeira ligação"), isOn: $trustNew)
                Text(app.m("The first key is saved securely. A changed key is always rejected.", "A primeira chave é guardada em segurança. Uma chave alterada é sempre recusada.")).font(.caption)
            }
            Button(app.m("Test connection", "Testar ligação")) { test() }.disabled(!valid || testing)
            if testing { ProgressView() }
            if let message { Text(message).font(.caption) }
            Button(app.m("Save destination", "Guardar destino")) { save() }.disabled(!valid || testing)
        }
        .navigationTitle(app.m("Destination", "Destino"))
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button(app.m("Cancel", "Cancelar")) { dismiss() } } }
        .fileImporter(isPresented: $keyPicker, allowedContentTypes: [.data]) { result in
            do {
                let url = try result.get(); let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
                privateKey = try String(contentsOf: url, encoding: .utf8)
            } catch { message = error.localizedDescription }
        }
        .onDisappear { connection?.cancel() }
        .onAppear {
            guard !loaded else { return }; loaded = true
            if let destination {
                name = destination.name; protocolKind = destination.transferProtocol; host = destination.host; port = destination.port
                username = destination.username; folder = destination.remoteFolderTemplate; bucket = destination.bucket; region = destination.region
                trustNew = destination.trustUnknownHostKey; password = Keychain.password(account: destination.id.uuidString) ?? ""
                privateKey = Keychain.password(account: "privatekey:\(destination.id.uuidString)")
            }
        }
    }
    private func save() {
        let target = destination ?? UploadDestination(name: name, transferProtocol: protocolKind)
        let oldCredentials = [target.id.uuidString: Keychain.password(account: target.id.uuidString) ?? "",
                              "privatekey:\(target.id)": Keychain.password(account: "privatekey:\(target.id)") ?? ""]
        let old = (target.name, target.transferProtocol, target.host, target.port, target.username,
                   target.remoteFolderTemplate, target.bucket, target.region, target.trustUnknownHostKey,
                   target.lastTestedAt, target.lastTestError)
        guard Keychain.setPasswords([target.id.uuidString: password, "privatekey:\(target.id)": privateKey ?? ""]) else {
            message = app.m("Unable to save credentials securely.", "Não foi possível guardar as credenciais em segurança."); return
        }
        target.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        target.transferProtocol = protocolKind; target.host = host.trimmingCharacters(in: .whitespacesAndNewlines); target.port = port
        target.username = username; target.remoteFolderTemplate = folder; target.bucket = bucket; target.region = region; target.trustUnknownHostKey = trustNew
        target.lastTestedAt = nil; target.lastTestError = nil
        if destination == nil { context.insert(target) }
        do { try context.save(); dismiss() } catch {
            target.name = old.0; target.transferProtocol = old.1; target.host = old.2; target.port = old.3
            target.username = old.4; target.remoteFolderTemplate = old.5; target.bucket = old.6
            target.region = old.7; target.trustUnknownHostKey = old.8; target.lastTestedAt = old.9; target.lastTestError = old.10
            if destination == nil { context.delete(target) }
            let restored = Keychain.setPasswords(oldCredentials)
            message = error.localizedDescription + (restored ? "" : app.m(" Credentials could not be restored; save them again.", " Não foi possível repor as credenciais; guarda-as novamente."))
        }
    }
    private func test() {
        testing = true
        let endpoint = endpoint
        let process = CurlProcess(); connection = process
        Task {
            do { try await process.execute(.test(endpoint)); message = app.m("Connection successful", "Ligação bem-sucedida") }
            catch { message = error.localizedDescription }
            connection = nil; testing = false
        }
    }
}

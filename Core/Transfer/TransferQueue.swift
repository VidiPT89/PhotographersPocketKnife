import Foundation
import SwiftData
import UserNotifications

enum TransferStatus: Equatable, Codable {
    case pending, running, waitingRetry, done
    case failed(String)
}

enum ConnectionState: Equatable {
    case idle, transferring, paused, error
}

@Observable
@MainActor
final class TransferItem: Identifiable {
    let id: UUID
    let fileURL: URL
    let destinationID: UUID
    let destinationName: String
    let remotePath: String
    let bytes: Int64
    /// Foto do catálogo que deu origem ao ficheiro (exportação); `nil` = procura pelo caminho do original.
    let sourcePhotoID: UUID?
    var status: TransferStatus = .pending
    var progress = 0.0
    var attempts = 0
    /// Velocidade suavizada (média exponencial) em bytes por segundo.
    var bytesPerSecond = 0.0
    @ObservationIgnored private var lastSample: (time: Date, progress: Double)?

    init(id: UUID = UUID(), fileURL: URL, destinationID: UUID, destinationName: String, remotePath: String, bytes: Int64? = nil, sourcePhotoID: UUID? = nil) {
        self.id = id
        self.sourcePhotoID = sourcePhotoID
        self.fileURL = fileURL
        self.destinationID = destinationID
        self.destinationName = destinationName
        self.remotePath = remotePath
        self.bytes = bytes ?? Int64((try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }

    func updateProgress(_ value: Double, now: Date = Date()) {
        let newValue = max(progress, min(value, 1))
        if let last = lastSample {
            let elapsed = now.timeIntervalSince(last.time)
            if elapsed >= 0.25 {
                let instant = (newValue - last.progress) * Double(bytes) / elapsed
                bytesPerSecond = bytesPerSecond == 0 ? instant : bytesPerSecond * 0.7 + instant * 0.3
                lastSample = (now, newValue)
            }
        } else {
            lastSample = (now, newValue)
        }
        progress = newValue
    }

    func resetSpeed() {
        bytesPerSecond = 0
        lastSample = nil
    }

    var remainingSeconds: Double? {
        guard bytesPerSecond > 1 else { return nil }
        return (1 - progress) * Double(bytes) / bytesPerSecond
    }
}

/// Itens da fila agrupados por destino, pela ordem em que cada destino apareceu.
struct TransferGroup: Identifiable {
    let id: UUID
    let name: String
    let items: [TransferItem]

    @MainActor
    static func make(_ items: [TransferItem]) -> [TransferGroup] {
        var order: [UUID] = []
        var grouped: [UUID: [TransferItem]] = [:]
        for item in items {
            if grouped[item.destinationID] == nil { order.append(item.destinationID) }
            grouped[item.destinationID, default: []].append(item)
        }
        return order.compactMap { id in
            grouped[id].map { TransferGroup(id: id, name: $0[0].destinationName, items: $0) }
        }
    }
}

enum TransferFormat {
    static func speed(_ bytesPerSecond: Double) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytesPerSecond), countStyle: .file) + "/s"
    }

    static func duration(_ seconds: Double) -> String {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.allowedUnits = seconds >= 3600 ? [.hour, .minute] : [.minute, .second]
        formatter.maximumUnitCount = 2
        return formatter.string(from: max(seconds, 1)) ?? ""
    }
}

/// Fila de envios com concorrência, pausa/retoma, retry automático, histórico e notificação final.
@Observable
@MainActor
final class TransferQueue {
    var items: [TransferItem] = []
    var isPaused = false
    var maxConcurrent: Int {
        didSet { UserDefaults.standard.set(maxConcurrent, forKey: "transfers.maxConcurrent"); pump() }
    }
    var maxAttempts: Int {
        didSet { UserDefaults.standard.set(maxAttempts, forKey: "transfers.maxAttempts") }
    }

    @ObservationIgnored var localize: (String) -> String = { $0 }
    @ObservationIgnored var onBatchFinished: ((Int, Int) -> Void)?
    @ObservationIgnored private var context: ModelContext?
    @ObservationIgnored private var running: [UUID: CurlProcess] = [:]
    @ObservationIgnored private var batchActive = false
    @ObservationIgnored private var batchIDs: Set<UUID> = []
    @ObservationIgnored private var persistenceURL: URL?
    private(set) var persistenceError: String?

    private struct SavedItem: Codable {
        var id: UUID
        var fileURL: URL
        var destinationID: UUID
        var destinationName: String
        var remotePath: String
        var bytes: Int64
        var status: TransferStatus
        var sourcePhotoID: UUID?
    }

    /// Recupera o trabalho interrompido em pausa, para o fotógrafo rever antes de retomar.
    func restore(from url: URL) {
        guard persistenceURL == nil else { return }
        persistenceURL = url
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let saved = try JSONDecoder().decode([SavedItem].self, from: Data(contentsOf: url))
            items = saved.map { entry in
                let item = TransferItem(id: entry.id, fileURL: entry.fileURL, destinationID: entry.destinationID,
                                        destinationName: entry.destinationName, remotePath: entry.remotePath, bytes: entry.bytes,
                                        sourcePhotoID: entry.sourcePhotoID)
                switch entry.status {
                case .running, .waitingRetry: item.status = .pending
                default: item.status = entry.status
                }
                if item.status == .done { item.progress = 1 }
                return item
            }
            isPaused = items.contains { $0.status == .pending }
            batchActive = isPaused
            batchIDs = Set(items.filter { $0.status == .pending }.map(\.id))
        } catch {
            persistenceError = error.localizedDescription
            // Um ficheiro que não conseguimos ler fica intacto.
            persistenceURL = nil
        }
    }

    private func saveQueue() {
        guard let persistenceURL else { return }
        do {
            let saved = items.map { SavedItem(id: $0.id, fileURL: $0.fileURL, destinationID: $0.destinationID,
                destinationName: $0.destinationName, remotePath: $0.remotePath, bytes: $0.bytes, status: $0.status,
                sourcePhotoID: $0.sourcePhotoID) }
            try FileManager.default.createDirectory(at: persistenceURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(saved).write(to: persistenceURL, options: .atomic)
            persistenceError = nil
        } catch {
            persistenceError = error.localizedDescription
        }
    }

    init() {
        let defaults = UserDefaults.standard
        maxConcurrent = max(1, defaults.object(forKey: "transfers.maxConcurrent") as? Int ?? 2)
        maxAttempts = defaults.object(forKey: "transfers.maxAttempts") as? Int ?? 3
    }

    func attach(context: ModelContext) {
        self.context = context
    }

    var connectionState: ConnectionState {
        if items.contains(where: { $0.status == .running }) { return .transferring }
        if isPaused, items.contains(where: { $0.status == .pending || $0.status == .waitingRetry }) { return .paused }
        if items.contains(where: { if case .failed = $0.status { true } else { false } }) { return .error }
        return .idle
    }

    var overallProgress: Double {
        let total = items.reduce(0) { $0 + max($1.bytes, 1) }
        guard total > 0 else { return 0 }
        let done = items.reduce(0.0) { $0 + Double(max($1.bytes, 1)) * ($1.status == .done ? 1 : $1.progress) }
        return done / Double(total)
    }

    var totalBytesPerSecond: Double {
        items.filter { $0.status == .running }.reduce(0) { $0 + $1.bytesPerSecond }
    }

    /// Tempo estimado para acabar tudo o que falta, à velocidade atual.
    var remainingSeconds: Double? {
        let speed = totalBytesPerSecond
        guard speed > 1 else { return nil }
        let remaining = items
            .filter { [.pending, .running, .waitingRetry].contains($0.status) }
            .reduce(0.0) { $0 + (1 - $1.progress) * Double($1.bytes) }
        return remaining / speed
    }

    var completedCount: Int { items.filter { $0.status == .done }.count }
    var failedCount: Int { items.filter { if case .failed = $0.status { true } else { false } }.count }

    // MARK: Controlo

    /// `sources` liga cada ficheiro exportado à foto de origem, para a marcar como enviada.
    func enqueue(files: [URL], destination: UploadDestination, event: String, sources: [URL: UUID] = [:]) {
        guard !files.isEmpty else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        let folder = RemotePath.folder(template: destination.remoteFolderTemplate, date: Date(), event: event)
        for file in files {
            let item = TransferItem(
                fileURL: file,
                destinationID: destination.id,
                destinationName: destination.name,
                remotePath: RemotePath.join(folder, file.lastPathComponent),
                sourcePhotoID: sources[file]
            )
            items.append(item)
            batchIDs.insert(item.id)
        }
        batchActive = true
        saveQueue()
        pump()
    }

    func pause() {
        isPaused = true
        for item in items where item.status == .running {
            running[item.id]?.cancel()
        }
    }

    func resume() {
        isPaused = false
        pump()
    }

    func retry(_ item: TransferItem) {
        guard items.contains(where: { $0.id == item.id }), case .failed = item.status else { return }
        item.progress = 0
        item.resetSpeed()
        item.status = .pending
        item.attempts = 0
        batchIDs.insert(item.id)
        batchActive = true
        saveQueue()
        pump()
    }

    func retryFailed() {
        for item in items {
            if case .failed = item.status { retry(item) }
        }
    }

    func remove(_ item: TransferItem) {
        running[item.id]?.cancel()
        items.removeAll { $0.id == item.id }
        batchIDs.remove(item.id)
        saveQueue()
        pump()
    }

    func clearFinished() {
        items.removeAll { $0.status == .done }
        saveQueue()
    }

    // MARK: Execução

    private func pump() {
        guard !isPaused else { return }
        while running.count < max(1, maxConcurrent), let next = items.first(where: { $0.status == .pending }) {
            start(next)
        }
        saveQueue()
        finishBatchIfNeeded()
    }

    private func start(_ item: TransferItem) {
        guard let destination = fetchDestination(item.destinationID) else {
            item.status = .failed(TransferError.missingDestination.localizedDescription)
            record(item, error: TransferError.missingDestination.localizedDescription)
            return
        }
        let endpoint = destination.endpoint()
        // A partir da 2.ª tentativa retoma o ficheiro parcial (FTP/SFTP).
        let resume = item.attempts > 0 && item.progress > 0 && [.ftp, .ftps, .sftp].contains(endpoint.transferProtocol)
        let command = TransferCommand.upload(endpoint, file: item.fileURL, remotePath: item.remotePath, resume: resume)

        if !resume { item.progress = 0 }
        item.resetSpeed()
        item.status = .running
        item.attempts += 1
        let process = CurlProcess(executable: command.executable, environment: command.environment)
        running[item.id] = process

        Task {
            do {
                try await process.run(arguments: command.arguments, config: command.input) { progress in
                    Task { @MainActor in item.updateProgress(progress) }
                }
                guard items.contains(where: { $0.id == item.id }) else {
                    running[item.id] = nil
                    pump()
                    return
                }
                item.progress = 1
                item.resetSpeed()
                item.status = .done
                markDelivered(item)
                record(item, error: nil)
            } catch TransferError.cancelled {
                item.resetSpeed()
                if item.status == .running { item.status = .pending }
            } catch let error as TransferError where error.isRetryable && item.attempts < maxAttempts {
                item.status = .waitingRetry
                scheduleRetry(item)
            } catch {
                item.status = .failed(error.localizedDescription)
                record(item, error: error.localizedDescription)
            }
            running[item.id] = nil
            saveQueue()
            pump()
        }
    }

    private func scheduleRetry(_ item: TransferItem) {
        let delay = pow(2, Double(item.attempts))
        Task {
            try? await Task.sleep(for: .seconds(delay))
            guard items.contains(where: { $0.id == item.id }), item.status == .waitingRetry else { return }
            item.status = .pending
            pump()
        }
    }

    private func finishBatchIfNeeded() {
        let busy = items.contains { [.pending, .running, .waitingRetry].contains($0.status) }
        guard batchActive, !busy else { return }
        batchActive = false
        let batch = items.filter { batchIDs.contains($0.id) }
        batchIDs = []
        guard !batch.isEmpty else { return }
        let completed = batch.filter { $0.status == .done }.count
        let failed = batch.filter { if case .failed = $0.status { true } else { false } }.count
        onBatchFinished?(completed, failed)
        let content = UNMutableNotificationContent()
        content.title = localize("notification.uploadDone.title")
        content.body = String(format: localize("notification.uploadDone.body"), completed, failed)
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    private func fetchDestination(_ id: UUID) -> UploadDestination? {
        let descriptor = FetchDescriptor<UploadDestination>(predicate: #Predicate { $0.id == id })
        return try? context?.fetch(descriptor).first
    }

    /// A foto de origem fica marcada como enviada: pelo id, quando o ficheiro é uma exportação,
    /// ou pelo caminho, quando se enviou o próprio original. A gravação fica a cargo de `record`.
    func markDelivered(_ item: TransferItem, at date: Date = Date()) {
        guard let context else { return }
        let descriptor: FetchDescriptor<Photo>
        if let id = item.sourcePhotoID {
            descriptor = FetchDescriptor(predicate: #Predicate { $0.id == id })
        } else {
            let path = item.fileURL.path
            descriptor = FetchDescriptor(predicate: #Predicate { $0.path == path })
        }
        guard let photo = try? context.fetch(descriptor).first else { return }
        photo.deliveredAt = date
        photo.deliveredTo = item.destinationName
    }

    private func record(_ item: TransferItem, error: String?) {
        guard let context else { return }
        context.insert(UploadRecord(
            fileName: item.fileURL.lastPathComponent,
            destinationName: item.destinationName,
            remotePath: item.remotePath,
            success: error == nil,
            errorMessage: error,
            bytes: item.bytes,
            destinationID: item.destinationID
        ))
        try? context.save()
    }
}

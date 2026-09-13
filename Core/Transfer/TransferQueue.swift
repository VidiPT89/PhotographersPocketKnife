import Foundation
import SwiftData
import UserNotifications

enum TransferStatus: Equatable {
    case pending, running, waitingRetry, done
    case failed(String)
}

enum ConnectionState: Equatable {
    case idle, transferring, paused, error
}

@Observable
@MainActor
final class TransferItem: Identifiable {
    let id = UUID()
    let fileURL: URL
    let destinationID: UUID
    let destinationName: String
    let remotePath: String
    let bytes: Int64
    var status: TransferStatus = .pending
    var progress = 0.0
    var attempts = 0
    /// Velocidade suavizada (média exponencial) em bytes por segundo.
    var bytesPerSecond = 0.0
    @ObservationIgnored private var lastSample: (time: Date, progress: Double)?

    init(fileURL: URL, destinationID: UUID, destinationName: String, remotePath: String, bytes: Int64? = nil) {
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

    init() {
        let defaults = UserDefaults.standard
        maxConcurrent = defaults.object(forKey: "transfers.maxConcurrent") as? Int ?? 2
        maxAttempts = defaults.object(forKey: "transfers.maxAttempts") as? Int ?? 3
    }

    func attach(context: ModelContext) {
        self.context = context
    }

    var connectionState: ConnectionState {
        if items.contains(where: { $0.status == .running }) { return .transferring }
        if isPaused, items.contains(where: { $0.status == .pending }) { return .paused }
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

    func enqueue(files: [URL], destination: UploadDestination, event: String) {
        guard !files.isEmpty else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        let folder = RemotePath.folder(template: destination.remoteFolderTemplate, date: Date(), event: event)
        for file in files {
            items.append(TransferItem(
                fileURL: file,
                destinationID: destination.id,
                destinationName: destination.name,
                remotePath: RemotePath.join(folder, file.lastPathComponent)
            ))
        }
        batchActive = true
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
        item.status = .pending
        item.attempts = 0
        batchActive = true
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
    }

    func clearFinished() {
        items.removeAll { $0.status == .done }
    }

    // MARK: Execução

    private func pump() {
        guard !isPaused else { return }
        while running.count < maxConcurrent, let next = items.first(where: { $0.status == .pending }) {
            start(next)
        }
        finishBatchIfNeeded()
    }

    private func start(_ item: TransferItem) {
        guard let destination = fetchDestination(item.destinationID) else {
            item.status = .failed(TransferError.missingDestination.localizedDescription)
            return
        }
        let endpoint = TransferEndpoint(
            transferProtocol: destination.transferProtocol,
            host: destination.host,
            port: destination.port,
            username: destination.username,
            password: Keychain.password(account: destination.id.uuidString) ?? "",
            bucket: destination.bucket,
            region: destination.region,
            trustUnknownHostKey: destination.trustUnknownHostKey
        )
        // A partir da 2.ª tentativa retoma o ficheiro parcial (FTP/SFTP).
        let resume = item.attempts > 0 && item.progress > 0 && [.ftp, .ftps, .sftp].contains(endpoint.transferProtocol)
        let command = TransferCommand.upload(endpoint, file: item.fileURL, remotePath: item.remotePath, resume: resume)

        item.status = .running
        item.attempts += 1
        let process = CurlProcess(executable: command.executable, environment: command.environment)
        running[item.id] = process

        Task {
            do {
                try await process.run(arguments: command.arguments, config: command.input) { progress in
                    Task { @MainActor in item.updateProgress(progress) }
                }
                item.progress = 1
                item.resetSpeed()
                item.status = .done
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
            pump()
        }
    }

    private func scheduleRetry(_ item: TransferItem) {
        let delay = pow(2, Double(item.attempts))
        Task {
            try? await Task.sleep(for: .seconds(delay))
            guard item.status == .waitingRetry else { return }
            item.status = .pending
            pump()
        }
    }

    private func finishBatchIfNeeded() {
        let busy = items.contains { [.pending, .running, .waitingRetry].contains($0.status) }
        guard batchActive, !busy, !items.isEmpty else { return }
        batchActive = false
        onBatchFinished?(completedCount, failedCount)
        let content = UNMutableNotificationContent()
        content.title = localize("notification.uploadDone.title")
        content.body = String(format: localize("notification.uploadDone.body"), completedCount, failedCount)
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    private func fetchDestination(_ id: UUID) -> UploadDestination? {
        let descriptor = FetchDescriptor<UploadDestination>(predicate: #Predicate { $0.id == id })
        return try? context?.fetch(descriptor).first
    }

    private func record(_ item: TransferItem, error: String?) {
        guard let context else { return }
        context.insert(UploadRecord(
            fileName: item.fileURL.lastPathComponent,
            destinationName: item.destinationName,
            remotePath: item.remotePath,
            success: error == nil,
            errorMessage: error,
            bytes: item.bytes
        ))
        try? context.save()
    }
}

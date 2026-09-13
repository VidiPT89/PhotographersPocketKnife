import SwiftUI
import SwiftData

/// Modo "hot folder": tudo o que recebe a etiqueta escolhida (verde, por defeito) é exportado com as últimas
/// definições de exportação e enviado automaticamente para o destino escolhido (fluxo de desporto ao vivo).
@Observable
@MainActor
final class HotFolderService {
    private let defaults: UserDefaults

    var isEnabled: Bool { didSet { defaults.set(isEnabled, forKey: Keys.enabled) } }
    var label: ColorLabel { didSet { defaults.set(label.rawValue, forKey: Keys.label) } }
    var destinationID: UUID? { didSet { defaults.set(destinationID?.uuidString, forKey: Keys.destination) } }
    var event: String { didSet { defaults.set(event, forKey: Keys.event) } }
    var exportFolderPath: String { didSet { defaults.set(exportFolderPath, forKey: Keys.folder) } }
    private(set) var activeExports = 0

    @ObservationIgnored private var context: ModelContext?
    /// Fotos já tratadas nesta sessão (voltar a pôr a etiqueta não duplica o envio).
    @ObservationIgnored private(set) var processed: Set<UUID> = []

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isEnabled = defaults.bool(forKey: Keys.enabled)
        label = ColorLabel(rawValue: defaults.object(forKey: Keys.label) as? Int ?? ColorLabel.green.rawValue) ?? .green
        destinationID = defaults.string(forKey: Keys.destination).flatMap(UUID.init(uuidString:))
        event = defaults.string(forKey: Keys.event) ?? ""
        exportFolderPath = defaults.string(forKey: Keys.folder) ?? ""
    }

    func attach(context: ModelContext) {
        self.context = context
    }

    var exportFolder: URL {
        if !exportFolderPath.isEmpty { return URL(fileURLWithPath: exportFolderPath, isDirectory: true) }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PhotographersPocketKnife/HotFolder", isDirectory: true)
    }

    func shouldProcess(_ photo: Photo) -> Bool {
        isEnabled && destinationID != nil && photo.colorLabel == label && !processed.contains(photo.id)
    }

    /// Chamado depois de uma alteração de etiqueta. Devolve quantas fotos entraram no fluxo.
    @discardableResult
    func handleLabelChange(_ photos: [Photo], transfers: TransferQueue) -> Int {
        let targets = photos.filter(shouldProcess)
        guard !targets.isEmpty, let destination = fetchDestination() else { return 0 }
        targets.forEach { processed.insert($0.id) }

        let jobs = targets.map { photo in
            (url: photo.url, recipe: photo.recipeData.flatMap { try? JSONDecoder().decode(EditRecipe.self, from: $0) } ?? EditRecipe())
        }
        let settings = ExportPresetStore.lastSettings
        let folder = exportFolder
        let event = event
        activeExports += jobs.count
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        Task {
            var outputs: [URL] = []
            for job in jobs {
                if let output = try? await Task.detached(priority: .userInitiated, operation: {
                    try ImageRenderer.shared.export(url: job.url, recipe: job.recipe, settings: settings, to: folder)
                }).value {
                    outputs.append(output)
                }
                activeExports -= 1
            }
            transfers.enqueue(files: outputs, destination: destination, event: event)
        }
        return targets.count
    }

    private func fetchDestination() -> UploadDestination? {
        guard let id = destinationID else { return nil }
        let descriptor = FetchDescriptor<UploadDestination>(predicate: #Predicate { $0.id == id })
        return try? context?.fetch(descriptor).first
    }

    private enum Keys {
        static let enabled = "hotFolder.enabled"
        static let label = "hotFolder.label"
        static let destination = "hotFolder.destination"
        static let event = "hotFolder.event"
        static let folder = "hotFolder.folder"
    }
}

/// Relatório de envios em CSV (lista de ficheiros, destino, tamanho, hora e resultado).
enum UploadReport {
    struct Row: Sendable {
        var date: Date
        var fileName: String
        var destination: String
        var remotePath: String
        var bytes: Int64
        var success: Bool
        var error: String?
    }

    static func csv(_ rows: [Row]) -> String {
        let formatter = ISO8601DateFormatter()
        var lines = ["date,file,destination,remote_path,bytes,status,error"]
        for row in rows {
            lines.append([
                formatter.string(from: row.date),
                row.fileName,
                row.destination,
                row.remotePath,
                String(row.bytes),
                row.success ? "ok" : "failed",
                row.error ?? "",
            ].map(field).joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func field(_ value: String) -> String {
        guard value.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" }) else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}

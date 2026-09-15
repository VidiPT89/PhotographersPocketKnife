import Foundation
import SwiftData

enum WatchFolderScanner {
    /// Ficheiros novos cujo tamanho não mudou desde a leitura anterior (a câmara ou o FTP já acabou de escrever).
    static func ready(current: [String: Int64], previous: [String: Int64], known: Set<String>) -> [String] {
        current
            .filter { path, size in size > 0 && !known.contains(path) && previous[path] == size }
            .map(\.key)
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    static func sizes(in folder: URL) -> [String: Int64] {
        var result: [String: Int64] = [:]
        for url in PhotoImporter.imageFiles(in: folder) {
            result[url.path] = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return result
    }
}

/// Pasta vigiada: as fotos que chegam (FTP da câmara, Wi-Fi, tethering) entram sozinhas no catálogo.
@Observable
@MainActor
final class WatchFolderService {
    private let defaults: UserDefaults

    var isEnabled: Bool {
        didSet { defaults.set(isEnabled, forKey: Keys.enabled); restart() }
    }
    var folderPath: String {
        didSet { defaults.set(folderPath, forKey: Keys.folder); restart() }
    }
    var sessionName: String {
        didSet { defaults.set(sessionName, forKey: Keys.session) }
    }
    private(set) var importedCount = 0

    @ObservationIgnored var onImported: ((Int) -> Void)?
    @ObservationIgnored private var context: ModelContext?
    @ObservationIgnored private weak var culling: CullingModel?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var previous: [String: Int64] = [:]
    @ObservationIgnored private var known: Set<String> = []

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isEnabled = defaults.bool(forKey: Keys.enabled)
        folderPath = defaults.string(forKey: Keys.folder) ?? ""
        sessionName = defaults.string(forKey: Keys.session) ?? "Live"
    }

    func attach(context: ModelContext, culling: CullingModel) {
        self.context = context
        self.culling = culling
        restart()
    }

    private func restart() {
        task?.cancel()
        task = nil
        previous = [:]
        guard isEnabled, !folderPath.isEmpty, let context else { return }
        known = Set(((try? context.fetch(FetchDescriptor<Photo>())) ?? []).map(\.path))
        let folder = URL(fileURLWithPath: folderPath, isDirectory: true)
        task = Task { [weak self] in
            while !Task.isCancelled {
                let sizes = await Task.detached(priority: .utility) { WatchFolderScanner.sizes(in: folder) }.value
                guard let self, !Task.isCancelled else { return }
                await self.tick(sizes)
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func tick(_ sizes: [String: Int64]) async {
        let ready = WatchFolderScanner.ready(current: sizes, previous: previous, known: known)
        previous = sizes
        guard !ready.isEmpty, let context, let culling, !culling.isImporting else { return }
        known.formUnion(ready)
        let name = sessionName.trimmingCharacters(in: .whitespaces).isEmpty ? "Live" : sessionName
        await culling.importFiles(ready.map { URL(fileURLWithPath: $0) }, options: .init(copyDestination: nil), session: name, context: context)
        let added = culling.lastImportCount ?? 0
        guard added > 0 else { return }
        importedCount += added
        onImported?(added)
    }

    private enum Keys {
        static let enabled = "watchFolder.enabled"
        static let folder = "watchFolder.folder"
        static let session = "watchFolder.session"
    }
}

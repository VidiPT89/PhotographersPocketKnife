import SwiftUI
import SwiftData

enum FlagFilter: String, CaseIterable, Identifiable {
    case all, picks, rejects, unflagged
    var id: String { rawValue }
    var labelKey: String { "flagFilter.\(rawValue)" }
}

enum PhotoSort: String, CaseIterable, Identifiable {
    case captureDate, fileName, rating, camera
    var id: String { rawValue }
    var labelKey: String { "sort.\(rawValue)" }
}

enum CullingViewMode: String, CaseIterable, Identifiable {
    case grid, loupe, compare
    var id: String { rawValue }

    var icon: String {
        switch self {
        case .grid: "square.grid.2x2"
        case .loupe: "rectangle"
        case .compare: "rectangle.split.2x1"
        }
    }
}

enum CullingSheet: Identifiable {
    case importFolder(URL), rename, metadata

    var id: String {
        switch self {
        case .importFolder(let url): "import-\(url.path)"
        case .rename: "rename"
        case .metadata: "metadata"
        }
    }
}

@Observable
@MainActor
final class CullingModel {
    var selection: Set<UUID> = []
    var focusedID: UUID?

    var session: String?
    var minRating = 0
    var flagFilter: FlagFilter = .all
    var colorFilter: ColorLabel?
    var camera: String?
    var lens: String?
    var minISO = 0
    var focalLength: Double?
    var searchText = ""
    var sort: PhotoSort = .captureDate
    var sortAscending = true

    var viewMode: CullingViewMode = .grid {
        didSet { if viewMode != .loupe { zoomed = false; magnifier = false } }
    }
    /// 5 tamanhos de miniatura (teclas `-` e `+`).
    static let thumbnailSizes: [Double] = [110, 150, 200, 270, 360]
    static let isoSteps = [0, 400, 800, 1600, 3200, 6400]
    var thumbnailStep = 2
    var thumbnailSize: Double { Self.thumbnailSizes[min(max(thumbnailStep, 0), Self.thumbnailSizes.count - 1)] }
    /// Zoom 100 % a seguir o cursor, na lupa.
    var zoomed = false
    /// Lupa circular a 100 % a seguir o cursor.
    var magnifier = false
    /// Modo apresentação ao cliente, em ecrã completo.
    var presenting = false
    /// Direção da última navegação, para o pré-carregamento dar mais peso ao que vem a seguir.
    var lastDirection = 1
    var gridColumns = 1
    var showInfoPanel = true
    var activeSheet: CullingSheet?

    var showDuplicatesOnly = false
    var duplicateGroups: [UUID: Int] = [:]
    var isFindingDuplicates = false

    var isImporting = false
    var importProgress = 0.0
    var lastImportCount: Int?
    var lastImportFailures = 0

    var hasActiveFilters: Bool {
        minRating > 0 || flagFilter != .all || colorFilter != nil || camera != nil || lens != nil
            || minISO > 0 || focalLength != nil || showDuplicatesOnly
    }

    func clearFilters() {
        minRating = 0
        flagFilter = .all
        colorFilter = nil
        camera = nil
        lens = nil
        minISO = 0
        focalLength = nil
        showDuplicatesOnly = false
        searchText = ""
    }

    // MARK: Filtros e ordenação

    func visible(_ photos: [Photo]) -> [Photo] {
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        let list = photos.filter { photo in
            if let session, photo.sessionName != session { return false }
            if photo.rating < minRating { return false }
            switch flagFilter {
            case .all: break
            case .picks: if photo.flag != .pick { return false }
            case .rejects: if photo.flag != .reject { return false }
            case .unflagged: if photo.flag != .none { return false }
            }
            if let colorFilter, photo.colorLabel != colorFilter { return false }
            if let camera, photo.camera != camera { return false }
            if let lens, photo.lens != lens { return false }
            if minISO > 0, (photo.iso ?? 0) < minISO { return false }
            if let focalLength, photo.focalLength?.rounded() != focalLength { return false }
            if showDuplicatesOnly, duplicateGroups[photo.id] == nil { return false }
            if !query.isEmpty, !photo.fileName.lowercased().contains(query) { return false }
            return true
        }
        return list.sorted { a, b in
            if showDuplicatesOnly, let ga = duplicateGroups[a.id], let gb = duplicateGroups[b.id], ga != gb {
                return ga < gb
            }
            return sortAscending ? less(a, b) : less(b, a)
        }
    }

    private func less(_ a: Photo, _ b: Photo) -> Bool {
        switch sort {
        case .captureDate: (a.captureDate ?? .distantPast, a.fileName) < (b.captureDate ?? .distantPast, b.fileName)
        case .fileName: a.fileName.localizedStandardCompare(b.fileName) == .orderedAscending
        case .rating: (a.rating, a.fileName) < (b.rating, b.fileName)
        case .camera: (a.camera ?? "", a.fileName) < (b.camera ?? "", b.fileName)
        }
    }

    // MARK: Seleção

    func focused(in list: [Photo]) -> Photo? {
        list.first { $0.id == focusedID }
    }

    func click(_ photo: Photo, in list: [Photo]) {
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) {
            if selection.contains(photo.id) { selection.remove(photo.id) } else { selection.insert(photo.id) }
        } else if flags.contains(.shift),
                  let anchor = list.firstIndex(where: { $0.id == focusedID }),
                  let index = list.firstIndex(where: { $0.id == photo.id }) {
            selection.formUnion(list[min(anchor, index)...max(anchor, index)].map(\.id))
        } else {
            selection = [photo.id]
        }
        focusedID = photo.id
    }

    /// Fotos afetadas por uma ação: a seleção, ou a foto em foco.
    func targets(in list: [Photo]) -> [Photo] {
        let selected = list.filter { selection.contains($0.id) }
        return selected.isEmpty ? list.filter { $0.id == focusedID } : selected
    }

    func move(by delta: Int, in list: [Photo], extend: Bool) {
        guard !list.isEmpty else { return }
        lastDirection = delta >= 0 ? 1 : -1
        let next: Int
        if let current = list.firstIndex(where: { $0.id == focusedID }) {
            next = min(max(current + delta, 0), list.count - 1)
        } else {
            next = 0
        }
        let id = list[next].id
        focusedID = id
        if extend { selection.insert(id) } else { selection = [id] }
    }

    func comparePhotos(in list: [Photo]) -> [Photo] {
        var picked = list.filter { selection.contains($0.id) }
        if picked.count < 2, let index = list.firstIndex(where: { $0.id == focusedID }) ?? list.indices.first {
            picked = Array(list[index..<min(index + 2, list.count)])
        }
        return Array(picked.prefix(4))
    }

    // MARK: Ações

    func perform(_ action: CullingAction, in list: [Photo]) {
        // Em comparação, a ação aplica-se só ao painel em foco.
        let photos = viewMode == .compare ? list.filter { $0.id == focusedID } : targets(in: list)
        switch action {
        case .rate0, .rate1, .rate2, .rate3, .rate4, .rate5:
            let value = Int(String(action.rawValue.last ?? "0")) ?? 0
            photos.forEach { $0.rating = value }
        case .pick: toggle(.pick, photos)
        case .reject: toggle(.reject, photos)
        case .unflag: photos.forEach { $0.flag = .none }
        case .labelRed: toggle(.red, photos)
        case .labelYellow: toggle(.yellow, photos)
        case .labelGreen: toggle(.green, photos)
        case .labelBlue: toggle(.blue, photos)
        case .labelPurple: toggle(.purple, photos)
        case .loupe: viewMode = viewMode == .loupe ? .grid : .loupe
        case .compare: viewMode = viewMode == .compare ? .grid : .compare
        case .zoom:
            if viewMode != .loupe { viewMode = .loupe }
            zoomed.toggle()
            if zoomed { magnifier = false }
        case .magnifier:
            if viewMode != .loupe { viewMode = .loupe }
            magnifier.toggle()
            if magnifier { zoomed = false }
        case .smaller: thumbnailStep = max(thumbnailStep - 1, 0)
        case .larger: thumbnailStep = min(thumbnailStep + 1, Self.thumbnailSizes.count - 1)
        case .presentation: presenting.toggle()
        case .develop, .crop: break // tratados pela app (mudam de módulo)
        }
    }

    private func toggle(_ flag: PhotoFlag, _ photos: [Photo]) {
        let newValue: PhotoFlag = photos.allSatisfy { $0.flag == flag } ? .none : flag
        photos.forEach { $0.flag = newValue }
    }

    private func toggle(_ label: ColorLabel, _ photos: [Photo]) {
        let newValue: ColorLabel = photos.allSatisfy { $0.colorLabel == label } ? .none : label
        photos.forEach { $0.colorLabel = newValue }
    }

    // MARK: Importação e duplicados

    func importFolder(_ folder: URL, options: PhotoImporter.Options, session: String, context: ModelContext) async {
        let files = await Task.detached(priority: .userInitiated) { PhotoImporter.imageFiles(in: folder) }.value
        await importFiles(files, options: options, session: session, context: context)
    }

    func importFiles(_ files: [URL], options: PhotoImporter.Options, session: String, context: ModelContext) async {
        isImporting = true
        importProgress = 0
        let result = await Task.detached(priority: .userInitiated) {
            (try? PhotoImporter.runReporting(files: files, options: options) { done, total in
                Task { @MainActor in self.importProgress = Double(done) / Double(max(total, 1)) }
            }) ?? PhotoImporter.Result(infos: [], failures: [])
        }.value
        lastImportFailures = result.failures.count
        lastImportCount = CatalogService.insert(result.infos, session: session, into: context)
        self.session = session
        isImporting = false
    }

    func findDuplicates(in photos: [Photo]) async {
        isFindingDuplicates = true
        let pending = photos.filter { $0.perceptualHash == nil }.map { (id: $0.id, url: $0.url) }
        let hashes = await Task.detached(priority: .userInitiated) {
            pending.compactMap { item -> (UUID, Int64)? in
                guard let thumb = ThumbnailCache.shared.thumbnail(for: item.url, maxPixel: 320) else { return nil }
                return (item.id, Int64(bitPattern: PerceptualHash.dHash(thumb.cgImage)))
            }
        }.value
        let byID = Dictionary(uniqueKeysWithValues: hashes)
        for photo in photos {
            if let hash = byID[photo.id] { photo.perceptualHash = hash }
        }
        let items = photos.compactMap { photo in
            photo.perceptualHash.map { (id: photo.id, hash: UInt64(bitPattern: $0)) }
        }
        duplicateGroups = PerceptualHash.groups(items, threshold: 6)
        showDuplicatesOnly = true
        isFindingDuplicates = false
    }
}

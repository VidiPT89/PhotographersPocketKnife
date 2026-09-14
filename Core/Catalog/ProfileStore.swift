import Foundation

/// Perfil aprendido (estilo de edição ou gosto de seleção), guardado como JSON.
protocol StoredProfile: Codable, Identifiable, Sendable where ID == UUID {
    static var folderName: String { get }
    var name: String { get }
}

/// Perfis em ficheiros JSON em Application Support (fáceis de copiar para outro Mac).
struct ProfileStore<Profile: StoredProfile>: Sendable {
    let directory: URL

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PhotographersPocketKnife/\(Profile.folderName)", isDirectory: true)
    }

    func all() -> [Profile] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { try? JSONDecoder().decode(Profile.self, from: Data(contentsOf: $0)) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func profile(id: UUID) -> Profile? {
        try? JSONDecoder().decode(Profile.self, from: Data(contentsOf: url(for: id)))
    }

    func save(_ profile: Profile) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? JSONEncoder().encode(profile).write(to: url(for: profile.id), options: .atomic)
    }

    func delete(_ id: UUID) {
        try? FileManager.default.removeItem(at: url(for: id))
    }

    private func url(for id: UUID) -> URL {
        directory.appendingPathComponent(id.uuidString).appendingPathExtension("json")
    }
}

typealias StyleProfileStore = ProfileStore<StyleProfile>
typealias TasteProfileStore = ProfileStore<TasteProfile>

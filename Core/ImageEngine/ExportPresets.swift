import SwiftUI
import SwiftData

struct ExportPreset: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var settings: ExportSettings
}

enum ExportPresetStore {
    private static let presetsKey = "export.presets"
    private static let lastKey = "export.lastSettings"

    static func presets() -> [ExportPreset] {
        guard let data = UserDefaults.standard.data(forKey: presetsKey) else { return [] }
        return (try? JSONDecoder().decode([ExportPreset].self, from: data)) ?? []
    }

    static func save(_ presets: [ExportPreset]) {
        UserDefaults.standard.set(try? JSONEncoder().encode(presets), forKey: presetsKey)
    }

    static var lastSettings: ExportSettings {
        get {
            UserDefaults.standard.data(forKey: lastKey).flatMap { try? JSONDecoder().decode(ExportSettings.self, from: $0) } ?? ExportSettings()
        }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: lastKey) }
    }
}

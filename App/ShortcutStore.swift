import SwiftUI

enum CullingAction: String, CaseIterable, Identifiable, Sendable {
    case rate0, rate1, rate2, rate3, rate4, rate5
    case pick, reject, unflag
    case labelRed, labelYellow, labelGreen, labelBlue, labelPurple
    case loupe, compare

    var id: String { rawValue }
    var labelKey: String { "shortcut.\(rawValue)" }

    /// Paridade com o Photo Mechanic: 1–5 rating, P pick, X reject.
    var defaultKey: String {
        switch self {
        case .rate0: "0"
        case .rate1: "1"
        case .rate2: "2"
        case .rate3: "3"
        case .rate4: "4"
        case .rate5: "5"
        case .pick: "p"
        case .reject: "x"
        case .unflag: "u"
        case .labelRed: "6"
        case .labelYellow: "7"
        case .labelGreen: "8"
        case .labelBlue: "9"
        case .labelPurple: "v"
        case .loupe: " "
        case .compare: "c"
        }
    }
}

@Observable
@MainActor
final class ShortcutStore {
    private let defaults: UserDefaults
    private static let storageKey = "shortcuts"
    private(set) var bindings: [CullingAction: String]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let saved = defaults.dictionary(forKey: Self.storageKey) as? [String: String] ?? [:]
        bindings = Dictionary(uniqueKeysWithValues: CullingAction.allCases.map { ($0, saved[$0.rawValue] ?? $0.defaultKey) })
    }

    func key(for action: CullingAction) -> String {
        bindings[action] ?? action.defaultKey
    }

    func action(for characters: String) -> CullingAction? {
        let key = characters.lowercased()
        return CullingAction.allCases.first { self.key(for: $0) == key }
    }

    /// Atribui uma tecla; se já estava noutra ação, as duas trocam.
    func assign(_ key: String, to action: CullingAction) {
        let key = String(key.lowercased().prefix(1))
        guard !key.isEmpty else { return }
        if let other = self.action(for: key), other != action {
            bindings[other] = self.key(for: action)
        }
        bindings[action] = key
        save()
    }

    func resetToDefaults() {
        bindings = Dictionary(uniqueKeysWithValues: CullingAction.allCases.map { ($0, $0.defaultKey) })
        save()
    }

    static func display(_ key: String) -> String {
        key == " " ? "␣" : key.uppercased()
    }

    private func save() {
        defaults.set(Dictionary(uniqueKeysWithValues: bindings.map { ($0.key.rawValue, $0.value) }), forKey: Self.storageKey)
    }
}

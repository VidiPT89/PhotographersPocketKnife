import Foundation
import CryptoKit
import SwiftData
import AppKit

/// Ficheiro `.ppk` (JSON) ao lado da foto: a classificação e a revelação sobrevivem mesmo sem o catálogo.
struct PPKSidecar: Codable, Equatable, Sendable {
    var version = 1
    var file: String
    var rating: Int
    var label: String
    var flag: Int
    var develop: EditRecipe?

    /// `DSC_4821.NEF` → `DSC_4821.NEF.ppk` (não colide com pares RAW + JPEG).
    static func url(for photo: URL) -> URL {
        photo.appendingPathExtension("ppk")
    }

    static func read(for photo: URL) -> PPKSidecar? {
        guard let data = try? Data(contentsOf: url(for: photo)) else { return nil }
        return try? JSONDecoder().decode(PPKSidecar.self, from: data)
    }

    func write(for photo: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: Self.url(for: photo), options: .atomic)
    }
}

extension ColorLabel {
    /// Nome usado em `xmp:Label` (Lightroom/Bridge).
    var xmpName: String? {
        switch self {
        case .none: nil
        case .red: "Red"
        case .yellow: "Yellow"
        case .green: "Green"
        case .blue: "Blue"
        case .purple: "Purple"
        }
    }

    init(name: String) {
        self = ColorLabel.allCases.first { "\($0)" == name.lowercased() } ?? .none
    }
}

enum FileChecksum {
    /// SHA-256 do ficheiro completo, lido em blocos de 4 MB.
    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Estrutura de pastas na importação, ex. `{year}/{date}_{event}/{type}` → `2026/2026-09-13_Estoril-Benfica/RAW`.
enum IngestTemplate {
    static let tokens = ["{year}", "{month}", "{day}", "{date}", "{event}", "{type}"]

    static func path(_ template: String, date: Date, event: String, isRaw: Bool) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        let year = String(format: "%04d", c.year ?? 0)
        let month = String(format: "%02d", c.month ?? 0)
        let day = String(format: "%02d", c.day ?? 0)
        let resolved = template
            .replacingOccurrences(of: "{date}", with: "\(year)-\(month)-\(day)")
            .replacingOccurrences(of: "{year}", with: year)
            .replacingOccurrences(of: "{month}", with: month)
            .replacingOccurrences(of: "{day}", with: day)
            .replacingOccurrences(of: "{event}", with: RenameTemplate.sanitize(event).replacingOccurrences(of: " ", with: "-"))
            .replacingOccurrences(of: "{type}", with: isRaw ? "RAW" : "JPEG")
        return resolved
            .split(separator: "/")
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " _-")) }
            .filter { !$0.isEmpty }
            .joined(separator: "/")
    }
}

/// Legendas e títulos com variáveis, resolvidos por foto (essencial para desporto e imprensa).
enum CaptionTemplate {
    static let tokens = ["{date}", "{event}", "{camera}", "{city}", "{country}", "{creator}", "{filename}", "{seq}", "{players}"]

    struct Context: Sendable {
        var date: Date?
        var event = ""
        var camera: String?
        var city = ""
        var country = ""
        var creator = ""
        var fileName = ""
        var sequence = 1
        /// Jogadores reconhecidos pelo número da camisola e pelo plantel.
        var players = ""
    }

    static func usesPlayers(_ text: String) -> Bool { text.contains("{players}") }

    /// `Ronaldo`, `Ronaldo e Pepe`, `Ronaldo, Pepe e Bruno`.
    static func joinNames(_ names: [String], and: String) -> String {
        guard names.count > 1, let last = names.last else { return names.first ?? "" }
        return names.dropLast().joined(separator: ", ") + and + last
    }

    static func resolve(_ text: String, _ context: Context) -> String {
        guard text.contains("{") else { return text }
        let values: [String: String] = [
            "{date}": context.date?.formatted(date: .long, time: .omitted) ?? "",
            "{event}": context.event,
            "{camera}": context.camera ?? "",
            "{city}": context.city,
            "{country}": context.country,
            "{creator}": context.creator,
            "{filename}": context.fileName,
            "{seq}": String(context.sequence),
            "{players}": context.players,
        ]
        var result = text
        for (token, value) in values {
            result = result.replacingOccurrences(of: token, with: value)
        }
        while result.contains("  ") {
            result = result.replacingOccurrences(of: "  ", with: " ")
        }
        return result.trimmingCharacters(in: .whitespaces)
    }
}

/// Grava os `.ppk` sozinho, como o Photo Mechanic faz com os XMP: sempre que o catálogo guarda
/// alterações a fotos (estrelas, marcação, etiqueta, revelação), por qualquer caminho da app.
@Observable
@MainActor
final class SidecarAutosave {
    private let defaults: UserDefaults
    var isEnabled: Bool { didSet { defaults.set(isEnabled, forKey: Self.key) } }
    /// Espera para juntar alterações seguidas (arrastar um cursor, percorrer fotos a classificar).
    @ObservationIgnored var delay: Duration = .milliseconds(800)

    @ObservationIgnored private var context: ModelContext?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var pending: Set<PersistentIdentifier> = []
    @ObservationIgnored private var flushTask: Task<Void, Never>?
    private static let key = "sidecars.autosave"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isEnabled = defaults.object(forKey: Self.key) as? Bool ?? true
    }

    func attach(context: ModelContext) {
        guard self.context == nil else { return }
        self.context = context
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: ModelContext.didSave, object: context, queue: .main) { [weak self] note in
            let ids = note.userInfo?[ModelContext.NotificationKey.updatedIdentifiers.rawValue] as? [PersistentIdentifier] ?? []
            MainActor.assumeIsolated { self?.schedule(ids) }
        })
        // Fechar a app logo a seguir a classificar: grava o catálogo e os .ppk antes de sair.
        observers.append(center.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.flushBeforeQuit() }
        })
    }

    private func flushBeforeQuit() {
        guard let context else { return }
        try? context.save()
        flushTask?.cancel()
        Self.write(takePending(from: context))
    }

    private func takePending(from context: ModelContext) -> [(url: URL, sidecar: PPKSidecar)] {
        let photos = pending.compactMap { context.registeredModel(for: $0) as Photo? }
        pending = []
        return CatalogService.sidecars(for: photos)
    }

    nonisolated private static func write(_ items: [(url: URL, sidecar: PPKSidecar)]) {
        for item in items {
            // Igual ao que lá está: não toca no ficheiro (a data de modificação conta para a importação).
            guard PPKSidecar.read(for: item.url) != item.sidecar,
                  FileManager.default.fileExists(atPath: item.url.path) else { continue }
            try? item.sidecar.write(for: item.url)
        }
    }

    private func schedule(_ ids: [PersistentIdentifier]) {
        guard isEnabled, !ids.isEmpty else { return }
        pending.formUnion(ids)
        flushTask?.cancel()
        flushTask = Task { [weak self, delay] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.flush()
        }
    }

    /// Escreve já o que estiver pendente (também usado pelos testes).
    func flush() async {
        guard let context else { return }
        let items = takePending(from: context)
        await Task.detached(priority: .utility) { Self.write(items) }.value
    }
}

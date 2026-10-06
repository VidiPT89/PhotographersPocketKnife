import Foundation

enum RenameTemplate {
    static let tokens = ["{date}", "{time}", "{seq}", "{event}", "{name}", "{camera}"]

    static func resolve(_ template: String, date: Date?, sequence: Int, event: String, originalName: String, camera: String?) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date ?? Date())
        let values: [String: String] = [
            "{date}": String(format: "%04d%02d%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0),
            "{time}": String(format: "%02d%02d%02d", c.hour ?? 0, c.minute ?? 0, c.second ?? 0),
            "{seq}": String(format: "%04d", sequence),
            "{event}": event,
            "{name}": originalName,
            "{camera}": camera ?? "",
        ]
        var result = template
        for (token, value) in values {
            result = result.replacingOccurrences(of: token, with: value)
        }
        result = sanitize(result)
        return result.isEmpty ? originalName : result
    }

    /// Reduz o texto a um único componente de caminho seguro. O nome do evento é escrito pelo fotógrafo
    /// e acaba em pastas locais e remotas, por isso separadores, caracteres de controlo e os nomes
    /// especiais `.` e `..` (que subiriam na hierarquia) são retirados.
    static func sanitize(_ name: String) -> String {
        let cleaned = name.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .components(separatedBy: .controlCharacters).joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.allSatisfy { $0 == "." } ? "" : cleaned
    }
}

enum BatchRenamer {
    struct Item: Sendable {
        let url: URL
        let date: Date?
        let camera: String?
    }

    struct Plan: Sendable, Equatable {
        let from: URL
        let to: URL
    }

    static func plan(_ items: [Item], template: String, event: String, start: Int = 1) -> [Plan] {
        items.enumerated().map { index, item in
            let base = RenameTemplate.resolve(
                template,
                date: item.date,
                sequence: start + index,
                event: event,
                originalName: item.url.deletingPathExtension().lastPathComponent,
                camera: item.camera
            )
            let target = item.url.deletingLastPathComponent()
                .appendingPathComponent(base)
                .appendingPathExtension(item.url.pathExtension)
            return Plan(from: item.url, to: target)
        }
    }

    /// Planos cujo destino colide com outro plano ou com um ficheiro existente que não vai ser renomeado.
    static func conflicts(_ plans: [Plan], fileExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> [Plan] {
        // O APFS por defeito não distingue maiúsculas de minúsculas.
        func key(_ url: URL) -> String { url.standardizedFileURL.path.lowercased() }
        let sources = Set(plans.map { key($0.from) })
        var seen = Set<String>()
        var result: [Plan] = []
        for plan in plans {
            let target = key(plan.to)
            if seen.contains(target) || (target != key(plan.from) && !sources.contains(target) && fileExists(plan.to)) {
                result.append(plan)
            }
            seen.insert(target)
        }
        return result
    }

    /// Renomeia em duas fases (nome temporário → nome final) para suportar cadeias A→B, B→C.
    static func apply(_ plans: [Plan]) throws {
        let fm = FileManager.default
        // Fotografias e sidecars fazem parte da mesma operação. Uma falha nunca é ignorada.
        var moves: [(from: URL, to: URL, temp: URL)] = []
        var seen: [URL: URL] = [:]
        for plan in plans where plan.from != plan.to {
            let pairs = [(plan.from, plan.to),
                         (MetadataWriter.sidecarURL(for: plan.from), MetadataWriter.sidecarURL(for: plan.to)),
                         (PPKSidecar.url(for: plan.from), PPKSidecar.url(for: plan.to))]
            for (index, pair) in pairs.enumerated() {
                guard index == 0 || fm.fileExists(atPath: pair.0.path) else { continue }
                if let target = seen[pair.0] {
                    // Um XMP partilhado por RAW+JPEG não pode seguir dois nomes diferentes.
                    guard target == pair.1 else { throw CocoaError(.fileWriteFileExists) }
                    continue
                }
                seen[pair.0] = pair.1
                moves.append((pair.0, pair.1, pair.0.deletingLastPathComponent()
                    .appendingPathComponent(".ppk-rename-\(UUID().uuidString)")))
            }
        }
        let expanded = moves.map { Plan(from: $0.from, to: $0.to) }
        guard conflicts(expanded).isEmpty else {
            throw CocoaError(.fileWriteFileExists)
        }
        var staged = 0, completed = 0
        do {
            for move in moves {
                try fm.moveItem(at: move.from, to: move.temp)
                staged += 1
            }
            for move in moves {
                try fm.moveItem(at: move.temp, to: move.to)
                completed += 1
            }
        } catch {
            // Primeiro desfazer os destinos finais para libertar ciclos A→B, B→A.
            var recoveryErrors: [String] = []
            for move in moves.prefix(completed).reversed() {
                do { try fm.moveItem(at: move.to, to: move.temp) }
                catch { recoveryErrors.append("\(move.to.path): \(error.localizedDescription)") }
            }
            for move in moves.prefix(staged).reversed() {
                guard fm.fileExists(atPath: move.temp.path) else { continue }
                do { try fm.moveItem(at: move.temp, to: move.from) }
                catch { recoveryErrors.append("\(move.temp.path): \(error.localizedDescription)") }
            }
            if !recoveryErrors.isEmpty {
                throw NSError(domain: "PhotographersPocketKnife.BatchRenamer", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: error.localizedDescription + "\n" + recoveryErrors.joined(separator: "\n"),
                    NSUnderlyingErrorKey: error,
                ])
            }
            throw error
        }
    }
}

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
        // Os sidecars acompanham a foto: sem eles, a classificação (.ppk) e o XMP ficariam no nome antigo.
        let sidecarKinds: [(url: (URL) -> URL, suffix: String)] = [
            ({ MetadataWriter.sidecarURL(for: $0) }, "xmp"),
            ({ PPKSidecar.url(for: $0) }, "ppk"),
        ]
        var staged: [(temp: URL, sidecarTemps: [URL?], plan: Plan)] = []
        for plan in plans where plan.from != plan.to {
            let dir = plan.from.deletingLastPathComponent()
            let temp = dir.appendingPathComponent(".ppk-rename-\(UUID().uuidString)")
            try fm.moveItem(at: plan.from, to: temp)
            // Cada sidecar também passa por um nome temporário, senão entra na cadeia de outro plano.
            let sidecarTemps = sidecarKinds.map { kind -> URL? in
                let sidecar = kind.url(plan.from)
                guard fm.fileExists(atPath: sidecar.path) else { return nil }
                let candidate = dir.appendingPathComponent(".ppk-rename-\(UUID().uuidString).\(kind.suffix)")
                return (try? fm.moveItem(at: sidecar, to: candidate)) != nil ? candidate : nil
            }
            staged.append((temp, sidecarTemps, plan))
        }
        for (temp, sidecarTemps, plan) in staged {
            try fm.moveItem(at: temp, to: plan.to)
            for (kind, sidecarTemp) in zip(sidecarKinds, sidecarTemps) {
                guard let sidecarTemp else { continue }
                try? fm.moveItem(at: sidecarTemp, to: kind.url(plan.to))
            }
        }
    }
}

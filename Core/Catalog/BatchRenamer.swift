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

    static func sanitize(_ name: String) -> String {
        name.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
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
        var staged: [(temp: URL, sidecarTemp: URL?, plan: Plan)] = []
        for plan in plans where plan.from != plan.to {
            let dir = plan.from.deletingLastPathComponent()
            let temp = dir.appendingPathComponent(".ppk-rename-\(UUID().uuidString)")
            try fm.moveItem(at: plan.from, to: temp)
            // O sidecar .xmp também passa por um nome temporário, senão entra na cadeia de outro plano.
            var sidecarTemp: URL?
            let sidecar = MetadataWriter.sidecarURL(for: plan.from)
            if fm.fileExists(atPath: sidecar.path) {
                let candidate = dir.appendingPathComponent(".ppk-rename-\(UUID().uuidString).xmp")
                if (try? fm.moveItem(at: sidecar, to: candidate)) != nil { sidecarTemp = candidate }
            }
            staged.append((temp, sidecarTemp, plan))
        }
        for (temp, sidecarTemp, plan) in staged {
            try fm.moveItem(at: temp, to: plan.to)
            if let sidecarTemp {
                try? fm.moveItem(at: sidecarTemp, to: MetadataWriter.sidecarURL(for: plan.to))
            }
        }
    }
}

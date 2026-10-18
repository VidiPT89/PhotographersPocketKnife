import Foundation

/// iOS may move the application container during an update or restore.
/// Keep persisted jobs usable without assuming its previous absolute prefix.
enum LocalFileLocation {
    static func restored(_ url: URL) -> URL {
        #if os(iOS)
        guard !FileManager.default.fileExists(atPath: url.path) else { return url }
        for (marker, directory) in [("/Documents/", FileManager.SearchPathDirectory.documentDirectory),
                                     ("/Library/Application Support/", .applicationSupportDirectory)] {
            guard let range = url.path.range(of: marker) else { continue }
            let base = FileManager.default.urls(for: directory, in: .userDomainMask)[0]
            let candidate = base.appendingPathComponent(String(url.path[range.upperBound...]))
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        #endif
        return url
    }
}

import Foundation
import SQLite3

/// Onde vive o catálogo. Sem sandbox, a configuração por defeito do SwiftData grava em
/// `Application Support/default.store`, um nome que qualquer outra app SwiftData sem sandbox também usa.
enum CatalogStore {
    private static var applicationSupport: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }

    /// Outro processo (ou o SwiftData a fechar) pode estar a meio de um checkpoint: espera em vez de desistir.
    private static let busyTimeout: Int32 = 3000

    static var url: URL { applicationSupport.appendingPathComponent("PhotographersPocketKnife/Catalog.store") }
    static var legacyURL: URL { applicationSupport.appendingPathComponent("default.store") }

    /// O catálogo a abrir: o da pasta da app, trazendo o antigo na primeira vez. Se a cópia falhar,
    /// fica o antigo nesta sessão — abrir um catálogo vazio no sítio novo esconderia as fotos para sempre.
    static func prepare() -> URL {
        do {
            try migrateLegacy(from: legacyURL, to: url)
            return FileManager.default.fileExists(atPath: url.path) || !isCatalog(legacyURL) ? url : legacyURL
        } catch {
            return legacyURL
        }
    }

    /// Copia o catálogo antigo uma única vez, só se for mesmo desta app. O original fica intacto.
    /// `VACUUM INTO` dá uma cópia consistente num só ficheiro, com o que ainda estava no WAL.
    @discardableResult
    static func migrateLegacy(from legacy: URL, to target: URL) throws -> Bool {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: target.path), isCatalog(legacy) else { return false }
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let partial = target.appendingPathExtension("partial")
        try? fm.removeItem(at: partial)
        var db: OpaquePointer?
        defer { sqlite3_close(db) }
        guard sqlite3_open_v2(legacy.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { throw CocoaError(.fileReadUnknown) }
        sqlite3_busy_timeout(db, busyTimeout)
        let escaped = partial.path.replacingOccurrences(of: "'", with: "''")
        guard sqlite3_exec(db, "VACUUM INTO '\(escaped)'", nil, nil, nil) == SQLITE_OK else {
            try? fm.removeItem(at: partial)
            throw CocoaError(.fileWriteUnknown)
        }
        try fm.moveItem(at: partial, to: target)
        return true
    }

    /// Um ficheiro SQLite com as tabelas das fotos e dos destinos desta app.
    static func isCatalog(_ url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        var db: OpaquePointer?
        defer { sqlite3_close(db) }
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return false }
        sqlite3_busy_timeout(db, busyTimeout)
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let query = "SELECT count(*) FROM sqlite_master WHERE type = 'table' AND name IN ('ZPHOTO', 'ZUPLOADDESTINATION')"
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK, sqlite3_step(statement) == SQLITE_ROW else { return false }
        return sqlite3_column_int(statement, 0) == 2
    }
}

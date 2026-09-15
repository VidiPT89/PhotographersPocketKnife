import Foundation

extension TransferProtocol {
    var symbol: String {
        switch self {
        case .ftp: "server.rack"
        case .ftps: "lock.rectangle.stack"
        case .sftp: "lock.shield"
        case .webdav: "globe"
        case .s3: "cloud"
        }
    }
}

extension UploadDestination {
    func endpoint(password: String? = nil) -> TransferEndpoint {
        TransferEndpoint(
            transferProtocol: transferProtocol,
            host: host,
            port: port,
            username: username,
            password: password ?? Keychain.password(account: id.uuidString) ?? "",
            bucket: bucket,
            region: region,
            trustUnknownHostKey: trustUnknownHostKey
        )
    }

    /// Resumo curto para listas: `utilizador@servidor:porta` ou `bucket · endpoint`.
    var addressLabel: String {
        DestinationAddress.label(transferProtocol: transferProtocol, host: host, port: port, username: username, bucket: bucket)
    }

    var testStatus: DestinationTestStatus {
        guard let lastTestedAt else { return .untested }
        return lastTestError == nil ? .ok(lastTestedAt) : .failed(lastTestedAt, lastTestError ?? "")
    }
}

enum DestinationTestStatus: Equatable {
    case untested
    case ok(Date)
    case failed(Date, String)
}

/// Dados de ligação lidos de um endereço colado, ex. `sftp://ana@fotos.pt:2222/entregas`.
struct ParsedDestination: Equatable {
    var transferProtocol: TransferProtocol
    var host: String
    var port: Int
    var username: String
    var password: String?
    var folder: String?
}

enum DestinationAddress {
    static func label(transferProtocol: TransferProtocol, host: String, port: Int, username: String, bucket: String) -> String {
        let server = host.isEmpty ? "—" : host
        switch transferProtocol {
        case .s3:
            return bucket.isEmpty ? server : "\(bucket) · \(server)"
        case .webdav where host.contains("://"):
            return server
        default:
            let user = username.isEmpty ? "" : "\(username)@"
            return port == transferProtocol.defaultPort ? "\(user)\(server)" : "\(user)\(server):\(port)"
        }
    }

    static func parse(_ text: String) -> ParsedDestination? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              let host = components.host, !host.isEmpty else { return nil }
        let transferProtocol: TransferProtocol
        switch scheme {
        case "ftp": transferProtocol = .ftp
        case "ftps", "ftpes": transferProtocol = .ftps
        case "sftp", "ssh", "scp": transferProtocol = .sftp
        case "http", "https", "dav", "davs", "webdav": transferProtocol = .webdav
        default: return nil
        }
        let folder = components.path.isEmpty || components.path == "/" ? nil : components.path
        var result = ParsedDestination(
            transferProtocol: transferProtocol,
            host: host,
            port: components.port ?? transferProtocol.defaultPort,
            username: components.user ?? "",
            password: components.password,
            folder: folder
        )
        if transferProtocol == .webdav {
            // O WebDAV guarda o esquema no servidor, para funcionar também em http:// local.
            let secure = scheme != "http" && scheme != "dav"
            result.port = components.port ?? (secure ? 443 : 80)
            let defaultPort = secure ? 443 : 80
            result.host = (secure ? "https://" : "http://") + host + (result.port == defaultPort ? "" : ":\(result.port)")
        }
        return result
    }
}

/// Problemas de configuração mostrados no editor; devolve chaves de tradução com o argumento opcional.
enum DestinationValidation {
    struct Issue: Equatable {
        let key: String
        var argument: String?
    }

    static func issues(transferProtocol: TransferProtocol, host: String, port: Int, username: String, bucket: String, template: String) -> [Issue] {
        var result: [Issue] = []
        let server = host.trimmingCharacters(in: .whitespaces)
        if server.isEmpty {
            result.append(Issue(key: "destination.issue.host"))
        } else if server.contains(" ") || (server.contains("://") && ![.webdav, .s3].contains(transferProtocol)) {
            result.append(Issue(key: "destination.issue.address"))
        }
        if !(1...65535).contains(port) {
            result.append(Issue(key: "destination.issue.port"))
        }
        if username.trimmingCharacters(in: .whitespaces).isEmpty, transferProtocol != .webdav {
            result.append(Issue(key: "destination.issue.user"))
        }
        if transferProtocol == .s3, bucket.trimmingCharacters(in: .whitespaces).isEmpty {
            result.append(Issue(key: "destination.issue.bucket"))
        }
        let unknown = unknownTokens(in: template)
        if !unknown.isEmpty {
            result.append(Issue(key: "destination.issue.token", argument: unknown.joined(separator: " ")))
        }
        return result
    }

    static func unknownTokens(in template: String) -> [String] {
        var tokens: [String] = []
        var rest = template[...]
        while let open = rest.firstIndex(of: "{"), let close = rest[open...].firstIndex(of: "}") {
            let token = String(rest[open...close])
            if !RemotePath.tokens.contains(token), !tokens.contains(token) { tokens.append(token) }
            rest = rest[rest.index(after: close)...]
        }
        return tokens
    }
}

/// Totais de envio por destino, a partir do histórico.
struct DestinationStats: Equatable {
    var uploaded = 0
    var failed = 0
    var bytes: Int64 = 0
    var lastUpload: Date?

    struct Entry {
        var destinationID: UUID?
        var destinationName: String
        var success: Bool
        var bytes: Int64
        var date: Date
    }

    /// Registos antigos não têm o id do destino e são associados pelo nome.
    static func compute(_ entries: [Entry], id: UUID, name: String) -> DestinationStats {
        var stats = DestinationStats()
        for entry in entries where entry.destinationID == id || (entry.destinationID == nil && entry.destinationName == name) {
            if entry.success {
                stats.uploaded += 1
                stats.bytes += entry.bytes
                stats.lastUpload = max(stats.lastUpload ?? entry.date, entry.date)
            } else {
                stats.failed += 1
            }
        }
        return stats
    }
}

/// Destino predefinido: pré-escolhido nas folhas de envio, exportação e galeria.
enum DestinationDefaults {
    static let key = "upload.defaultDestination"

    static var storedID: UUID? {
        get { UserDefaults.standard.string(forKey: key).flatMap(UUID.init(uuidString:)) }
        set { UserDefaults.standard.set(newValue?.uuidString, forKey: key) }
    }

    static func preferredID(among ids: [UUID], stored: UUID? = storedID) -> UUID? {
        if let stored, ids.contains(stored) { return stored }
        return ids.first
    }

    static func copyName(_ name: String, suffix: String, existing: [String]) -> String {
        let base = "\(name) (\(suffix))"
        guard existing.contains(base) else { return base }
        var index = 2
        while existing.contains("\(base) \(index)") { index += 1 }
        return "\(base) \(index)"
    }
}

enum UploadHistoryFilter {
    enum Status: String, CaseIterable, Identifiable {
        case all, ok, failed
        var id: String { rawValue }
        var labelKey: String { "history.filter.\(rawValue)" }
    }

    static func matches(fileName: String, remotePath: String, destinationName: String, success: Bool,
                        query: String, destination: String?, status: Status) -> Bool {
        if let destination, destinationName != destination { return false }
        switch status {
        case .all: break
        case .ok: if !success { return false }
        case .failed: if success { return false }
        }
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return true }
        return fileName.localizedCaseInsensitiveContains(needle) || remotePath.localizedCaseInsensitiveContains(needle)
    }
}

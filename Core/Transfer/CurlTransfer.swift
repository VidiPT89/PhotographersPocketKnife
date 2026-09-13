import Foundation

struct TransferEndpoint: Sendable {
    var transferProtocol: TransferProtocol
    var host: String
    var port: Int
    var username: String
    var password: String
    var bucket: String
    var region: String
    var trustUnknownHostKey: Bool
}

enum RemotePath {
    static let tokens = ["{date}", "{year}", "{month}", "{day}", "{event}"]

    static func folder(template: String, date: Date, event: String) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        let year = String(format: "%04d", c.year ?? 0)
        let month = String(format: "%02d", c.month ?? 0)
        let day = String(format: "%02d", c.day ?? 0)
        let cleanEvent = RenameTemplate.sanitize(event)
        var result = template
            .replacingOccurrences(of: "{date}", with: "\(year)-\(month)-\(day)")
            .replacingOccurrences(of: "{year}", with: year)
            .replacingOccurrences(of: "{month}", with: month)
            .replacingOccurrences(of: "{day}", with: day)
            .replacingOccurrences(of: "{event}", with: cleanEvent)
        // Remove segmentos vazios (ex. evento em branco).
        result = result.split(separator: "/").map(String.init).filter { !$0.isEmpty }.joined(separator: "/")
        return "/" + result
    }

    static func join(_ folder: String, _ fileName: String) -> String {
        let trimmed = folder.hasSuffix("/") ? String(folder.dropLast()) : folder
        return (trimmed.hasPrefix("/") ? trimmed : "/" + trimmed) + "/" + fileName
    }
}

enum TransferError: LocalizedError, Equatable {
    case curl(code: Int32, message: String)
    case cancelled
    case missingDestination

    var errorDescription: String? {
        switch self {
        case .curl(let code, let message): message.isEmpty ? "curl error \(code)" : message
        case .cancelled: "Cancelled"
        case .missingDestination: "Destination not found"
        }
    }

    /// Erros de rede/timeout que valem a pena repetir (não inclui login recusado).
    var isRetryable: Bool {
        guard case .curl(let code, _) = self else { return false }
        return [5, 6, 7, 18, 23, 28, 35, 52, 55, 56, 79].contains(code)
    }
}

/// Construção de comandos para o `curl` do sistema, que suporta FTP, FTPS, SFTP e assinatura S3.
enum CurlCommand {
    static func url(_ endpoint: TransferEndpoint, remotePath: String) -> String {
        let encodedPath = remotePath
            .split(separator: "/", omittingEmptySubsequences: false)
            .map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? String($0) }
            .joined(separator: "/")
        let path = encodedPath.hasPrefix("/") ? encodedPath : "/" + encodedPath
        switch endpoint.transferProtocol {
        case .ftp, .ftps: return "ftp://\(endpoint.host):\(endpoint.port)\(path)"
        case .sftp: return "sftp://\(endpoint.host):\(endpoint.port)\(path)"
        case .s3: return "https://\(endpoint.host):\(endpoint.port)/\(endpoint.bucket)\(path)"
        }
    }

    static func uploadArguments(_ endpoint: TransferEndpoint, file: URL, remotePath: String, resume: Bool) -> [String] {
        var args = commonArguments(endpoint)
        args += ["--progress-bar", "-T", file.path]
        switch endpoint.transferProtocol {
        case .ftp, .ftps, .sftp:
            args.append("--ftp-create-dirs")
            if resume { args += ["-C", "-"] }
        case .s3:
            break
        }
        args.append(url(endpoint, remotePath: remotePath))
        return args
    }

    static func testArguments(_ endpoint: TransferEndpoint) -> [String] {
        var args = commonArguments(endpoint) + ["--silent"]
        switch endpoint.transferProtocol {
        case .ftp, .ftps:
            args += ["--list-only", url(endpoint, remotePath: "/")]
        case .sftp:
            args += ["--list-only", "sftp://\(endpoint.host):\(endpoint.port)/~/"]
        case .s3:
            args += ["-I", url(endpoint, remotePath: "/")]
        }
        return args
    }

    /// Credenciais via stdin (`--config -`) para não aparecerem na lista de processos.
    static func config(_ endpoint: TransferEndpoint) -> String {
        func escape(_ s: String) -> String {
            s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        }
        return "user = \"\(escape(endpoint.username)):\(escape(endpoint.password))\"\n"
    }

    static func parseProgress(_ output: String) -> Double? {
        guard let match = output.matches(of: /([0-9]{1,3}(?:[.,][0-9])?)%/).last,
              let value = Double(match.1.replacingOccurrences(of: ",", with: ".")) else { return nil }
        return min(max(value / 100, 0), 1)
    }

    private static func commonArguments(_ endpoint: TransferEndpoint) -> [String] {
        var args = ["--show-error", "--fail", "--connect-timeout", "20", "--config", "-"]
        switch endpoint.transferProtocol {
        case .ftps: args.append("--ssl-reqd")
        case .sftp: if endpoint.trustUnknownHostKey { args.append("--insecure") }
        case .s3: args += ["--aws-sigv4", "aws:amz:\(endpoint.region):s3"]
        case .ftp: break
        }
        return args
    }
}

/// Um processo `curl` com progresso e cancelamento.
final class CurlProcess: @unchecked Sendable {
    private let process = Process()
    private let lock = NSLock()
    private var cancelled = false

    func run(arguments: [String], config: String, onProgress: @escaping @Sendable (Double) -> Void = { _ in }) async throws {
        process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        process.arguments = arguments
        let input = Pipe(), errors = Pipe()
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errors

        let log = OutputLog()
        errors.fileHandleForReading.readabilityHandler = { handle in
            let chunk = String(decoding: handle.availableData, as: UTF8.self)
            guard !chunk.isEmpty else { return }
            log.append(chunk)
            if let progress = CurlCommand.parseProgress(chunk) { onProgress(progress) }
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            process.terminationHandler = { [self] finished in
                errors.fileHandleForReading.readabilityHandler = nil
                let wasCancelled = lock.withLock { cancelled }
                if wasCancelled {
                    continuation.resume(throwing: TransferError.cancelled)
                } else if finished.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: TransferError.curl(code: finished.terminationStatus, message: log.errorMessage))
                }
            }
            do {
                try process.run()
                input.fileHandleForWriting.write(Data(config.utf8))
                try? input.fileHandleForWriting.close()
            } catch {
                process.terminationHandler = nil
                continuation.resume(throwing: error)
            }
        }
    }

    func cancel() {
        lock.withLock { cancelled = true }
        if process.isRunning { process.terminate() }
    }
}

private final class OutputLog: @unchecked Sendable {
    private let lock = NSLock()
    private var text = ""

    func append(_ chunk: String) {
        lock.withLock { text += chunk }
    }

    /// Última linha de erro do curl, sem as barras de progresso.
    var errorMessage: String {
        lock.withLock {
            text.split(whereSeparator: { $0 == "\n" || $0 == "\r" })
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .last { $0.hasPrefix("curl:") } ?? ""
        }
    }
}

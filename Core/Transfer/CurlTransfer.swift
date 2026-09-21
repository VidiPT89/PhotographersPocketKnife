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
        let name = RenameTemplate.sanitize(fileName)
        return (trimmed.hasPrefix("/") ? trimmed : "/" + trimmed) + "/" + (name.isEmpty ? "unnamed" : name)
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
        // 255 = falha de ligação do ssh/sftp.
        return [5, 6, 7, 18, 23, 28, 35, 52, 55, 56, 79, 255].contains(code)
    }
}

/// Comando a executar para um envio ou teste de ligação, consoante o protocolo.
struct TransferCommand: Sendable {
    let executable: String
    let arguments: [String]
    let input: String
    let environment: [String: String]?

    static func upload(_ endpoint: TransferEndpoint, file: URL, remotePath: String, resume: Bool) -> TransferCommand {
        if endpoint.transferProtocol == .webdav {
            return TransferCommand(executable: "/usr/bin/curl", arguments: ["--config", "-"], input: WebDAVCommand.uploadConfig(endpoint, file: file, remotePath: remotePath), environment: nil)
        }
        if endpoint.transferProtocol == .sftp {
            return TransferCommand(
                executable: SFTPCommand.executable,
                arguments: SFTPCommand.arguments(endpoint),
                input: SFTPCommand.uploadBatch(file: file, remotePath: remotePath, resume: resume),
                environment: SFTPCommand.environment(password: endpoint.password)
            )
        }
        return TransferCommand(
            executable: "/usr/bin/curl",
            arguments: CurlCommand.uploadArguments(endpoint, file: file, remotePath: remotePath, resume: resume),
            input: CurlCommand.config(endpoint),
            environment: nil
        )
    }

    static func test(_ endpoint: TransferEndpoint) -> TransferCommand {
        if endpoint.transferProtocol == .webdav {
            return TransferCommand(executable: "/usr/bin/curl", arguments: ["--config", "-"], input: WebDAVCommand.testConfig(endpoint), environment: nil)
        }
        if endpoint.transferProtocol == .sftp {
            return TransferCommand(
                executable: SFTPCommand.executable,
                arguments: SFTPCommand.arguments(endpoint),
                input: "pwd\n",
                environment: SFTPCommand.environment(password: endpoint.password)
            )
        }
        return TransferCommand(executable: "/usr/bin/curl", arguments: CurlCommand.testArguments(endpoint), input: CurlCommand.config(endpoint), environment: nil)
    }
}

/// WebDAV com o curl do sistema. Tudo vai no ficheiro de configuração (stdin), incluindo as credenciais:
/// primeiro um MKCOL por cada pasta (ignora "já existe"), depois o PUT do ficheiro.
enum WebDAVCommand {
    static func uploadConfig(_ endpoint: TransferEndpoint, file: URL, remotePath: String) -> String {
        let credentials = CurlCommand.config(endpoint)
        var parts: [String] = []
        var folder = ""
        for component in remotePath.split(separator: "/").dropLast() {
            folder += "/" + component
            parts.append(credentials + """
            connect-timeout = 20
            silent
            request = "MKCOL"
            url = "\(CurlCommand.escape(CurlCommand.url(endpoint, remotePath: folder + "/")))"

            """)
        }
        parts.append(credentials + """
        connect-timeout = 20
        show-error
        fail
        progress-bar
        upload-file = "\(CurlCommand.escape(file.path))"
        url = "\(CurlCommand.escape(CurlCommand.url(endpoint, remotePath: remotePath)))"

        """)
        return parts.joined(separator: "next\n")
    }

    static func testConfig(_ endpoint: TransferEndpoint) -> String {
        CurlCommand.config(endpoint) + """
        connect-timeout = 20
        silent
        show-error
        fail
        request = "PROPFIND"
        header = "Depth: 0"
        output = "/dev/null"
        url = "\(CurlCommand.escape(CurlCommand.url(endpoint, remotePath: "/")))"

        """
    }
}

/// SFTP com o OpenSSH do sistema (o curl da Apple não inclui SFTP).
/// Usa as chaves e o ~/.ssh/config do utilizador; com password, entrega-a por SSH_ASKPASS (nunca nos argumentos).
enum SFTPCommand {
    static let executable = "/usr/bin/sftp"

    static func arguments(_ endpoint: TransferEndpoint) -> [String] {
        var args = [
            // BatchMode tem de vir antes de -b, que de outra forma o força a "yes" e desliga a password.
            "-o", "BatchMode=\(endpoint.password.isEmpty ? "yes" : "no")",
            "-o", "StrictHostKeyChecking=\(endpoint.trustUnknownHostKey ? "accept-new" : "yes")",
            "-o", "ConnectTimeout=20",
            "-o", "NumberOfPasswordPrompts=1",
        ]
        if !endpoint.password.isEmpty {
            args += ["-o", "PreferredAuthentications=password,keyboard-interactive"]
        }
        args += ["-P", String(endpoint.port), "-b", "-", "\(endpoint.username)@\(endpoint.host)"]
        return args
    }

    /// Cria as pastas remotas (ignorando as que já existem) e envia o ficheiro.
    static func uploadBatch(file: URL, remotePath: String, resume: Bool) -> String {
        var lines: [String] = []
        var current = remotePath.hasPrefix("/") ? "" : "."
        for component in remotePath.split(separator: "/").dropLast() {
            current += "/" + component
            lines.append("-mkdir \(quote(current))")
        }
        lines.append("\(resume ? "reput" : "put") \(quote(file.path)) \(quote(remotePath))")
        return lines.joined(separator: "\n") + "\n"
    }

    /// O batch do sftp é um comando por linha e não há forma de escapar uma mudança de linha dentro de um
    /// caminho, por isso os caracteres de controlo são retirados: um nome com `\n` acrescentaria comandos.
    static func quote(_ value: String) -> String {
        let safe = value.components(separatedBy: .controlCharacters).joined()
        return "\"" + safe.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    static func environment(password: String) -> [String: String]? {
        guard !password.isEmpty, let askpass = askpassScript() else { return nil }
        return ["SSH_ASKPASS": askpass.path, "SSH_ASKPASS_REQUIRE": "force", "PPK_SSH_PASSWORD": password, "DISPLAY": ":0"]
    }

    private static func askpassScript() -> URL? {
        let fm = FileManager.default
        let dir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PhotographersPocketKnife", isDirectory: true)
        let url = dir.appendingPathComponent("askpass.sh")
        if !fm.isExecutableFile(atPath: url.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            guard (try? Data("#!/bin/sh\nprintf '%s\\n' \"$PPK_SSH_PASSWORD\"\n".utf8).write(to: url)) != nil else { return nil }
            try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        }
        return url
    }
}

/// Construção de comandos para o `curl` do sistema: FTP, FTPS, WebDAV e S3 (o SFTP passa pelo `SFTPCommand`).
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
        case .webdav:
            if endpoint.host.hasPrefix("http://") || endpoint.host.hasPrefix("https://") {
                let base = endpoint.host.hasSuffix("/") ? String(endpoint.host.dropLast()) : endpoint.host
                return base + path
            }
            return "https://\(endpoint.host):\(endpoint.port)\(path)"
        case .s3:
            // Endpoints com esquema explícito (ex. MinIO local em http://) são usados tal como estão.
            if endpoint.host.hasPrefix("http://") || endpoint.host.hasPrefix("https://") {
                let base = endpoint.host.hasSuffix("/") ? String(endpoint.host.dropLast()) : endpoint.host
                return "\(base)/\(endpoint.bucket)\(path)"
            }
            return "https://\(endpoint.host):\(endpoint.port)/\(endpoint.bucket)\(path)"
        }
    }

    static func uploadArguments(_ endpoint: TransferEndpoint, file: URL, remotePath: String, resume: Bool) -> [String] {
        var args = commonArguments(endpoint)
        args += ["--progress-bar", "-T", file.path]
        switch endpoint.transferProtocol {
        case .ftp, .ftps:
            args.append("--ftp-create-dirs")
            if resume { args += ["-C", "-"] }
        case .s3, .webdav, .sftp:
            break
        }
        args.append(url(endpoint, remotePath: remotePath))
        return args
    }

    static func testArguments(_ endpoint: TransferEndpoint) -> [String] {
        var args = commonArguments(endpoint) + ["--silent"]
        switch endpoint.transferProtocol {
        case .ftp, .ftps, .sftp:
            args += ["--list-only", url(endpoint, remotePath: "/")]
        case .s3:
            args += ["-I", url(endpoint, remotePath: "/")]
        case .webdav:
            args += ["-X", "PROPFIND", "-H", "Depth: 0", url(endpoint, remotePath: "/")]
        }
        return args
    }

    /// O ficheiro de configuração do curl é uma diretiva por linha. As mudanças de linha vão escapadas
    /// (o curl aceita `\n`, `\r` e `\t` dentro de aspas) para uma password ou um caminho não acrescentarem diretivas.
    static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\t", with: "\\t")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n")
    }

    /// Credenciais via stdin (`--config -`) para não aparecerem na lista de processos.
    static func config(_ endpoint: TransferEndpoint) -> String {
        "user = \"\(escape(endpoint.username)):\(escape(endpoint.password))\"\n"
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
        case .s3: args += ["--aws-sigv4", "aws:amz:\(endpoint.region):s3"]
        case .ftp, .webdav, .sftp: break
        }
        return args
    }
}

/// Um processo `curl` com progresso e cancelamento.
final class CurlProcess: @unchecked Sendable {
    private let process = Process()
    private let lock = NSLock()
    private var cancelled = false
    private let executable: String
    private let environment: [String: String]?

    init(executable: String = "/usr/bin/curl", environment: [String: String]? = nil) {
        self.executable = executable
        self.environment = environment
    }

    /// `config` é escrito no stdin (configuração do curl ou comandos batch do sftp).
    func run(arguments: [String], config: String, onProgress: @escaping @Sendable (Double) -> Void = { _ in }) async throws {
        // Pausar mal o envio arranca podia chamar `cancel()` antes de haver processo para terminar,
        // e o ficheiro seguia à mesma para o servidor só para depois voltar à fila.
        guard !lock.withLock({ cancelled }) else { throw TransferError.cancelled }
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment {
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }
        }
        let input = Pipe(), errors = Pipe()
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errors

        let log = OutputLog()
        // A barra de progresso do curl escreve muitas vezes por segundo; sem este travão, cada pedaço
        // acordaria o MainActor para uma alteração invisível.
        let throttle = ProgressThrottle()
        errors.fileHandleForReading.readabilityHandler = { handle in
            let chunk = String(decoding: handle.availableData, as: UTF8.self)
            guard !chunk.isEmpty else { return }
            log.append(chunk)
            if let progress = CurlCommand.parseProgress(chunk), throttle.allows(progress) { onProgress(progress) }
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

/// Deixa passar uma leitura de progresso no máximo a cada 100 ms, e sempre a que chega ao fim.
private final class ProgressThrottle: @unchecked Sendable {
    private let lock = NSLock()
    private var lastSent: Date?

    func allows(_ progress: Double, now: Date = Date()) -> Bool {
        lock.withLock {
            guard progress < 1 else { return true }
            if let lastSent, now.timeIntervalSince(lastSent) < 0.1 { return false }
            lastSent = now
            return true
        }
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
            let lines = text.split(whereSeparator: { $0 == "\n" || $0 == "\r" })
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && !$0.contains("#") && !$0.hasSuffix("%") }
            return lines.last { $0.hasPrefix("curl:") } ?? lines.last ?? ""
        }
    }
}

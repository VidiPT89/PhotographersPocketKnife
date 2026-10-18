import Foundation
@preconcurrency import Citadel
@preconcurrency import Crypto
@preconcurrency import NIOCore
@preconcurrency import NIOSSH

/// Native transports: no subprocesses, shell commands or credentials in files.
final class CurlProcess: @unchecked Sendable {
    private let native = PPKCurl()
    private let lock = NSLock()
    private var ssh: SSHClient?
    private let caBundle: URL?
    init(caBundle: URL? = nil) { self.caBundle = caBundle }

    func cancel() {
        native.cancelled = true
        let client = lock.withLock { ssh }
        if let client { Task { try? await client.close() } }
    }

    func execute(_ command: TransferCommand, onProgress: @escaping @Sendable (Double) -> Void = { _ in }) async throws {
        let endpoint = command.endpoint
        guard !native.cancelled else { throw TransferError.cancelled }
        let throttle = ProgressThrottle()
        let report: @Sendable (Double) -> Void = { value in if throttle.allows(value) { onProgress(value) } }
        do {
            if endpoint.transferProtocol == .sftp {
                try await sftp(command, endpoint: endpoint, progress: report)
            } else {
                try await Task.detached(priority: .utility) { [self] in
                    guard let ca = caBundle?.path ?? Bundle.main.path(forResource: "cacert", ofType: "pem") else {
                        throw TransferError.curl(code: 77, message: "Certificate bundle is missing")
                    }
                    func request(path: String, file: URL?, method: String?) throws {
                        try native.performURL(CurlCommand.url(endpoint, remotePath: path), file: file?.path,
                            username: endpoint.username, password: endpoint.password, tls: endpoint.transferProtocol == .ftps,
                            signature: endpoint.transferProtocol == .s3 ? "aws:amz:\(endpoint.region):s3" : nil,
                            method: method, caBundle: ca, progress: report)
                    }
                    if endpoint.transferProtocol == .webdav, command.file != nil {
                        var folder = ""
                        for component in command.remotePath.split(separator: "/").dropLast() {
                            folder += "/" + component
                            try request(path: folder + "/", file: nil, method: "MKCOL")
                        }
                    }
                    try request(path: command.remotePath, file: command.file,
                                method: endpoint.transferProtocol == .webdav && command.file == nil ? "PROPFIND" : nil)
                }.value
            }
        } catch {
            if native.cancelled { throw TransferError.cancelled }
            if let transfer = error as? TransferError { throw transfer }
            let ns = error as NSError
            throw TransferError.curl(code: Int32(ns.code), message: ns.localizedDescription)
        }
    }

    private func sftp(_ command: TransferCommand, endpoint: TransferEndpoint, progress: @escaping @Sendable (Double) -> Void) async throws {
        let validator = MobileHostKeyValidator(host: endpoint.host, port: endpoint.port, acceptNew: endpoint.trustUnknownHostKey)
        let authentication: SSHAuthenticationMethod
        if let key = endpoint.sshPrivateKey, !key.isEmpty {
            let passphrase = endpoint.password.isEmpty ? nil : Data(endpoint.password.utf8)
            if let ed = try? Curve25519.Signing.PrivateKey(sshEd25519: key, decryptionKey: passphrase) {
                authentication = .ed25519(username: endpoint.username, privateKey: ed)
            } else if let rsa = try? Insecure.RSA.PrivateKey(sshRsa: key, decryptionKey: passphrase) {
                authentication = .rsa(username: endpoint.username, privateKey: rsa)
            } else {
                throw TransferError.curl(code: 67, message: "Cannot read the OpenSSH key. Use an Ed25519 or RSA key and its correct passphrase.")
            }
        } else { authentication = .passwordBased(username: endpoint.username, password: endpoint.password) }
        let client = try await SSHClient.connect(host: endpoint.host, port: endpoint.port,
            authenticationMethod: authentication,
            hostKeyValidator: .custom(validator), reconnect: .never)
        lock.withLock { ssh = client }
        do {
            guard !native.cancelled else { throw TransferError.cancelled }
            let sftp = try await client.openSFTP()
            if let file = command.file {
                var folder = ""
                for component in command.remotePath.split(separator: "/").dropLast() {
                    folder += "/" + component
                    do { try await sftp.createDirectory(atPath: folder) }
                    catch { _ = try await sftp.getAttributes(at: folder) }
                }
                // Retry starts from byte zero, so a replaced local file cannot leave a corrupt remote tail.
                let remote = try await sftp.openFile(filePath: command.remotePath, flags: [.write, .create, .truncate])
                let handle = try FileHandle(forReadingFrom: file)
                defer { try? handle.close() }
                let size = max(Int64((try file.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0), 1)
                var offset: UInt64 = 0
                while let data = try handle.read(upToCount: 256 * 1024), !data.isEmpty {
                    guard !native.cancelled else { throw TransferError.cancelled }
                    try await remote.write(ByteBuffer(bytes: data), at: offset)
                    offset += UInt64(data.count)
                    progress(Double(offset) / Double(size))
                }
                try await remote.close()
            } else { _ = try await sftp.getRealPath(atPath: ".") }
            try await sftp.close()
            try await client.close()
            lock.withLock { ssh = nil }
        } catch {
            try? await client.close()
            lock.withLock { ssh = nil }
            throw error
        }
    }
}

/// Trust-on-first-use is opt-in; a changed key is always rejected.
private final class MobileHostKeyValidator: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
    let account: String
    let acceptNew: Bool
    init(host: String, port: Int, acceptNew: Bool) {
        account = "hostkey:\(host.lowercased()):\(port)"
        self.acceptNew = acceptNew
    }
    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let key = String(openSSHPublicKey: hostKey)
        if let stored = Keychain.password(account: account) {
            if stored == key { validationCompletePromise.succeed(()) }
            else { validationCompletePromise.fail(TransferError.curl(code: 60, message: "The server host key has changed. Verify the server before reconnecting.")) }
        } else if acceptNew {
            Keychain.setPassword(key, account: account)
            if Keychain.password(account: account) == key { validationCompletePromise.succeed(()) }
            else { validationCompletePromise.fail(TransferError.curl(code: 60, message: "Cannot save the server host key.")) }
        } else {
            validationCompletePromise.fail(TransferError.curl(code: 60, message: "Unknown server host key. Enable trust on first connection for this destination after verifying the server."))
        }
    }
}

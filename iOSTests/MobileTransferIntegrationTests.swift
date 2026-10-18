import XCTest
@testable import PhotographersPocketKnife

/// Run scripts/test-ios-transfers.py and set TEST_RUNNER_PPK_MOBILE_INTEGRATION=1.
final class MobileTransferIntegrationTests: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["PPK_MOBILE_INTEGRATION"] == "1", "Local transfer fixtures are not enabled")
    }
    func testFTP() async throws { try await verify(.ftp, port: 12121) }
    func testFTPS() async throws { try await verify(.ftps, port: 12122) }
    func testWebDAV() async throws { try await verify(.webdav, port: 18088) }
    func testS3() async throws { try await verify(.s3, port: 19100) }
    func testSFTP() async throws {
        Keychain.deletePassword(account: "hostkey:127.0.0.1:12222")
        try await verify(.sftp, port: 12222)
        XCTAssertNotNil(Keychain.password(account: "hostkey:127.0.0.1:12222"))
    }
    func testFTPSRejectsUntrustedCertificate() async throws {
        let endpoint = endpoint(.ftps, port: 12122)
        do { try await CurlProcess().execute(.test(endpoint)); XCTFail("Untrusted certificate was accepted") }
        catch { XCTAssertNotEqual(error as? TransferError, .cancelled) }
    }
    func testSFTPRejectsChangedHostKey() async throws {
        let account = "hostkey:127.0.0.1:12222"
        let original = Keychain.password(account: account)
        Keychain.setPassword("different-key", account: account)
        defer { Keychain.setPassword(original ?? "", account: account) }
        do { try await CurlProcess().execute(.test(endpoint(.sftp, port: 12222))); XCTFail("Changed host key accepted") }
        catch { XCTAssertTrue(error.localizedDescription.contains("key")) }
    }
    func testWebDAVRejectsWrongPassword() async throws {
        var endpoint = endpoint(.webdav, port: 18088); endpoint.password = "wrong"
        do { try await CurlProcess().execute(.test(endpoint)); XCTFail("Wrong password accepted") }
        catch { XCTAssertNotEqual(error as? TransferError, .cancelled) }
    }
    private func endpoint(_ kind: TransferProtocol, port: Int) -> TransferEndpoint {
        TransferEndpoint(transferProtocol: kind, host: [.webdav, .s3].contains(kind) ? "http://127.0.0.1:\(port)" : "127.0.0.1", port: port, username: "ppk", password: "ppk-test", bucket: "ppk-bucket", region: "us-east-1", trustUnknownHostKey: true)
    }
    private func verify(_ kind: TransferProtocol, port: Int) async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("fotografia espaço.jpg")
        let data = Data((0..<131_072).map { UInt8($0 % 251) })
        try data.write(to: file)
        let cert = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:18088/ca.pem")!).0
        let ca = folder.appendingPathComponent("ca.pem"); try cert.write(to: ca)
        let remote = "/shoot-\(UUID().uuidString)/fotografia espaço.jpg"
        let process = CurlProcess(caBundle: kind == .ftps ? ca : nil)
        try await process.execute(.upload(endpoint(kind, port: port), file: file, remotePath: remote, resume: false))
        var components = URLComponents(string: "http://127.0.0.1:18088/verify")!
        components.queryItems = [.init(name: "kind", value: kind.rawValue), .init(name: "path", value: remote)]
        let (received, response) = try await URLSession.shared.data(from: XCTUnwrap(components.url))
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(received, data, "Remote bytes differ from the uploaded file")
    }
}

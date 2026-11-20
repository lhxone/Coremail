import Security
import XCTest
@testable import NativeMail

final class CryptoAndServicesTests: XCTestCase {
    func testEncryptedMIMEWithAttachmentInteroperatesWithOpenSSL() throws {
        try withTemporaryDirectory { directory in
            try runOpenSSL([
                "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1",
                "-subj", "/CN=Test Recipient/emailAddress=recipient@example.com",
                "-addext", "extendedKeyUsage=emailProtection",
                "-keyout", "key.pem", "-out", "certificate.pem"
            ], in: directory)
            try runOpenSSL(["x509", "-in", "certificate.pem", "-outform", "DER", "-out", "certificate.der"], in: directory)
            let certificate = try XCTUnwrap(SecCertificateCreateWithData(nil,
                Data(contentsOf: directory.appendingPathComponent("certificate.der")) as CFData))
            let plaintext = Data("Content-Type: text/plain; charset=UTF-8\r\n\r\n邮件正文和二进制附件都要保密。".utf8)
                + Data(repeating: 0xAD, count: 150_000)
            let ciphertext = try SMIME.envelope(plaintext, certificates: [certificate])
            XCTAssertNil(ciphertext.range(of: Data("邮件正文".utf8)))
            XCTAssertNotNil(ciphertext.range(of: Data([0x06, 0x09, 0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x01, 0x2A])))
            try ciphertext.write(to: directory.appendingPathComponent("message.der"))
            try runOpenSSL([
                "cms", "-decrypt", "-binary", "-inform", "DER", "-in", "message.der",
                "-recip", "certificate.pem", "-inkey", "key.pem", "-out", "clear.mime"
            ], in: directory)
            XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("clear.mime")), plaintext)
        }
    }

    func testCalDAVMultistatusAndEventRoundTrip() throws {
        let sample = """
            <D:multistatus xmlns:D="DAV:" xmlns:C="urn:ietf:params:xml:ns:caldav">
            <D:response><D:href>/calendar/me/</D:href><D:propstat>
            <D:prop><C:calendar-home-set><D:href>/calendar/me/</D:href></C:calendar-home-set></D:prop>
            <D:status>HTTP/1.1 200 OK</D:status>
            </D:propstat></D:response></D:multistatus>
            """
        let document = try DAVElement.read(Data(sample.utf8))
        XCTAssertEqual(document.child("response", "DAV:")?.child("href", "DAV:")?.text, "/calendar/me/")
        let first = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-17T01:30:00Z"))
        let calendar = ServerCalendar(url: URL(string: "https://example.com/calendar/me/")!, name: "企业日历", canCreate: true)
        let title = String(repeating: "会议\n计划；讨论,测试\\", count: 12)
        let event = CalendarFile.event(uid: "test", title: title, location: "会议室", start: first, end: first + 3600)
        let raw = String(decoding: event, as: UTF8.self)
        XCTAssertTrue(raw.components(separatedBy: "\r\n").allSatisfy { $0.utf8.count <= 75 })
        let saved = CalendarFile.events(raw, calendar: calendar, from: first - 60, to: first + 4000)
        XCTAssertEqual(saved.first?.title, title)
        XCTAssertEqual(saved.first?.start, first)
        XCTAssertEqual(saved.first?.end, first + 3600)
        XCTAssertEqual(saved.first?.location, "会议室")
    }

    private func runOpenSSL(_ args: [String], in directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        process.currentDirectoryURL = directory
        process.arguments = args
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw MailError("OpenSSL fixture failed: \(args.first ?? "")") }
    }

    private func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CoremailTest-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }
}

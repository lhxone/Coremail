import XCTest
@testable import NativeMail

final class AttachmentSecurityTests: XCTestCase {
    func testSafeNameRemovesBidiOverridesAndInvisibleCharacters() {
        let spoofed = Attachment(name: "invoice\u{202E}fdp.command", type: "application/octet-stream", data: Data())
        XCTAssertEqual(spoofed.safeName, "invoicefdp.command")
        let hidden = Attachment(name: "../re\u{200B}port\u{2067}.pdf\u{0007}\r\n", type: "application/pdf", data: Data())
        XCTAssertEqual(hidden.safeName, "report.pdf")
        XCTAssertEqual(Attachment(name: "\u{202E}\u{2066}", type: "text/plain", data: Data()).safeName, "附件")
        XCTAssertEqual(Attachment(name: "季度报告.pdf", type: "application/pdf", data: Data()).safeName, "季度报告.pdf")
    }

    func testWrittenAttachmentsAreQuarantined() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("run.command")
        try Data("#!/bin/sh\n".utf8).write(to: url)
        try Attachment.quarantine(url, sender: "sender@example.com")
        let properties = try XCTUnwrap(URL(fileURLWithPath: url.path).resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties)
        XCTAssertEqual(properties[kLSQuarantineAgentNameKey as String] as? String, "Coremail")
    }

    private func signedPart(boundary: String) -> String {
        "Content-Type: multipart/signed; protocol=\"application/pkcs7-signature\"; micalg=sha-256; boundary=\"\(boundary)\"\r\n\r\n"
            + "--\(boundary)\r\nContent-Type: text/plain\r\n\r\nSigned text\r\n"
            + "--\(boundary)\r\nContent-Type: application/pkcs7-signature\r\nContent-Transfer-Encoding: base64\r\n\r\nMIIB\r\n"
            + "--\(boundary)--\r\n"
    }

    func testSignedPartBesideUnsignedTextDoesNotVouchForTheMessage() {
        let raw = "From: boss@example.com\r\nSubject: Pay\r\nContent-Type: multipart/mixed; boundary=\"outer\"\r\n\r\n"
            + "--outer\r\nContent-Type: text/plain\r\n\r\nAttacker text\r\n"
            + "--outer\r\n" + signedPart(boundary: "inner") + "\r\n--outer--\r\n"
        let message = MIME.message(Data(raw.utf8))
        XCTAssertEqual(message.plain, "Attacker text")
        XCTAssertNil(message.signature)
        XCTAssertNotNil(message.securityWarning)
    }

    func testTopLevelSignatureIsStillVerified() {
        let raw = "From: boss@example.com\r\nSubject: Pay\r\n" + signedPart(boundary: "inner")
        let message = MIME.message(Data(raw.utf8))
        XCTAssertEqual(message.plain, "Signed text")
        XCTAssertNotNil(message.signature)
        XCTAssertNotEqual(message.signature, "签名有效")
        XCTAssertNil(message.securityWarning)
    }

    func testEncryptedPartBesidePlainTextIsNotReportedAsEncrypted() {
        let raw = "From: boss@example.com\r\nContent-Type: multipart/mixed; boundary=\"outer\"\r\n\r\n"
            + "--outer\r\nContent-Type: text/plain\r\n\r\nVisible\r\n"
            + "--outer\r\nContent-Type: application/pkcs7-mime; smime-type=enveloped-data\r\nContent-Transfer-Encoding: base64\r\n\r\nMIIB\r\n"
            + "--outer--\r\n"
        let message = MIME.message(Data(raw.utf8))
        XCTAssertFalse(message.encrypted)
        XCTAssertNotNil(message.securityWarning)
    }
}

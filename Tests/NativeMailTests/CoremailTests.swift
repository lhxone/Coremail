import AppKit
import Security
import XCTest
@testable import NativeMail

final class CoremailTests: XCTestCase {
    @MainActor
    func testMailboxRequestsOverHTTPS() async throws {
        // Publicly reproducible fixture only. Security does not generate 512-bit keys on current macOS.
        let fixtureKey = """
        MIIBOQIBAAJBALP/k3xewsV2PQ3limc/T0nDWYAoYFSFz8M1dwgak6JRLvfIdadC7RL6KHw5QVBla2qKisIAmF8Ws4GX4eHko2MCAwEAAQJA
        QTuDcNRK1BMox0uD4C0iiAIDAp4fYyJnjEBpFgfDr1QOrY7xOqTDx2WZLOqSnLI8YEujnFzAkzVfM97fOcszqQIhAOZhCE+lO2jhPxx47+E93fZ8
        n/4pO8z5YKeSAXWZ9KlHAiEAyAQwT8+3JbrUOueOZ+UI5RhtKfv7GOUlVIQBs0WSgwUCIGodacGd3zaZAgPwZLXAVHwTvXJJteTdPTsSUp/DsWFDAi
        AYM7mMzruAizzG6+HlXGdZIT2ESQM3HfMIaPizsoVp6QIgScX5SYvAocbzSD3LdhJWawLh+lCG+g28G0ByEW4B15U=
        """
        let der = try XCTUnwrap(Data(base64Encoded: fixtureKey, options: .ignoreUnknownCharacters))
        let privateKey = try XCTUnwrap(SecKeyCreateWithData(der as CFData, [
            kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPrivate
        ] as CFDictionary, nil))
        let modulus = "B3FF937C5EC2C5763D0DE58A673F4F49C3598028605485CFC33577081A93A2512EF7C875A742ED12FA287C394150656B6A8A8AC200985F16B38197E1E1E4A363"

        var account = Account()
        account.email = "me+test@example.com"
        account.host = "mail.example.com"
        let email = account.email
        let profileName = "Example Person (示例姓名)"
        let secret = "fixture-password"
        let attachment = Attachment(name: "快照.bin", type: "application/octet-stream", data: Data([0, 1, 255]))
        var draft = Draft()
        draft.to = [.init(name: "收件人", email: "reader@example.com")]
        draft.bcc = [.init(name: "", email: "hidden@example.com")]
        draft.subject = "中文标题"
        draft.body = "测试正文"
        draft.attachments = [attachment]
        let summary: [String: Any] = ["id": "1:test+mid", "subject": draft.subject,
                                      "from": "发信人 <sender@example.com>", "to": "reader@example.com",
                                      "receivedDate": "2026-11-17 14:00:00",
                                      "flags": ["attached": true, "read": false, "flagged": true]]

        let imageBytes = try XCTUnwrap(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aX1sAAAAASUVORK5CYII="))
        var submittedImages: [Message] = []
        var emlActions: [String] = []
        var stagedEnvelope: [String: Any]?
        var visited: [String] = []
        var folderID = 1
        var submittedDraftMessageID: String?
        var acknowledgeDraft = true
        var hasNewMail = false
        var listWindows: [(start: Int, limit: Int)] = []
        CoremailFixture.respond = { request in
            let url = try XCTUnwrap(request.url)
            let query = Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
                .map { ($0.name, $0.value ?? "") })
            let function = try XCTUnwrap(query["func"])
            visited.append(function)
            XCTAssertEqual(url.scheme, "https")
            XCTAssertEqual(url.path, function == "directData" ? "/coremail/XT/jsp/upload.jsp" : "/coremail/s/json")
            if function != "user:getPasswordKey" && function != "user:login" {
                XCTAssertEqual(query["sid"], "mailbox+sid")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "Coremail=fixture")
            }
            if function != "directData" && function != "mbox:composeF" && request.httpMethod == "POST" {
                XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "text/x-json")
            }
            switch function {
            case "user:getPasswordKey":
                XCTAssertNil(query["sid"])
                return try .ok(["sid": "temporary", "key": ["type": "RSA", "e": "10001", "n": modulus]])
            case "user:login":
                XCTAssertEqual(query["sid"], "temporary")
                let body = try CoremailFixture.jsonBody(request)
                XCTAssertEqual(body["uid"] as? String, email)
                let hex = Array(try XCTUnwrap(body["password"] as? String))
                XCTAssertEqual(hex.count, 128)
                let cipher = Data(stride(from: 0, to: hex.count, by: 2).compactMap {
                    UInt8(String(hex[$0..<$0 + 2]), radix: 16)
                })
                let decrypted = try XCTUnwrap(SecKeyCreateDecryptedData(privateKey, .rsaEncryptionPKCS1, cipher as CFData, nil))
                XCTAssertEqual(String(decoding: decrypted as Data, as: UTF8.self), secret)
                return try .ok(["sid": "mailbox+sid"], headers: ["Set-Cookie": "Coremail=fixture; Secure; Path=/coremail"])
            case "mbox:getAllFolders":
                return try .ok([
                    ["id": 1, "name": "收件箱", "children": [["id": 1024, "name": "报告/项目"]]],
                    ["id": 2, "name": "草稿"],
                    ["id": 4, "name": "废件箱"],
                    ["id": 1025, "name": "收件箱"],
                    ["id": 1026, "name": "归档"]
                ])
            case "mbox:listMessages":
                let body = try CoremailFixture.jsonBody(request)
                let start = try XCTUnwrap(body["start"] as? Int)
                XCTAssertGreaterThanOrEqual(start, 0)
                XCTAssertEqual(body["order"] as? String, "receivedDate")
                XCTAssertEqual(body["desc"] as? Bool, true)
                let limit = try XCTUnwrap(body["limit"] as? Int)
                listWindows.append((start, limit))
                guard body["fid"] as? Int == folderID else { return try .ok([]) }
                // As on the real server, the id prefix is not the folder: it stays put when the message moves.
                var current = summary
                current["id"] = "1:test+mid"
                current["fid"] = folderID
                let older: [[String: Any]] = folderID == 1 ? (1...50).map { index in
                    ["id": "1:older-\(index)", "subject": "Older \(index)",
                     "receivedDate": String(format: "2025-01-01 00:00:%02d", 60 - index),
                     "flags": ["inlineAttached": true, "linkAttached": true]]
                } : []
                let arrivals: [[String: Any]] = folderID == 1 && hasNewMail
                    ? [["id": "1:new", "subject": "New mail", "receivedDate": "2026-01-01 00:00:00"]]
                    : []
                return try .ok(Array((arrivals + [current] + older).dropFirst(start).prefix(limit)))
            case "mbox:searchMessages":
                let body = try CoremailFixture.jsonBody(request)
                XCTAssertEqual(body["pattern"] as? String, "测试", "the server ignores `keyword`")
                XCTAssertNil(body["keyword"])
                XCTAssertEqual(body["start"] as? Int, 0, "the server ignores `start`; pages widen `limit` instead")
                return try .ok(["1:test+mid"])
            case "mbox:getMessageInfos":
                let ids = try CoremailFixture.jsonBody(request)["ids"] as? [String]
                if ids == ["5:draft-mid"] {
                    return try .ok([["id": "5:draft-mid", "fid": 2, "hmid": try XCTUnwrap(submittedDraftMessageID)]])
                }
                XCTAssertEqual(ids, ["1:test+mid"])
                var info = summary
                info["fid"] = folderID
                return try .ok([info])
            case "mbox:getMessageData":
                XCTAssertEqual(query["mid"], "test+mid")
                XCTAssertEqual(query["mode"], "download")
                XCTAssertEqual(request.httpMethod, "GET")
                return .init(bytes: Data("Subject: Test\r\n\r\nMessage".utf8), headers: ["Content-Type": "message/rfc822"])
            case "mbox:updateMessageInfos":
                let body = try CoremailFixture.jsonBody(request)
                XCTAssertEqual(body["ids"] as? [String], ["1:test+mid"])
                let attrs = try XCTUnwrap(body["attrs"] as? [String: Any])
                folderID = try XCTUnwrap(attrs["fid"] as? Int)
                return try .ok(NSNull())
            case "mbox:deleteMessages":
                XCTAssertEqual(try CoremailFixture.jsonBody(request)["ids"] as? [String], ["1:test+mid"])
                XCTAssertEqual(try CoremailFixture.jsonBody(request)["permanently"] as? Bool, true)
                return try .ok(NSNull())
            case "mbox:getComposeInfo":
                XCTAssertEqual(try CoremailFixture.jsonBody(request)["id"] as? String, "compose-1")
                return try .ok(["account": "\(profileName) <\(email)>"])
            case "mbox:compose":
                let body = try CoremailFixture.jsonBody(request)
                let attrs = try XCTUnwrap(body["attrs"] as? [String: Any])
                XCTAssertEqual(attrs["account"] as? String, email)
                let action = try XCTUnwrap(body["action"] as? String)
                if action == "continue" {
                    if body["id"] == nil {
                        stagedEnvelope = nil
                    } else {
                        XCTAssertEqual(body["id"] as? String, "compose-1")
                        stagedEnvelope = attrs
                    }
                    return try .ok("compose-1")
                }
                XCTAssertEqual(body["id"] as? String, "compose-1")
                XCTAssertEqual(body["returnInfo"] as? Bool, true)
                XCTAssertEqual(attrs["from"] as? String, "\"\(profileName)\" <\(email)>")
                XCTAssertEqual(attrs["charset"] as? String, "UTF-8")
                XCTAssertEqual(attrs["subject"] as? String, draft.subject)
                XCTAssertEqual(attrs["content"] as? String, draft.body)
                XCTAssertEqual(attrs["to"] as? [String], ["\"收件人\" <reader@example.com>"])
                XCTAssertEqual(attrs["bcc"] as? [String], ["hidden@example.com"])
                let descriptors = try XCTUnwrap(attrs["attachments"] as? [[String: Any]])
                XCTAssertEqual(descriptors.count, 1)
                XCTAssertEqual(descriptors.first?["id"] as? Int, 1)
                XCTAssertEqual(descriptors.first?["type"] as? String, "upload")
                XCTAssertEqual(descriptors.first?["name"] as? String, attachment.name)
                XCTAssertEqual(descriptors.first?["size"] as? Int, attachment.data.count)
                if action == "save" {
                    let headers = try XCTUnwrap(attrs["extraHeaders"] as? [String: String])
                    submittedDraftMessageID = try XCTUnwrap(headers["Message-ID"])
                    return try .json(acknowledgeDraft
                        ? ["code": "S_OK", "var": ["id": "compose-1"], "draftId": "5:draft-mid"]
                        : ["code": "S_OK", "var": ["id": "compose-1"]])
                }
                XCTAssertEqual(action, "deliver")
                return try .json(["code": "S_OK", "var": [:], "savedSent": "3:sent-mid"])
            case "mbox:composeF":
                XCTAssertEqual(query["composeId"], "compose-1")
                // The real server uses the compose session as its delivery envelope.
                // EML To/Cc/Bcc alone do not prevent FA_NO_RECEIPT.
                guard let envelope = stagedEnvelope,
                      let to = envelope["to"] as? [String], !to.isEmpty else {
                    return try .json(["code": "FA_NO_RECEIPT"])
                }
                XCTAssertEqual(to, ["\"收件人\" <reader@example.com>"])
                XCTAssertEqual(envelope["bcc"] as? [String], ["hidden@example.com"])
                XCTAssertEqual(envelope["cc"] as? [String], ["\"抄送\" <copy@example.com>"])
                XCTAssertEqual(envelope["subject"] as? String, draft.subject)
                let type = try XCTUnwrap(request.value(forHTTPHeaderField: "Content-Type"))
                let boundary = try XCTUnwrap(type.components(separatedBy: "boundary=").last)
                let body = try CoremailFixture.body(request)
                let start = try XCTUnwrap(body.range(of: Data("Content-Type: message/rfc822\r\n\r\n".utf8)))
                let end = try XCTUnwrap(body.range(of: Data("\r\n--\(boundary)--".utf8), in: start.upperBound..<body.endIndex))
                let eml = body.subdata(in: start.upperBound..<end.lowerBound)
                let message = MIME.message(eml)
                submittedImages.append(message)
                XCTAssertEqual(message.inlineImages.count, 1)
                XCTAssertEqual(message.inlineImages.first?.bytes, imageBytes)
                XCTAssertEqual(message.attachments.map(\.data), [attachment.data])
                XCTAssertEqual(message.bcc.map(\.email), ["hidden@example.com"])
                let resolved = MailHTML(html: try XCTUnwrap(message.html), images: message.inlineImages)
                XCTAssertFalse(resolved.content.contains("cid:"))
                XCTAssertEqual(resolved.resources.count, 1)
                let isSave = String(decoding: body, as: UTF8.self).contains("name=\"action\"\r\n\r\nsave\r\n")
                emlActions.append(isSave ? "save" : "deliver")
                if isSave {
                    submittedDraftMessageID = message.headers["message-id"]
                    return try .json(["code": "S_OK", "var": [:], "draftId": "5:draft-mid"])
                }
                return try .json(["code": "S_OK", "var": [:], "savedSent": "3:sent-mid"])
            case "upload:prepare":
                let body = try CoremailFixture.jsonBody(request)
                XCTAssertEqual(body["composeId"] as? String, "compose-1")
                XCTAssertEqual(body["attachmentId"] as? Int, -1)
                XCTAssertEqual(body["fileName"] as? String, attachment.name)
                XCTAssertEqual(body["contentType"] as? String, attachment.type)
                XCTAssertEqual(body["size"] as? Int, attachment.data.count)
                return try .ok(["attachmentId": 1])
            case "directData":
                XCTAssertEqual(query["composeId"], "compose-1")
                XCTAssertEqual(query["attachmentId"], "1")
                XCTAssertEqual(query["offset"], "0")
                let type = try XCTUnwrap(request.value(forHTTPHeaderField: "Content-Type"))
                XCTAssertTrue(type.hasPrefix("multipart/form-data; boundary="))
                let bytes = try CoremailFixture.body(request)
                let separator = try XCTUnwrap(bytes.range(of: Data("\r\n\r\n".utf8)))
                let headers = String(decoding: bytes.prefix(upTo: separator.lowerBound), as: UTF8.self)
                XCTAssertTrue(headers.contains("name=\"undefined\"; filename=\"\(attachment.name)\""))
                XCTAssertTrue(headers.contains("Content-Type: \(attachment.type)"))
                XCTAssertEqual(bytes.dropFirst(separator.upperBound).prefix(attachment.data.count), attachment.data)
                return try .ok(["attachmentId": 1, "actualSize": attachment.data.count])
            case "oab:autoMatch":
                let body = try CoremailFixture.jsonBody(request)
                XCTAssertEqual(body["limit"] as? Int, 30)
                if body["keyword"] as? String == email {
                    return try .ok([["email": "li@example.com", "true_name": "李同事"],
                                    ["email": email.uppercased(), "true_name": " 本人姓名 "]])
                }
                XCTAssertEqual(body["keyword"] as? String, "同事")
                return try .ok([["email": "li@example.com", "true_name": "李同事"]])
            default:
                XCTFail("Unexpected request: \(function)")
                throw URLError(.unsupportedURL)
            }
        }
        defer { CoremailFixture.respond = nil }

        let metadataDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: metadataDirectory) }
        let mailbox = try CoremailMailbox(account: account, password: secret, protocolClasses: [CoremailFixture.self],
                                          metadataDirectory: metadataDirectory)
        let folders = try await mailbox.folders()
        let ownName = try await mailbox.ownDisplayName()
        XCTAssertEqual(ownName, profileName)
        XCTAssertEqual(folders.first?.role, .inbox)
        XCTAssertEqual(folders.first { $0.id == "INBOX/1024" }?.display, "报告/项目")
        XCTAssertNil(folders.first { $0.id == "1025" }?.role)
        XCTAssertEqual(folders.first { $0.id == "1026" }?.role, .archive)
        let inbox = try await mailbox.list("INBOX", widen: false)
        XCTAssertEqual(inbox.rows.count, 50)
        XCTAssertTrue(inbox.more)
        let row = try XCTUnwrap(inbox.rows.first)
        XCTAssertEqual(row.subject, draft.subject)
        XCTAssertEqual(row.sender?.name, "发信人")
        XCTAssertNotNil(row.date)
        XCTAssertTrue(row.hasAttachment && row.unread && row.flagged)
        XCTAssertTrue(inbox.rows.dropFirst().allSatisfy { !$0.hasAttachment })
        let pagesBefore = listWindows.count
        let widened = try await mailbox.list("INBOX", widen: true)
        // Loading more asks only for the next page plus a short overlap, not the whole list again.
        XCTAssertEqual(listWindows.dropFirst(pagesBefore).map(\.start), [45])
        XCTAssertEqual(widened.rows.first?.id, row.id)
        XCTAssertEqual(widened.rows.last?.subject, "Older 50")
        XCTAssertFalse(widened.more)
        let refreshed = try await mailbox.poll("INBOX", inbox: "INBOX")
        XCTAssertEqual(refreshed.rows, widened.rows)
        XCTAssertTrue(refreshed.arrivals.isEmpty)
        hasNewMail = true
        let inboxOnly = try await mailbox.poll(nil, inbox: "INBOX")
        XCTAssertTrue(inboxOnly.rows.isEmpty)
        XCTAssertEqual(inboxOnly.arrivals.map(\.subject), ["New mail"])
        let repeated = try await mailbox.list("INBOX", widen: false)
        XCTAssertTrue(repeated.arrivals.isEmpty)
        hasNewMail = false
        let results = try await mailbox.search("测试", in: "INBOX")
        XCTAssertEqual(results.rows.map(\.id), [row.id])
        XCTAssertNil(results.next, "a short page means the server has no more results")
        XCTAssertEqual(results.rows.first?.fid, 1, "the folder comes from the message's fid, not its id prefix")

        let beforeSync = visited.count
        let snapshot = try await mailbox.syncMetadata { _ in }
        XCTAssertEqual(snapshot.folders, folders)
        XCTAssertEqual(snapshot.rows["INBOX"]?.count, 51)
        XCTAssertEqual(snapshot.rows["INBOX"]?.last?.subject, "Older 50")
        XCTAssertEqual(snapshot.rows["2"], [])
        XCTAssertFalse(visited.dropFirst(beforeSync).contains("mbox:getMessageData"))

        let offlineMailbox = try CoremailMailbox(account: account, password: "", protocolClasses: [CoremailFixture.self],
                                                 metadataDirectory: metadataDirectory)
        let beforeOffline = visited.count
        let reopened = await offlineMailbox.localMetadata()
        XCTAssertNotNil(reopened)
        XCTAssertEqual(reopened?.rows["INBOX"]?.last?.serverID, "1:older-50")
        XCTAssertEqual(reopened?.rows["INBOX"]?.filter { MailSearchQuery("older 50").matches($0) }.count, 1)
        let localRows = await offlineMailbox.localRows(in: ["INBOX", "INBOX"])
        XCTAssertEqual(localRows.count, 51, "rows are listed once")
        XCTAssertEqual(visited.count, beforeOffline)
        let afterSync = try await mailbox.list("INBOX", widen: false)
        XCTAssertEqual(afterSync.rows.count, 51)
        XCTAssertFalse(afterSync.more)

        let downloadsBefore = visited.filter { $0 == "mbox:getMessageData" }.count
        async let firstRead = mailbox.message(row.id)
        async let concurrentRead = mailbox.message(row.id)
        let (raw, concurrent) = try await (firstRead, concurrentRead)
        XCTAssertEqual(raw, concurrent)
        XCTAssertEqual(MIME.message(raw).subject, "Test")
        XCTAssertEqual(visited.filter { $0 == "mbox:getMessageData" }.count, downloadsBefore + 1)
        let offlineID = try XCTUnwrap(reopened?.rows["INBOX"]?.first?.id)
        let cachedRead = try await offlineMailbox.message(offlineID, allowDownload: false)
        XCTAssertEqual(cachedRead, raw)
        XCTAssertEqual(visited.filter { $0 == "mbox:getMessageData" }.count, downloadsBefore + 1)
        let bodies = await offlineMailbox.cachedBodies([offlineID])
        XCTAssertNotNil(bodies[offlineID], "cached bodies are searchable offline")
        XCTAssertEqual(visited.filter { $0 == "mbox:getMessageData" }.count, downloadsBefore + 1)
        try await mailbox.clearBodyCache()
        do {
            _ = try await offlineMailbox.message(offlineID, allowDownload: false)
            XCTFail("Cleared content must not be available offline")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("未缓存"))
        }
        _ = try await mailbox.message(row.id)
        XCTAssertEqual(visited.filter { $0 == "mbox:getMessageData" }.count, downloadsBefore + 2)
        try await mailbox.move(row.id, to: "INBOX/1024")
        let moved = try await mailbox.list("INBOX/1024", widen: false)
        XCTAssertEqual(moved.rows.map(\.id), [row.id])
        XCTAssertEqual(moved.rows.first?.fid, 1024)
        try await mailbox.delete(row.id, permanently: false)
        try await mailbox.delete(row.id, permanently: true)
        let saved = try await mailbox.saveDraft(draft, in: "2")
        XCTAssertNotEqual(saved, row.id)
        let firstMessageID = submittedDraftMessageID
        acknowledgeDraft = false
        do {
            _ = try await mailbox.saveDraft(draft, in: "2")
            XCTFail("An S_OK without a visible draft must not report success")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("草稿箱里找不到"))
        }
        XCTAssertNotEqual(firstMessageID, submittedDraftMessageID)
        try await mailbox.send(draft)
        // Exercise the real mailbox submission, including save/deliver and Bcc.
        var imageDraft = draft
        imageDraft.cc = [MailAddress(name: "抄送", email: "copy@example.com")]
        let resource = InlineImage(contentID: "original@example.com", location: nil,
                                   mediaType: "image/png", name: "图片.png", bytes: imageBytes)
        let rich = NSMutableAttributedString(string: "图片正文\n")
        rich.append(NSAttributedString(attachment: MailImageAttachment(resource: resource)))
        imageDraft.richBody = rich
        imageDraft.body = rich.string
        imageDraft.htmlBody = try RichEditor.exportHTML(rich, plain: rich.string)
        let beforeImageSubmission = visited.count
        try await mailbox.send(imageDraft)
        _ = try await mailbox.saveDraft(imageDraft, in: "2")
        XCTAssertEqual(emlActions, ["deliver", "save"])
        XCTAssertEqual(submittedImages.count, 2)
        XCTAssertFalse(visited.dropFirst(beforeImageSubmission).contains("upload:prepare"))
        let directory = try await mailbox.directorySearch("同事")
        XCTAssertEqual(directory, [ContactChoice(name: "李同事", email: "li@example.com")])
        XCTAssertEqual(visited.filter { $0 == "user:login" }.count, 1)
    }

    func testDirectoryResponse() throws {
        let rows = [
            ["email": "li@example.com", "true_name": "李同事"],
            ["email": "LI@example.com", "true_name": "重复"],
            ["email": "wang@example.com", "nick_name": "小王"],
            ["email": "invalid"]
        ]
        XCTAssertEqual(try CompanyDirectory.decode(rows), [
            ContactChoice(name: "李同事", email: "li@example.com"),
            ContactChoice(name: "小王", email: "wang@example.com")
        ])
        XCTAssertThrowsError(try CompanyDirectory.decode(["email": "li@example.com"]))
    }
}

private final class CoremailFixture: URLProtocol {
    struct Reply {
        let bytes: Data
        let headers: [String: String]

        static func ok(_ value: Any, headers: [String: String] = [:]) throws -> Reply {
            try json(["code": "S_OK", "var": value], headers: headers)
        }

        static func json(_ object: [String: Any], headers: [String: String] = [:]) throws -> Reply {
            Reply(bytes: try JSONSerialization.data(withJSONObject: object),
                  headers: ["Content-Type": "text/x-json"].merging(headers) { _, new in new })
        }
    }

    static var respond: ((URLRequest) throws -> Reply)?

    static func body(_ request: URLRequest) throws -> Data {
        if let bytes = request.httpBody { return bytes }
        let stream = try XCTUnwrap(request.httpBodyStream)
        stream.open()
        defer { stream.close() }
        var bytes = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count == 0 { return bytes }
            if count < 0 { throw stream.streamError ?? URLError(.cannotDecodeRawData) }
            bytes.append(contentsOf: buffer.prefix(count))
        }
    }

    static func jsonBody(_ request: URLRequest) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: body(request)) as? [String: Any])
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            let reply = try XCTUnwrap(Self.respond)(request)
            let response = try XCTUnwrap(HTTPURLResponse(url: XCTUnwrap(request.url), statusCode: 200,
                                                        httpVersion: "HTTP/1.1", headerFields: reply.headers))
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: reply.bytes)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

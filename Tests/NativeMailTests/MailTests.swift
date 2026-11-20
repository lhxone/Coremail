import XCTest
@testable import NativeMail

final class MailTests: XCTestCase {
    func testComposeTitleFollowsActionEvenWhenSubjectIsEdited() {
        let message = MIME.message(Data("Subject: Report\r\n\r\nNotes".utf8))
        let account = Account()
        XCTAssertEqual(Draft().composeTitle, "新邮件")
        let titles: [(ComposeAction, String)] = [
            (.reply, "回复"), (.replyAll, "回复全部"), (.replyWithAttachments, "回复全部并带附件"),
            (.forward, "转发"), (.forwardAsAttachment, "作为附件转发")
        ]
        for (action, title) in titles {
            var draft = Draft(message: message, account: account, action: action)
            draft.subject = ""
            XCTAssertEqual(draft.composeTitle, title)
        }
    }

    func testRecipientFieldsKeepNamesAndRejectUnresolvedInputBeforeSending() throws {
        var draft = Draft()
        try draft.addRecipients([MailAddress(name: "王女士", email: "wang@example.com")], to: .to)
        draft.pendingRecipients[.to] = "WANG@example.com, person@example.com"
        draft.pendingRecipients[.bcc] = "查不到的联系人"
        XCTAssertThrowsError(try draft.commitPendingRecipients())
        XCTAssertEqual(draft.to.count, 1)
        draft.pendingRecipients[.bcc] = "hidden@example.com"
        try draft.commitPendingRecipients()
        XCTAssertEqual(draft.to.map(\.email), ["wang@example.com", "person@example.com"])
        XCTAssertEqual(draft.to.first?.name, "王女士")
        XCTAssertEqual(draft.bcc.map(\.email), ["hidden@example.com"])
    }

    func testNativeMIMERoundTripWithChineseAttachmentAndPrivateBcc() throws {
        var account = Account()
        account.host = "mail.example.com"
        account.email = "self@example.com"
        var draft = Draft()
        draft.to = [MailAddress(name: "同事", email: "person@example.com")]
        draft.bcc = [MailAddress(name: "", email: "hidden@example.com")]
        draft.subject = String(repeating: "研发进展 📨", count: 15)
        draft.body = "你好，附件见下方。\n.测试"
        let attachment = Attachment(name: "测试 报告.txt", type: "text/plain", data: Data([0, 13, 10, 255, 37]))
        draft.attachments = [attachment]
        let (raw, recipients) = try MIME.outgoing(account: account, draft: draft)
        let message = MIME.message(raw)
        XCTAssertEqual(message.subject, draft.subject)
        XCTAssertEqual(message.plain, draft.body)
        XCTAssertEqual(message.attachments.first?.name, attachment.name)
        XCTAssertEqual(message.attachments.first?.data, attachment.data)
        XCTAssertEqual(recipients, ["person@example.com", "hidden@example.com"])
        XCTAssertNil(message.headers["bcc"])
        XCTAssertFalse(String(decoding: raw, as: UTF8.self).contains("hidden@example.com"))
    }

    func testReplyAllUsesReplyToExcludesSelfAndPreservesAttachments() {
        var account = Account()
        account.host = "mail.example.com"
        account.email = "self@example.com"
        let raw = Data("""
            From: original@example.com
            Reply-To: reply@example.com
            To: self@example.com, team@example.com
            Cc: TEAM@example.com, visible@example.com
            Bcc: secret@example.com
            Subject: hello
            Message-ID: <original@example.com>
            Content-Type: text/plain

            Original
            """.utf8)
        var message = MIME.message(raw)
        message.attachments = [Attachment(name: "file", type: "application/octet-stream", data: Data([1, 2]))]
        let draft = Draft(message: message, account: account, action: .replyWithAttachments)
        XCTAssertEqual(draft.to.map(\.email), ["reply@example.com"])
        XCTAssertEqual(draft.cc.map(\.email), ["team@example.com", "visible@example.com"])
        XCTAssertEqual(draft.inReplyTo, "<original@example.com>")
        XCTAssertEqual(draft.attachments, message.attachments)
        XCTAssertEqual(draft.quote?.plain, "Original")
        XCTAssertTrue(draft.body.isEmpty)
    }

}

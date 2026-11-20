import XCTest
@testable import NativeMail

final class ReaderAndFoldersTests: XCTestCase {
    func testRelatedMIMEReferencesImagesAndSeparatesAttachments() throws {
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a9foAAAAASUVORK5CYII=")!
        let original = """
            From: sender@example.com
            Subject: Inline images
            Content-Type: multipart/related; boundary=mail-image

            --mail-image
            Content-Type: text/html; charset=utf-8
            Content-Location: https://example.com/assets/body.html

            <img src="cid:image%40example.com"><img src='logo.png'><img src=//example.com/counter.gif>
            --mail-image
            Content-Type: image/png; name=first.png
            Content-ID: <IMAGE@example.com>
            Content-Transfer-Encoding: base64

            \(png.base64EncodedString())
            --mail-image
            Content-Type: image/png; name=logo.png
            Content-Location: https://example.com/assets/logo.png
            Content-Transfer-Encoding: base64

            \(png.base64EncodedString())
            --mail-image
            Content-Type: image/png
            Content-Disposition: attachment; filename=download.png
            Content-Transfer-Encoding: base64

            \(png.base64EncodedString())
            --mail-image--
            """
        let message = MIME.message(Data(original.utf8))
        let html = try XCTUnwrap(message.html)
        let page = MailHTML(html: html, images: message.inlineImages, location: message.htmlLocation)
        XCTAssertEqual(message.inlineImages.count, 2)
        XCTAssertEqual(message.attachments.map(\.name), ["download.png"])
        XCTAssertEqual(page.resources.count, 2)
        XCTAssertTrue(page.resources.values.allSatisfy { $0.bytes == png })
        XCTAssertTrue(message.inlineImages.allSatisfy { page.content.contains($0.url) })
        XCTAssertTrue(page.hasRemoteImages)
        XCTAssertTrue(page.content.contains("https://example.com/counter.gif"))
    }

    func testUnreferencedCIDAndLocationImagesStayDownloadable() {
        let raw = """
            Content-Type: multipart/mixed; boundary=files

            --files
            Content-Type: text/html; charset=utf-8

            <p>See the files.</p><img src="cid:inline@example.com">
            --files
            Content-Type: image/png; name=inline.png
            Content-ID: <inline@example.com>
            Content-Transfer-Encoding: base64

            AA==
            --files
            Content-Type: image/png; name=report.png
            Content-ID: <report@example.com>
            Content-Disposition: inline; filename=report.png
            Content-Transfer-Encoding: base64

            AQ==
            --files
            Content-Type: image/jpeg
            Content-Location: https://example.com/files/photo.jpg
            Content-Transfer-Encoding: base64

            Ag==
            --files
            Content-Type: image/png
            Content-ID: <attachment@example.com>
            Content-Disposition: attachment; filename=download.png
            Content-Transfer-Encoding: base64

            Aw==
            --files--
            """
        let message = MIME.message(Data(raw.utf8))
        XCTAssertEqual(message.inlineImages.map(\.name), ["inline.png"])
        let files = Dictionary(uniqueKeysWithValues: message.attachments.map { ($0.name, $0.data) })
        XCTAssertEqual(files, ["report.png": Data([1]), "photo.jpg": Data([2]), "download.png": Data([3])])
    }

    func testRelatedMailUsesExplicitMessageIDThenSubjectAndDate() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let event = AgendaEvent(id: "event", title: "【会议通知】 SIP trunk 联调，时间：11/16",
                                location: "", calendar: "Calendar", start: start,
                                end: start.addingTimeInterval(3600), allDay: false,
                                sourceURL: URL(string: "message:%3Cmeeting%40example.com%3E"))
        let invitation = MailSummary(id: 1, subject: "Invitation", sender: nil, date: nil, unread: false,
                                     headerMessageID: "<MEETING@example.com>")
        let reply = MailSummary(id: 2, subject: "RE: 回复：SIP trunk 联调", sender: nil, date: start, unread: false)
        let old = MailSummary(id: 3, subject: reply.subject, sender: nil,
                              date: start.addingTimeInterval(-365 * 86_400), unread: false)
        XCTAssertEqual(RelatedMail.eventQuery(event.title), "SIP trunk 联调")
        let results = RelatedMail.matches(["INBOX": [old, reply, invitation]], event: event)
        XCTAssertEqual(results.map { $0.row.id }, [1, 2])
        XCTAssertEqual(results.map(\.exact), [true, false])
    }

    func testWeekGridClipsOvernightEventsAndSeparatesOverlaps() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let day = calendar.date(from: DateComponents(year: 2026, month: 11, day: 18))!
        func event(_ id: String, _ start: Int, _ end: Int, allDay: Bool = false) -> AgendaEvent {
            AgendaEvent(id: id, title: id, location: "", calendar: "Calendar",
                        start: day.addingTimeInterval(Double(start * 60)),
                        end: day.addingTimeInterval(Double(end * 60)), allDay: allDay)
        }
        let schedule = DaySchedule(day: day, events: [
            event("all day", -1440, 1440, allDay: true),
            event("overnight", -120, 30), event("overlap", 15, 60),
            event("later", 120, 180), event("tomorrow", 1440, 1500)
        ], calendar: calendar)
        XCTAssertEqual(schedule.allDay.map(\.id), ["all day"])
        XCTAssertEqual(schedule.timed.map(\.start), [0, 15, 120])
        XCTAssertEqual(schedule.timed.map(\.lane), [0, 1, 0])
        XCTAssertEqual(schedule.timed.map(\.laneCount), [2, 2, 1])
    }

    func testFolderTreeUsesServerDelimiterRolesAndNonSelectableParents() throws {
        let folders = [
            MailFolder(id: "INBOX", name: "Inbox", delimiter: ".", role: .inbox),
            MailFolder(id: "INBOX.旅行", name: "INBOX.旅行", delimiter: "."),
            MailFolder(id: "Sent", name: "服务器自定义名称", role: .sent),
            MailFolder(id: "Drafts", name: "Drafts", role: .drafts),
            MailFolder(id: "Work.Release", name: "Work.Release", delimiter: "."),
            MailFolder(id: "Standalone.With.Dot", name: "Standalone.With.Dot")
        ]
        let rows = FolderOutline.rows(folders, collapsed: [])
        XCTAssertEqual(rows.map(\.name), ["收件箱", "旅行", "草稿箱", "已发送", "Standalone.With.Dot", "Work", "Release"])
        let child = try XCTUnwrap(rows.first { $0.depth == 1 })
        XCTAssertEqual(child.folder?.id, "INBOX.旅行")
        XCTAssertTrue(rows.first { $0.name == "Work" }?.hasChildren == true)
        XCTAssertNil(rows.first { $0.name == "Work" }?.folder)
        XCTAssertFalse(FolderOutline.rows(folders, collapsed: ["INBOX"]).contains { $0.name == "旅行" })
    }
}

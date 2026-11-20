import XCTest
@testable import NativeMail

final class MailSearchTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
    }

    private func row(_ subject: String, from: MailAddress? = MailAddress(name: "张三", email: "zhang@example.com"),
                     to: [MailAddress] = [MailAddress(name: "李四", email: "li@example.com")],
                     date: Date? = nil, unread: Bool = false, flagged: Bool = false,
                     attachment: Bool = false, id: UInt32 = 1) -> MailSummary {
        MailSummary(id: id, subject: subject, sender: from, date: date ?? self.date(2024, 5, 8), unread: unread,
                    flagged: flagged, hasAttachment: attachment, recipients: to, serverID: "3:m\(id)")
    }

    func testFreeWordsMustAllMatchAcrossFields() {
        let mail = row("季度合同审阅")
        XCTAssertTrue(MailSearchQuery("张三 合同").matches(mail))
        XCTAssertTrue(MailSearchQuery("li@example 季度").matches(mail))
        XCTAssertFalse(MailSearchQuery("张三 报价").matches(mail))
        XCTAssertTrue(MailSearchQuery("ＺＨＡＮＧ").matches(mail), "full-width letters match")
    }

    func testQuotedPhraseAndExclusion() {
        let mail = row("Project kickoff notes")
        XCTAssertTrue(MailSearchQuery("\"kickoff notes\"").matches(mail))
        XCTAssertFalse(MailSearchQuery("\"notes kickoff\"").matches(mail))
        XCTAssertTrue(MailSearchQuery("“kickoff notes”").matches(mail))
        XCTAssertFalse(MailSearchQuery("project -kickoff").matches(mail))
        XCTAssertTrue(MailSearchQuery("project -budget").matches(mail))
    }

    func testFieldFiltersOnlyLookAtTheirField() {
        let mail = row("来自李四的提醒")
        XCTAssertTrue(MailSearchQuery("from:张三").matches(mail))
        XCTAssertFalse(MailSearchQuery("from:李四").matches(mail))
        XCTAssertTrue(MailSearchQuery("to:li@").matches(mail))
        XCTAssertTrue(MailSearchQuery("发件人：zhang 主题:提醒").matches(mail))
        XCTAssertFalse(MailSearchQuery("subject:张三").matches(mail))
        XCTAssertTrue(MailSearchQuery("from:\"张三\"").matches(mail))
    }

    func testStateFilters() {
        let mail = row("周报", unread: true, flagged: false, attachment: true)
        XCTAssertTrue(MailSearchQuery("is:unread").matches(mail))
        XCTAssertFalse(MailSearchQuery("is:read").matches(mail))
        XCTAssertFalse(MailSearchQuery("-is:unread").matches(mail))
        XCTAssertFalse(MailSearchQuery("is:flagged").matches(mail))
        XCTAssertTrue(MailSearchQuery("has:attachment 周报").matches(mail))
        XCTAssertTrue(MailSearchQuery("是:未读 有:附件").matches(mail))
        XCTAssertNil(MailSearchQuery("is:unread has:attachment").serverKeyword)
    }

    func testDateFilters() {
        let mail = row("x", date: date(2024, 5, 8))
        func q(_ text: String) -> MailSearchQuery { MailSearchQuery(text, calendar: calendar) }
        XCTAssertTrue(q("after:2024-05-08").matches(mail))
        XCTAssertFalse(q("after:2024-05-09").matches(mail))
        XCTAssertTrue(q("before:2024-05-09").matches(mail))
        XCTAssertFalse(q("before:2024-05-08").matches(mail), "before is exclusive")
        XCTAssertTrue(q("date:2024-05").matches(mail))
        XCTAssertFalse(q("date:2024-06").matches(mail))
        XCTAssertTrue(q("date:2024").matches(mail))
        XCTAssertTrue(q("date:2024年5月").matches(mail))
        XCTAssertNil(MailSearchQuery.dateRange("2024-02-30", calendar: calendar))
    }

    func testUnknownPrefixesAreSearchedAsText() {
        let mail = row("Re: 会议 10:30")
        XCTAssertTrue(MailSearchQuery("Re:").matches(mail))
        XCTAssertTrue(MailSearchQuery("10:30").matches(mail))
        XCTAssertFalse(MailSearchQuery("is:whatever").matches(mail))
        XCTAssertFalse(MailSearchQuery("after:昨天").isEmpty)
    }

    func testBodyAndServerMatches() {
        let mail = row("周报")
        let query = MailSearchQuery("周报 预算")
        XCTAssertFalse(query.matches(mail))
        XCTAssertTrue(query.needsBody(mail))
        XCTAssertTrue(query.matches(mail, body: "本季度预算如下"))
        XCTAssertTrue(query.matches(mail, trustServer: true))
        XCTAssertFalse(MailSearchQuery("预算 from:王五").matches(mail, trustServer: true),
                       "field filters still apply to server results")
        XCTAssertEqual(query.serverKeyword, "周报 预算")
        XCTAssertEqual(MailSearchQuery("from:张三 is:unread").serverKeyword, "张三")
        XCTAssertEqual(query.highlights, ["周报", "预算"])
    }

    func testBodyTextIncludesAttachmentNamesAndSkipsEncryptedMail() {
        let plain = Data("""
        Content-Type: multipart/mixed; boundary="b"\r
        \r
        --b\r
        Content-Type: text/plain; charset=utf-8\r
        \r
        预算明细见附件\r
        --b\r
        Content-Type: application/pdf; name="report.pdf"\r
        Content-Disposition: attachment; filename="report.pdf"\r
        \r
        JVBERi0=\r
        --b--\r
        """.utf8)
        let text = MailSearchQuery.bodyText(plain) ?? ""
        XCTAssertTrue(text.contains("预算明细"))
        XCTAssertTrue(text.contains("report.pdf"))
        let encrypted = Data("Content-Type: application/pkcs7-mime; smime-type=enveloped-data\r\n\r\nMIAG".utf8)
        XCTAssertNil(MailSearchQuery.bodyText(encrypted))
    }

    func testFilterTokensToggle() {
        XCTAssertEqual(MailSearchQuery.toggling(token: "is:unread", in: ""), "is:unread")
        XCTAssertEqual(MailSearchQuery.toggling(token: "is:unread", in: "合同 "), "合同 is:unread")
        XCTAssertEqual(MailSearchQuery.toggling(token: "is:unread", in: "合同 is:unread"), "合同")
        XCTAssertTrue(MailSearchQuery.contains(token: "is:unread", in: "IS:UNREAD 合同"))
    }

    func testResultMergeAndRecentSearches() {
        let older = row("a", date: date(2024, 1, 1), id: 1)
        let newer = row("b", date: date(2024, 2, 1), id: 2)
        var updated = older
        updated.unread = true
        let merged = SearchResults.merge([older], [newer, updated])
        XCTAssertEqual(merged.map(\.id), [2, 1])
        XCTAssertEqual(merged.last?.unread, true, "server rows replace local copies")

        var recent: [String] = []
        for term in ["a", "b", "a", " ", "c"] { recent = RecentSearches.adding(term, to: recent) }
        XCTAssertEqual(recent, ["c", "a", "b"])
    }

    func testFolderNumbers() {
        XCTAssertEqual(MailFolder(id: "INBOX", name: "收件箱").coremailFID, 1)
        XCTAssertEqual(MailFolder(id: "3", name: "已发送").coremailFID, 3)
        XCTAssertEqual(MailFolder(id: "12/105", name: "项目").coremailFID, 105)
        XCTAssertEqual(row("x", id: 9).serverFID, 3)
    }

    func testBodyCachePeekDoesNotRefreshAge() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var account = Account()
        account.host = "mail.example.com"
        account.email = "self@example.com"
        let cache = MessageBodyCache(account: account, root: root)
        try cache.save(Data("hello".utf8), id: "mid-1")
        XCTAssertEqual(cache.cachedIDs(among: ["mid-1", "mid-2"]), ["mid-1"])
        let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: cache.directory, includingPropertiesForKeys: nil).first)
        let old = Date().addingTimeInterval(-3600)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: file.path)
        XCTAssertEqual(cache.peek("mid-1"), Data("hello".utf8))
        // A fresh URL: URL instances cache resource values.
        let modified = try URL(fileURLWithPath: file.path).resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate
        XCTAssertEqual(modified?.timeIntervalSince1970 ?? 0, old.timeIntervalSince1970, accuracy: 1)
    }
}

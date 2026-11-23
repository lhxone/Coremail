import XCTest
@testable import NativeMail

final class MailboxActionsTests: XCTestCase {
    func testAccountsSavedByEarlierVersionsStillDecode() throws {
        let legacy = #"{"email":"me@example.com","username":"","imapHost":"mail.example.com","imapPort":1993,"smtpHost":"mail.example.com","smtpPort":465,"smtpStartTLS":false,"sentFolder":""}"#
        let account = try JSONDecoder().decode(Account.self, from: Data(legacy.utf8))
        XCTAssertEqual(account.email, "me@example.com")
        XCTAssertEqual(account.host, "mail.example.com")
        XCTAssertEqual(account.displayName, "")
        XCTAssertEqual(account.signature, "")
        let partial = try JSONDecoder().decode(Account.self, from: Data(#"{"email":"x@example.com"}"#.utf8))
        XCTAssertTrue(Account().host.isEmpty)
        XCTAssertTrue(partial.host.isEmpty)
        XCTAssertThrowsError(try partial.validate())
        XCTAssertEqual(account.keychainAccount, "me@example.com@mail.example.com:1993")
        let roundTrip = try JSONDecoder().decode(Account.self, from: JSONEncoder().encode(account))
        XCTAssertEqual(roundTrip.keychainAccount, account.keychainAccount)
    }

    func testOutgoingHeadersCarryDisplayNamesAndDraftsKeepBcc() throws {
        var account = Account()
        account.host = "mail.example.com"
        account.email = "self@example.com"
        account.displayName = "张三"
        var draft = Draft()
        draft.to = [MailAddress(name: "Li Si", email: "li@example.com")]
        draft.bcc = [MailAddress(name: "", email: "hidden@example.com")]
        draft.subject = "周报"
        draft.body = "内容"
        let (raw, _) = try MIME.outgoing(account: account, draft: draft)
        let message = MIME.message(raw)
        XCTAssertEqual(message.from.first?.name, "张三")
        XCTAssertEqual(message.from.first?.email, "self@example.com")
        XCTAssertEqual(message.to.first?.name, "Li Si")
        XCTAssertNil(message.headers["bcc"])

        let (saved, _) = try MIME.outgoing(account: account, draft: draft, asDraft: true)
        let reopened = Draft(draft: MIME.message(saved), replacing: nil)
        XCTAssertEqual(reopened.bcc.map(\.email), ["hidden@example.com"])
        XCTAssertEqual(reopened.to.map(\.email), ["li@example.com"])
        XCTAssertEqual(reopened.subject, "周报")
        XCTAssertEqual(reopened.composeTitle, "编辑草稿")
    }

    func testDraftsMayOmitRecipientsButNotPlaintextSMIME() throws {
        var account = Account()
        account.host = "mail.example.com"
        account.email = "self@example.com"
        var draft = Draft()
        draft.subject = "未完成"
        XCTAssertThrowsError(try MIME.outgoing(account: account, draft: draft))
        XCTAssertNoThrow(try MIME.outgoing(account: account, draft: draft, asDraft: true))
        draft.encrypt = true
        XCTAssertThrowsError(try MIME.outgoing(account: account, draft: draft, asDraft: true))
    }

    func testSignatureIsAddedToNewMessagesAndReplies() {
        var account = Account()
        account.signature = "研发部 张三"
        XCTAssertEqual(Draft(signature: account.signature).body, "\n\n研发部 张三")
        let reply = Draft(message: MIME.message(Data("Subject: Hi\r\n\r\nx".utf8)), account: account, action: .reply)
        XCTAssertTrue(reply.body.contains("研发部 张三"))
        XCTAssertEqual(Draft().body, "")
    }

    func testMailDateSectionsUseMondayAndPreferMoreSpecificPeriods() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 18, hour: 12)))
        let days = [(11, 18), (11, 17), (11, 16), (11, 15), (11, 8), (10, 31)]
        var rows = days.enumerated().map { index, day in
            MailSummary(id: UInt32(index + 1), subject: "", sender: nil,
                        date: calendar.date(from: DateComponents(year: 2026, month: day.0, day: day.1, hour: 23)),
                        unread: false, flagged: false, hasAttachment: false)
        }
        rows.append(MailSummary(id: 7, subject: "", sender: nil, date: nil,
                                unread: false, flagged: false, hasAttachment: false))
        let grouped = MailDate.groups(rows, now: now, calendar: calendar)
        XCTAssertEqual(MailDate.Group.allCases.map { grouped[$0]?.map(\.id) }, [[1], [2], [3], [4], [5], [6, 7]])
    }

    func testShortDatesFollowMailListConventions() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 17, hour: 15)))
        let yesterday = try XCTUnwrap(calendar.date(byAdding: .day, value: -1, to: now))
        let lastYear = try XCTUnwrap(calendar.date(from: DateComponents(year: 2025, month: 3, day: 2)))
        XCTAssertEqual(MailDate.short(yesterday, now: now, calendar: calendar), "昨天")
        XCTAssertNotEqual(MailDate.short(lastYear, now: now, calendar: calendar), MailDate.short(yesterday, now: now, calendar: calendar))
        XCTAssertTrue(MailDate.short(lastYear, now: now, calendar: calendar).contains("2025"))
    }

    func testInitialsSuitChineseAndLatinNames() {
        XCTAssertEqual(MailAddress(name: "王小明", email: "w@example.com").initials, "小明")
        XCTAssertEqual(MailAddress(name: "李四", email: "l@example.com").initials, "李四")
        XCTAssertEqual(MailAddress(name: "Ada Lovelace", email: "a@example.com").initials, "AL")
        XCTAssertEqual(MailAddress(name: "", email: "bob@example.com").initials, "B")
    }

    func testLongRecipientListsCollapseInReaderHeader() {
        let list = (1...60).map { MailAddress(name: "同事\($0)", email: "p\($0)@example.com") }
        let short = MailAddress.summary(list, expanded: false)
        XCTAssertEqual(short, "同事1、同事2、同事3、同事4、同事5 等 60 人")
        XCTAssertTrue(MailAddress.summary(list, expanded: true).hasSuffix("同事60"))
        XCTAssertEqual(MailAddress.summary(Array(list.prefix(2)), expanded: false), "同事1、同事2")
    }

    @MainActor
    func testContactsMergeSourcesRankByFrequencyAndFilter() {
        let model = ContactsModel()
        let recent = [
            RecentContact(name: "", email: "Wang@example.com", count: 2, lastSeen: Date()),
            RecentContact(name: "李四", email: "li@example.com", count: 9, lastSeen: Date())
        ]
        var entries = model.entries(recent: recent)
        XCTAssertEqual(entries.map(\.email), ["li@example.com", "Wang@example.com"])
        model.query = "wang"
        entries = model.entries(recent: recent)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.sources, [.recent])
        model.query = "李"
        XCTAssertEqual(model.entries(recent: recent).first?.display, "李四")
    }

    func testFreeBusyResponsesAreParsedClippedAndMerged() throws {
        let xml = """
            <?xml version="1.0" encoding="utf-8"?>
            <C:schedule-response xmlns:D="DAV:" xmlns:C="urn:ietf:params:xml:ns:caldav">
              <C:response>
                <C:recipient><D:href>mailto:a@example.com</D:href></C:recipient>
                <C:request-status>2.0;Success</C:request-status>
                <C:calendar-data>BEGIN:VCALENDAR\r\nBEGIN:VFREEBUSY\r\nFREEBUSY;FBTYPE=BUSY:20261118T010000Z/20261118T020000Z,20261118T013000Z/PT2H\r\nFREEBUSY;FBTYPE=FREE:20261118T050000Z/20261118T060000Z\r\nFREEBUSY:20261118T070000Z/20261118T08\r\n 0000Z\r\nEND:VFREEBUSY\r\nEND:VCALENDAR</C:calendar-data>
              </C:response>
            </C:schedule-response>
            """
        let start = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-18T00:00:00Z"))
        let end = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-18T12:00:00Z"))
        let busy = try CalDAV.busyPeriods(in: Data(xml.utf8), from: start, to: end)
        XCTAssertEqual(busy.count, 2, "Overlapping busy periods merge and FREE periods are skipped.")
        XCTAssertEqual(busy[0].duration, 2.5 * 3600, accuracy: 1)
        XCTAssertEqual(busy[1].duration, 3600, accuracy: 1, "Folded lines are unfolded.")

        let unknown = xml.replacingOccurrences(of: "2.0;Success", with: "3.7;Invalid calendar user")
        XCTAssertThrowsError(try CalDAV.busyPeriods(in: Data(unknown.utf8), from: start, to: end))
    }

    func testFirstFreeSlotSkipsBusyTimeAndPastHours() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let monday = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 16, hour: 8)))
        let days = FreeBusyView.days(from: monday, calendar: calendar)
        XCTAssertEqual(days.count, 5)
        func at(_ hour: Int, _ minute: Int = 0) -> Date { calendar.date(bySettingHour: hour, minute: minute, second: 0, of: monday)! }
        let busy = [DateInterval(start: at(9), end: at(11)), DateInterval(start: at(11, 15), end: at(13))]
        let free = try XCTUnwrap(FreeBusyView.firstFree(busy: busy, days: days, now: monday, calendar: calendar))
        XCTAssertEqual(free.start, at(13), "A 15-minute gap is too short; the first real gap starts at 13:00.")
        XCTAssertEqual(free.end, at(18))
    }
}

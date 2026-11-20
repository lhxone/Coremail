import Foundation

struct RelatedMail: Identifiable {
    let folder: String
    let row: MailSummary
    let exact: Bool

    var id: String { row.serverID ?? "\(folder):\(row.id)" }

    static func searchTerm(_ subject: String) -> String {
        subject.replacingOccurrences(of: #"(?i)^\s*(?:(?:re|fw|fwd|回复|答复|转发)\s*[:：]\s*)+"#,
                                     with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func eventQuery(_ title: String) -> String {
        let title = searchTerm(title)
        let timeSuffix = #"(?i)[，,\s]*(?:时间|日期|time|date)\s*[:：].*$"#
        let subject = title.replacingOccurrences(of: timeSuffix, with: "", options: .regularExpression)
        let notificationPrefix = #"^\s*[【\[]\s*(?:会议通知|会议邀请|日程通知)\s*[】\]]\s*"#
        return subject.replacingOccurrences(of: notificationPrefix, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "【】[]，,")))
    }

    static func matches(_ folders: [String: [MailSummary]], event: AgendaEvent) -> [RelatedMail] {
        func normalized(_ value: String) -> String {
            searchTerm(value).lowercased().filter { $0.isLetter || $0.isNumber }
        }
        let titles = Set([normalized(event.title), normalized(eventQuery(event.title))]).filter { !$0.isEmpty }
        let sourceID = event.sourceMessageID
        guard !titles.isEmpty || sourceID != nil else { return [] }
        let calendar = Calendar.current
        let earliest = calendar.date(byAdding: .day, value: -90, to: event.start) ?? event.start
        let latest = calendar.date(byAdding: .day, value: 14, to: event.end) ?? event.end
        var output: [RelatedMail] = []
        var seen = Set<String>()
        for (folder, rows) in folders {
            for row in rows {
                let exact = sourceID.map { id in
                    row.headerMessageID.map(MailHTML.canonicalContentID) == id
                } ?? false
                if !exact {
                    guard !titles.isEmpty, let date = row.date, (earliest...latest).contains(date) else { continue }
                    let subject = normalized(row.subject)
                    guard titles.contains(where: { title in
                        subject == title || (min(subject.count, title.count) >= 8 &&
                            (subject.contains(title) || title.contains(subject)))
                    }) else { continue }
                }
                let result = RelatedMail(folder: folder, row: row, exact: exact)
                if seen.insert(result.id).inserted { output.append(result) }
            }
        }
        return Array(output.sorted {
            if $0.exact != $1.exact { return $0.exact }
            return ($0.row.date ?? .distantPast) > ($1.row.date ?? .distantPast)
        }.prefix(12))
    }
}

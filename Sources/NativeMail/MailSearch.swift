import Foundation

/// Search box input, parsed once and matched against list rows.
///
/// Plain words must all match (subject, people, or a cached body). Quotes keep a phrase together.
/// `from:` `to:` `subject:` narrow a word to one field, `-word` excludes it, and
/// `is:unread` `is:read` `is:flagged` `has:attachment` `after:` `before:` `date:` filter rows.
/// Chinese keywords (`发件人:` `收件人:` `主题:` `是:未读` `有:附件` …) work the same way.
struct MailSearchQuery: Equatable {
    enum Field: Equatable { case any, from, to, subject }

    struct Term: Equatable {
        var field: Field
        var text: String
        var negated = false
    }

    private(set) var terms: [Term] = []
    private(set) var unread: Bool?
    private(set) var flagged: Bool?
    private(set) var attachment: Bool?
    /// Inclusive lower bound.
    private(set) var after: Date?
    /// Exclusive upper bound.
    private(set) var before: Date?

    init(_ text: String, calendar: Calendar = .current) {
        for token in Self.tokens(text) {
            guard let key = token.key else {
                add(.any, token.value, negated: token.negated)
                continue
            }
            if !apply(key: key.lowercased(), value: token.value, negated: token.negated, calendar: calendar) {
                // Not a known filter (for example "Re:" or a URL): search for the text as typed.
                add(.any, key + ":" + token.value, negated: token.negated)
            }
        }
    }

    var isEmpty: Bool {
        terms.isEmpty && unread == nil && flagged == nil && attachment == nil && after == nil && before == nil
    }

    /// Words worth highlighting in the list.
    var highlights: [String] {
        terms.filter { !$0.negated }.map(\.text)
    }

    /// What to send to `mbox:searchMessages`, or nil when only state filters were given.
    /// Free words go first because the server may also look in bodies; otherwise the first field word.
    var serverKeyword: String? {
        let free = terms.filter { $0.field == .any && !$0.negated }.map(\.text)
        if !free.isEmpty { return free.joined(separator: " ") }
        return terms.first { !$0.negated }?.text
    }

    /// Whether `row` satisfies the query. `body` is the cached message text, when there is one.
    /// With `trustServer`, free words count as matched: the server found them, possibly in the body.
    func matches(_ row: MailSummary, body: String? = nil, trustServer: Bool = false) -> Bool {
        if let unread, row.unread != unread { return false }
        if let flagged, row.flagged != flagged { return false }
        if let attachment, row.hasAttachment != attachment { return false }
        if after != nil || before != nil {
            guard let date = row.date else { return false }
            if let after, date < after { return false }
            if let before, date >= before { return false }
        }
        for term in terms {
            if trustServer && term.field == .any && !term.negated { continue }
            if Self.matches(term, row, body: body) == term.negated { return false }
        }
        return true
    }

    /// Whether a match is possible only through the body (some free word is absent from the headers).
    func needsBody(_ row: MailSummary) -> Bool {
        !matches(row) && matches(row, trustServer: true)
    }

    /// Whether the search box text has this filter token (such as `is:unread`) on its own.
    static func contains(token: String, in text: String) -> Bool {
        text.split(whereSeparator: \.isWhitespace).contains { $0.lowercased() == token }
    }

    /// Adds the filter token, or removes it when it is already there.
    static func toggling(token: String, in text: String) -> String {
        let parts = text.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        if contains(token: token, in: text) {
            return parts.filter { $0.lowercased() != token }.joined(separator: " ")
                .trimmingCharacters(in: .whitespaces)
        }
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? token : trimmed + " " + token
    }

    static func contains(_ text: String, _ word: String) -> Bool {
        !word.isEmpty && text.range(of: word, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]) != nil
    }

    /// Readable text of a raw message for local body search: plain body and attachment names.
    /// Encrypted messages are skipped so searching never asks for a private key.
    static func bodyText(_ raw: Data) -> String? {
        let type = MIME.headers(raw)["content-type"]?.lowercased() ?? ""
        if type.contains("pkcs7-mime") { return nil }
        let message = MIME.message(raw)
        if message.encrypted { return nil }
        let body = message.plain ?? message.html.map(MIME.plainText) ?? ""
        let names = message.attachments.map(\.name).joined(separator: "\n")
        return names.isEmpty ? body : body + "\n" + names
    }

    // MARK: - Parsing

    private mutating func add(_ field: Field, _ text: String, negated: Bool) {
        let text = text.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        terms.append(Term(field: field, text: text, negated: negated))
    }

    private mutating func apply(key: String, value: String, negated: Bool, calendar: Calendar) -> Bool {
        let value = value.trimmingCharacters(in: .whitespaces)
        switch key {
        case "from", "发件人", "发件", "寄件人":
            add(.from, value, negated: negated)
        case "to", "收件人", "收件":
            add(.to, value, negated: negated)
        case "subject", "主题", "标题":
            add(.subject, value, negated: negated)
        case "is", "是", "状态":
            switch value.lowercased() {
            case "unread", "未读": unread = !negated
            case "read", "已读": unread = negated
            case "flagged", "starred", "旗标", "星标", "红旗": flagged = !negated
            default: return false
            }
        case "has", "有", "含":
            guard ["attachment", "attachments", "attach", "附件"].contains(value.lowercased()) else { return false }
            attachment = !negated
        case "after", "since", "晚于", "之后", "从":
            guard !negated, let range = Self.dateRange(value, calendar: calendar) else { return false }
            after = range.lowerBound
        case "before", "until", "早于", "之前", "到":
            guard !negated, let range = Self.dateRange(value, calendar: calendar) else { return false }
            before = range.lowerBound
        case "date", "on", "日期":
            guard !negated, let range = Self.dateRange(value, calendar: calendar) else { return false }
            after = range.lowerBound
            before = range.upperBound
        default:
            return false
        }
        return true
    }

    /// `2024`, `2024-05`, `2024-05-08` (also `/` or `.`) → the year, month or day it names.
    static func dateRange(_ text: String, calendar: Calendar) -> Range<Date>? {
        let parts = text.split(whereSeparator: { "-/.年月日".contains($0) }).map(String.init)
        guard (1...3).contains(parts.count), parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isASCII) }) else { return nil }
        let numbers = parts.compactMap { Int($0) }
        guard numbers.count == parts.count, (1970...2100).contains(numbers[0]) else { return nil }
        var components = DateComponents(year: numbers[0], month: 1, day: 1)
        let unit: Calendar.Component
        switch numbers.count {
        case 1: unit = .year
        case 2:
            guard (1...12).contains(numbers[1]) else { return nil }
            components.month = numbers[1]; unit = .month
        default:
            guard (1...12).contains(numbers[1]), (1...31).contains(numbers[2]) else { return nil }
            components.month = numbers[1]; components.day = numbers[2]; unit = .day
        }
        guard let start = calendar.date(from: components),
              calendar.component(.month, from: start) == components.month,
              let end = calendar.date(byAdding: unit, value: 1, to: start) else { return nil }
        return start..<end
    }

    private struct Token { var negated: Bool; var key: String?; var value: String }

    private static func tokens(_ text: String) -> [Token] {
        let quotes: Set<Character> = ["\"", "“", "”", "「", "」"]
        let characters = Array(text)
        var tokens: [Token] = []
        var index = 0
        while index < characters.count {
            if characters[index].isWhitespace { index += 1; continue }
            var token = Token(negated: false, key: nil, value: "")
            if characters[index] == "-", index + 1 < characters.count, !characters[index + 1].isWhitespace {
                token.negated = true
                index += 1
            }
            var quoted = false
            var sawQuote = false
            while index < characters.count {
                let character = characters[index]
                index += 1
                if quotes.contains(character) { quoted.toggle(); sawQuote = true; continue }
                if !quoted && character.isWhitespace { break }
                if !quoted, !sawQuote, token.key == nil, character == ":" || character == "：", !token.value.isEmpty {
                    token.key = token.value
                    token.value = ""
                    continue
                }
                token.value.append(character)
            }
            if token.key != nil || !token.value.isEmpty { tokens.append(token) }
        }
        return tokens
    }

    private static func matches(_ term: Term, _ row: MailSummary, body: String?) -> Bool {
        let word = term.text
        let sender = contains(row.from, word) || row.sender.map { contains($0.email, word) } == true
        let recipient = row.recipients.contains { contains($0.name, word) || contains($0.email, word) }
        switch term.field {
        case .from: return sender
        case .to: return recipient
        case .subject: return contains(row.subject, word)
        case .any: return contains(row.subject, word) || sender || recipient || body.map { contains($0, word) } == true
        }
    }
}

/// Where a search looks.
enum MailSearchScope: String, CaseIterable, Identifiable {
    case folder, all
    var id: Self { self }
    var title: String { self == .folder ? "当前文件夹" : "所有文件夹" }
}

/// A list of recent search box entries, newest first.
struct RecentSearches {
    static let key = "recentMailSearches"
    static let limit = 8

    static func adding(_ term: String, to list: [String]) -> [String] {
        let term = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return list }
        return Array(([term] + list.filter { $0 != term }).prefix(limit))
    }
}

/// One page of server search results; `next` is the offset of the following page, nil at the end.
struct SearchPage: Sendable {
    let rows: [MailSummary]
    let next: Int?
}

/// Merges result pages: one row per message, newest first.
enum SearchResults {
    static func merge(_ existing: [MailSummary], _ incoming: [MailSummary]) -> [MailSummary] {
        var byID = Dictionary(existing.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for row in incoming { byID[row.id] = row }
        return byID.values.sorted { ($0.date ?? .distantPast, $0.id) > ($1.date ?? .distantPast, $1.id) }
    }
}

extension MailSummary {
    /// The Coremail folder number in the server key (`"<fid>:<mid>"`).
    var serverFID: Int? {
        serverID?.split(separator: ":", maxSplits: 1).first.flatMap { Int($0) }
    }
}

extension MailFolder {
    /// Coremail folder number: `INBOX` is 1, nested folders end with their own number.
    var coremailFID: Int? {
        id == "INBOX" ? 1 : id.split(separator: "/").last.flatMap { Int($0) }
    }
}

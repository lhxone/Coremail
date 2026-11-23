import AppKit
import CoreServices
import Foundation
import UniformTypeIdentifiers

struct MailError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

struct Account: Codable, Equatable {
    var email = ""
    var username = ""
    var host = ""
    var displayName = ""
    var signature = ""

    // Keep the old port in the Keychain identifier so existing credentials remain accessible.
    private var credentialPort = 993

    private enum CodingKeys: String, CodingKey {
        case email, username, host, displayName, signature, credentialPort
    }

    private enum LegacyKeys: String, CodingKey {
        case imapHost, imapPort
    }

    init() {}

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let legacy = try decoder.container(keyedBy: LegacyKeys.self)
        email = try values.decodeIfPresent(String.self, forKey: .email) ?? ""
        username = try values.decodeIfPresent(String.self, forKey: .username) ?? ""
        host = try values.decodeIfPresent(String.self, forKey: .host)
            ?? legacy.decodeIfPresent(String.self, forKey: .imapHost) ?? host
        credentialPort = try values.decodeIfPresent(Int.self, forKey: .credentialPort)
            ?? legacy.decodeIfPresent(Int.self, forKey: .imapPort) ?? credentialPort
        displayName = try values.decodeIfPresent(String.self, forKey: .displayName) ?? ""
        signature = try values.decodeIfPresent(String.self, forKey: .signature) ?? ""
    }

    var login: String { username.isEmpty ? email : username }
    var keychainAccount: String { "\(login)@\(host):\(credentialPort)" }

    func validate() throws {
        guard MailAddress.isValid(email),
              host.range(of: #"\A[A-Za-z0-9][A-Za-z0-9.-]*\z"#, options: .regularExpression) != nil,
              !login.utf8.contains(where: { [0, 10, 13].contains($0) }) else {
            throw MailError("请填写有效的邮箱和服务器域名。")
        }
    }
}

struct MailAddress: Hashable, Codable {
    let name: String
    let email: String

    static func isValid(_ address: String) -> Bool {
        address.range(of: #"\A[A-Za-z0-9!#$%&'*+/=?^_`{|}~-]+(?:\.[A-Za-z0-9!#$%&'*+/=?^_`{|}~-]+)*@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+\z"#,
                      options: .regularExpression) != nil
    }

    static func parse(_ input: String) -> [MailAddress] {
        var tokens: [String] = []
        var token = ""
        var quoted = false
        var escaped = false
        var angle = false
        var comments = 0
        for character in input {
            if escaped {
                token.append(character)
                escaped = false
                continue
            }
            if character == "\\" && (quoted || comments > 0) { escaped = true }
            if character == "\"" && comments == 0 { quoted.toggle() }
            if !quoted {
                if character == "(" { comments += 1 }
                if character == ")" && comments > 0 { comments -= 1 }
                if comments == 0 {
                    if character == "<" { angle = true }
                    if character == ">" { angle = false }
                    if !angle && [",", ";", "\n", "，", "；"].contains(character) {
                        tokens.append(token)
                        token = ""
                        continue
                    }
                }
            }
            token.append(character)
        }
        tokens.append(token)
        return tokens.compactMap { raw in
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            if let open = trimmed.lastIndex(of: "<"), let close = trimmed.lastIndex(of: ">"), open < close {
                let name = trimmed[..<open].trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                return MailAddress(name: MIME.decodeWords(name), email: String(trimmed[trimmed.index(after: open)..<close]))
            }
            let bare = trimmed.components(separatedBy: " (").first ?? trimmed
            return MailAddress(name: "", email: bare)
        }
    }

    static func unique(_ addresses: [MailAddress], excluding: String? = nil) -> [MailAddress] {
        var seen = Set([excluding?.lowercased()].compactMap { $0 })
        return addresses.filter { seen.insert($0.email.lowercased()).inserted }
    }

    var display: String { name.isEmpty ? email : name }
    var full: String { name.isEmpty ? email : "\(name) <\(email)>" }

    static let collapsedCount = 5

    /// Reader header text: long lists are shortened to the first few names plus a count.
    static func summary(_ list: [MailAddress], expanded: Bool) -> String {
        let names = list.map(\.display)
        guard !expanded, names.count > collapsedCount else { return names.joined(separator: "、") }
        return names.prefix(collapsedCount).joined(separator: "、") + " 等 \(names.count) 人"
    }

    var initials: String {
        let source = name.trimmingCharacters(in: .whitespaces).isEmpty
            ? String(email.split(separator: "@").first ?? "") : name
        guard let first = source.first(where: { $0.isLetter || $0.isNumber }) else { return "?" }
        if first.unicodeScalars.first.map({ $0.value >= 0x2E80 }) == true {
            // CJK names usually read best with the last one or two characters.
            let letters = source.filter { $0.unicodeScalars.first.map { $0.value >= 0x2E80 } == true }
            return String(letters.suffix(letters.count >= 3 ? 2 : letters.count))
        }
        let words = source.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        let picked = words.prefix(2).compactMap(\.first)
        return String(picked.isEmpty ? [first] : picked).uppercased()
    }
}

enum MailFolderRole: Int, CaseIterable, Codable {
    case inbox, drafts, sent, archive, junk, trash, flagged, all

    var title: String {
        switch self {
        case .inbox: return "收件箱"
        case .drafts: return "草稿箱"
        case .sent: return "已发送"
        case .archive: return "存档"
        case .junk: return "垃圾邮件"
        case .trash: return "已删除"
        case .flagged: return "旗标邮件"
        case .all: return "所有邮件"
        }
    }

    var icon: String {
        switch self {
        case .inbox: return "tray"
        case .drafts: return "doc"
        case .sent: return "paperplane"
        case .archive: return "archivebox"
        case .junk: return "xmark.bin"
        case .trash: return "trash"
        case .flagged: return "flag"
        case .all: return "envelope.stack"
        }
    }

    static func identify(id: String, name: String, delimiter: String?, flags: [String]) -> Self? {
        if id.caseInsensitiveCompare("INBOX") == .orderedSame { return .inbox }
        let special: [(Self, [String])] = [
            (.drafts, [#"\drafts"#]), (.sent, [#"\sent"#]), (.archive, [#"\archive"#]),
            (.junk, [#"\junk"#, #"\spam"#]), (.trash, [#"\trash"#]),
            (.flagged, [#"\flagged"#, #"\starred"#]), (.all, [#"\all"#, #"\allmail"#])
        ]
        if let explicit = special.first(where: { $0.1.contains(where: flags.contains) })?.0 { return explicit }
        if let delimiter, name.contains(delimiter) { return nil }
        switch name.lowercased() {
        case "drafts", "draft", "草稿", "草稿箱": return .drafts
        case "sent", "sent items", "sent messages", "已发送", "已寄邮件", "发件箱": return .sent
        case "archive", "archives", "归档", "存档": return .archive
        case "junk e-mail", "junk email", "junk", "spam", "垃圾邮件": return .junk
        case "trash", "deleted", "deleted items", "已删除", "废纸篓": return .trash
        default: return nil
        }
    }
}

struct MailFolder: Identifiable, Hashable, Codable {
    let id: String
    let name: String
    let delimiter: String?
    let role: MailFolderRole?
    private let nameIsLeaf: Bool

    init(id: String, name: String, delimiter: String? = nil, role: MailFolderRole? = nil, nameIsLeaf: Bool = false) {
        self.id = id
        self.name = name
        self.delimiter = delimiter
        self.nameIsLeaf = nameIsLeaf
        self.role = nameIsLeaf ? role : role ?? MailFolderRole.identify(id: id, name: name, delimiter: delimiter, flags: [])
    }

    var display: String { role?.title ?? leafName }
    var icon: String { role?.icon ?? "folder" }
    var leafName: String {
        guard !nameIsLeaf, let delimiter else { return name }
        return name.components(separatedBy: delimiter).last ?? name
    }

    var hierarchyID: String {
        guard let delimiter, let first = id.range(of: delimiter) else { return role == .inbox ? "INBOX" : id }
        return id[..<first.lowerBound].uppercased() == "INBOX" ? "INBOX" + id[first.lowerBound...] : id
    }

    var parentID: String? {
        guard let delimiter, let range = hierarchyID.range(of: delimiter, options: .backwards), range.lowerBound > hierarchyID.startIndex
        else { return nil }
        return String(hierarchyID[..<range.lowerBound])
    }
}

struct FolderOutline {
    struct Row: Identifiable, Equatable {
        let id: String
        let name: String
        let icon: String
        let folder: MailFolder?
        let depth: Int
        let hasChildren: Bool
    }

    static func rows(_ folders: [MailFolder], collapsed: Set<String>) -> [Row] {
        var nodes: [String: MailFolder] = [:]
        var available: [String: MailFolder] = [:]
        for folder in folders { available[folder.hierarchyID] = folder }
        nodes = available
        for folder in folders {
            var current = folder
            while let parent = current.parentID, nodes[parent] == nil {
                current = MailFolder(id: parent, name: parent, delimiter: current.delimiter)
                nodes[parent] = current
            }
        }

        var children: [String?: [MailFolder]] = [:]
        for folder in nodes.values { children[folder.parentID, default: []].append(folder) }

        var output: [Row] = []
        func visit(parent: String?, depth: Int) {
            for node in (children[parent] ?? []).sorted(by: before) {
                let id = node.hierarchyID
                let hasChildren = !(children[id]?.isEmpty ?? true)
                output.append(Row(id: id, name: node.display, icon: node.icon, folder: available[id],
                                  depth: depth, hasChildren: hasChildren))
                if hasChildren && !collapsed.contains(id) { visit(parent: id, depth: depth + 1) }
            }
        }
        visit(parent: nil, depth: 0)
        return output
    }

    private static func before(_ left: MailFolder, _ right: MailFolder) -> Bool {
        let l = left.role?.rawValue ?? Int.max
        let r = right.role?.rawValue ?? Int.max
        if l != r { return l < r }
        let order = left.display.localizedStandardCompare(right.display)
        return order == .orderedSame ? left.id < right.id : order == .orderedAscending
    }
}

struct MailSummary: Identifiable, Hashable, Codable {
    var id: UInt32
    var serverID: String?
    var headerMessageID: String?
    let subject: String
    let sender: MailAddress?
    let date: Date?
    var from: String { sender?.display ?? "" }
    var unread: Bool
    var flagged = false
    var hasAttachment = false
    var recipients: [MailAddress] = []
    /// Coremail folder number the message is in. The prefix of `serverID` is not a folder.
    var fid: Int?

    init(id: UInt32, subject: String, sender: MailAddress?, date: Date?, unread: Bool,
         flagged: Bool = false, hasAttachment: Bool = false, recipients: [MailAddress] = [], serverID: String? = nil,
         headerMessageID: String? = nil, fid: Int? = nil) {
        self.id = id
        self.serverID = serverID
        self.headerMessageID = headerMessageID
        self.subject = subject
        self.sender = sender
        self.date = date
        self.unread = unread
        self.flagged = flagged
        self.hasAttachment = hasAttachment
        self.recipients = recipients
        self.fid = fid
    }

}

enum MailDate {
    enum Group: String, CaseIterable, Codable {
        case today = "今天"
        case yesterday = "昨天"
        case thisWeek = "本周"
        case lastWeek = "上周"
        case thisMonth = "本月"
        case earlier = "更早"
    }

    static func groups(_ rows: [MailSummary], now: Date = Date(), calendar: Calendar = .current) -> [Group: [MailSummary]] {
        var calendar = calendar
        calendar.firstWeekday = 2
        let today = calendar.startOfDay(for: now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today) ?? today
        let week = calendar.dateInterval(of: .weekOfYear, for: today)?.start ?? today
        let lastWeek = calendar.date(byAdding: .weekOfYear, value: -1, to: week) ?? week
        let month = calendar.dateInterval(of: .month, for: today)?.start ?? today
        return Dictionary(grouping: rows) { row in
            guard let date = row.date else { return .earlier }
            if date >= today { return .today }
            if date >= yesterday { return .yesterday }
            if date >= week { return .thisWeek }
            if date >= lastWeek { return .lastWeek }
            return date >= month ? .thisMonth : .earlier
        }
    }

    static func short(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) {
            return date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) { return "昨天" }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 99
        if (0..<7).contains(days) { return date.formatted(.dateTime.weekday(.wide)) }
        if calendar.isDate(date, equalTo: now, toGranularity: .year) {
            return date.formatted(.dateTime.month(.defaultDigits).day())
        }
        return date.formatted(.dateTime.year().month(.twoDigits).day(.twoDigits))
    }
}

enum MailAction {
    case markRead(Bool), flag(Bool), delete, move(MailFolder)
}

struct Attachment: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let type: String
    let data: Data

    init(name: String, type: String, data: Data) {
        self.name = name
        self.type = type
        self.data = data
    }

    init(file: URL) throws {
        let values = try file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, let length = values.fileSize, length <= 24 * 1024 * 1024 else {
            throw MailError("请选择 24 MB 以内的文件。")
        }
        self.init(name: file.lastPathComponent,
                  type: UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream",
                  data: try Data(contentsOf: file))
    }

    /// Bidi controls let "invoice\u{202E}fdp.command" display as a PDF; control and format
    /// characters are invisible in Finder and in the attachment chip.
    private static let hiddenScalars = CharacterSet.controlCharacters
        .union(CharacterSet(charactersIn: "\u{061C}\u{200B}\u{200E}\u{200F}\u{202A}\u{202B}\u{202C}\u{202D}\u{202E}"
                            + "\u{2066}\u{2067}\u{2068}\u{2069}\u{FEFF}"))

    var safeName: String {
        let last = name.components(separatedBy: CharacterSet(charactersIn: "/\\:")).last ?? ""
        var scalars = String.UnicodeScalarView()
        scalars.append(contentsOf: last.unicodeScalars.filter { !Self.hiddenScalars.contains($0) })
        let cleaned = String(scalars).trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty || cleaned == "." || cleaned == ".." ? "附件" : cleaned
    }

    /// Marks a file written from mail as downloaded, so Gatekeeper checks it before it runs.
    static func quarantine(_ url: URL, sender: String? = nil) throws {
        var properties: [String: Any] = [
            kLSQuarantineAgentNameKey as String: "Coremail",
            kLSQuarantineTypeKey as String: kLSQuarantineTypeOtherDownload as String
        ]
        if let sender, !sender.isEmpty { properties[kLSQuarantineOriginURLKey as String] = "mailto:" + sender }
        var values = URLResourceValues()
        values.quarantineProperties = properties
        var target = url
        try target.setResourceValues(values)
    }

    var calendar: Bool { type == "text/calendar" || name.lowercased().hasSuffix(".ics") }
}

struct InlineImage {
    let id: UUID
    let contentID: String?
    let location: String?
    let mediaType: String
    let name: String?
    let bytes: Data

    init(contentID: String?, location: String?, mediaType: String, name: String?, bytes: Data) {
        id = UUID()
        self.contentID = contentID
        self.location = location
        self.mediaType = mediaType
        self.name = name
        self.bytes = bytes
    }

    var url: String { "coremail-image://inline/" + id.uuidString }
}

struct Message {
    var headers: [String: String]
    var plain: String?
    var html: String?
    var htmlLocation: String?
    var attachments: [Attachment]
    var inlineImages: [InlineImage] = []
    var encrypted = false
    var signature: String?
    var securityError: String?
    /// Set when only some parts are signed or encrypted.
    var securityWarning: String?
    var raw: Data

    var relayableAttachments: [Attachment] {
        let images = inlineImages.enumerated().compactMap { index, image -> Attachment? in
            if attachments.contains(where: { $0.type == image.mediaType && $0.data == image.bytes }) { return nil }
            let ext = UTType(mimeType: image.mediaType)?.preferredFilenameExtension ?? "img"
            return Attachment(name: image.name ?? "内嵌图片-\(index + 1).\(ext)", type: image.mediaType, data: image.bytes)
        }
        return attachments + images
    }

    var subject: String { MIME.decodeWords(headers["subject"] ?? "") }
    var from: [MailAddress] { MailAddress.parse(headers["from"] ?? "") }
    var to: [MailAddress] { MailAddress.parse(headers["to"] ?? "") }
    var cc: [MailAddress] { MailAddress.parse(headers["cc"] ?? "") }
    var bcc: [MailAddress] { MailAddress.parse(headers["bcc"] ?? "") }
    var date: Date? { MIME.date(headers["date"]) }
}

enum ComposeAction {
    case reply, replyAll, replyWithAttachments, forward, forwardAsAttachment, editDraft

    var title: String {
        switch self {
        case .reply: return "回复"
        case .replyAll: return "回复全部"
        case .replyWithAttachments: return "回复全部并带附件"
        case .forward: return "转发"
        case .forwardAsAttachment: return "作为附件转发"
        case .editDraft: return "编辑草稿"
        }
    }
}

enum RecipientField: String, CaseIterable, Hashable {
    case to, cc, bcc

    var label: String {
        switch self {
        case .to: return "收件人"
        case .cc: return "抄送"
        case .bcc: return "密送"
        }
    }
}

struct Draft: Identifiable {
    let id = UUID()
    let composeAction: ComposeAction?
    var composeTitle: String { composeAction?.title ?? "新邮件" }
    var to: [MailAddress] = []
    var cc: [MailAddress] = []
    var bcc: [MailAddress] = []
    var pendingRecipients: [RecipientField: String] = [:]

    subscript(field: RecipientField) -> [MailAddress] {
        get {
            switch field {
            case .to: return to
            case .cc: return cc
            case .bcc: return bcc
            }
        }
        set {
            switch field {
            case .to: to = newValue
            case .cc: cc = newValue
            case .bcc: bcc = newValue
            }
        }
    }

    mutating func addRecipients(_ addresses: [MailAddress], to field: RecipientField) throws {
        guard !addresses.isEmpty, addresses.allSatisfy({ MailAddress.isValid($0.email) }) else {
            throw MailError("请在「\(field.label)」选择联系人或填写有效的邮箱地址。")
        }
        self[field] = MailAddress.unique(self[field] + addresses)
        pendingRecipients[field] = nil
    }

    mutating func commitPendingRecipients() throws {
        var updated = self
        for field in RecipientField.allCases {
            let input = pendingRecipients[field, default: ""].trimmingCharacters(in: .whitespacesAndNewlines)
            if !input.isEmpty { try updated.addRecipients(MailAddress.parse(input), to: field) }
        }
        self = updated
    }

    mutating func includeMention(_ contact: ContactChoice) {
        guard MailAddress.isValid(contact.email),
              !(to + cc + bcc).contains(where: { $0.email.caseInsensitiveCompare(contact.email) == .orderedSame }) else { return }
        to.append(MailAddress(name: contact.name, email: contact.email))
    }
    var subject = ""
    private var plainBody = ""
    var body: String {
        get { (richBody as? NSTextStorage)?.string ?? plainBody }
        set { plainBody = newValue }
    }
    var richBody: NSAttributedString?

    /// Freeze the editable document before handing it to an asynchronous transport.
    func bodySnapshot() -> Self {
        guard let storage = richBody as? NSTextStorage else { return self }
        var snapshot = self
        snapshot.richBody = NSAttributedString(attributedString: storage)
        snapshot.body = snapshot.richBody?.string ?? ""
        return snapshot
    }
    var signatureID: UUID?
    var htmlBody: String?
    var quote: ReplyQuote?
    var attachments: [Attachment] = []
    var encrypt = false
    var sign = false
    var inReplyTo: String?
    var references: String?
    /// Server draft that this draft replaces once it is sent or saved again.
    var replacing: (folder: String, uid: UInt32)?

    init(signature: String = "") {
        composeAction = nil
        if !signature.isEmpty { body = Self.signatureBlock(signature) }
    }

    static func signatureBlock(_ signature: String) -> String {
        "\n\n" + signature
    }

    init(draft message: Message, replacing source: (folder: String, uid: UInt32)?) {
        composeAction = .editDraft
        to = message.to.filter { MailAddress.isValid($0.email) }
        cc = message.cc.filter { MailAddress.isValid($0.email) }
        bcc = message.bcc.filter { MailAddress.isValid($0.email) }
        subject = message.subject
        body = message.plain ?? message.html.map(MIME.plainText) ?? ""
        attachments = message.relayableAttachments
        inReplyTo = message.headers["in-reply-to"]
        references = message.headers["references"]
        replacing = source
    }

    init(message: Message, account: Account, action: ComposeAction) {
        composeAction = action
        if !account.signature.isEmpty { body = Self.signatureBlock(account.signature) }
        let forwarding = action == .forward || action == .forwardAsAttachment
        let prefix = forwarding ? "Fwd:" : "Re:"
        subject = message.subject.lowercased().hasPrefix(prefix.lowercased())
            ? message.subject : "\(prefix) \(message.subject)"
        if !forwarding {
            let replyTo = MailAddress.parse(message.headers["reply-to"] ?? message.headers["from"] ?? "")
            let originalTo = MailAddress.parse(message.headers["to"] ?? "")
            let targets = replyTo.contains { $0.email.caseInsensitiveCompare(account.email) != .orderedSame }
                ? replyTo : originalTo
            to = MailAddress.unique(targets, excluding: account.email)
            if action != .reply {
                cc = MailAddress.unique(targets + originalTo + MailAddress.parse(message.headers["cc"] ?? ""),
                                        excluding: account.email)
                    .filter { candidate in !targets.contains { $0.email.caseInsensitiveCompare(candidate.email) == .orderedSame } }
            }
            inReplyTo = message.headers["message-id"]
            references = [message.headers["references"], inReplyTo].compactMap { $0 }.joined(separator: " ")
        }
        let original = message.plain ?? message.html.map(MIME.plainText) ?? ""
        let heading = ReplyQuote.originalHeading(for: message)
        switch action {
        case .forwardAsAttachment:
            attachments = [Attachment(name: "原始邮件.eml", type: "message/rfc822", data: message.raw)]
        case .forward:
            attachments = message.attachments.filter { item in !message.inlineImages.contains { $0.bytes == item.data && $0.mediaType == item.type } }
            quote = ReplyQuote(heading: heading, plain: original, sourceHTML: message.html, images: message.inlineImages, sourceLocation: message.htmlLocation)
        default:
            if action == .replyWithAttachments { attachments = message.attachments.filter { item in !message.inlineImages.contains { $0.bytes == item.data && $0.mediaType == item.type } } }
            quote = ReplyQuote(heading: heading, plain: original, sourceHTML: message.html, images: message.inlineImages, sourceLocation: message.htmlLocation)
        }
        encrypt = message.encrypted && action != .forwardAsAttachment
    }
}

enum AppSection: String, CaseIterable, Identifiable {
    case mail, calendar, contacts
    var id: Self { self }
    var title: String {
        switch self {
        case .mail: return "邮件"
        case .calendar: return "日历"
        case .contacts: return "联系人"
        }
    }
    var icon: String {
        switch self {
        case .mail: return "envelope"
        case .calendar: return "calendar"
        case .contacts: return "person.2"
        }
    }
}

struct RecentContact: Codable, Identifiable, Hashable {
    var id: String { email.lowercased() }
    var name: String
    var email: String
    var count: Int
    var lastSeen: Date
    var seenIDs: [UInt32] = []

    var address: MailAddress { MailAddress(name: name, email: email) }
    /// Frequent and recent correspondents first.
    var rank: Double {
        let days = max(0, Date().timeIntervalSince(lastSeen) / 86_400)
        return Double(min(count, 50)) / (1 + days / 30)
    }
}

import AppKit
import UniformTypeIdentifiers

struct MailSignature: Codable, Identifiable {
    let id: UUID
    var name: String
    var plain: String
    var rtf: Data?
    var pictures: [Picture] = []

    struct Picture: Codable {
        let marker: String
        let name: String?
        let mediaType: String
        let bytes: Data
        let width: Double
        let height: Double
    }

    init(id: UUID = UUID(), name: String, plain: String) {
        self.id = id
        self.name = name
        self.plain = plain
    }

    init(id: UUID, name: String, document: NSAttributedString) throws {
        self.init(id: id, name: name, plain: document.string)
        let copy = NSMutableAttributedString(attributedString: document)
        var replacements: [(NSRange, Picture)] = []
        let whole = NSRange(location: 0, length: copy.length)
        copy.enumerateAttribute(.attachment, in: whole) { value, range, _ in
            if let image = value as? MailImageAttachment {
                replacements.append((range, Picture(marker: "COREMAILSIGNATURE" + UUID().uuidString + "END",
                    name: image.resource.name, mediaType: image.resource.mediaType, bytes: image.resource.bytes,
                    width: image.displaySize.width, height: image.displaySize.height)))
            }
        }
        guard replacements.reduce(0, { $0 + $1.1.bytes.count }) <= 12 * 1024 * 1024 else {
            throw MailError("单条签名的图片合计不能超过 12 MB。")
        }
        for (range, picture) in replacements.reversed() {
            var attributes = copy.attributes(at: range.location, effectiveRange: nil)
            attributes.removeValue(forKey: .attachment)
            copy.replaceCharacters(in: range, with: NSAttributedString(string: picture.marker, attributes: attributes))
        }
        // Adaptive system colors are restored by RichEditor when the signature is opened.
        var defaultColors: [NSRange] = []
        copy.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: copy.length)) { color, range, _ in
            if let color = color as? NSColor, color == .labelColor || color == .textColor { defaultColors.append(range) }
        }
        for range in defaultColors { copy.removeAttribute(.foregroundColor, range: range) }
        rtf = try copy.data(from: NSRange(location: 0, length: copy.length), documentAttributes: [
            .documentType: NSAttributedString.DocumentType.rtf
        ])
        pictures = replacements.map(\.1)
    }

    func document() -> NSAttributedString {
        guard let rtf, let text = try? NSMutableAttributedString(data: rtf,
            options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil) else {
            return NSAttributedString(string: plain)
        }
        for picture in pictures {
            let range = (text.string as NSString).range(of: picture.marker)
            guard range.location != NSNotFound else { continue }
            let image = InlineImage(contentID: nil, location: nil, mediaType: picture.mediaType,
                                    name: picture.name, bytes: picture.bytes)
            let attachment = MailImageAttachment(resource: image, width: picture.width, height: picture.height)
            let replacement = NSMutableAttributedString(attachment: attachment)
            for (key, value) in text.attributes(at: range.location, effectiveRange: nil) where key != .attachment {
                replacement.addAttribute(key, value: value, range: NSRange(location: 0, length: replacement.length))
            }
            text.replaceCharacters(in: range, with: replacement)
        }
        return text
    }

    func block() -> NSAttributedString {
        let text = NSMutableAttributedString(string: Draft.signatureBlock(""))
        text.append(document())
        text.addAttribute(.mailSignature, value: id.uuidString, range: NSRange(location: 0, length: text.length))
        return text
    }
}

struct MailSignatureLibrary: Codable {
    var entries: [MailSignature] = []
    var defaultID: UUID?

    var defaultSignature: MailSignature? { entries.first { $0.id == defaultID } }

    private static func file(for account: Account) -> URL {
        MailMetadataFile(account: account, directory: MailStorage.signatures).url
    }

    static func load(for account: Account) throws -> Self {
        do {
            return try JSONDecoder().decode(Self.self, from: Data(contentsOf: file(for: account)))
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            guard !account.signature.isEmpty else { return Self() }
            let original = MailSignature(name: "原有签名", plain: account.signature)
            return Self(entries: [original], defaultID: original.id)
        }
    }

    func save(for account: Account) throws {
        let url = Self.file(for: account)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }
}

extension NSAttributedString.Key {
    static let mailSignature = Self("Coremail.MailSignature")
    static let mailQuote = Self("Coremail.MailQuote")
}

import AppKit

/// Keeps the original encoded bytes alongside the editor's image representation.
final class MailImageAttachment: NSTextAttachment {
    let resource: InlineImage
    let displaySize: NSSize

    static func contentID(for image: InlineImage) -> String { image.id.uuidString + "@coremail.local" }

    init(resource: InlineImage, width: Double = 0, height: Double = 0) {
        self.resource = resource
        let image = NSImage(data: resource.bytes)
        let natural = image?.size ?? NSSize(width: 100, height: 100)
        var size = natural
        if width > 0 { size.width = width; size.height = height > 0 ? height : width * natural.height / max(1, natural.width) }
        else if height > 0 { size.height = height; size.width = height * natural.width / max(1, natural.height) }
        let scale = min(1, 600 / max(1, size.width))
        displaySize = NSSize(width: size.width * scale, height: size.height * scale)
        super.init(data: resource.bytes, ofType: resource.mediaType)
        if let image {
            image.size = displaySize
            attachmentCell = NSTextAttachmentCell(imageCell: image)
        }
    }

    var htmlTag: String {
        "<img src=\"cid:\(Self.contentID(for: resource))\" width=\"\(displaySize.width)\" height=\"\(displaySize.height)\" style=\"width:\(displaySize.width)px;height:\(displaySize.height)px\">"
    }

    static func replaceMarkers(in html: String, resource: InlineImage) -> String {
        let pattern = "COREMAILIMAGE" + resource.id.uuidString + "(?:SIZE([0-9.]+)X([0-9.]+))?END"
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return html }
        var result = html
        for match in expression.matches(in: html, range: NSRange(location: 0, length: (html as NSString).length)).reversed() {
            func number(_ index: Int) -> Double {
                guard match.range(at: index).location != NSNotFound else { return 0 }
                return Double((html as NSString).substring(with: match.range(at: index))) ?? 0
            }
            let attachment = MailImageAttachment(resource: resource, width: number(1), height: number(2))
            if let range = Range(match.range, in: result) { result.replaceSubrange(range, with: attachment.htmlTag) }
        }
        return result
    }

    /// Turns CID images in an editable server draft back into native attachments.
    static func editableDraft(_ html: String, images: [InlineImage]) throws -> NSMutableAttributedString {
        let tagPattern = #"(?i)<img\b[^>]*?\bsrc\s*=\s*["']cid:([^"']+)["'][^>]*>"#
        let tags = try NSRegularExpression(pattern: tagPattern)
        let source = html as NSString
        var marked = html
        var replacements: [(String, MailImageAttachment)] = []
        for match in tags.matches(in: html, range: NSRange(location: 0, length: source.length)).reversed() {
            let cid = source.substring(with: match.range(at: 1))
            guard let image = images.first(where: {
                $0.contentID?.trimmingCharacters(in: CharacterSet(charactersIn: "<>")).caseInsensitiveCompare(cid) == .orderedSame
            }), let range = Range(match.range, in: marked) else { continue }
            let tag = source.substring(with: match.range)
            func dimension(_ name: String) -> Double {
                let pattern = #"(?i)\s"# + name + #"\s*=\s*["']?([0-9]+(?:\.[0-9]+)?)"#
                guard let result = tag.range(of: pattern, options: .regularExpression),
                      let value = tag[result].firstIndex(where: \.isNumber) else { return 0 }
                return Double(tag[value..<result.upperBound]) ?? 0
            }
            let marker = "COREMAILDRAFTIMAGE" + UUID().uuidString + "END"
            replacements.append((marker, MailImageAttachment(resource: image, width: dimension("width"),
                                                               height: dimension("height"))))
            marked.replaceSubrange(range, with: marker)
        }
        let document = try NSMutableAttributedString(data: Data(marked.utf8), options: [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue
        ], documentAttributes: nil)
        for (marker, attachment) in replacements {
            let range = (document.string as NSString).range(of: marker)
            guard range.location != NSNotFound else { continue }
            let replacement = NSMutableAttributedString(attachment: attachment)
            for (key, value) in document.attributes(at: range.location, effectiveRange: nil) where key != .attachment {
                replacement.addAttribute(key, value: value, range: NSRange(location: 0, length: replacement.length))
            }
            document.replaceCharacters(in: range, with: replacement)
        }
        return document
    }

    required init?(coder: NSCoder) { return nil }

    static func resources(in text: NSAttributedString?) -> [InlineImage] {
        guard let text else { return [] }
        var images: [InlineImage] = []
        text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.length)) { value, _, _ in
            if let attachment = value as? MailImageAttachment,
               !images.contains(where: { $0.id == attachment.resource.id }) {
                images.append(attachment.resource)
            }
        }
        return images
    }
}

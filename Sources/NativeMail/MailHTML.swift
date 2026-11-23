import Foundation

struct MailHTML {
    let id = UUID()
    let content: String
    let resources: [String: InlineImage]
    let hasRemoteImages: Bool

    private static let imageReference = try! NSRegularExpression(
        pattern: #"(?i)(?:\b(?:src|background|poster)\s*=\s*|\burl\(\s*)(?:"([^"]*)"|'([^']*)'|([^\s>"')]+))"#)
    private static let sourceSet = try! NSRegularExpression(pattern: #"(?i)\bsrcset\s*=\s*(?:"([^"]*)"|'([^']*)')"#)
    private static let sourceSetURL = try! NSRegularExpression(pattern: #"(?:^|,)\s*([^\s,]+)"#)

    init(html: String, images: [InlineImage], location: String? = nil) {
        let base = location.flatMap { URL(string: $0) }.flatMap { $0.scheme == nil ? nil : $0 }
        var byID: [String: InlineImage] = [:]
        var byLocation: [String: InlineImage] = [:]
        for image in images {
            if let id = image.contentID, byID[id] == nil { byID[id] = image }
            if let location = image.location, byLocation[location] == nil { byLocation[location] = image }
        }
        var files: [String: InlineImage] = [:]
        var remote = false
        var edits: [(Range<String.Index>, String)] = []

        func record(_ range: Range<String.Index>) {
            let source = String(html[range]).trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "&amp;", with: "&", options: [.caseInsensitive])
            let image: InlineImage?
            if source.lowercased().hasPrefix("cid:") {
                image = byID[Self.canonicalContentID(String(source.dropFirst(4)))]
            } else {
                let absolute = base.flatMap { URL(string: source, relativeTo: $0)?.absoluteURL.absoluteString }
                image = byLocation[source] ?? source.removingPercentEncoding.flatMap { byLocation[$0] }
                    ?? absolute.flatMap { byLocation[$0] }
            }
            if let image {
                edits.append((range, image.url))
                files[image.id.uuidString] = image
            } else {
                let lower = source.lowercased()
                if lower.hasPrefix("//") {
                    edits.append((range, "https:" + html[range].trimmingCharacters(in: .whitespacesAndNewlines)))
                    remote = true
                } else if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
                    remote = true
                }
            }
        }

        let range = NSRange(html.startIndex..., in: html)
        for match in Self.imageReference.matches(in: html, range: range) {
            if let captured = (1...3).compactMap({ Range(match.range(at: $0), in: html) }).first { record(captured) }
        }
        for match in Self.sourceSet.matches(in: html, range: range) {
            guard let set = (1...2).compactMap({ Range(match.range(at: $0), in: html) }).first,
                  !html[set].localizedCaseInsensitiveContains("data:") else { continue }
            for candidate in Self.sourceSetURL.matches(in: html, range: NSRange(set, in: html)) {
                if let item = Range(candidate.range(at: 1), in: html) { record(item) }
            }
        }

        var rewritten = ""
        var cursor = html.startIndex
        for (range, replacement) in edits.sorted(by: { $0.0.lowerBound < $1.0.lowerBound }) {
            guard range.lowerBound >= cursor else { continue }
            rewritten += html[cursor..<range.lowerBound]
            rewritten += replacement
            cursor = range.upperBound
        }
        rewritten += html[cursor...]
        content = rewritten
        resources = files
        hasRemoteImages = remote
    }

    static func canonicalContentID(_ value: String) -> String {
        let decoded = value.removingPercentEncoding ?? value
        return decoded.replacingOccurrences(of: "&lt;", with: "<", options: .caseInsensitive)
            .replacingOccurrences(of: "&gt;", with: ">", options: .caseInsensitive)
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "<>")))
            .lowercased()
    }

    static func isInlineImageType(_ mime: String) -> Bool {
        ["image/png", "image/jpeg", "image/pjpeg", "image/gif", "image/webp", "image/apng", "image/bmp",
         "image/x-ms-bmp", "image/tiff", "image/x-icon", "image/vnd.microsoft.icon", "image/avif",
         "image/heic", "image/heif", "image/svg+xml"].contains(mime)
    }
}

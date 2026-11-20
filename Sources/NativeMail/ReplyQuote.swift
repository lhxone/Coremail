import AppKit
import WebKit

struct ReplyQuote {
    let heading: String
    let plain: String
    let sourceHTML: String?
    var formattedHTML: String?
    var images: [InlineImage] = []
    var sourceLocation: String? = nil

    var plainBlock: String { heading + "\n" + plain }

    /// Coremail-style header block placed above the original text in replies and forwards.
    static func originalHeading(for message: Message) -> String {
        func list(_ addresses: [MailAddress]) -> String {
            addresses.map { $0.name.isEmpty ? $0.email : "\"\($0.name)\" <\($0.email)>" }.joined(separator: ",")
        }
        var lines = ["-----原始邮件-----", "发件人: " + list(message.from)]
        if let date = message.date {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
            lines.append("发送时间: " + formatter.string(from: date))
        }
        if !message.to.isEmpty { lines.append("收件人: " + list(message.to)) }
        if !message.cc.isEmpty { lines.append("抄送: " + list(message.cc)) }
        lines.append("主题: " + message.subject)
        return lines.joined(separator: "\n")
    }

    /// HTML for the quote as it appears inside the editable body: labels in bold, original behind a left bar.
    var editableHTML: String {
        let header = heading.components(separatedBy: "\n").map { line -> String in
            guard let colon = line.firstIndex(of: ":"), !line.hasPrefix("-") else { return Self.escape(line) }
            return "<b>" + Self.escape(String(line[...colon])) + "</b>" + Self.escape(String(line[line.index(after: colon)...]))
        }.joined(separator: "<br>")
        let original = formattedHTML ?? "<div style=\"white-space:pre-wrap\">\(Self.escape(plain))</div>"
        return """
            <html><body style="font-family:-apple-system,'PingFang SC','Helvetica Neue',sans-serif;font-size:13px">
            <div>\(header)<br><br>\(original)</div>
            </body></html>
            """
    }

    var htmlBlock: String {
        var original = formattedHTML ?? "<div style=\"white-space:pre-wrap\">\(Self.escape(plain))</div>"
        for image in images {
            original = MailImageAttachment.replaceMarkers(in: original, resource: image)
        }
        return """
            <div style="margin-top:16px">\(Self.escape(heading).replacingOccurrences(of: "\n", with: "<br>"))</div>
            <blockquote style="margin:8px 0 0;padding-left:12px;border-left:2px solid #b0b5bd">\(original)</blockquote>
            """
    }

    static func marker(for image: InlineImage) -> String { "COREMAILIMAGE" + image.id.uuidString + "END" }

    @MainActor
    func editorDocument() throws -> NSMutableAttributedString {
        let document = try NSMutableAttributedString(data: Data(editableHTML.utf8), options: [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue
        ], documentAttributes: nil)
        for image in images {
            let pattern = "COREMAILIMAGE" + image.id.uuidString + "(?:SIZE([0-9.]+)X([0-9.]+))?END"
            let expression = try NSRegularExpression(pattern: pattern)
            let matches = expression.matches(in: document.string, range: NSRange(location: 0, length: document.length))
            for match in matches.reversed() {
                func number(_ index: Int) -> Double {
                    guard match.range(at: index).location != NSNotFound else { return 0 }
                    return Double((document.string as NSString).substring(with: match.range(at: index))) ?? 0
                }
                let attachment = MailImageAttachment(resource: image, width: number(1), height: number(2))
                let attributes = document.attributes(at: match.range.location, effectiveRange: nil)
                let replacement = NSMutableAttributedString(attachment: attachment)
                for (key, value) in attributes where key != .attachment {
                    replacement.addAttribute(key, value: value, range: NSRange(location: 0, length: replacement.length))
                }
                document.replaceCharacters(in: match.range, with: replacement)
            }
        }
        return document
    }

    /// Use a real table cell as the outer block: AppKit asks every enclosing
    /// block for its table when drawing imported HTML tables.
    @MainActor
    static func addQuoteBorder(to original: NSMutableAttributedString) {
        let table = NSTextTable()
        table.numberOfColumns = 1
        let bar = NSTextTableBlock(table: table, startingRow: 0, rowSpan: 1,
                                   startingColumn: 0, columnSpan: 1)
        bar.setWidth(2, type: .absoluteValueType, for: .border, edge: .minX)
        bar.setBorderColor(NSColor(srgbRed: 0.69, green: 0.71, blue: 0.74, alpha: 1), for: .minX)
        bar.setWidth(10, type: .absoluteValueType, for: .padding, edge: .minX)
        bar.setContentWidth(100, type: .percentageValueType)
        var styles: [(NSRange, NSParagraphStyle)] = []
        original.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: original.length)) { value, range, _ in
            let style = (value as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
            style.textBlocks = [bar] + style.textBlocks
            styles.append((range, style))
        }
        for (range, style) in styles { original.addAttribute(.paragraphStyle, value: style, range: range) }
    }

    static func append(_ quote: String, to html: String) -> String {
        guard let close = html.range(of: "</body>", options: [.caseInsensitive, .backwards]) else { return html + quote }
        return html.replacingCharacters(in: close, with: quote + "</body>")
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    @MainActor
    static func format(_ html: String, images: [InlineImage] = [], location: String? = nil) async throws -> String? {
        guard html.utf8.count <= 1_000_000 else { return nil }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let web = WKWebView(frame: .zero, configuration: configuration)
        let resolved = MailHTML(html: html, images: images, location: location)
        let markers = Dictionary(uniqueKeysWithValues: resolved.resources.values.map { ($0.url, Self.marker(for: $0)) })
        let naturalWidths = Dictionary(uniqueKeysWithValues: resolved.resources.values.map { ($0.url, NSImage(data: $0.bytes)?.size.width ?? 0) })
        return try await web.callAsyncJavaScript(cleanHTML, arguments: ["html": resolved.content, "images": markers, "naturalWidths": naturalWidths], in: nil,
                                                  contentWorld: .defaultClient) as? String
    }

    // Template contents stay inert. Build a new fragment with approved tags and
    // inline values only, so the outgoing quote contains no active or remote resources.
    private static let cleanHTML = #"""
        const source = document.createElement("template");
        source.innerHTML = html;
        const sizingRoot = source.content;
        """# + ImageSizing.javascript + #"""
        const result = document.createElement("div");
        const keep = new Set(("P DIV SPAN SECTION ARTICLE HEADER FOOTER BR HR B STRONG I EM U S DEL INS SUPER SUB SUP " +
            "SMALL BIG FONT H1 H2 H3 H4 H5 H6 BLOCKQUOTE PRE CODE UL OL LI DL DT DD TABLE CAPTION COLGROUP COL " +
            "THEAD TBODY TFOOT TR TD TH A CENTER").split(" "));
        const omit = new Set("SCRIPT STYLE META LINK TITLE BASE OBJECT EMBED IFRAME VIDEO AUDIO SVG MATH NOSCRIPT TEMPLATE".split(" "));
        const styleNames = ("color background-color font-family font-size font-weight font-style text-decoration text-align " +
            "white-space line-height margin margin-left margin-right margin-top margin-bottom padding padding-left padding-right " +
            "padding-top padding-bottom border border-color border-style border-width border-collapse vertical-align").split(" ");
        let budget = 18000;

        function copy(node, parent, depth) {
            if (depth > 80 || --budget < 0) throw Error("Quote too large");
            if (node.nodeType === Node.TEXT_NODE) {
                parent.append(document.createTextNode(node.data));
                return;
            }
            if (node.nodeType !== Node.ELEMENT_NODE || omit.has(node.tagName)) return;
            const tag = node.tagName;
            if (tag === "IMG") {
                const marker = images[node.getAttribute("src")];
                if (marker) {
                    const [width, height] = imageDimensions(node, naturalWidths[node.getAttribute("src")] || 0);
                    const sized = marker.replace(/END$/, `SIZE${width.toFixed(3)}X${height.toFixed(3)}END`);
                    parent.append(document.createTextNode(sized));
                    return;
                }
                const alt = node.getAttribute("alt");
                if (alt) parent.append(document.createTextNode(alt));
                return;
            }
            let target = parent;
            if (keep.has(tag)) {
                target = document.createElement(tag.toLowerCase());
                for (const property of styleNames) {
                    const value = node.style.getPropertyValue(property);
                    if (value && value.length <= 180 && !/[();{}\\]/.test(value) && !/url|expression/i.test(value)) {
                        target.style.setProperty(property, value);
                    }
                    if (/^(?:rgb|rgba|hsl|hsla)\([0-9,.%\s]+\)$/.test(value) &&
                        (property === "color" || property === "background-color")) target.style.setProperty(property, value);
                }
                for (const key of ["align", "valign", "colspan", "rowspan", "width", "height", "start", "size", "face", "color", "bgcolor"]) {
                    const value = node.getAttribute(key);
                    if (value && value.length <= 110 && /^[\p{L}\p{N} .,#+%\-]+$/u.test(value)) target.setAttribute(key, value);
                }
                if (tag === "A") {
                    const href = node.getAttribute("href") || "";
                    if (/^(https?:|mailto:)/i.test(href)) target.setAttribute("href", href);
                }
                parent.append(target);
            }
            for (const child of node.childNodes) copy(child, target, depth + 1);
        }
        for (const child of source.content.childNodes) copy(child, result, 0);
        return result.innerHTML;
        """#
}

import Foundation
import CoreFoundation
import UniformTypeIdentifiers

enum MIME {
    private static let crlf = Data([13, 10])
    private static let encodedWord = try! NSRegularExpression(pattern: #"=\?([^?\s]+)\?([bBqQ])\?([^?]*)\?="#)

    static func headers(_ data: Data) -> [String: String] {
        splitEntity(data).0
    }

    private static func splitEntity(_ data: Data) -> ([String: String], Data) {
        let separator = data.range(of: Data([13, 10, 13, 10])) ?? data.range(of: Data([10, 10]))
        let headerEnd = separator?.lowerBound ?? data.endIndex
        // A slice shares storage with `data`; nested multiparts are not copied at each level.
        let body = separator.map { data[$0.upperBound...] } ?? Data()
        let source = String(decoding: data[..<headerEnd], as: UTF8.self)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: #"\n[ \t]+"#, with: " ", options: .regularExpression)
        var result: [String: String] = [:]
        for line in source.split(separator: "\n") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
            if result[name] == nil { result[name] = value }
        }
        return (result, body)
    }

    static func decodeWords(_ value: String) -> String {
        let matches = encodedWord.matches(in: value, range: NSRange(value.startIndex..., in: value))
        var output = ""
        var end = value.startIndex
        for match in matches {
            guard let whole = Range(match.range, in: value),
                  let charset = Range(match.range(at: 1), in: value),
                  let encoding = Range(match.range(at: 2), in: value),
                  let payload = Range(match.range(at: 3), in: value) else { continue }
            let gap = value[end..<whole.lowerBound]
            if end == value.startIndex || !gap.allSatisfy(\.isWhitespace) { output += gap }
            let raw = String(value[payload])
            let bytes = value[encoding].lowercased() == "b" ? Data(base64Encoded: raw) :
                quotedPrintable(Data(raw.replacingOccurrences(of: "_", with: " ").utf8))
            output += bytes.map { text($0, charset: String(value[charset])) } ?? String(value[whole])
            end = whole.upperBound
        }
        return output + value[end...]
    }

    static func text(_ data: Data, charset: String?) -> String {
        if let charset {
            let cf = CFStringConvertIANACharSetNameToEncoding(charset as CFString)
            if cf != kCFStringEncodingInvalidId,
               let decoded = String(data: data, encoding: String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))) {
                return decoded
            }
        }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
            ?? String(decoding: data, as: UTF8.self)
    }

    /// Configured once; DateFormatter is thread-safe as long as it is not mutated.
    private static let headerDateFormatters: [DateFormatter] = [
        "EEE, d MMM yyyy HH:mm:ss Z", "d MMM yyyy HH:mm:ss Z",
        "EEE, d MMM yyyy HH:mm Z", "d MMM yyyy HH:mm Z",
        "EEE, d MMM yy HH:mm:ss Z", "d MMM yy HH:mm:ss Z"
    ].map { format in
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = format
        return formatter
    }

    private static let outgoingDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return formatter
    }()

    static func date(_ header: String?) -> Date? {
        guard let header else { return nil }
        let clean = header.replacingOccurrences(of: #"\s*\([^)]*\)"#, with: "", options: .regularExpression)
        for formatter in headerDateFormatters {
            if let date = formatter.date(from: clean) { return date }
        }
        return nil
    }

    private static func quotedPrintable(_ data: Data) -> Data {
        let bytes = Array(data)
        var result = Data()
        var index = 0
        func hex(_ byte: UInt8) -> UInt8? {
            switch byte {
            case 48...57: return byte - 48
            case 65...70: return byte - 55
            case 97...102: return byte - 87
            default: return nil
            }
        }
        while index < bytes.count {
            if bytes[index] == 61, index + 1 < bytes.count {
                if bytes[index + 1] == 10 {
                    index += 2
                    continue
                }
                if index + 2 < bytes.count {
                    if bytes[index + 1] == 13, bytes[index + 2] == 10 {
                        index += 3
                        continue
                    }
                    if let high = hex(bytes[index + 1]), let low = hex(bytes[index + 2]) {
                        result.append(high * 16 + low)
                        index += 3
                        continue
                    }
                }
            }
            result.append(bytes[index])
            index += 1
        }
        return result
    }

    private static func parameters(_ header: String) -> (String, [String: String]) {
        var pieces: [String] = []
        var token = ""
        var quoted = false
        var escaped = false
        for character in header {
            if escaped {
                token.append(character)
                escaped = false
            } else if quoted && character == "\\" {
                escaped = true
            } else if character == "\"" {
                quoted.toggle()
            } else if !quoted && character == ";" {
                pieces.append(token)
                token = ""
            } else {
                token.append(character)
            }
        }
        pieces.append(token)
        let kind = pieces.removeFirst().trimmingCharacters(in: .whitespaces).lowercased()
        var values: [String: String] = [:]
        for piece in pieces {
            let pair = piece.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            if pair.count == 2 {
                let name = pair[0].trimmingCharacters(in: .whitespaces).lowercased()
                values[name] = pair[1].trimmingCharacters(in: .whitespaces)
            }
        }
        return (kind, values)
    }

    private static func parameter(_ name: String, from values: [String: String]) -> String? {
        var pieces: [(String, Bool)] = []
        for index in 0..<100 {
            let key = "\(name)*\(index)"
            if let encoded = values[key + "*"] { pieces.append((encoded, true)) }
            else if let raw = values[key] { pieces.append((raw, false)) }
            else { break }
        }
        if pieces.isEmpty, let single = values[name + "*"] { pieces = [(single, true)] }
        guard !pieces.isEmpty else { return values[name].map(decodeWords) }
        var charset: String?
        var data = Data()
        for (index, piece) in pieces.enumerated() {
            var value = piece.0
            if index == 0 && piece.1 {
                let fields = value.split(separator: "'", maxSplits: 2, omittingEmptySubsequences: false)
                if fields.count == 3 {
                    charset = String(fields[0])
                    value = String(fields[2])
                }
            }
            if piece.1 {
                let mapped = value.replacingOccurrences(of: "%", with: "=")
                data.append(quotedPrintable(Data(mapped.utf8)))
            } else {
                data.append(Data(value.utf8))
            }
        }
        return text(data, charset: charset)
    }

    private static func multipart(_ data: Data, boundary: String) -> [Data] {
        let marker = Data(("--" + boundary).utf8)
        guard !boundary.isEmpty else { return [] }
        var slices: [Data] = []
        var position = data.startIndex
        var partStart: Data.Index?
        while position < data.endIndex {
            guard let markerRange = data.range(of: marker, in: position..<data.endIndex) else { break }
            let begin = markerRange.lowerBound
            position = markerRange.upperBound
            guard begin == data.startIndex || data[data.index(before: begin)] == 10 else { continue }
            let end = data[position...].firstIndex(of: 10) ?? data.endIndex
            let tail = String(decoding: data[position..<end], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            guard tail.isEmpty || tail == "--" else { continue }
            if let partStart {
                var payloadEnd = begin
                if payloadEnd > partStart && data[data.index(before: payloadEnd)] == 10 { payloadEnd -= 1 }
                if payloadEnd > partStart && data[data.index(before: payloadEnd)] == 13 { payloadEnd -= 1 }
                slices.append(data[partStart..<payloadEnd])
            }
            if tail == "--" { return slices }
            position = end == data.endIndex ? end : data.index(after: end)
            partStart = position
        }
        if let partStart, partStart < data.endIndex { slices.append(data[partStart...]) }
        return slices
    }

    static func message(_ data: Data) -> Message {
        var result = Message(headers: headers(data), attachments: [], raw: data)
        var partial = PartialSecurity()
        collect(data, into: &result, depth: 0, covered: true, partial: &partial)
        // A signed or encrypted part next to unprotected parts says nothing about the
        // message the reader sees, so only a layer that wraps the whole body counts.
        var warnings: [String] = []
        if partial.signed && result.signature == nil { warnings.append("仅部分内容带有签名，签名不代表整封邮件") }
        if partial.encrypted && !result.encrypted { warnings.append("仅部分内容经过加密，其余内容未受保护") }
        if !warnings.isEmpty { result.securityWarning = warnings.joined(separator: "；") }
        result.readerPage = result.html.map {
            MailHTML(html: $0, images: result.inlineImages, location: result.htmlLocation)
        }
        classifyImageAttachments(in: &result)
        return result
    }

    private static func classifyImageAttachments(in message: inout Message) {
        guard !message.inlineImages.isEmpty else { return }
        let referenced = message.readerPage?.resources ?? [:]
        let explicitAttachments = message.attachments
        var inline: [InlineImage] = []
        for (index, image) in message.inlineImages.enumerated() {
            if referenced[image.id.uuidString] != nil {
                inline.append(image)
                continue
            }
            let ext = UTType(mimeType: image.mediaType)?.preferredFilenameExtension ?? "img"
            let locationName = image.location.flatMap { URL(string: $0)?.lastPathComponent }.flatMap {
                ($0 as NSString).pathExtension.isEmpty ? nil : $0
            }
            let declaredName = image.name ?? locationName
            // Explicit attachments have already been collected with their MIME name.
            if explicitAttachments.contains(where: {
                $0.name == (image.name ?? "附件") && $0.type == image.mediaType && $0.data == image.bytes
            }) { continue }
            message.attachments.append(Attachment(name: declaredName ?? "图片-\(index + 1).\(ext)",
                                                  type: image.mediaType, data: image.bytes))
        }
        message.inlineImages = inline
    }

    private struct PartialSecurity {
        var signed = false
        var encrypted = false
    }

    /// `covered` is true while `data` is the entire message body, or the sole content of a
    /// security layer that is itself covered.
    private static func collect(_ data: Data, into result: inout Message, depth: Int,
                                covered: Bool, partial: inout PartialSecurity) {
        guard depth < 20 else { return }
        let (headers, body) = splitEntity(data)
        let (kind, typeParams) = parameters(headers["content-type"] ?? "text/plain")
        let (disposition, dispositionParams) = parameters(headers["content-disposition"] ?? "")
        if kind.hasPrefix("multipart/"), let boundary = typeParams["boundary"] {
            let parts = multipart(body, boundary: boundary)
            if kind == "multipart/signed", parts.count == 2 {
                let (_, signature) = splitEntity(parts[1])
                if covered {
                    if let signature = Data(base64Encoded: signature, options: .ignoreUnknownCharacters) {
                        result.signature = SMIME.verify(signature, detached: parts[0], sender: result.from.first?.email)
                    } else {
                        result.signature = "签名验证失败或证书不受信任"
                    }
                } else {
                    partial.signed = true
                }
                collect(parts[0], into: &result, depth: depth + 1, covered: covered, partial: &partial)
            } else {
                for part in parts { collect(part, into: &result, depth: depth + 1, covered: false, partial: &partial) }
            }
            return
        }

        let decoded: Data?
        switch headers["content-transfer-encoding"]?.lowercased() {
        case "base64": decoded = Data(base64Encoded: body, options: .ignoreUnknownCharacters)
        case "quoted-printable": decoded = quotedPrintable(body)
        default: decoded = Data(body) // Detach leaf content from the whole raw message.
        }
        guard let decoded else { return }

        if ["application/pkcs7-mime", "application/x-pkcs7-mime"].contains(kind) {
            let enveloped = typeParams["smime-type"]?.lowercased() != "signed-data"
            if covered { result.encrypted = result.encrypted || enveloped }
            else if enveloped { partial.encrypted = true }
            do {
                let content = try SMIME.decode(decoded, sender: result.from.first?.email)
                if covered {
                    result.encrypted = result.encrypted || content.encrypted
                    if let signature = content.signature { result.signature = signature }
                } else {
                    partial.encrypted = partial.encrypted || content.encrypted
                    partial.signed = partial.signed || content.signature != nil
                }
                collect(content.body, into: &result, depth: depth + 1, covered: covered, partial: &partial)
            } catch {
                result.securityError = error.localizedDescription
                result.attachments.append(Attachment(name: "smime.p7m", type: kind, data: decoded))
            }
            return
        }

        let filename = parameter("filename", from: dispositionParams) ?? parameter("name", from: typeParams)
        if MailHTML.isInlineImageType(kind) {
            let contentID = headers["content-id"].map(MailHTML.canonicalContentID)
            let location = headers["content-location"]
            if contentID?.isEmpty == false || location?.isEmpty == false {
                result.inlineImages.append(InlineImage(contentID: contentID, location: location, mediaType: kind, name: filename, bytes: decoded))
                if disposition != "attachment" { return }
            }
        }

        if disposition == "attachment" || filename != nil || !["text/plain", "text/html"].contains(kind) {
            let fallback = kind == "text/calendar" ? "日程.ics" : kind == "message/rfc822" ? "邮件.eml" : "附件"
            result.attachments.append(Attachment(name: filename ?? fallback, type: kind, data: decoded))
        } else if kind == "text/plain" && result.plain == nil {
            result.plain = text(decoded, charset: typeParams["charset"])
        } else if kind == "text/html" && result.html == nil {
            result.html = text(decoded, charset: typeParams["charset"])
            result.htmlLocation = headers["content-base"] ?? headers["content-location"]
        }
    }

    static func plainText(_ html: String) -> String {
        html.replacingOccurrences(of: #"(?is)<(script|style|head)\b[^>]*>.*?</\1>"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)<(?:br\b[^>]*|/(?:p|div|li|tr))>"#, with: "\n", options: .regularExpression)
            .replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    static func base64(_ data: Data) -> String {
        data.base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed])
    }

    private static func encodedHeader(_ string: String) -> String {
        var words: [String] = []
        var chunk = ""
        for scalar in string.unicodeScalars where !CharacterSet.controlCharacters.contains(scalar) {
            let next = String(scalar)
            if chunk.utf8.count + next.utf8.count > 42 {
                words.append(chunk)
                chunk = ""
            }
            chunk += next
        }
        if !chunk.isEmpty { words.append(chunk) }
        return words.map { "=?UTF-8?B?\(Data($0.utf8).base64EncodedString())?=" }.joined(separator: "\r\n ")
    }

    static func outgoingMessageID(account: Account, id: UUID) -> String {
        let domain = account.email.split(separator: "@").last ?? "localhost"
        return "\(id.uuidString.lowercased())@\(domain)"
    }

    static func outgoingDraft(_ source: Draft, asDraft: Bool) throws -> Draft {
        var draft = source
        try draft.commitPendingRecipients()
        let addresses = draft.to + draft.cc + draft.bcc
        guard asDraft || !addresses.isEmpty, addresses.allSatisfy({ MailAddress.isValid($0.email) }) else {
            throw MailError("请填写有效的收件人邮箱。")
        }
        if asDraft && (draft.encrypt || draft.sign) {
            throw MailError("启用了 S/MIME 的邮件不会以明文保存到服务器草稿箱。")
        }
        return draft
    }

    static func outgoingImages(_ draft: Draft, html: String?) -> [InlineImage] {
        var result: [InlineImage] = []
        for image in MailImageAttachment.resources(in: draft.richBody) + (draft.quote?.images ?? []) {
            if html?.contains("cid:" + MailImageAttachment.contentID(for: image)) == true,
               !result.contains(where: { $0.id == image.id }) { result.append(image) }
        }
        return result
    }

    static func outgoingBodies(_ draft: Draft) throws -> (plain: String, html: String?) {
        let plain = draft.quote.map { draft.body + "\r\n\r\n" + $0.plainBlock } ?? draft.body
        let html = draft.quote.map {
            ReplyQuote.append($0.htmlBlock, to: draft.htmlBody ?? "<div style=\"white-space:pre-wrap\">" +
                              ReplyQuote.escape(draft.body) + "</div>")
        } ?? draft.htmlBody
        let imageBytes = outgoingImages(draft, html: html).reduce(0) { $0 + $1.bytes.count }
        let total = draft.attachments.reduce(max(plain.utf8.count, html?.utf8.count ?? 0)) { $0 + $1.data.count }
        guard total + imageBytes <= 24 * 1024 * 1024 else { throw MailError("正文和附件合计不能超过 24 MB。") }
        return (plain, html)
    }

    static func threadingHeaders(_ draft: Draft) -> [(String, String)] {
        [("In-Reply-To", draft.inReplyTo), ("References", draft.references)].compactMap { key, value in
            guard let value else { return nil }
            let ids = value.split(whereSeparator: \.isWhitespace)
                .filter { $0.range(of: #"^<[^<>\p{C}\s]{1,250}>$"#, options: .regularExpression) != nil }
                .suffix(30)
            return ids.isEmpty ? nil : (key, ids.joined(separator: " "))
        }
    }

    static func outgoing(account: Account, draft: Draft, asDraft: Bool = false, keepBcc: Bool = false,
                         messageID: String? = nil) throws -> (Data, [String]) {
        try account.validate()
        let draft = try outgoingDraft(draft, asDraft: asDraft)
        let to = draft.to
        let cc = draft.cc
        let recipients = MailAddress.unique(to + cc + draft.bcc).map(\.email)
        func mailbox(_ address: MailAddress) -> String {
            let name = address.name.trimmingCharacters(in: .whitespacesAndNewlines)
                .filter { !$0.isNewline && $0 != "\"" && $0 != "\\" }
            guard !name.isEmpty else { return "<\(address.email)>" }
            let phrase = name.unicodeScalars.allSatisfy({ $0.isASCII && $0.value >= 32 })
                ? "\"" + name + "\"" : encodedHeader(name)
            return "\(phrase) <\(address.email)>"
        }
        let (plainBody, htmlBody) = try outgoingBodies(draft)

        let formatter = outgoingDateFormatter
        var envelope = [
            "From: " + mailbox(MailAddress(name: account.displayName, email: account.email)),
            "To: " + (to.isEmpty ? "undisclosed-recipients:;" : to.map(mailbox).joined(separator: ",\r\n ")),
            "Date: \(formatter.string(from: Date()))",
            "Message-ID: <\(messageID ?? outgoingMessageID(account: account, id: draft.id))>",
            "Subject: \(encodedHeader(draft.subject))",
            "MIME-Version: 1.0"
        ]
        if !cc.isEmpty { envelope.append("Cc: " + cc.map(mailbox).joined(separator: ",\r\n ")) }
        // Preserve Bcc for drafts and full-message submission; Coremail also needs
        // its compose-session envelope populated separately before delivery.
        if (asDraft || keepBcc) && !draft.bcc.isEmpty { envelope.append("Bcc: " + draft.bcc.map(mailbox).joined(separator: ",\r\n ")) }
        for (key, value) in threadingHeaders(draft) {
            envelope.append(key + ": " + value.replacingOccurrences(of: " ", with: "\r\n "))
        }

        func textEntity(_ subtype: String, content: String) -> String {
            "Content-Type: text/\(subtype); charset=UTF-8\r\nContent-Transfer-Encoding: base64\r\n\r\n"
                + base64(Data(content.utf8)) + "\r\n"
        }
        let plain = textEntity("plain", content: plainBody)
        var textPart: String
        if let html = htmlBody {
            let boundary = "native-mail-alt-" + UUID().uuidString
            textPart = "Content-Type: multipart/alternative; boundary=\"\(boundary)\"\r\n\r\n"
                + "--\(boundary)\r\n" + plain + "\r\n--\(boundary)\r\n"
                + textEntity("html", content: html) + "\r\n--\(boundary)--\r\n"
        } else {
            textPart = plain
        }
        let images = outgoingImages(draft, html: htmlBody)
        if !images.isEmpty {
            let boundary = "native-mail-related-" + UUID().uuidString
            var related = "Content-Type: multipart/related; boundary=\"\(boundary)\"\r\n\r\n--\(boundary)\r\n" + textPart + "\r\n"
            for image in images {
                related += "--\(boundary)\r\nContent-Type: \(image.mediaType)\r\nContent-ID: <\(MailImageAttachment.contentID(for: image))>\r\nContent-Disposition: inline\r\nContent-Transfer-Encoding: base64\r\n\r\n"
                    + base64(image.bytes) + "\r\n"
            }
            textPart = related + "--\(boundary)--\r\n"
        }
        var entity: Data
        if draft.attachments.isEmpty {
            entity = Data(textPart.utf8)
        } else {
            let boundary = "native-mail-" + UUID().uuidString
            entity = Data("Content-Type: multipart/mixed; boundary=\"\(boundary)\"\r\n\r\n--\(boundary)\r\n\(textPart)\r\n".utf8)
            for attachment in draft.attachments {
                let encodedName = attachment.safeName.addingPercentEncoding(withAllowedCharacters:
                    CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._")) ?? "attachment"
                let type = attachment.type.range(of: #"^[a-zA-Z0-9.+-]+/[a-zA-Z0-9.+-]+$"#, options: .regularExpression) != nil
                    ? attachment.type : "application/octet-stream"
                let wrapper = type == "message/rfc822" ? "application/octet-stream" : type
                let part = "--\(boundary)\r\nContent-Type: \(wrapper)\r\nContent-Disposition: attachment;\r\n filename*=UTF-8''\(encodedName)\r\nContent-Transfer-Encoding: base64\r\n\r\n"
                entity.append(Data(part.utf8))
                entity.append(Data(base64(attachment.data).utf8))
                entity.append(crlf)
            }
            entity.append(Data("--\(boundary)--\r\n".utf8))
        }

        if draft.sign {
            let signed = try SMIME.sign(entity, sender: account.email)
            entity = wrappedCMS(signed, type: "signed-data")
        }
        if draft.encrypt {
            let encrypted = try SMIME.encrypt(entity, recipients: recipients, sender: account.email)
            entity = wrappedCMS(encrypted, type: "enveloped-data")
        }
        var complete = Data((envelope.joined(separator: "\r\n") + "\r\n").utf8)
        complete.append(entity)
        return (complete, recipients)
    }

    private static func wrappedCMS(_ bytes: Data, type: String) -> Data {
        Data(("Content-Type: application/pkcs7-mime; smime-type=\(type); name=smime.p7m\r\n"
              + "Content-Disposition: attachment; filename=smime.p7m\r\nContent-Transfer-Encoding: base64\r\n\r\n"
              + base64(bytes) + "\r\n").utf8)
    }
}

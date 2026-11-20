import AppKit
import SwiftUI
import XCTest
@testable import NativeMail

final class RichEditorTests: XCTestCase {
    @MainActor
    func testRichSignaturePersistsAndSwitchesWithoutChangingMessageOrQuote() throws {
        let png = try XCTUnwrap(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a0mQAAAAASUVORK5CYII="))
        let image = InlineImage(contentID: nil, location: nil, mediaType: "image/png", name: "logo.png", bytes: png)
        let content = NSMutableAttributedString(string: "Team ", attributes: [
            .font: NSFont.boldSystemFont(ofSize: 18), .foregroundColor: NSColor.blue
        ])
        content.append(NSAttributedString(attachment: MailImageAttachment(resource: image)))
        let entry = try MailSignature(id: UUID(), name: "工作", document: content)
        let library = MailSignatureLibrary(entries: [entry], defaultID: entry.id)
        let decoded = try JSONDecoder().decode(MailSignatureLibrary.self, from: JSONEncoder().encode(library))
        let signature = try XCTUnwrap(decoded.defaultSignature)
        let restored = signature.document()
        XCTAssertEqual(MailImageAttachment.resources(in: restored).first?.bytes, png)
        XCTAssertEqual((restored.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize, 18)

        let editor = NSTextView(frame: .zero)
        let body = NSMutableAttributedString(string: "Message")
        body.append(NSAttributedString(string: "\nQuote", attributes: [.mailQuote: true]))
        editor.textStorage?.setAttributedString(body)
        RichEditor.apply(.signature(signature), in: editor)
        XCTAssertTrue(editor.string.hasPrefix("Message\n\n-- \nTeam"))
        XCTAssertTrue(editor.string.hasSuffix("\nQuote"))
        var draft = Draft()
        draft.richBody = editor.textStorage
        draft.body = editor.string
        let html = try RichEditor.exportHTML(draft.richBody, plain: draft.body)
        XCTAssertEqual(MIME.outgoingImages(draft, html: html).first?.bytes, png)
        var account = Account()
        account.host = "mail.example.com"
        account.email = "sender@example.com"
        draft.htmlBody = html
        let (eml, _) = try MIME.outgoing(account: account, draft: draft, asDraft: true, keepBcc: true,
                                          messageID: "signature-test@example.com")
        let message = MIME.message(eml)
        let reopened = try MailImageAttachment.editableDraft(try XCTUnwrap(message.html), images: message.inlineImages)
        XCTAssertEqual(MailImageAttachment.resources(in: reopened).first?.bytes, png)

        RichEditor.apply(.signature(MailSignature(name: "个人", plain: "Personal")), in: editor)
        XCTAssertEqual(editor.string, "Message\n\n-- \nPersonal\nQuote")
        RichEditor.apply(.signature(nil), in: editor)
        XCTAssertEqual(editor.string, "Message\nQuote")
    }

    @MainActor
    func testCustomMarkersAndColorsSurviveExport() throws {
        let editor = NSTextView(frame: .zero)
        editor.string = "One\nTwo"
        editor.setSelectedRange(NSRange(location: 0, length: editor.string.utf16.count))
        RichEditor.apply(.color(.red, background: false), in: editor)
        RichEditor.apply(.color(.yellow, background: true), in: editor)
        RichEditor.apply(.list(.init(rawValue: "{lower-alpha})")), in: editor)
        XCTAssertEqual(editor.string, "\ta)\tOne\n\tb)\tTwo")
        editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
        XCTAssertTrue(RichEditor.continueList(in: editor))
        XCTAssertTrue(editor.string.hasSuffix("\tc)\t"))
        let html = try RichEditor.exportHTML(editor.textStorage, plain: editor.string)
        XCTAssertTrue(html.contains("a)"))
        XCTAssertTrue(html.contains("b)"))
        XCTAssertTrue(html.contains("background-color"))
        XCTAssertTrue(html.contains("; color: #"))
    }

    @MainActor
    func testListsAndFontChoicesExportAsHTML() throws {
        let editor = NSTextView(frame: .zero)
        editor.string = "第一项\n第二项"
        editor.setSelectedRange(NSRange(location: 0, length: (editor.string as NSString).length))
        RichEditor.apply(.family("Helvetica"), in: editor)
        RichEditor.apply(.size(18), in: editor)
        RichEditor.apply(.list(.decimal), in: editor)
        XCTAssertEqual(editor.string, "\t1.\t第一项\n\t2.\t第二项")
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
        XCTAssertTrue(RichEditor.continueList(in: editor))
        XCTAssertTrue(editor.string.hasSuffix("\n\t3.\t"))
        XCTAssertTrue(RichEditor.continueList(in: editor))
        XCTAssertFalse(editor.string.contains("3."))
        let ordered = try RichEditor.exportHTML(editor.textStorage, plain: editor.string)
        XCTAssertTrue(ordered.contains("<ol"))
        let font = try XCTUnwrap(editor.textStorage?.attribute(.font, at: 4, effectiveRange: nil) as? NSFont)
        XCTAssertEqual(font.pointSize, 18)
        XCTAssertTrue(ordered.contains("18.0px") || ordered.contains("18.0pt"), ordered)
        XCTAssertTrue(ordered.contains("Helvetica"))

        editor.string = "一\n二"
        editor.setSelectedRange(NSRange(location: 0, length: (editor.string as NSString).length))
        RichEditor.apply(.list(.disc), in: editor)
        let unordered = try RichEditor.exportHTML(editor.textStorage, plain: editor.string)
        XCTAssertTrue(unordered.contains("<ul"))
        RichEditor.apply(.list(.disc), in: editor)
        XCTAssertEqual(editor.string, "一\n二")
    }

    @MainActor
    func testQuotedLogoKeepsPerOccurrenceDimensionsThroughExport() async throws {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 800, pixelsHigh: 800,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0))
        let bytes = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let image = InlineImage(contentID: "logo@example.com", location: nil, mediaType: "image/png", name: "logo.png", bytes: bytes)
        let source = """
            <style>td.signature { width:45.4px }</style>
            <img src="cid:logo@example.com" width="80" height="80">
            <img src="cid:logo@example.com" style="width:18pt;height:18pt">
            <table><tr><td class="signature"><img src="cid:logo@example.com"></td></tr></table>
            """
        let formatted = try await ReplyQuote.format(source, images: [image])
        let quote = ReplyQuote(heading: "原始邮件", plain: "", sourceHTML: source, formattedHTML: formatted, images: [image])
        let document = try quote.editorDocument()
        var sizes: [NSSize] = []
        document.enumerateAttribute(.attachment, in: NSRange(location: 0, length: document.length)) { value, _, _ in
            if let image = value as? MailImageAttachment { sizes.append(image.displaySize) }
        }
        XCTAssertEqual(sizes.count, 3)
        for (size, expected) in zip(sizes, [80.0, 24.0, 45.4]) {
            XCTAssertEqual(size.width, expected, accuracy: 0.01)
            XCTAssertEqual(size.height, expected, accuracy: 0.01)
        }
        let html = try RichEditor.exportHTML(document, plain: document.string)
        for width in ["80.0", "24.0", "45.4"] {
            XCTAssertTrue(html.contains("width=\"\(width)\""))
            XCTAssertTrue(quote.htmlBlock.contains("width=\"\(width)\""))
        }
        var draft = Draft()
        draft.to = [MailAddress(name: "", email: "other@example.com")]
        draft.richBody = document
        draft.body = document.string
        draft.htmlBody = html
        var account = Account()
        account.host = "mail.example.com"
        account.email = "me@example.com"
        let sent = MIME.message(try MIME.outgoing(account: account, draft: draft).0)
        XCTAssertEqual(sent.inlineImages.count, 1)
        XCTAssertEqual(sent.inlineImages.first?.bytes, bytes)
        // A second forward must keep the same small sizes, rather than reverting to 800px.
        let secondHTML = try await ReplyQuote.format(try XCTUnwrap(sent.html), images: sent.inlineImages)
        let second = ReplyQuote(heading: "再次转发", plain: "", sourceHTML: sent.html, formattedHTML: secondHTML, images: sent.inlineImages)
        let secondDocument = try second.editorDocument()
        var secondSizes: [NSSize] = []
        secondDocument.enumerateAttribute(.attachment, in: NSRange(location: 0, length: secondDocument.length)) { value, _, _ in
            if let image = value as? MailImageAttachment { secondSizes.append(image.displaySize) }
        }
        XCTAssertEqual(secondSizes, sizes)
    }

    @MainActor
    func testRecipientCompletionReturnFillsSelectedAddressInEveryField() async throws {
        let defaults = UserDefaults.standard
        let keys = ["account", "recentContacts", "touchID"]
        let saved = keys.map { defaults.object(forKey: $0) }
        defer {
            for (key, value) in zip(keys, saved) {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
        }
        var account = Account()
        account.host = "mail.example.com"
        account.email = "me@example.com"
        defaults.set(try JSONEncoder().encode(account), forKey: "account")
        defaults.set(false, forKey: "touchID")
        let contacts = [
            RecentContact(name: "测试甲", email: "first@example.com", count: 2, lastSeen: Date()),
            RecentContact(name: "测试乙", email: "second@example.com", count: 1, lastSeen: Date())
        ]
        defaults.set(try JSONEncoder().encode(contacts), forKey: "recentContacts")
        let store = MailStore()
        let draft = Draft()
        store.draft = draft
        let host = NSHostingView(rootView: Composer(store: store, initial: draft))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 780),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        func input(in view: NSView, label: String) -> NSTextField? {
            if let field = view as? NSTextField, field.isEditable, field.accessibilityLabel() == label { return field }
            return view.subviews.lazy.compactMap { input(in: $0, label: label) }.first
        }
        for field in RecipientField.allCases {
            let input = try XCTUnwrap(input(in: host, label: field.label))
            XCTAssertTrue(window.makeFirstResponder(input))
            let editor = try XCTUnwrap(input.currentEditor() as? NSTextView)
            editor.insertText("测试", replacementRange: editor.selectedRange())
            try await Task.sleep(for: .milliseconds(100))
            editor.doCommand(by: #selector(NSResponder.moveDown(_:)))
            editor.doCommand(by: #selector(NSResponder.moveDown(_:)))
            editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertEqual(store.draft?[field].map(\.email), ["second@example.com"])
            XCTAssertTrue(store.draft?.pendingRecipients[field, default: ""].isEmpty == true)
            // A second Return must consume no stale name or completion.
            editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
            try await Task.sleep(for: .milliseconds(30))
            XCTAssertEqual(store.draft?[field].count, 1)
            editor.insertText("测试", replacementRange: editor.selectedRange())
            try await Task.sleep(for: .milliseconds(100))
            editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertEqual(store.draft?[field].map(\.email), ["second@example.com", "first@example.com"])
        }
    }

    @MainActor
    func testReplyAndForwardKeepEmbeddedImagesThroughEditorAndMIME() async throws {
        let png = try XCTUnwrap(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aX1sAAAAASUVORK5CYII="))
        let image = InlineImage(contentID: "photo@example.com", location: "images/photo.png",
                                mediaType: "image/png", name: "照片.png", bytes: png)
        var original = Message(headers: ["from": "other@example.com"],
            html: "<p>图片前</p><img src='cid:photo%40example.com'><img src='images/photo.png'><img src='https://example.com/track' alt='远程图片'><p>图片后</p>",
            attachments: [Attachment(name: "合同.txt", type: "text/plain", data: Data("合同".utf8))],
            inlineImages: [image], raw: Data())
        var account = Account()
        account.host = "mail.example.com"
        account.email = "me@example.com"
        for action in [ComposeAction.reply, .replyAll, .replyWithAttachments, .forward] {
            var draft = Draft(message: original, account: account, action: action)
            draft.to = [MailAddress(name: "", email: "other@example.com")]
            var quote = try XCTUnwrap(draft.quote)
            quote.formattedHTML = try await ReplyQuote.format(try XCTUnwrap(quote.sourceHTML), images: quote.images)
            XCTAssertFalse(try XCTUnwrap(quote.formattedHTML).contains("https://example.com/track"))
            let document = try quote.editorDocument()
            var count = 0
            document.enumerateAttribute(.attachment, in: NSRange(location: 0, length: document.length)) { value, _, _ in
                if value is MailImageAttachment { count += 1 }
            }
            XCTAssertEqual(count, 2)
            ReplyQuote.addQuoteBorder(to: document)
            draft.richBody = document
            draft.body = document.string
            draft.quote = nil
            draft.htmlBody = try RichEditor.exportHTML(document, plain: document.string)
            XCTAssertFalse(try XCTUnwrap(draft.htmlBody).contains("COREMAILIMAGE"))
            let (data, _) = try MIME.outgoing(account: account, draft: draft)
            let sent = MIME.message(data)
            XCTAssertEqual(sent.inlineImages.count, 1)
            XCTAssertEqual(sent.inlineImages.first?.bytes, png)
            XCTAssertEqual(sent.attachments.count, action == .forward || action == .replyWithAttachments ? 1 : 0)
            let resolved = MailHTML(html: try XCTUnwrap(sent.html), images: sent.inlineImages)
            XCTAssertEqual(resolved.resources.count, 1)
            XCTAssertFalse(resolved.content.contains("cid:"))
            XCTAssertTrue(resolved.content.contains("图片前"))
            // Deleting the quoted images also removes their MIME payload.
            let empty = NSAttributedString(string: "删除图片")
            draft.richBody = empty
            draft.htmlBody = try RichEditor.exportHTML(empty, plain: empty.string)
            XCTAssertTrue(MIME.message(try MIME.outgoing(account: account, draft: draft).0).inlineImages.isEmpty)
        }
        original.inlineImages = []
        let stripped = try await ReplyQuote.format(try XCTUnwrap(original.html))
        XCTAssertFalse(try XCTUnwrap(stripped).contains("<img"))
    }

    @MainActor
    func testComposerKeyboardMentionFlowAndEscape() async throws {
        let store = MailStore()
        var draft = Draft()
        draft.to = [MailAddress(name: "张三", email: "zhang@example.com")]
        draft.cc = [MailAddress(name: "李四", email: "li@example.com")]
        store.draft = draft
        let host = NSHostingView(rootView: Composer(store: store, initial: draft))
        host.appearance = NSAppearance(named: .darkAqua)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 780),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        func textView(in view: NSView) -> NSTextView? {
            if let editor = view as? NSTextView, !editor.isFieldEditor { return editor }
            return view.subviews.lazy.compactMap { textView(in: $0) }.first
        }
        let editor = try XCTUnwrap(textView(in: host))
        XCTAssertTrue(window.makeFirstResponder(editor))
        editor.insertText("@", replacementRange: editor.selectedRange())
        try await Task.sleep(for: .milliseconds(150))
        editor.doCommand(by: #selector(NSResponder.moveDown(_:)))
        try await Task.sleep(for: .milliseconds(50))
        editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(editor.string, "@李四 ")
        XCTAssertEqual(store.draft?.body, "@李四 ")
        XCTAssertEqual(store.draft?.to.count, 1)
        XCTAssertEqual(store.draft?.cc.count, 1)

        editor.insertText("@张", replacementRange: editor.selectedRange())
        try await Task.sleep(for: .milliseconds(100))
        editor.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        try await Task.sleep(for: .milliseconds(50))
        editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(editor.string, "@李四 @张\n")
    }

    func testMentionDetectionHandlesChineseUTF16AndEmailAddresses() throws {
        for (input, query) in [("@", ""), ("请 @张三", "张三"), ("👋＠liu", "liu"),
                               ("请@liu@example.com", "liu@example.com")] {
            let token = try XCTUnwrap(MentionToken.at(NSRange(location: (input as NSString).length, length: 0), in: input))
            XCTAssertEqual(token.query, query)
        }
        for input in ["liu@example.com", "hello@@liu", "@张三 ", "@", "a@b"] {
            let selection = NSRange(location: (input as NSString).length, length: input == "@" ? 1 : 0)
            XCTAssertNil(MentionToken.at(selection, in: input))
        }
        XCTAssertNil(MentionToken.at(NSRange(location: 100, length: 0), in: "@a"))
    }

    @MainActor
    func testMentionInsertionPreservesQuoteSupportsUndoAndSurvivesOutgoingMIME() throws {
        let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 240))
        editor.allowsUndo = true
        let window = NSWindow(contentRect: editor.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = editor
        defer { window.close() }
        window.makeFirstResponder(editor)
        let original = NSAttributedString(string: "👋 @张\n原邮件保持加粗", attributes: [.font: NSFont.boldSystemFont(ofSize: 14)])
        editor.textStorage?.setAttributedString(original)
        let cursor = ("👋 @张" as NSString).length
        editor.setSelectedRange(NSRange(location: cursor, length: 0))
        let token = try XCTUnwrap(MentionToken.at(editor.selectedRange(), in: editor.string))
        let contact = ContactChoice(name: "张三", email: "zhang@example.com")
        let insertion = MentionInsertion(token: token, contact: contact)
        XCTAssertTrue(RichEditor.insertMention(insertion, in: editor))
        XCTAssertEqual(editor.string, "👋 @张三 \n原邮件保持加粗")
        XCTAssertEqual(editor.selectedRange().location, ("👋 @张三 " as NSString).length)
        XCTAssertNil(editor.typingAttributes[.link])
        let storage = try XCTUnwrap(editor.textStorage)
        let font = try XCTUnwrap(storage.attribute(.font, at: storage.length - 1, effectiveRange: nil) as? NSFont)
        XCTAssertTrue(NSFontManager.shared.traits(of: font).contains(.boldFontMask))
        var draft = Draft()
        draft.body = editor.string
        draft.richBody = NSAttributedString(attributedString: storage)
        draft.includeMention(contact)
        draft.includeMention(ContactChoice(name: "重复", email: "ZHANG@example.com"))
        XCTAssertEqual(draft.to.count, 1)
        draft.cc = [MailAddress(name: "抄送", email: "cc@example.com")]
        draft.bcc = [MailAddress(name: "密送", email: "bcc@example.com")]
        draft.includeMention(ContactChoice(name: "", email: "CC@example.com"))
        draft.includeMention(ContactChoice(name: "", email: "bcc@example.com"))
        XCTAssertEqual(draft.to.count, 1)
        draft.htmlBody = try RichEditor.exportHTML(draft.richBody, plain: draft.body)
        var account = Account()
        account.host = "mail.example.com"
        account.email = "me@example.com"
        let (data, _) = try MIME.outgoing(account: account, draft: draft)
        let sent = MIME.message(data)
        XCTAssertTrue(sent.html?.contains("mailto:zhang@example.com") == true)
        XCTAssertTrue(sent.plain?.contains("@张三") == true)
        XCTAssertEqual(sent.to.map(\.email), ["zhang@example.com"])
        XCTAssertFalse(RichEditor.insertMention(insertion, in: editor), "An old suggestion must not replace text after the cursor moved.")
        editor.undoManager?.undo()
        XCTAssertEqual(editor.string, original.string)
    }

    @MainActor
    func testEditorRendersReadableNewAndImportedTextInBothAppearances() async throws {
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            for imported in [false, true] {
                let text = "正文 Text @联系人"
                let rich = imported ? NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 18), .foregroundColor: NSColor.black]) : nil
                let root = RichEditor(text: .constant(text), richText: .constant(rich), command: nil,
                                      initiallyFocused: false, isEditable: true)
                let host = NSHostingView(rootView: root)
                host.appearance = NSAppearance(named: appearance)
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 120),
                                      styleMask: [.titled], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.contentView = host
                defer { window.close() }
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(50))
                func textView(in view: NSView) -> NSTextView? {
                    if let editor = view as? NSTextView { return editor }
                    return view.subviews.lazy.compactMap { textView(in: $0) }.first
                }
                let editor = try XCTUnwrap(textView(in: host))
                XCTAssertTrue(editor.usesAdaptiveColorMappingForDarkAppearance)
                let bitmap = try XCTUnwrap(editor.bitmapImageRepForCachingDisplay(in: editor.bounds))
                editor.cacheDisplay(in: editor.bounds, to: bitmap)
                let dark = appearance == .darkAqua
                let background = try XCTUnwrap(bitmap.colorAt(x: bitmap.pixelsWide - 8, y: bitmap.pixelsHigh - 8)?.usingColorSpace(.sRGB))
                let backgroundBrightness = (background.redComponent + background.greenComponent + background.blueComponent) / 3
                if dark { XCTAssertLessThan(backgroundBrightness, 0.3) }
                else { XCTAssertGreaterThan(backgroundBrightness, 0.8) }
                var visiblePixels = 0
                for y in 0..<min(80, bitmap.pixelsHigh) {
                    for x in 0..<min(450, bitmap.pixelsWide) {
                        let pixel = try XCTUnwrap(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
                        let brightness = (pixel.redComponent + pixel.greenComponent + pixel.blueComponent) / 3
                        if dark ? brightness > 0.6 : brightness < 0.4 { visiblePixels += 1 }
                    }
                }
                XCTAssertGreaterThan(visiblePixels, 40, "\(appearance.rawValue), imported \(imported)")
            }
        }
    }

    @MainActor
    func testQuoteBorderPreservesAndDrawsNestedHTMLTables() throws {
        let html = "<p>原始邮件</p><table><tr><td>金额<table><tr><td>明细</td></tr></table></td><td>100</td></tr></table><p>结束</p>"
        let original = try NSMutableAttributedString(data: Data(html.utf8), options: [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue
        ], documentAttributes: nil)
        let whole = NSRange(location: 0, length: original.length)
        var before: [(NSRange, [NSTextBlock])] = []
        original.enumerateAttribute(.paragraphStyle, in: whole) { value, range, _ in
            before.append((range, (value as? NSParagraphStyle)?.textBlocks ?? []))
        }
        XCTAssertTrue(before.contains { $0.1.count >= 2 })
        ReplyQuote.addQuoteBorder(to: original)
        var outer: NSTextTableBlock?
        for (range, blocks) in before {
            let style = try XCTUnwrap(original.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle)
            XCTAssertEqual(style.textBlocks.count, blocks.count + 1)
            let bar = try XCTUnwrap(style.textBlocks.first as? NSTextTableBlock)
            if let outer { XCTAssertTrue(bar === outer) } else { outer = bar }
            for (actual, expected) in zip(style.textBlocks.dropFirst(), blocks) {
                XCTAssertTrue(actual === expected)
            }
        }
        // Exercise the background drawing path from the crash report, not just layout.
        let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 640, height: 800))
        editor.textStorage?.setAttributedString(RichEditor.editorDocument(original, plain: original.string))
        editor.layoutManager?.ensureLayout(for: try XCTUnwrap(editor.textContainer))
        let bitmap = try XCTUnwrap(editor.bitmapImageRepForCachingDisplay(in: editor.bounds))
        editor.cacheDisplay(in: editor.bounds, to: bitmap)
        let exported = try RichEditor.exportHTML(original, plain: original.string)
        XCTAssertTrue(exported.contains("<table"))
        XCTAssertTrue(exported.contains("明细") || exported.contains("&#"))
    }

    @MainActor
    func testQuoteRetainsFormattedMarkupInOutgoingMailWithoutActiveContent() async throws {
        let source = """
            <html><head><style>body { background: url(https://example.com/track); }</style></head>
            <body><p><strong>合同</strong> <em>要点</em></p><table><tr><td>金额</td></tr></table>
            <a href="https://example.com/info">链接</a><a href="javascript:alert(1)">坏链接</a>
            <img src="https://example.com/track" onerror="alert(1)" alt="示意图"><script>alert(1)</script></body></html>
            """
        let formatted = try await ReplyQuote.format(source)
        let quote = ReplyQuote(heading: "同事 写道：", plain: "合同要点", sourceHTML: source, formattedHTML: formatted)
        XCTAssertTrue(quote.htmlBlock.contains("<strong>合同</strong>"))
        XCTAssertTrue(quote.htmlBlock.contains("<td>金额</td>"))
        XCTAssertTrue(quote.htmlBlock.contains("https://example.com/info"))
        XCTAssertFalse(quote.htmlBlock.contains("example.com/track"))
        XCTAssertFalse(quote.htmlBlock.contains("javascript:"))
        XCTAssertFalse(quote.htmlBlock.contains("<script"))
        var draft = Draft()
        draft.to = [MailAddress(name: "", email: "other@example.com")]
        draft.body = "好的"
        draft.htmlBody = "<html><body><p>好的</p></body></html>"
        draft.quote = quote
        var account = Account()
        account.host = "mail.example.com"
        account.email = "me@example.com"
        let (data, _) = try MIME.outgoing(account: account, draft: draft)
        let message = MIME.message(data)
        let sentHTML = try XCTUnwrap(message.html)
        XCTAssertTrue(sentHTML.contains("<p>好的</p>"))
        XCTAssertTrue(sentHTML.contains("<strong>合同</strong>"))
        XCTAssertTrue(message.plain?.contains("合同要点") == true)
    }

    @MainActor
    func testHTMLExportRetainsFormattedChineseTextAndSupportsEmptyBody() async throws {
        let formatted = NSAttributedString(string: "加粗正文", attributes: [
            .font: NSFont.boldSystemFont(ofSize: 14),
            .underlineStyle: NSUnderlineStyle.single.rawValue
        ])
        let html = try RichEditor.exportHTML(formatted, plain: formatted.string)
        XCTAssertTrue(html.contains("加粗正文") || html.contains("&#"))
        XCTAssertTrue(html.contains("font-weight: bold") || html.contains("<b>"))
        XCTAssertTrue(html.contains("underline"))
        XCTAssertFalse(try RichEditor.exportHTML(nil, plain: "").isEmpty)
    }
}

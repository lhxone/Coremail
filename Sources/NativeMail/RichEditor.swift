import AppKit
import SwiftUI

enum RichStyle: String, CaseIterable, Identifiable {
    case bold, italic, underline

    var id: Self { self }
    var title: String {
        switch self {
        case .bold: return "加粗"
        case .italic: return "斜体"
        case .underline: return "下划线"
        }
    }
    var key: String {
        switch self {
        case .bold: return "b"
        case .italic: return "i"
        case .underline: return "u"
        }
    }
}

struct RichEdit: Identifiable {
    let id = UUID()
    enum Action {
        case style(RichStyle)
        case family(String)
        case size(CGFloat)
        case paragraph(CGFloat, bold: Bool)
        case color(NSColor?, background: Bool)
        case list(NSTextList.MarkerFormat)
        case image(InlineImage)
        case signature(MailSignature?)
    }

    let action: Action

    init(_ action: Action) { self.action = action }
    init(style: RichStyle) { self.init(.style(style)) }
}

struct MentionToken: Equatable {
    let range: NSRange
    let query: String

    // An ASCII word or email immediately before @ is part of the surrounding text.
    private static let pattern = try! NSRegularExpression(
        pattern: #"(?<![A-Za-z0-9._%+@＠-])[@＠]([\p{L}\p{M}\p{N}._%+-]{0,120}(?:@[A-Za-z0-9.-]{0,120})?)$"#
    )

    static func at(_ selection: NSRange, in text: String) -> Self? {
        let text = text as NSString
        guard selection.length == 0, selection.location <= text.length else { return nil }
        let start = max(0, selection.location - 242)
        let prefix = NSRange(location: start, length: selection.location - start)
        guard let match = pattern.firstMatch(in: text as String, options: .withTransparentBounds, range: prefix) else { return nil }
        return Self(range: match.range, query: text.substring(with: match.range(at: 1)))
    }
}

struct BodyMention: Equatable {
    let token: MentionToken
    let caret: CGRect
}

struct MentionInsertion: Identifiable {
    let id = UUID()
    let token: MentionToken
    let contact: ContactChoice
}

enum MentionKey { case up, down, accept, dismiss }

struct RichEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var richText: NSAttributedString?
    let command: RichEdit?
    let initiallyFocused: Bool
    let isEditable: Bool
    var mentionInsertion: MentionInsertion? = nil
    var mentionChanged: (BodyMention?) -> Void = { _ in }
    var mentionKey: (MentionKey) -> Bool = { _ in false }
    var mentioned: (ContactChoice) -> Void = { _ in }

    private static let baseFont = NSFont.systemFont(ofSize: NSFont.systemFontSize)

    static func editorDocument(_ richText: NSAttributedString?, plain: String) -> NSAttributedString {
        let document = NSMutableAttributedString(attributedString: richText ?? NSAttributedString(string: plain, attributes: [.font: baseFont]))
        let whole = NSRange(location: 0, length: document.length)
        var uncolored: [NSRange] = []
        document.enumerateAttribute(.foregroundColor, in: whole) { color, range, _ in
            if color == nil { uncolored.append(range) }
        }
        for range in uncolored { document.addAttribute(.foregroundColor, value: NSColor.textColor, range: range) }
        return document
    }

    static func exportHTML(_ richText: NSAttributedString?, plain: String) throws -> String {
        let document = NSMutableAttributedString(attributedString: richText ?? NSAttributedString(string: plain))
        var replacements: [(NSRange, MailImageAttachment, String)] = []
        document.enumerateAttribute(.attachment, in: NSRange(location: 0, length: document.length)) { value, range, _ in
            if let attachment = value as? MailImageAttachment {
                replacements.append((range, attachment, "COREMAILIMAGEEXPORT" + UUID().uuidString + "END"))
            }
        }
        for (range, _, marker) in replacements.reversed() {
            var attributes = document.attributes(at: range.location, effectiveRange: nil)
            attributes.removeValue(forKey: .attachment)
            document.replaceCharacters(in: range, with: NSAttributedString(string: marker, attributes: attributes))
        }
        let range = NSRange(location: 0, length: document.length)
        // Remove the editor's adaptive default so the receiving client controls its foreground.
        var defaultColors: [NSRange] = []
        document.enumerateAttribute(.foregroundColor, in: range) { color, range, _ in
            if let color = color as? NSColor, color == .labelColor || color == .textColor { defaultColors.append(range) }
        }
        for range in defaultColors { document.removeAttribute(.foregroundColor, range: range) }
        // The Cocoa HTML writer normalizes custom marker glyphs and punctuation.
        // Keep their visible text in the exported copy so recipients see the selected marker.
        let literalMarkers: Set<NSTextList.MarkerFormat> = [
            .diamond, .check, .init(rawValue: "✧"), .init(rawValue: "➢"),
            .init(rawValue: "{decimal})"), .init(rawValue: "（{cjk-ideographic}）"),
            .init(rawValue: "{lower-alpha})")
        ]
        let text = document.string as NSString
        var literalStyles: [(NSRange, NSParagraphStyle)] = []
        document.enumerateAttribute(.paragraphStyle, in: range) { value, span, _ in
            guard let style = value as? NSParagraphStyle, style.textLists.count == 1,
                  let list = style.textLists.first, literalMarkers.contains(list.markerFormat),
                  Self.listMarker(in: text.substring(with: span)) != nil,
                  let copy = style.mutableCopy() as? NSMutableParagraphStyle else { return }
            copy.textLists = []
            literalStyles.append((span, copy))
        }
        for (span, style) in literalStyles { document.addAttribute(.paragraphStyle, value: style, range: span) }
        let bytes = try document.data(from: range, documentAttributes: [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue
        ])
        guard var html = String(data: bytes, encoding: .utf8) else { throw MailError("无法生成邮件的 HTML 正文。") }
        for (_, attachment, marker) in replacements {
            html = html.replacingOccurrences(of: marker, with: attachment.htmlTag)
        }
        return html
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        guard let editor = scroll.documentView as? NSTextView else { return scroll }
        editor.isRichText = true
        editor.importsGraphics = false
        editor.allowsUndo = true
        editor.usesFontPanel = true
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticLinkDetectionEnabled = true
        editor.usesAdaptiveColorMappingForDarkAppearance = true
        editor.textContainerInset = NSSize(width: 4, height: 7)
        editor.setAccessibilityLabel("正文")
        editor.font = Self.baseFont
        editor.textColor = .textColor
        editor.backgroundColor = .textBackgroundColor
        editor.textStorage?.setAttributedString(Self.editorDocument(richText, plain: text))
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        editor.typingAttributes = [.font: Self.baseFont, .foregroundColor: NSColor.textColor]
        editor.delegate = context.coordinator
        context.coordinator.editor = editor
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.scrolled),
                                               name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        if initiallyFocused {
            DispatchQueue.main.async { [weak editor] in
                guard let editor, let window = editor.window else { return }
                window.makeFirstResponder(editor)
            }
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let editor = scroll.documentView as? NSTextView else { return }
        editor.isEditable = isEditable
        guard isEditable else { return }
        if let insertion = mentionInsertion, context.coordinator.lastMention != insertion.id {
            let coordinator = context.coordinator
            coordinator.lastMention = insertion.id
            DispatchQueue.main.async { [weak editor, weak coordinator] in
                guard let editor, let coordinator, editor.isEditable,
                      Self.insertMention(insertion, in: editor) else { return }
                coordinator.parent.mentioned(insertion.contact)
            }
        }
        guard let command, context.coordinator.lastCommand != command.id else { return }
        context.coordinator.lastCommand = command.id
        DispatchQueue.main.async { [weak editor] in
            guard let editor, editor.isEditable else { return }
            editor.window?.makeFirstResponder(editor)
            Self.apply(command.action, in: editor)
        }
    }

    static func insertMention(_ insertion: MentionInsertion, in editor: NSTextView) -> Bool {
        guard MentionToken.at(editor.selectedRange(), in: editor.string) == insertion.token,
              let storage = editor.textStorage, MailAddress.isValid(insertion.contact.email) else { return false }
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = insertion.contact.email
        guard let link = components.url else { return false }
        let name = insertion.contact.name.isEmpty ? insertion.contact.email : insertion.contact.name
        var attributes = storage.attributes(at: insertion.token.range.location, effectiveRange: nil)
        attributes.removeValue(forKey: .link)
        let text = NSMutableAttributedString(string: "@\(name)", attributes: attributes)
        text.addAttribute(.link, value: link, range: NSRange(location: 0, length: text.length))
        text.append(NSAttributedString(string: " ", attributes: attributes))
        editor.window?.makeFirstResponder(editor)
        guard editor.shouldChangeText(in: insertion.token.range, replacementString: text.string) else { return false }
        storage.replaceCharacters(in: insertion.token.range, with: text)
        editor.setSelectedRange(NSRange(location: insertion.token.range.location + text.length, length: 0))
        editor.typingAttributes = attributes
        editor.didChangeText()
        return true
    }

    static func apply(_ action: RichEdit.Action, in editor: NSTextView) {
        let selection = editor.selectedRange()
        switch action {
        case .list(let format):
            applyList(format, in: editor)
            return
        case .image(let image):
            let attachment = MailImageAttachment(resource: image, width: min(320, NSImage(data: image.bytes)?.size.width ?? 320))
            let text = NSAttributedString(attachment: attachment)
            replace(selection, with: text, in: editor,
                    selection: NSRange(location: selection.location + text.length, length: 0))
            return
        case .signature(let signature):
            applySignature(signature, in: editor)
            return
        default:
            break
        }
        guard let storage = editor.textStorage else { return }
        let target: NSRange
        if case .paragraph = action {
            target = (editor.string as NSString).paragraphRange(for: selection)
        } else {
            target = selection
        }
        var typing = editor.typingAttributes
        let first = target.length == 0 ? typing : storage.attributes(at: target.location, effectiveRange: nil)
        func update(_ attributes: inout [NSAttributedString.Key: Any]) {
            let font = attributes[.font] as? NSFont ?? baseFont
            switch action {
            case .style(let style):
                toggle(style, attributes: &attributes, enabled: !isEnabled(style, attributes: first))
            case .family(let family):
                attributes[.font] = NSFontManager.shared.convert(font, toFamily: family)
            case .size(let size):
                attributes[.font] = NSFontManager.shared.convert(font, toSize: size)
            case .paragraph(let size, let bold):
                let resized = NSFontManager.shared.convert(font, toSize: size)
                attributes[.font] = bold ? NSFontManager.shared.convert(resized, toHaveTrait: .boldFontMask)
                    : NSFontManager.shared.convert(resized, toNotHaveTrait: .boldFontMask)
            case .color(let color, let background):
                if background { attributes[.backgroundColor] = color }
                else { attributes[.foregroundColor] = color ?? NSColor.textColor }
            case .list, .image, .signature:
                break
            }
        }
        if target.length == 0 {
            update(&typing)
            editor.typingAttributes = typing
            return
        }
        let edited = NSMutableAttributedString(attributedString: storage.attributedSubstring(from: target))
        edited.enumerateAttributes(in: NSRange(location: 0, length: edited.length)) { attributes, range, _ in
            var updated = attributes
            update(&updated)
            edited.setAttributes(updated, range: range)
        }
        replace(target, with: edited, in: editor, selection: selection)
    }

    private static func applySignature(_ signature: MailSignature?, in editor: NSTextView) {
        guard let storage = editor.textStorage else { return }
        let whole = NSRange(location: 0, length: storage.length)
        var existing: NSRange?
        var quoteStart = storage.length
        storage.enumerateAttributes(in: whole) { attributes, range, _ in
            if attributes[.mailSignature] != nil {
                existing = existing.map { NSUnionRange($0, range) } ?? range
            }
            if attributes[.mailQuote] != nil { quoteStart = min(quoteStart, range.location) }
        }
        guard existing != nil || signature != nil else { return }
        let range = existing ?? NSRange(location: quoteStart, length: 0)
        let text = signature.map { editorDocument($0.block(), plain: "") } ?? NSAttributedString()
        let old = editor.selectedRange()
        let caret = old.location <= range.location ? old.location
            : old.location >= NSMaxRange(range) ? old.location + text.length - range.length
            : range.location + text.length
        var typing = editor.typingAttributes
        if replace(range, with: text, in: editor, selection: NSRange(location: caret, length: 0)) {
            typing.removeValue(forKey: .mailSignature)
            editor.typingAttributes = typing
        }
    }

    private static func applyList(_ format: NSTextList.MarkerFormat, in editor: NSTextView) {
        guard let storage = editor.textStorage else { return }
        let text = editor.string as NSString
        let selection = editor.selectedRange()
        let range = text.paragraphRange(for: selection)
        let first = range.length > 0 ? storage.attributes(at: range.location, effectiveRange: nil) : editor.typingAttributes
        let remove = (first[.paragraphStyle] as? NSParagraphStyle)?.textLists.last?.markerFormat == format
        let list = NSTextList(markerFormat: format, options: [], startingItemNumber: 1)
        let replacement = NSMutableAttributedString()
        var location = range.location
        var item = 1
        repeat {
            let paragraph = text.paragraphRange(for: NSRange(location: location, length: 0))
            let line = NSMutableAttributedString(attributedString: storage.attributedSubstring(from: paragraph))
            var attributes = line.length > 0 ? line.attributes(at: 0, effectiveRange: nil) : first
            let style = listStyle(from: attributes)
            if !style.textLists.isEmpty, let marker = listMarker(in: line.string) {
                line.deleteCharacters(in: marker)
            }
            style.textLists = remove ? [] : [list]
            if !remove {
                attributes.removeValue(forKey: .link)
                attributes.removeValue(forKey: .attachment)
                line.insert(NSAttributedString(string: marker(for: list, item: item), attributes: attributes), at: 0)
            }
            line.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: line.length))
            replacement.append(line)
            location = NSMaxRange(paragraph)
            item += 1
        } while location < NSMaxRange(range)
        let updatedSelection: NSRange
        if selection.length == 0 {
            let delta = replacement.length - range.length
            updatedSelection = NSRange(location: max(range.location, selection.location + delta), length: 0)
        } else {
            updatedSelection = NSRange(location: range.location, length: replacement.length)
        }
        replace(range, with: replacement, in: editor, selection: updatedSelection)
    }

    private static func listStyle(from attributes: [NSAttributedString.Key: Any]) -> NSMutableParagraphStyle {
        (attributes[.paragraphStyle] as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle
            ?? NSMutableParagraphStyle()
    }

    private static func marker(for list: NSTextList, item: Int) -> String {
        let marker = list.marker(forItemNumber: item)
        return "\t" + marker + (list.markerFormat == .decimal ? "." : "") + "\t"
    }

    private static func listMarker(in line: String) -> NSRange? {
        guard line.hasPrefix("\t"), let end = line.dropFirst().firstIndex(of: "\t") else { return nil }
        return NSRange(line.startIndex...end, in: line)
    }

    @discardableResult
    private static func replace(_ range: NSRange, with text: NSAttributedString, in editor: NSTextView,
                                selection: NSRange) -> Bool {
        guard let storage = editor.textStorage,
              editor.shouldChangeText(in: range, replacementString: text.string) else { return false }
        storage.replaceCharacters(in: range, with: text)
        editor.didChangeText()
        editor.setSelectedRange(selection)
        return true
    }

    static func continueList(in editor: NSTextView) -> Bool {
        let selection = editor.selectedRange()
        let text = editor.string as NSString
        guard selection.length == 0, selection.location > 0, let storage = editor.textStorage else { return false }
        let paragraph = text.paragraphRange(for: selection)
        guard paragraph.length > 0,
              selection.location == text.length || text.character(at: selection.location) == 10 else { return false }
        let line = text.substring(with: paragraph)
        var attributes = storage.attributes(at: paragraph.location, effectiveRange: nil)
        guard let list = (attributes[.paragraphStyle] as? NSParagraphStyle)?.textLists.last,
              let prefix = listMarker(in: line) else { return false }
        attributes.removeValue(forKey: .link)
        attributes.removeValue(forKey: .attachment)
        if (line as NSString).substring(from: NSMaxRange(prefix)).trimmingCharacters(in: .newlines).isEmpty {
            let range = NSRange(location: paragraph.location, length: prefix.length)
            guard replace(range, with: NSAttributedString(), in: editor,
                          selection: NSRange(location: range.location, length: 0)) else { return false }
            let style = listStyle(from: attributes)
            style.textLists = []
            attributes[.paragraphStyle] = style
            editor.typingAttributes = attributes
            return true
        }
        let item = storage.itemNumber(in: list, at: paragraph.location) + 1
        let next = NSAttributedString(string: "\n" + marker(for: list, item: item), attributes: attributes)
        return replace(selection, with: next, in: editor,
                       selection: NSRange(location: selection.location + next.length, length: 0))
    }

    private static func isEnabled(_ style: RichStyle, attributes: [NSAttributedString.Key: Any]) -> Bool {
        if style == .underline { return (attributes[.underlineStyle] as? Int ?? 0) != 0 }
        let font = attributes[.font] as? NSFont ?? baseFont
        return NSFontManager.shared.traits(of: font).contains(style == .bold ? .boldFontMask : .italicFontMask)
    }

    private static func toggle(_ style: RichStyle, attributes: inout [NSAttributedString.Key: Any], enabled: Bool) {
        if style == .underline {
            attributes[.underlineStyle] = enabled ? NSUnderlineStyle.single.rawValue : nil
        } else {
            let font = attributes[.font] as? NSFont ?? baseFont
            let trait: NSFontTraitMask = style == .bold ? .boldFontMask : .italicFontMask
            attributes[.font] = enabled ? NSFontManager.shared.convert(font, toHaveTrait: trait)
                : NSFontManager.shared.convert(font, toNotHaveTrait: trait)
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: RichEditor
        var lastCommand: UUID?
        var lastMention: UUID?
        weak var editor: NSTextView?
        private var pendingUpdate = false
        private var dismissedToken: MentionToken?

        init(_ parent: RichEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView, let storage = editor.textStorage else { return }
            parent.richText = NSAttributedString(attributedString: storage)
            parent.text = editor.string
            refreshMention()
        }

        func textViewDidChangeSelection(_ notification: Notification) { refreshMention() }
        func textDidBeginEditing(_ notification: Notification) { refreshMention() }
        func textDidEndEditing(_ notification: Notification) { refreshMention() }
        @objc func scrolled() { refreshMention() }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard !textView.hasMarkedText() else { return false }
            switch selector {
            case #selector(NSResponder.moveUp(_:)): return parent.mentionKey(.up)
            case #selector(NSResponder.moveDown(_:)): return parent.mentionKey(.down)
            case #selector(NSResponder.insertNewline(_:)):
                return parent.mentionKey(.accept) || RichEditor.continueList(in: textView)
            case #selector(NSResponder.cancelOperation(_:)):
                guard parent.mentionKey(.dismiss) else { return false }
                dismissedToken = MentionToken.at(textView.selectedRange(), in: textView.string)
                return true
            default: return false
            }
        }

        private func refreshMention() {
            guard !pendingUpdate else { return }
            pendingUpdate = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                pendingUpdate = false
                guard let editor, let scroll = editor.enclosingScrollView,
                      let window = editor.window, window.firstResponder === editor, editor.isEditable,
                      !editor.hasMarkedText(),
                      let token = MentionToken.at(editor.selectedRange(), in: editor.string),
                      editor.textStorage?.attribute(.link, at: token.range.location, effectiveRange: nil) == nil else {
                    dismissedToken = nil
                    parent.mentionChanged(nil)
                    return
                }
                guard dismissedToken != token else { return }
                dismissedToken = nil
                let rect = editor.firstRect(forCharacterRange: editor.selectedRange(), actualRange: nil)
                let local = scroll.convert(window.convertFromScreen(rect), from: nil)
                let y = scroll.isFlipped ? local.minY : scroll.bounds.height - local.maxY
                guard y >= 0, y < scroll.bounds.height else { parent.mentionChanged(nil); return }
                parent.mentionChanged(BodyMention(token: token, caret: CGRect(x: local.minX, y: y, width: local.width, height: local.height)))
            }
        }
    }
}

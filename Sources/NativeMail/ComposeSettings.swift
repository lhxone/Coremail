import AppKit
import SwiftUI
import UniformTypeIdentifiers
struct ComposeColorPalette: View {
    let title: String
    let reset: String
    let select: (NSColor?) -> Void
    @State private var custom = Color.black

    private static let theme: [UInt32] = [
        0xFFFFFF, 0x000000, 0xE7E6E6, 0x44546A, 0x5B9BD5,
        0xED7D31, 0xA5A5A5, 0xFFC000, 0x4472C4, 0x70AD47
    ]
    private static let standard: [UInt32] = [
        0xC00000, 0xFF0000, 0xFFC000, 0xFFFF00, 0x92D050,
        0x00B050, 0x00B0F0, 0x0070C0, 0x002060, 0x7030A0
    ]
    private static let columns = Array(repeating: GridItem(.fixed(19), spacing: 4), count: 10)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            Text("主题颜色").font(.caption)
            LazyVGrid(columns: Self.columns, spacing: 4) {
                ForEach(0..<60) { index in
                    let row = index / 10
                    let base = Self.color(Self.theme[index % 10])
                    let shade = [0.0, 0.8, 0.6, 0.4, 0.25, 0.5][row]
                    let color = base.blended(withFraction: shade, of: row < 4 ? .white : .black) ?? base
                    swatch(color)
                }
            }
            Text("标准颜色").font(.caption)
            LazyVGrid(columns: Self.columns, spacing: 4) {
                ForEach(Self.standard, id: \.self) { swatch(Self.color($0)) }
            }
            Divider()
            HStack {
                Button(reset) { select(nil) }
                Spacer()
                ColorPicker("自选颜色", selection: $custom, supportsOpacity: false)
                    .labelsHidden().accessibilityLabel("自选颜色")
                Button("应用自选颜色") { select(NSColor(custom)) }
            }
        }
        .padding(12)
        .frame(width: 254)
    }

    private func swatch(_ color: NSColor) -> some View {
        let rgb = color.usingColorSpace(.sRGB) ?? color
        return Button { select(color) } label: {
            Rectangle().fill(Color(nsColor: color))
                .frame(width: 18, height: 18)
                .overlay { Rectangle().strokeBorder(.separator) }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("红 \(Int(rgb.redComponent * 255))，绿 \(Int(rgb.greenComponent * 255))，蓝 \(Int(rgb.blueComponent * 255))")
    }

    private static func color(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255,
                green: CGFloat((hex >> 8) & 255) / 255,
                blue: CGFloat(hex & 255) / 255, alpha: 1)
    }
}

struct Composer: View {
    @ObservedObject var store: MailStore
    /// Closes the compose window right away, before the draft is cleared.
    var close: () -> Void = {}
    @State private var draft: Draft
    @State private var initialBody: String
    @State private var showPicker = false
    @State private var confirmDiscard = false
    @State private var error: String?
    @State private var formatting: RichEdit?
    @State private var currentFont = RichEditor.baseFont
    @State private var ink = NSColor.textColor
    @State private var highlight: NSColor?
    @State private var underlined = false
    @State private var struck = false
    @State private var alignment = NSTextAlignment.natural
    @AppStorage("composeRecentFontFamilies") private var recentFamilies = "Helvetica\nTimes\nMenlo"
    @State private var showFormatBar = true
    @State private var showBcc = false
    @State private var showTextColors = false
    @State private var showHighlightColors = false
    @State private var recipientHeight: CGFloat = 128
    @State private var preparingQuote: Bool
    @State private var dropTarget = false
    @State private var addingAttachments = false
    @FocusState private var focus: Field?
    @State private var focusedRecipient: RecipientField?
    @State private var suggestions: [ContactChoice] = []
    @State private var suggestionKey: SearchKey?
    @State private var selectedSuggestion: String?
    @State private var searchError: String?
    @State private var directoryRetryAfter: Date?
    @State private var bodyMention: BodyMention?
    @State private var mentionInsertion: MentionInsertion?
    @State private var mentionContacts: [ContactChoice] = []
    @State private var selectedMention: String?
    @State private var mentionLoading = false
    @State private var mentionError: String?

    private enum Field: Hashable { case subject }

    private struct SearchKey: Equatable {
        let field: RecipientField
        let query: String
    }

    init(store: MailStore, initial: Draft, close: @escaping () -> Void = {}) {
        self.store = store
        self.close = close
        _draft = State(initialValue: initial)
        _initialBody = State(initialValue: initial.body)
        // Replies and forwards first fold the original mail into the editable body.
        _preparingQuote = State(initialValue: initial.quote != nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView(.vertical) {
                recipientFields.onGeometryChange(for: CGFloat.self, of: { $0.size.height }) {
                    recipientHeight = $0
                }
            }
            .scrollDisabled(recipientHeight <= 200)
            .frame(height: min(recipientHeight, 200))
            if !draft.attachments.isEmpty || addingAttachments { attachmentChips }
            Divider()
            if showFormatBar {
                ScrollView(.horizontal) { formatBar.fixedSize(horizontal: true, vertical: false) }
                    .padding(.vertical, 8)
            }
            if preparingQuote {
                ProgressView("正在准备原邮件…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .frame(minHeight: 200)
            } else {
                editor.frame(minHeight: 200)
            }
            if let error { Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
        }
        .dropDestination(for: URL.self) { files, _ in
            guard !addingAttachments, !store.sending, !files.isEmpty, files.allSatisfy(\.isFileURL) else { return false }
            addAttachments(files)
            return true
        } isTargeted: { dropTarget = $0 }
        .overlay {
            if dropTarget {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                    .background(Color.accentColor.opacity(0.06), in: .rect(cornerRadius: 10))
                    .overlay { Label("松开以添加附件", systemImage: "paperclip").font(.title3).foregroundStyle(Color.accentColor) }
                    .padding(6)
                    .allowsHitTesting(false)
            }
        }
        .padding(.horizontal, 16)
        .background(Color(nsColor: .textBackgroundColor))
        .frame(minWidth: 680, idealWidth: 820, minHeight: 600, idealHeight: 780)
        .overlayPreferenceValue(RecipientAnchorKey.self) { anchors in
            GeometryReader { proxy in
                suggestionDropdown(anchors, in: proxy)
            }
        }
        .navigationTitle(draft.subject.isEmpty ? draft.composeTitle : "\(draft.composeTitle)：\(draft.subject)")
        .disabled(store.sending)
        // Declared after `.disabled` so the send button keeps its blue while the mail goes out.
        .toolbar { composeToolbar }
        .interactiveDismissDisabled()
        .onAppear {
            if draft.to.isEmpty { focusedRecipient = .to }
        }
        .onChange(of: draft.subject) { _, _ in changed() }
        .onChange(of: draft.encrypt) { _, _ in changed() }
        .onChange(of: draft.sign) { _, _ in changed() }
        .onChange(of: focus) { _, _ in selectedSuggestion = nil }
        .onChange(of: focusedRecipient) { _, _ in selectedSuggestion = nil }
        .onChange(of: store.composeCloseRequest) { _, _ in cancel() }
        .task(id: searchKey) { await findContacts(searchKey) }
        .task(id: bodyMention?.token.query) { await findMentionContacts(bodyMention?.token.query) }
        .task {
            guard preparingQuote, var quote = draft.quote else { return }
            if let source = quote.sourceHTML, quote.formattedHTML == nil {
                quote.formattedHTML = try? await ReplyQuote.format(source, images: quote.images, location: quote.sourceLocation)
                guard !Task.isCancelled else { return }
            }
            inline(quote)
            preparingQuote = false
            changed()
        }
        .fileImporter(isPresented: $showPicker, allowedContentTypes: [.data], allowsMultipleSelection: true) { result in
            do { addAttachments(try result.get()) }
            catch { self.error = error.localizedDescription }
        }
        .confirmationDialog("关闭前保存这封邮件？", isPresented: $confirmDiscard, titleVisibility: .visible) {
            if canSaveDraft {
                Button("存为草稿") { saveDraft(close: true) }
            }
            Button("不保存", role: .destructive) { discard() }
            Button("继续编辑", role: .cancel) {}
        } message: {
            Text(canSaveDraft ? "草稿会保存到服务器草稿箱，可在其他设备继续编辑。" : "当前编辑和附件将被清除。")
        }
    }

    private var editor: some View {
        RichEditor(text: $draft.body, richText: $draft.richBody, command: formatting,
                   initiallyFocused: !draft.to.isEmpty, isEditable: !store.sending,
                   storageChanged: { storage in
                       guard draft.richBody !== storage else { return }
                       draft.richBody = storage
                       changed()
                   },
                   formatChanged: { attributes in
                       currentFont = attributes[.font] as? NSFont ?? RichEditor.baseFont
                       ink = attributes[.foregroundColor] as? NSColor ?? .textColor
                       highlight = attributes[.backgroundColor] as? NSColor
                       underlined = (attributes[.underlineStyle] as? Int ?? 0) != 0
                       struck = (attributes[.strikethroughStyle] as? Int ?? 0) != 0
                       alignment = (attributes[.paragraphStyle] as? NSParagraphStyle)?.alignment ?? .natural
                   },
                   mentionInsertion: mentionInsertion,
                   mentionChanged: { value in
                       guard bodyMention != value else { return }
                       if bodyMention?.token != value?.token { selectedMention = nil }
                       bodyMention = value
                   },
                   mentionKey: handleMentionKey,
                   mentioned: { contact in
                       draft.includeMention(contact)
                       bodyMention = nil
                       mentionInsertion = nil
                       changed()
                   })
            .overlay(alignment: .topLeading) {
                GeometryReader { proxy in
                    if let mention = bodyMention {
                        mentionDropdown(mention, size: proxy.size)
                    }
                }
            }
            .padding(.bottom, 4)
    }

    private func mentionDropdown(_ mention: BodyMention, size: CGSize) -> some View {
        let width = min(360, size.width)
        let height = min(CGFloat(max(1, mentionContacts.count)) * 48 + 38, size.height)
        let below = mention.caret.maxY + 4
        let y = below + height <= size.height ? below : max(0, mention.caret.minY - height - 4)
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("提及联系人").font(.caption.weight(.medium))
                Spacer()
                if mentionLoading { ProgressView().controlSize(.mini) }
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10).padding(.vertical, 8)
            ScrollViewReader { scroll in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if mentionContacts.isEmpty {
                            Text(mentionError ?? (mentionLoading ? "正在查找联系人…" : "输入姓名或邮箱查找联系人"))
                                .font(.callout).foregroundStyle(.secondary)
                                .padding(10).frame(height: 48, alignment: .leading)
                        }
                        ForEach(mentionContacts) { contact in
                            Button { selectMention(contact) } label: {
                                HStack(spacing: 8) {
                                    Avatar(address: MailAddress(name: contact.name, email: contact.email), size: 26)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(contact.name.isEmpty ? contact.email : contact.name)
                                            .font(.callout.weight(.medium)).lineLimit(1)
                                        Text(contact.email).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                    Spacer(minLength: 0)
                                }
                                .padding(.horizontal, 10).frame(height: 48)
                                .background(contact.id == (selectedMention ?? mentionContacts.first?.id) ? Color.accentColor.opacity(0.2) : .clear,
                                            in: .rect(cornerRadius: 6))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .onHover { if $0 { selectedMention = contact.id } }
                        }
                    }
                }
                .frame(height: max(48, height - 38))
                .onChange(of: selectedMention) { _, contact in
                    if let contact { scroll.scrollTo(contact, anchor: .center) }
                }
            }
        }
        .padding(4)
        .frame(width: width)
        .background(.regularMaterial, in: .rect(cornerRadius: 9))
        .overlay { RoundedRectangle(cornerRadius: 9).strokeBorder(.separator) }
        .shadow(color: .black.opacity(0.2), radius: 10, y: 4)
        .offset(x: min(max(0, mention.caret.minX), max(0, size.width - width)), y: y)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("提及联系人")
    }

    private func findMentionContacts(_ query: String?) async {
        mentionContacts = []
        mentionError = nil
        mentionLoading = false
        guard let query else { return }
        let recipients = (draft.to + draft.cc + draft.bcc).map { ContactChoice(name: $0.name, email: $0.email) }
        let recent = store.recentContacts.map { ContactChoice(name: $0.name, email: $0.email) }
        let local = recipients + recent
        func matching(_ choices: [ContactChoice]) -> [ContactChoice] {
            var used = Set<String>()
            return Array(choices.filter {
                MailAddress.isValid($0.email) && used.insert($0.id).inserted
                    && (query.isEmpty || $0.name.localizedStandardContains(query) || $0.email.localizedStandardContains(query))
            }.prefix(6))
        }
        mentionContacts = matching(local)
        guard !query.isEmpty, store.account != nil else { return }
        mentionLoading = true
        defer { if bodyMention?.token.query == query { mentionLoading = false } }
        do {
            try await Task.sleep(for: .milliseconds(350))
            let remote = try await store.directorySearch(query)
            try Task.checkCancellation()
            guard bodyMention?.token.query == query else { return }
            // Directory matching also supports server-side aliases and phonetic names.
            var used = Set<String>()
            mentionContacts = Array((matching(local) + remote).filter {
                MailAddress.isValid($0.email) && used.insert($0.id).inserted
            }.prefix(6))
        } catch {
            guard !Task.isCancelled, bodyMention?.token.query == query else { return }
            if mentionContacts.isEmpty { mentionError = "通讯录暂时不可用，可继续编辑或输入其他姓名" }
        }
    }

    private func selectMention(_ contact: ContactChoice) {
        guard let bodyMention else { return }
        mentionInsertion = MentionInsertion(token: bodyMention.token, contact: contact)
    }

    private func handleMentionKey(_ key: MentionKey) -> Bool {
        guard bodyMention != nil else { return false }
        if key == .dismiss { bodyMention = nil; return true }
        guard !mentionContacts.isEmpty else { return false }
        let index = mentionContacts.firstIndex { $0.id == selectedMention } ?? 0
        switch key {
        case .up: selectedMention = mentionContacts[max(0, index - 1)].id
        case .down: selectedMention = mentionContacts[min(mentionContacts.count - 1, index + 1)].id
        case .accept: selectMention(mentionContacts[index])
        case .dismiss: break
        }
        return true
    }

    /// Puts the original mail into the editor below the cursor and signature, like Coremail does.
    private func inline(_ quote: ReplyQuote) {
        let base = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let document = NSMutableAttributedString(attributedString: draft.richBody
            ?? NSAttributedString(string: draft.body, attributes: [.font: base, .foregroundColor: NSColor.labelColor]))
        let spacer = document.length == 0 ? "\n\n\n" : "\n\n"
        if document.length == 0 || !document.string.hasPrefix("\n") {
            document.insert(NSAttributedString(string: "\n", attributes: [.font: base, .foregroundColor: NSColor.labelColor]), at: 0)
        }
        let quoteStart = document.length
        document.append(NSAttributedString(string: spacer, attributes: [.font: base]))
        if let original = try? quote.editorDocument() {
            // Black text from the importer becomes the adaptive label color so it stays readable in Dark Mode.
            original.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: original.length)) { value, range, _ in
                if let color = value as? NSColor, let rgb = color.usingColorSpace(.sRGB),
                   rgb.redComponent < 0.15, rgb.greenComponent < 0.15, rgb.blueComponent < 0.15 {
                    original.addAttribute(.foregroundColor, value: NSColor.labelColor, range: range)
                } else if value == nil {
                    original.addAttribute(.foregroundColor, value: NSColor.labelColor, range: range)
                }
            }
            if !quote.prefersParagraphLayout { ReplyQuote.addQuoteBorder(to: original) }
            document.append(original)
        } else {
            document.append(NSAttributedString(string: quote.plainBlock, attributes: [.font: base, .foregroundColor: NSColor.labelColor]))
        }
        document.addAttribute(.mailQuote, value: true, range: NSRange(location: quoteStart, length: document.length - quoteStart))
        draft.richBody = document
        draft.body = document.string
        // The original now lives in the body, so it must not be appended again when sending.
        draft.quote = nil
    }

    private var recipientFields: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(RecipientField.allCases.filter { $0 != .bcc || showBcc || !draft.bcc.isEmpty || !(draft.pendingRecipients[.bcc] ?? "").isEmpty }, id: \.self) { field in
                recipientRow(field).padding(.vertical, 6)
                Divider()
            }
            HStack(spacing: 8) {
                caption("主题")
                TextField("", text: $draft.subject)
                    .focused($focus, equals: .subject)
                    .accessibilityLabel("主题")
            }.frame(minHeight: 39)
            Divider()
            if let account = store.account {
                HStack(spacing: 8) {
                    caption("发件人")
                    Text(account.email).textSelection(.enabled)
                }.frame(minHeight: 39)
            }
        }.textFieldStyle(.plain)
    }

    private func caption(_ label: String) -> some View {
        Text(label + "：").foregroundStyle(.secondary).frame(width: 54, alignment: .leading)
    }

    private func recipientRow(_ field: RecipientField) -> some View {
        HStack(alignment: .top, spacing: 8) {
            caption(field.label).frame(height: 27)
            RecipientFlow {
                ForEach(draft[field], id: \.email) { address in
                    HStack(spacing: 5) {
                        Image(systemName: "person.crop.circle").foregroundStyle(.secondary)
                        Text(address.display).lineLimit(1).truncationMode(.middle)
                        Button("移除 \(address.display)", systemImage: "xmark.circle.fill") {
                            draft[field].removeAll { $0.email == address.email }
                            changed()
                        }.labelStyle(.iconOnly).buttonStyle(.plain).foregroundStyle(.secondary)
                    }
                    .font(.callout).padding(.vertical, 4).padding(.horizontal, 7)
                    .background(.quaternary, in: .capsule)
                    .help(address.email)
                }
                RecipientInput(text: Binding(
                    get: { draft.pendingRecipients[field, default: ""] },
                    set: { updateInput($0, field: field) }
                ), placeholder: "",
                   label: field.label, isFocused: focusedRecipient == field,
                   focusChanged: { active in
                    if active { focusedRecipient = field }
                    else if focusedRecipient == field { focusedRecipient = nil }
                }, key: { key in
                    switch key {
                    case .removePrevious:
                        guard draft.pendingRecipients[field, default: ""].isEmpty,
                              !draft[field].isEmpty else { return false }
                        draft[field].removeLast()
                        selectedSuggestion = nil
                        changed()
                        return true
                    case .accept:
                        submitRecipient(field)
                        return true
                    case .down: return moveSuggestion(1, field: field) == .handled
                    case .up: return moveSuggestion(-1, field: field) == .handled
                    case .dismiss:
                        guard let key = searchKey, key.field == field, !visibleContacts(key).isEmpty else { return false }
                        suggestions = []
                        selectedSuggestion = nil
                        return true
                    }
                })
                .frame(height: 27)
                .anchorPreference(key: RecipientAnchorKey.self, value: .bounds) { [field: $0] }
            }
            if field == .to {
                Menu {
                    ForEach(store.recentContacts.prefix(20), id: \.email) { contact in
                        Button(MailAddress(name: contact.name, email: contact.email).full) {
                            add([MailAddress(name: contact.name, email: contact.email)], to: .to)
                        }
                    }
                } label: {
                    Label("添加最近联系人", systemImage: "plus.circle.fill")
                }
                .labelStyle(.iconOnly).menuStyle(.borderlessButton).menuIndicator(.hidden)
                .fixedSize().frame(height: 27)
                .disabled(store.recentContacts.isEmpty)
                .help("添加最近联系人")
            }
        }
    }

    /// Floating list under the active recipient field.
    @ViewBuilder
    private func suggestionDropdown(_ anchors: [RecipientField: Anchor<CGRect>], in proxy: GeometryProxy) -> some View {
        if let key = searchKey, let anchor = anchors[key.field] {
            let results = Array(visibleContacts(key).prefix(6))
            let showError = searchError != nil && suggestionKey == key && results.isEmpty
            if !results.isEmpty || showError {
                let field = proxy[anchor]
                let width = min(max(field.width, 360), proxy.size.width - field.minX - 8)
                VStack(alignment: .leading, spacing: 0) {
                    if showError, let searchError {
                        Label(searchError, systemImage: "exclamationmark.circle")
                            .font(.caption).foregroundStyle(.secondary)
                            .padding(10)
                    }
                    ForEach(results) { contact in
                        Button {
                            add([MailAddress(name: contact.name, email: contact.email)], to: key.field)
                        } label: {
                            HStack(spacing: 9) {
                                Avatar(address: MailAddress(name: contact.name, email: contact.email), size: 26)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(contact.name.isEmpty ? contact.email : contact.name)
                                        .font(.callout.weight(.medium)).lineLimit(1)
                                    if !contact.name.isEmpty {
                                        Text(contact.email).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(contact.id == selectedSuggestion ? Color.accentColor.opacity(0.18) : .clear,
                                        in: .rect(cornerRadius: 6))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .onHover { if $0 { selectedSuggestion = contact.id } }
                    }
                }
                .padding(4)
                .frame(width: width, alignment: .leading)
                .background(.regularMaterial, in: .rect(cornerRadius: 9))
                .overlay { RoundedRectangle(cornerRadius: 9).strokeBorder(.separator) }
                .shadow(color: .black.opacity(0.18), radius: 12, y: 5)
                .offset(x: field.minX, y: field.maxY + 4)
                .transition(.opacity)
            }
        }
    }

    private var canSend: Bool {
        !addingAttachments && !preparingQuote && !store.sending && !RecipientField.allCases.allSatisfy {
            draft[$0].isEmpty && draft.pendingRecipients[$0, default: ""].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    @ToolbarContentBuilder
    private var composeToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .principal) {
            Button("撤销", systemImage: "arrow.uturn.backward") {
                NSApp.sendAction(Selector(("undo:")), to: nil, from: nil)
            }
            .disabled(store.sending)
            Button("格式") { showFormatBar.toggle() }
                .help("显示或隐藏格式栏")
            Button("表情与符号", systemImage: "face.smiling") { NSApp.orderFrontCharacterPalette(nil) }
                .disabled(store.sending)
        }
        ToolbarItem(placement: .principal) {
            Menu {
                Button("重做") { NSApp.sendAction(Selector(("redo:")), to: nil, from: nil) }
                Toggle("显示密送", isOn: $showBcc)
                    .disabled(!draft.bcc.isEmpty || !(draft.pendingRecipients[.bcc] ?? "").isEmpty)
                Menu("邮件签名") {
                    Button("无签名") { selectSignature(nil) }
                    ForEach(store.signatures.entries) { signature in
                        Button(signature.name) { selectSignature(signature) }
                    }
                }.disabled(preparingQuote || store.savingDraft || store.sending)
                Divider()
                Button("保存草稿") { saveDraft(close: false) }
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(!canSaveDraft || store.savingDraft || addingAttachments || preparingQuote)
            } label: { Label("写信选项", systemImage: "list.bullet.rectangle") }
            .disabled(store.sending)
        }
        ToolbarItem(placement: .principal) {
            Button("添加附件", systemImage: "paperclip") { showPicker = true }
                .disabled(addingAttachments || store.sending)
        }
        ToolbarItemGroup(placement: .principal) {
            Toggle(isOn: $draft.encrypt) {
                Label("加密", systemImage: draft.encrypt ? "lock.fill" : "lock.open")
            }
            .toggleStyle(.button)
            .disabled(store.sending)
            .help("S/MIME 加密")
            Toggle(isOn: $draft.sign) {
                Label("数字签名", systemImage: draft.sign ? "checkmark.seal.fill" : "checkmark.seal")
            }
            .toggleStyle(.button)
            .disabled(store.sending)
            .help("S/MIME 数字签名")
        }
        ToolbarItem(placement: .primaryAction) {
            let busy = store.sending || store.savingDraft
            Button(action: send) {
                // The spinner takes the arrow's place, so the button keeps its size and shape.
                Label("发送", systemImage: "arrow.up")
                    .opacity(busy ? 0 : 1)
                    .overlay {
                        if busy { ProgressView().controlSize(.small).environment(\.colorScheme, .dark) }
                    }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(!canSend && !busy)
            .allowsHitTesting(!busy)
            .help(store.sending ? "正在发送…" : store.savingDraft ? "正在保存草稿…" : "发送（⌘↩）")
            .accessibilityValue(busy ? (store.sending ? "正在发送" : "正在保存草稿") : "")
        }
    }

    private static let chineseFamilies = NSFontManager.shared.availableFontFamilies.filter { family in
        guard let font = NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: 12) else { return false }
        return (CTFontCopySupportedLanguages(font) as? [String] ?? []).contains { $0.hasPrefix("zh-Hans") }
    }.sorted { localizedFamily($0).localizedStandardCompare(localizedFamily($1)) == .orderedAscending }

    private static func localizedFamily(_ family: String) -> String {
        NSFontManager.shared.localizedName(forFamily: family, face: nil)
    }

    private func fontChoice(_ family: String) -> some View {
        Button {
            let recent = recentFamilies.components(separatedBy: "\n").filter { $0 != family }
            recentFamilies = ([family] + recent.prefix(5)).joined(separator: "\n")
            formatting = RichEdit(.family(family))
        } label: {
            if family == currentFont.familyName { Label(Self.localizedFamily(family), systemImage: "checkmark") }
            else { Text(Self.localizedFamily(family)) }
        }
    }

    private var formatBar: some View {
        let family = currentFont.familyName ?? "Helvetica"
        let faces = NSFontManager.shared.availableMembers(ofFontFamily: family) ?? []
        let traits = NSFontManager.shared.traits(of: currentFont)
        let size = currentFont.pointSize
        let headings: [CGFloat] = [12, 24, 20, 16]
        let heading = traits.contains(.boldFontMask) ? headings.dropFirst().firstIndex(of: size) ?? 0 : 0
        return HStack(spacing: 6) {
            Button { formatting = RichEdit(.formatBrush) } label: {
                Label("格式刷", systemImage: "paintbrush").labelStyle(.iconOnly)
            }.help("选中源文字后点击，再拖选目标文字以应用格式；Esc 取消")
            Picker("段落样式", selection: Binding(get: { heading }, set: { index in
                formatting = RichEdit(.paragraph(headings[index], bold: index != 0))
            })) {
                ForEach(headings.indices, id: \.self) { i in Text(i == 0 ? "正文" : "标题 \(i)").tag(i) }
            }.labelsHidden().frame(width: 98)
            Menu(Self.localizedFamily(family)) {
                Section("最近使用") {
                    ForEach(recentFamilies.components(separatedBy: "\n"), id: \.self) { fontChoice($0) }
                }
                Button("更多字体…") { formatting = RichEdit(.fontPanel) }
                Section("简体中文") { ForEach(Self.chineseFamilies, id: \.self) { fontChoice($0) } }
            }.frame(width: 116).accessibilityLabel("字体")
            Picker("字形", selection: Binding(get: { currentFont.fontName }, set: { formatting = RichEdit(.face($0)) })) {
                ForEach(faces.compactMap { $0.first as? String }, id: \.self) { name in
                    let face = NSFont(name: name, size: size)?.fontDescriptor.object(forKey: .face) as? String ?? name
                    let names = ["Regular":"常规体", "Roman":"常规体", "Oblique":"斜体", "Italic":"斜体", "Light":"细体", "Light Oblique":"细斜体", "Light Italic":"细斜体", "Bold":"粗体", "Bold Oblique":"粗斜体", "Bold Italic":"粗斜体"]
                    Text(names[face] ?? NSFontManager.shared.localizedName(forFamily: family, face: face)).tag(name)
                }
                if !faces.contains(where: { $0.first as? String == currentFont.fontName }) {
                    Text(currentFont.displayName ?? currentFont.fontName).tag(currentFont.fontName)
                }
            }.labelsHidden().frame(width: 108)
            Picker("字号", selection: Binding(get: { size }, set: { formatting = RichEdit(.size($0)) })) {
                ForEach(Set([9,10,11,12,13,14,16,18,20,24,28,32,36,48,72,size]).sorted(), id: \.self) { n in
                    Text(n.formatted()).tag(n)
                }
            }.labelsHidden().frame(width: 56)
            Button { showTextColors.toggle() } label: {
                RoundedRectangle(cornerRadius: 5).fill(Color(nsColor: ink)).frame(width: 24, height: 24)
            }.buttonStyle(.plain).accessibilityLabel("文字颜色")
                .popover(isPresented: $showTextColors, arrowEdge: .bottom) {
                    ComposeColorPalette(title: "文字颜色", reset: "自动") { color in
                        formatting = RichEdit(.color(color, background: false))
                        showTextColors = false
                    }
                }
            Button { showHighlightColors.toggle() } label: {
                Image(systemName: highlight == nil ? "nosign" : "highlighter")
                    .frame(width: 24, height: 24)
                    .background(highlight.map { Color(nsColor: $0) } ?? Color.secondary.opacity(0.12), in: .rect(cornerRadius: 5))
            }.buttonStyle(.plain).accessibilityLabel("高亮颜色")
                .popover(isPresented: $showHighlightColors, arrowEdge: .bottom) {
                    ComposeColorPalette(title: "高亮颜色", reset: "无高亮") { color in
                        formatting = RichEdit(.color(color, background: true))
                        showHighlightColors = false
                    }
                }
            ControlGroup {
                ForEach(RichStyle.allCases) { style in
                    let on = style == .bold ? traits.contains(.boldFontMask) : style == .italic ? traits.contains(.italicFontMask) : underlined
                    Toggle(isOn: Binding(get: { on }, set: { _ in formatting = RichEdit(style: style) })) {
                        Label(style.title, systemImage: style.rawValue)
                    }.keyboardShortcut(KeyEquivalent(Character(style.key)), modifiers: .command)
                }
                Toggle(isOn: Binding(get: { struck }, set: { _ in formatting = RichEdit(.strike) })) {
                    Label("删除线", systemImage: "strikethrough")
                }
            }.labelStyle(.iconOnly)
            Picker("对齐", selection: Binding(get: { alignment == .natural ? .left : alignment }, set: { formatting = RichEdit(.alignment($0)) })) {
                Image(systemName: "text.alignleft").accessibilityLabel("左对齐").tag(NSTextAlignment.left)
                Image(systemName: "text.aligncenter").accessibilityLabel("居中").tag(NSTextAlignment.center)
                Image(systemName: "text.alignright").accessibilityLabel("右对齐").tag(NSTextAlignment.right)
            }.labelsHidden().pickerStyle(.segmented)
            Menu {
            listMenu("有序列表", icon: "list.number", options: [
                ("1, 2, 3…", .decimal), ("1), 2), 3)…", .init(rawValue: "{decimal})")),
                ("一, 二, 三…", .init(rawValue: "{cjk-ideographic}")),
                ("（一）, （二）, （三）…", .init(rawValue: "（{cjk-ideographic}）")),
                ("A, B, C…", .uppercaseAlpha), ("a), b), c)…", .init(rawValue: "{lower-alpha})")),
                ("i, ii, iii…", .lowercaseRoman)
            ])
            listMenu("无序列表", icon: "list.bullet", options: [
                ("●, ●, ●…", .disc), ("○, ○, ○…", .circle), ("■, ■, ■…", .square),
                ("◆, ◆, ◆…", .diamond), ("✓, ✓, ✓…", .check),
                ("✧, ✧, ✧…", .init(rawValue: "✧")), ("➢, ➢, ➢…", .init(rawValue: "➢"))
            ])
            } label: { Label("列表", systemImage: "list.bullet").labelStyle(.iconOnly) }
        }
        .controlSize(.regular)
        .buttonStyle(.bordered)
    }

    private func listMenu(_ title: String, icon: String,
                          options: [(String, NSTextList.MarkerFormat)]) -> some View {
        Menu {
            ForEach(options.indices, id: \.self) { index in
                Button(options[index].0) { formatting = RichEdit(.list(options[index].1)) }
            }
        } label: {
            Label(title, systemImage: icon).labelStyle(.iconOnly)
        }
        .fixedSize()
        .help(title)
        .accessibilityLabel(title)
    }

    private var attachmentChips: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(draft.attachments) { item in
                    HStack(spacing: 6) {
                        Image(systemName: "paperclip").foregroundStyle(.secondary)
                        Text(item.safeName).lineLimit(1).truncationMode(.middle)
                        Text(ByteCountFormatter.string(fromByteCount: Int64(item.data.count), countStyle: .file))
                            .foregroundStyle(.secondary)
                        Button("移除 \(item.safeName)", systemImage: "xmark.circle.fill") {
                            draft.attachments.removeAll { $0.id == item.id }
                            changed()
                        }.labelStyle(.iconOnly).buttonStyle(.plain).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(.quaternary, in: .capsule)
                }
                if addingAttachments { ProgressView().controlSize(.small) }
            }
        }
        .font(.callout)
        .scrollIndicators(.hidden)
        .padding(.leading, 56)
    }

    private var searchKey: SearchKey? {
        guard let field = focusedRecipient else { return nil }
        let term = draft.pendingRecipients[field, default: ""].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return nil }
        return SearchKey(field: field, query: term)
    }

    private func visibleContacts(_ key: SearchKey) -> [ContactChoice] {
        guard suggestionKey == key else { return [] }
        var used = Set(draft[key.field].map { $0.email.lowercased() })
        return suggestions.filter { MailAddress.isValid($0.email) && used.insert($0.id).inserted }
    }

    private func findContacts(_ key: SearchKey?) async {
        guard !Task.isCancelled else { return }
        suggestions = []
        suggestionKey = key
        guard let key, store.account != nil else { return }
        // Recent correspondents answer instantly and work without directory access.
        let local = store.recentContacts.filter {
            $0.name.localizedStandardContains(key.query) || $0.email.localizedStandardContains(key.query)
        }.prefix(4).map { ContactChoice(name: $0.name, email: $0.email) }
        suggestions = Array(local)
        if let directoryRetryAfter, directoryRetryAfter > Date() { return }
        searchError = nil
        do {
            try await Task.sleep(for: .milliseconds(350))
            let matches = try await store.directorySearch(key.query)
            try Task.checkCancellation()
            suggestions = Array(local) + matches
        } catch {
            guard !Task.isCancelled else { return }
            if suggestions.isEmpty { searchError = error.localizedDescription }
            directoryRetryAfter = Date().addingTimeInterval(15)
        }
    }

    private func updateInput(_ input: String, field: RecipientField) {
        selectedSuggestion = nil
        draft.pendingRecipients[field] = input
        let parsed = MailAddress.parse(input)
        if (parsed.count > 1 || input.last.map({ ",;，；".contains($0) || $0.isNewline }) == true),
           !parsed.isEmpty, parsed.allSatisfy({ MailAddress.isValid($0.email) }) {
            add(parsed, to: field)
        } else { changed() }
    }

    private func moveSuggestion(_ direction: Int, field: RecipientField) -> KeyPress.Result {
        guard let key = searchKey, key.field == field else { return .ignored }
        let results = Array(visibleContacts(key).prefix(6))
        guard !results.isEmpty else { return .ignored }
        let index = results.firstIndex { $0.id == selectedSuggestion }
        let next = index.map { min(max(0, $0 + direction), results.count - 1) }
            ?? (direction > 0 ? 0 : results.count - 1)
        selectedSuggestion = results[next].id
        return .handled
    }

    private func submitRecipient(_ field: RecipientField) {
        let input = draft.pendingRecipients[field, default: ""]
        let parsed = MailAddress.parse(input)
        if let key = searchKey, key.field == field,
           let selected = visibleContacts(key).prefix(6).first(where: { $0.id == selectedSuggestion })
                ?? visibleContacts(key).first {
            add([MailAddress(name: selected.name, email: selected.email)], to: field)
        } else if !parsed.isEmpty, parsed.allSatisfy({ MailAddress.isValid($0.email) }) {
            add(parsed, to: field)
        } else if !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            error = "请在「\(field.label)」选择联系人或填写有效的邮箱地址。"
        }
    }

    private func add(_ addresses: [MailAddress], to field: RecipientField) {
        do {
            try draft.addRecipients(addresses, to: field)
            selectedSuggestion = nil
            error = nil
            focusedRecipient = field
            changed()
        } catch { self.error = error.localizedDescription }
    }

    private func addAttachments(_ files: [URL]) {
        guard !files.isEmpty, !addingAttachments else { return }
        addingAttachments = true
        let available = 24 * 1024 * 1024 - draft.attachments.reduce(0) { $0 + $1.data.count }
        Task {
            defer { addingAttachments = false }
            do {
                let attachments = try await Task.detached(priority: .userInitiated) {
                    var remaining = available
                    return try files.map { file in
                        let granted = file.startAccessingSecurityScopedResource()
                        defer { if granted { file.stopAccessingSecurityScopedResource() } }
                        let attachment = try Attachment(file: file)
                        guard attachment.data.count <= remaining else { throw MailError("附件合计不能超过 24 MB。") }
                        remaining -= attachment.data.count
                        return attachment
                    }
                }.value
                guard !store.locked, store.draft?.id == draft.id else { return }
                draft.attachments += attachments
                error = nil
                changed()
            } catch { self.error = error.localizedDescription }
        }
    }

    private func send() {
        guard canSend, !store.savingDraft else { return }
        do {
            try draft.commitPendingRecipients()
            draft.htmlBody = try RichEditor.exportHTML(draft.richBody, plain: draft.body)
        } catch { self.error = error.localizedDescription; return }
        changed()
        Task {
            error = nil
            await store.send()
            if store.draft == nil { close() }
            if store.draft != nil {
                error = store.error
                store.error = nil
            }
        }
    }

    private var canSaveDraft: Bool { store.draftsFolder != nil && !draft.encrypt && !draft.sign }

    private var isPristine: Bool {
        let bodyUntouched = draft.body.trimmingCharacters(in: .whitespacesAndNewlines)
            == initialBody.trimmingCharacters(in: .whitespacesAndNewlines)
        return draft.composeAction == nil && bodyUntouched && draft.subject.isEmpty && draft.attachments.isEmpty
            && RecipientField.allCases.allSatisfy { draft[$0].isEmpty && draft.pendingRecipients[$0, default: ""].isEmpty }
    }

    private func selectSignature(_ signature: MailSignature?) {
        draft.signatureID = signature?.id
        formatting = RichEdit(.signature(signature))
    }

    private func cancel() {
        if isPristine { discard() } else { confirmDiscard = true }
    }

    /// Hides the window first so it disappears at once, then drops the draft.
    private func discard() {
        close()
        store.draft = nil
    }

    private func saveDraft(close: Bool) {
        changed()
        let snapshot = draft.bodySnapshot()
        Task {
            error = nil
            let saved = await store.saveDraft(snapshot, close: close)
            if saved && close { self.close() }
            if !saved, store.draft != nil {
                error = store.error
                store.error = nil
            } else if saved, !close, let updated = store.draft, updated.id == draft.id {
                draft.replacing = updated.replacing
            }
        }
    }

    private func changed() {
        if store.draft?.id == draft.id { store.draft = draft }
    }
}

private struct RecipientAnchorKey: PreferenceKey {
    static var defaultValue: [RecipientField: Anchor<CGRect>] = [:]
    static func reduce(value: inout [RecipientField: Anchor<CGRect>], nextValue: () -> [RecipientField: Anchor<CGRect>]) {
        value.merge(nextValue()) { $1 }
    }
}

/// The separate compose window. It shows the store's current draft and closes once it is sent or discarded.
struct ComposeWindow: View {
    @ObservedObject var store: MailStore
    @State private var window: NSWindow?
    @State private var closeInterceptor = CloseInterceptor()

    var body: some View {
        Group {
            if store.locked {
                ContentUnavailableView("邮箱已锁定", systemImage: "lock", description: Text("解锁后继续编辑这封邮件。"))
            } else if let draft = store.draft {
                Composer(store: store, initial: draft, close: closeNow).id(draft.id)
            } else {
                ContentUnavailableView("没有正在编辑的邮件", systemImage: "square.and.pencil")
            }
        }
        .frame(minWidth: 680, minHeight: 600)
        .background(WindowReader(window: $window))
        .onChange(of: store.draft == nil) { _, closed in
            if closed { closeSoon() }
        }
        // A window restored at launch without a draft closes itself.
        .onChange(of: window) { _, window in
            // Compose windows are never restored at launch; an unsent draft lives in the store instead.
            window?.isRestorable = false
            // No zoom-out animation: a sent or discarded mail's window disappears immediately.
            window?.animationBehavior = .none
            // The red close button and ⌘W ask whether to keep the mail, like 取消.
            if let button = window?.standardWindowButton(.closeButton) {
                closeInterceptor.request = { [weak store = store, weak window] in
                    guard let store else { return }
                    if store.locked || store.draft == nil { window?.close() } else { store.requestComposeClose() }
                }
                button.target = closeInterceptor
                button.action = #selector(CloseInterceptor.closeClicked(_:))
            }
            if store.draft == nil { closeSoon() }
        }
    }

    private func closeNow() {
        let target = window ?? NSApp.windows.first { $0.identifier?.rawValue.hasPrefix("compose") == true }
        target?.orderOut(nil)
        target?.close()
    }

    /// Closes after the current event so a dismissing confirmation sheet can finish first.
    private func closeSoon() {
        DispatchQueue.main.async {
            guard store.draft == nil else { return }
            // SwiftUI names scene windows after their id, e.g. "compose-AppWindow-1".
            let target = window ?? NSApp.windows.first { $0.identifier?.rawValue.hasPrefix("compose") == true }
            target?.close()
        }
    }
}

/// Hands the hosting NSWindow to SwiftUI.
private struct WindowReader: NSViewRepresentable {
    @Binding var window: NSWindow?

    final class Probe: NSView {
        var found: ((NSWindow?) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            found?(window)
        }
    }

    func makeNSView(context: Context) -> Probe {
        let view = Probe()
        view.found = { found in DispatchQueue.main.async { if window !== found { window = found } } }
        return view
    }

    func updateNSView(_ view: Probe, context: Context) {}
}


/// Target for the compose window's close button.
final class CloseInterceptor: NSObject {
    var request: () -> Void = {}
    @objc func closeClicked(_ sender: Any?) { request() }
}

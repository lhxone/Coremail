import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct MailSettings: View {
    @ObservedObject var store: MailStore
    @Environment(\.dismiss) private var dismiss
    @State private var tab = Tab.account
    @State private var account: Account
    @State private var password = ""
    @State private var error: String?
    @State private var confirmRemoval = false
    @State private var confirmCacheClear = false
    @State private var cacheStatus: String?
    @State private var storageSizes: [URL: Int64]?
    @State private var storageRefresh = 0
    @State private var authenticating = false
    @State private var showConnectionCheck = false
    @AppStorage(MailStore.pollKey) private var pollMinutes = 5
    @AppStorage(MailStore.pushKey) private var listenForNewMail = true
    @AppStorage(MailStore.notifyKey) private var notify = true

    private enum Tab: Hashable { case account, incoming, compose, appearance, storage, updates }

    @AppStorage(MailAppearance.key) private var appearance: MailAppearance = .system

    init(store: MailStore) {
        self.store = store
        _account = State(initialValue: store.account ?? Account())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            TabView(selection: $tab) {
                Form {
                    Section("账户") {
                        TextField("邮箱地址", text: $account.email, prompt: Text("name@example.com"))
                        SecureField("密码或授权码", text: $password, prompt: Text(""))
                    }
                    Section("服务器") {
                        TextField("服务器域名", text: $account.host, prompt: Text("mail.example.com"))
                    }
                    Section("安全") {
                        Toggle(isOn: Binding(get: { store.touchEnabled }, set: { enabled in
                            authenticating = true
                            Task {
                                defer { authenticating = false }
                                await store.setTouchID(enabled)
                                error = store.error
                                store.error = nil
                            }
                        })) {
                            Label("使用 Touch ID 解锁邮箱", systemImage: "touchid")
                        }
                        .disabled(authenticating)
                    }
                }
                .formStyle(.grouped)
                .tabItem { Label("账户与安全", systemImage: "person.crop.circle") }
                .tag(Tab.account)

                Form {
                    Section("收信与通知") {
                        Toggle("实时监听新邮件", isOn: $listenForNewMail)
                            .onChange(of: listenForNewMail) { _, _ in store.updatePushPreference() }
                        if listenForNewMail, store.account != nil {
                            Text(store.pushConnected ? "推送已连接" : "正在连接推送 · 定时检查仍可使用")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Picker("定时检查新邮件", selection: $pollMinutes) {
                            Text("手动").tag(0)
                            Text("每 1 分钟").tag(1)
                            Text("每 5 分钟").tag(5)
                            Text("每 15 分钟").tag(15)
                            Text("每 30 分钟").tag(30)
                        }
                        .onChange(of: pollMinutes) { _, _ in store.schedulePolling() }
                        Toggle("新邮件通知", isOn: $notify)
                            .onChange(of: notify) { _, enabled in
                                if enabled { Task { await store.requestNotificationPermission() } }
                            }
                        if notify, let status = store.notificationStatus {
                            Text(status).font(.caption).foregroundStyle(.secondary)
                        }
                        if notify && store.canRequestNotifications {
                            Button("申请系统通知权限") {
                                Task { await store.requestNotificationPermission() }
                            }
                        }
                    }
                    Section("本地邮件摘要") {
                        Button(store.syncingMetadata ? "取消摘要同步" : "同步全部邮件摘要") {
                            if store.syncingMetadata { store.cancelMetadataSync() }
                            else { store.syncAllMetadata() }
                        }
                        .disabled(store.locked || store.account == nil)
                        if let progress = store.metadataProgress {
                            if progress.total > 0 {
                                ProgressView(value: Double(progress.completed), total: Double(progress.total)) {
                                    Text("\(progress.completed)/\(progress.total) 个文件夹 · \(progress.messages) 封")
                                } currentValueLabel: {
                                    Text(progress.folder).lineLimit(1)
                                }
                            } else {
                                ProgressView("正在获取文件夹…")
                            }
                        } else if let status = store.metadataSyncStatus {
                            Text(status).font(.caption).foregroundStyle(.secondary)
                        }
                        if let date = store.metadataSyncedAt {
                            LabeledContent("上次全量同步", value: date.formatted())
                        }
                    }
                }
                .formStyle(.grouped)
                .tabItem { Label("收信与通知", systemImage: "bell") }
                .tag(Tab.incoming)

                SignatureSettings(store: store)
                .tabItem { Label("写信", systemImage: "square.and.pencil") }
                .tag(Tab.compose)

                Form {
                    Picker("外观", selection: $appearance) {
                        Text("跟随系统").tag(MailAppearance.system)
                        Text("浅色").tag(MailAppearance.light)
                        Text("深色").tag(MailAppearance.dark)
                    }
                    AppIconSettings()
                }
                .formStyle(.grouped)
                .tabItem { Label("外观", systemImage: "circle.lefthalf.filled") }
                .tag(Tab.appearance)

                Form {
                    LabeledContent("本地总占用", value: storageSize(
                        [MailStorage.directory, MailStorage.messages]
                    ))
                    storagePath("应用数据目录", MailStorage.directory)
                    storagePath("本地邮件摘要", MailStorage.metadata)
                    storagePath("邮件签名", MailStorage.signatures)
                    Section("邮件缓存") {
                        storagePath("缓存目录", MailStorage.messages)
                        Button("清理邮件缓存…") { confirmCacheClear = true }
                            .disabled(store.locked || store.account == nil)
                        if let cacheStatus { Text(cacheStatus).font(.caption).foregroundStyle(.secondary) }
                    }
                }
                .formStyle(.grouped)
                .tabItem { Label("数据存储", systemImage: "internaldrive") }
                .tag(Tab.storage)

                UpdateSettings()
                    .tabItem { Label("软件更新", systemImage: "arrow.down.circle") }
                    .tag(Tab.updates)
            }
            .task { await store.updateNotificationStatus() }
            .task(id: tab == .storage ? storageRefresh : nil) {
                guard tab == .storage else { return }
                storageSizes = nil
                let scan = Task.detached(priority: .utility) {
                    var sizes: [URL: Int64] = [:]
                    for directory in [MailStorage.directory, MailStorage.metadata, MailStorage.signatures, MailStorage.messages] {
                        sizes[directory] = MailStorage.occupiedBytes(at: directory)
                    }
                    return sizes
                }
                let sizes = await withTaskCancellationHandler {
                    await scan.value
                } onCancel: {
                    scan.cancel()
                }
                if !Task.isCancelled { storageSizes = sizes }
            }
            if let error, tab == .account {
                Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled)
            }
            HStack {
                if tab == .account, store.account != nil {
                    Button("移除账户…", role: .destructive) { confirmRemoval = true }
                    Button("检查服务器…") { showConnectionCheck = true }
                }
                Spacer()
                Button(tab == .account ? "取消" : "完成") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                if tab == .account {
                    Button(store.account == nil ? "保存并连接" : "保存更改") { save() }.keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 580, height: 560)
        .sheet(isPresented: $showConnectionCheck) {
            if let saved = store.account { ConnectionCheck(account: saved, password: store.password(for:)) }
        }
        .confirmationDialog("清理邮件缓存？", isPresented: $confirmCacheClear, titleVisibility: .visible) {
            Button("清理缓存", role: .destructive) {
                Task {
                    do {
                        try await store.clearMessageCache()
                        cacheStatus = "邮件缓存已清理。"
                    } catch {
                        cacheStatus = error.localizedDescription
                    }
                    storageRefresh += 1
                }
            }
        } message: {
            Text("清理当前账户已下载的正文和附件。下一次打开这些邮件时会重新下载。")
        }
        .confirmationDialog("移除邮箱账户？", isPresented: $confirmRemoval, titleVisibility: .visible) {
            Button("移除账户", role: .destructive) { store.removeAccount() }
        } message: {
            Text("将删除这款应用保存的登录设置和钥匙串凭据。服务器上的邮件会保留。")
        }
    }

    private func storagePath(_ title: String, _ directory: URL) -> some View {
        LabeledContent(title) {
            VStack(alignment: .trailing, spacing: 3) {
                Text(storageSize([directory]))
                Text(directory.path)
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func storageSize(_ directories: [URL]) -> String {
        guard let storageSizes else { return "正在计算…" }
        let sizes = directories.compactMap { storageSizes[$0] }
        guard sizes.count == directories.count else { return "无法读取" }
        return ByteCountFormatter.string(fromByteCount: sizes.reduce(0, +), countStyle: .file)
    }

    private func save() {
        let trim = CharacterSet.whitespacesAndNewlines
        account.email = account.email.trimmingCharacters(in: trim)
        account.displayName = account.displayName.trimmingCharacters(in: trim)
        account.host = account.host.trimmingCharacters(in: trim).lowercased()
        if let saved = store.account,
           saved.email.caseInsensitiveCompare(account.email) != .orderedSame || saved.host != account.host {
            account.username = ""
        }
        do {
            try store.saveAccount(account, password: password)
            password = ""
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

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
        VStack(alignment: .leading, spacing: 10) {
            actionRow
            Divider()
            ScrollView(.vertical) {
                recipientFields.onGeometryChange(for: CGFloat.self, of: { $0.size.height }) {
                    recipientHeight = $0
                }
            }
            .scrollDisabled(recipientHeight <= 200)
            .frame(height: min(recipientHeight, 200))
            if !draft.attachments.isEmpty || addingAttachments { attachmentChips }
            Divider()
            formatBar
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
        .padding(20)
        .frame(minWidth: 680, idealWidth: 820, minHeight: 600, idealHeight: 780)
        .overlayPreferenceValue(RecipientAnchorKey.self) { anchors in
            GeometryReader { proxy in
                suggestionDropdown(anchors, in: proxy)
            }
        }
        .navigationTitle(draft.subject.isEmpty ? draft.composeTitle : "\(draft.composeTitle)：\(draft.subject)")
        .disabled(store.sending)
        .interactiveDismissDisabled()
        .onAppear {
            if draft.to.isEmpty { focusedRecipient = .to }
        }
        .onChange(of: draft.subject) { _, _ in changed() }
        .onChange(of: draft.body) { _, _ in changed() }
        .onChange(of: draft.richBody) { _, _ in changed() }
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
            .clipShape(.rect(cornerRadius: 6))
            .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(.separator) }
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
            ReplyQuote.addQuoteBorder(to: original)
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
        VStack(alignment: .leading, spacing: 5) {
            ForEach(RecipientField.allCases, id: \.self) { field in
                recipientRow(field)
            }
            HStack(spacing: 8) {
                caption("主题")
                TextField("主题", text: $draft.subject)
                    .focused($focus, equals: .subject)
                    .accessibilityLabel("主题")
            }.frame(minHeight: 27)
        }.textFieldStyle(.plain)
    }

    private func caption(_ label: String) -> some View {
        Text(label).foregroundStyle(.secondary).frame(width: 48, alignment: .trailing)
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
                ), placeholder: draft[field].isEmpty ? "输入姓名或邮箱" : "添加联系人",
                   label: field.label, isFocused: focusedRecipient == field,
                   focusChanged: { active in
                    if active { focusedRecipient = field }
                    else if focusedRecipient == field { focusedRecipient = nil }
                }, key: { key in
                    switch key {
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

    /// Send, save and attach sit in a row under the title bar, with the S/MIME options and the sender beside them.
    private var actionRow: some View {
        HStack(spacing: 8) {
            Button(action: send) {
                Label("发送", systemImage: "paperplane.fill").padding(.horizontal, 4)
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.return, modifiers: [.command])
            .disabled(!canSend)
            .help("发送（⌘↩）")
            Button { saveDraft(close: false) } label: {
                Label("保存草稿", systemImage: "square.and.arrow.down")
            }
            .keyboardShortcut("s", modifiers: .command)
            .disabled(!canSaveDraft || store.savingDraft || addingAttachments || preparingQuote)
            .help(draft.encrypt || draft.sign ? "启用 S/MIME 时不保存到服务器" : "保存到服务器草稿箱（⌘S）")
            Button { showPicker = true } label: {
                Label("附件", systemImage: "paperclip")
            }
            .disabled(addingAttachments)
            .help("添加附件，也可以把文件拖进窗口")
            if !store.signatures.entries.isEmpty || draft.signatureID != nil {
                Menu {
                    Button("无签名") { selectSignature(nil) }
                    ForEach(store.signatures.entries) { signature in
                        Button(signature.name) { selectSignature(signature) }
                    }
                } label: {
                    Label(store.signatures.entries.first { $0.id == draft.signatureID }?.name ?? "签名",
                          systemImage: "signature")
                        .lineLimit(1)
                }
                .frame(maxWidth: 136)
                .disabled(preparingQuote || store.savingDraft || store.sending)
                .help("选择邮件签名")
            }
            if store.sending || store.savingDraft { ProgressView().controlSize(.small).padding(.leading, 4) }
            Divider().frame(height: 18).padding(.horizontal, 6)
            Toggle("S/MIME 加密", isOn: $draft.encrypt)
                .help("端到端加密：收件人需安装受信任的邮件证书")
            Toggle("S/MIME 签名", isOn: $draft.sign)
                .help("完整性校验：用你的个人证书签名")
            Spacer(minLength: 8)
            if let account = store.account {
                Text(MailAddress(name: store.senderDisplayName, email: account.email).full)
                    .font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    .help("发件人")
            }
        }
        .toggleStyle(.checkbox)
        .controlSize(.large)
        .font(.callout)
    }

    private static let composeFontFamilies = {
        let available = Set(NSFontManager.shared.availableFontFamilies)
        return ["PingFang SC", "Songti SC", "Heiti SC", "Arial", "Helvetica Neue",
                "Times New Roman", "Georgia", "Verdana", "Menlo", "Courier New"].filter(available.contains)
    }()

    private var formatBar: some View {
        HStack(spacing: 2) {
            formatButton("撤销", "arrow.uturn.backward") { NSApp.sendAction(Selector(("undo:")), to: nil, from: nil) }
            formatButton("重做", "arrow.uturn.forward") { NSApp.sendAction(Selector(("redo:")), to: nil, from: nil) }
            Divider().frame(height: 16).padding(.horizontal, 4)
            ForEach(RichStyle.allCases) { style in
                Button(style.title, systemImage: style.rawValue) { formatting = RichEdit(style: style) }
                    .labelStyle(.iconOnly).help(style.title + "（⌘\(style.key.uppercased())）")
                    .frame(width: 28, height: 24)
                    .keyboardShortcut(KeyEquivalent(Character(style.key)), modifiers: .command)
            }
            Divider().frame(height: 16).padding(.horizontal, 4)
            Menu("正文样式") {
                Button("正文") { formatting = RichEdit(.paragraph(NSFont.systemFontSize, bold: false)) }
                Button("标题 1") { formatting = RichEdit(.paragraph(24, bold: true)) }
                Button("标题 2") { formatting = RichEdit(.paragraph(20, bold: true)) }
                Button("标题 3") { formatting = RichEdit(.paragraph(16, bold: true)) }
            }
            Menu("字体") {
                ForEach(Self.composeFontFamilies, id: \.self) { family in
                    Button(family) { formatting = RichEdit(.family(family)) }
                }
                Divider()
                Button("更多字体…") { NSFontManager.shared.orderFrontFontPanel(nil) }
            }
            .accessibilityLabel("字体")
            Menu("字号") {
                ForEach([9, 10, 11, 12, 13, 14, 16, 18, 20, 24, 28, 32, 36, 48, 72], id: \.self) { size in
                    Button("\(size) pt") { formatting = RichEdit(.size(CGFloat(size))) }
                }
            }
            .accessibilityLabel("字号")
            formatButton("文字颜色", "character") { showTextColors.toggle() }
                .popover(isPresented: $showTextColors, arrowEdge: .bottom) {
                    ComposeColorPalette(title: "文字颜色", reset: "自动") { color in
                        formatting = RichEdit(.color(color, background: false))
                        showTextColors = false
                    }
                }
            formatButton("高亮颜色", "highlighter") { showHighlightColors.toggle() }
                .popover(isPresented: $showHighlightColors, arrowEdge: .bottom) {
                    ComposeColorPalette(title: "高亮颜色", reset: "无高亮") { color in
                        formatting = RichEdit(.color(color, background: true))
                        showHighlightColors = false
                    }
                }
            Divider().frame(height: 16).padding(.horizontal, 4)
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
            Divider().frame(height: 16).padding(.horizontal, 4)
            formatButton("左对齐", "text.alignleft") { NSApp.sendAction(#selector(NSText.alignLeft(_:)), to: nil, from: nil) }
            formatButton("居中", "text.aligncenter") { NSApp.sendAction(#selector(NSText.alignCenter(_:)), to: nil, from: nil) }
            formatButton("右对齐", "text.alignright") { NSApp.sendAction(#selector(NSText.alignRight(_:)), to: nil, from: nil) }
            Spacer()
        }
        .buttonStyle(.borderless)
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

    private func formatButton(_ title: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(title, systemImage: icon, action: action)
            .labelStyle(.iconOnly).help(title).frame(width: 28, height: 24)
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
        let snapshot = draft
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

import AppKit
import LocalAuthentication
import SwiftUI
import UserNotifications

@MainActor
final class MailStore: ObservableObject {
    @Published private(set) var account: Account?
    @Published private(set) var serverDisplayName: String?
    private var profileTask: Task<Void, Never>?
    private var automaticMetadataPending = true

    var senderDisplayName: String {
        guard let account else { return "" }
        return account.displayName.isEmpty ? serverDisplayName ?? "" : account.displayName
    }
    func displayingAccountName(for address: MailAddress) -> MailAddress {
        let name = senderDisplayName
        guard !name.isEmpty, account?.email.caseInsensitiveCompare(address.email) == .orderedSame else {
            return address
        }
        return MailAddress(name: name, email: address.email)
    }

    @Published private(set) var signatures = MailSignatureLibrary()
    @Published private(set) var signatureLoadError: String?
    @Published private(set) var folders: [MailFolder] = []
    @Published private(set) var summaries: [MailSummary] = [] {
        didSet {
            summariesRevision &+= 1
            remember(Array(summaries.prefix(100)))
        }
    }
    /// Changes whenever `summaries` does, so views can reuse work derived from it.
    private(set) var summariesRevision = 0
    @Published private(set) var message: Message?
    private var verifiedAttachments: [UInt32: Bool] = [:]
    @Published private(set) var selectedFolder: MailFolder?
    @Published private(set) var selectedMail: UInt32?
    @Published private(set) var more = false
    @Published private(set) var syncing = false
    @Published private(set) var reading = false
    @Published private(set) var sending = false
    @Published private(set) var locked = false
    @Published private(set) var touchEnabled: Bool
    @Published private(set) var unlockInProgress = false
    @Published var error: String?
    @Published var notice: String?
    @Published private(set) var notificationStatus: String?
    @Published private(set) var canRequestNotifications = false
    @Published var draft: Draft? {
        didSet { if draft != nil && oldValue?.id != draft?.id { composeRequest += 1 } }
    }
    /// Incremented whenever the compose window should come to the front.
    @Published private(set) var composeRequest = 0
    /// Incremented when the compose window's close button asks to close.
    @Published private(set) var composeCloseRequest = 0

    func requestComposeClose() { composeCloseRequest += 1 }
    @Published var showSettings = false
    @Published var section: AppSection = .mail
    /// Set to open the contacts section on this person.
    @Published var contactFocus: MailAddress?
    @Published private(set) var recentContacts: [RecentContact] = []
    @Published private(set) var unreadCounts: [String: Int] = [:]
    /// Non-nil while the list shows results for this query.
    @Published private(set) var searchQuery: String? {
        didSet {
            guard searchQuery == nil else { return }
            activeSearch = nil
            searchPageStarts = [:]
            searchHasMore = false
            searchStatus = nil
        }
    }
    /// Where the next search looks; remembered between launches.
    @Published var searchScope: MailSearchScope = MailSearchScope(
        rawValue: UserDefaults.standard.string(forKey: "mailSearchScope") ?? "") ?? .folder {
        didSet { preferences.set(searchScope.rawValue, forKey: "mailSearchScope") }
    }
    /// Where the results on screen came from.
    @Published private(set) var activeSearchScope: MailSearchScope = .folder
    /// Progress or a partial-failure note for the server part of a search.
    @Published private(set) var searchStatus: String?
    @Published private(set) var searchHasMore = false
    private var activeSearch: (query: MailSearchQuery, keyword: String)?
    private var searchPageStarts: [String: Int] = [:]
    @Published private(set) var savingDraft = false
    @Published private(set) var metadataSyncStatus: String?
    @Published private(set) var metadataProgress: MetadataSyncProgress?
    @Published private(set) var metadataSyncedAt: Date?
    @Published private(set) var showingOfflineMetadata = false
    @Published private(set) var metadataFolders: Set<String> = []

    private var metadataTask: Task<Void, Never>?
    private var metadataOperation = UUID()

    private var coremail: CoremailMailbox?

    private var sessionPassword = SessionPassword()
    private var mailboxTask: Task<Void, Never>?
    private var readTask: Task<Void, Never>?
    private var stateID = UUID()
    private var readID = UUID()
    private let preferences = UserDefaults.standard
    private var pollTask: Task<Void, Never>?
    private var polling = false
    private var pushTask: Task<Void, Never>?
    private var pushRefresh: Task<Void, Never>?
    private var pushGeneration = UUID()
    private var pushRefreshPending = false
    @Published private(set) var pushConnected = false

    static let pollKey = "pollMinutes"
    static let pushKey = "listenForNewMail"
    static let notifyKey = "notifyNewMail"

    init() {
        let defaults = UserDefaults.standard
        defaults.register(defaults: [Self.pollKey: 5, Self.notifyKey: true, Self.pushKey: true])
        account = defaults.data(forKey: "account").flatMap { try? JSONDecoder().decode(Account.self, from: $0) }
        touchEnabled = defaults.bool(forKey: "touchID")
        locked = touchEnabled
        recentContacts = defaults.data(forKey: Self.recentKey)
            .flatMap { try? JSONDecoder().decode([RecentContact].self, from: $0) } ?? []
        loadSignatures()
        schedulePolling()
    }

    private func loadSignatures() {
        signatures = MailSignatureLibrary()
        signatureLoadError = nil
        guard let account else { return }
        do { signatures = try MailSignatureLibrary.load(for: account) }
        catch { signatureLoadError = "无法读取签名：\(error.localizedDescription)" }
    }

    func saveSignatures(_ library: MailSignatureLibrary) throws {
        guard let account, !locked else { throw MailError("请先登录邮箱。") }
        if let signatureLoadError { throw MailError(signatureLoadError) }
        try library.save(for: account)
        signatures = library
    }

    private func applyDefaultSignature(to draft: inout Draft) {
        let signature = signatures.defaultSignature
        draft.signatureID = signature?.id
        draft.richBody = signature?.block()
        draft.body = draft.richBody?.string ?? ""
    }

    // MARK: - Recent contacts

    // MARK: - Transport

    private func coremailClient(_ account: Account, _ password: String) throws -> CoremailMailbox {
        if let coremail, coremail.matches(account, password: password) { return coremail }
        if let previous = coremail { Task { await previous.flushMetadata() } }
        let client = try CoremailMailbox(account: account, password: password)
        coremail = client
        verifiedAttachments.removeAll()
        return client
    }

    func flushPendingWrites() async {
        await coremail?.flushMetadata()
    }

    func directorySearch(_ term: String) async throws -> [ContactChoice] {
        guard let account else { return [] }
        return try await coremailClient(account, password(for: account)).directorySearch(term)
    }

    func directoryAvatar(_ email: String) async -> NSImage? {
        guard let account,
              let client = try? coremailClient(account, password(for: account)),
              let data = try? await client.directoryAvatar(email), data.count <= 2 * 1024 * 1024,
              !Task.isCancelled, self.account == account, !locked else { return nil }
        return NSImage(data: data)
    }

    private static let recentKey = "recentContacts"
    private var recentSaveTask: Task<Void, Never>?

    /// Collects senders and recipients of loaded mail so contacts work without directory access.
    private func remember(_ rows: [MailSummary]) {
        guard let account, !rows.isEmpty else { return }
        var byEmail = Dictionary(recentContacts.map { ($0.email.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
        var changed = false
        for row in rows {
            for address in [row.sender].compactMap({ $0 }) + row.recipients {
                let key = address.email.lowercased()
                guard MailAddress.isValid(address.email), key != account.email.lowercased() else { continue }
                let name = address.name.trimmingCharacters(in: .whitespacesAndNewlines)
                if var known = byEmail[key] {
                    if let date = row.date, date > known.lastSeen { known.lastSeen = date; changed = true }
                    if known.name.isEmpty && !name.isEmpty { known.name = name; changed = true }
                    if !known.seenIDs.contains(row.id) {
                        known.seenIDs = Array((known.seenIDs + [row.id]).suffix(50))
                        known.count += 1
                        changed = true
                    }
                    byEmail[key] = known
                } else {
                    byEmail[key] = RecentContact(name: name, email: address.email, count: 1,
                                                 lastSeen: row.date ?? .distantPast, seenIDs: [row.id])
                    changed = true
                }
            }
        }
        guard changed else { return }
        recentContacts = Array(byEmail.values.sorted { $0.rank > $1.rank }.prefix(600))
        recentSaveTask?.cancel()
        let snapshot = recentContacts
        recentSaveTask = Task { [preferences] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let data = try? JSONEncoder().encode(snapshot) else { return }
            preferences.set(data, forKey: Self.recentKey)
        }
    }

    func compose(to address: MailAddress) {
        guard !locked, account != nil else { return }
        guard draft == nil else { composeRequest += 1; return }
        var new = Draft()
        applyDefaultSignature(to: &new)
        new.to = [address]
        draft = new
    }

    func showContact(_ address: MailAddress) {
        section = .contacts
        contactFocus = address
    }

    /// Shows the mail folder and searches messages exchanged with this address.
    func showMail(with address: String) {
        section = .mail
        if let inbox = folders.first(where: { $0.role == .inbox }), selectedFolder?.id != inbox.id {
            selectedFolder = inbox
        }
        search(address, scope: .all)
    }

    var inboxUnread: Int {
        folders.first { $0.role == .inbox }.flatMap { unreadCounts[$0.id] } ?? 0
    }

    var selectedSummary: MailSummary? {
        selectedMail.flatMap { uid in summaries.first { $0.id == uid } }
    }

    var trashFolder: MailFolder? { folders.first { $0.role == .trash } }
    var draftsFolder: MailFolder? { folders.first { $0.role == .drafts } }
    var junkFolder: MailFolder? { folders.first { $0.role == .junk } }
    var archiveFolder: MailFolder? { folders.first { $0.role == .archive } }
    var isDraftsFolder: Bool { selectedFolder?.role == .drafts }

    var currentFolderSynced: Bool {
        selectedFolder.map { metadataFolders.contains($0.id) } ?? false
    }

    var syncingMetadata: Bool { metadataProgress != nil }

    func syncAllMetadata() {
        guard !locked, let account, metadataTask == nil else { return }
        automaticMetadataPending = false
        let operation = UUID()
        metadataOperation = operation
        metadataSyncStatus = nil
        metadataProgress = .init(folder: "", completed: 0, total: 0, messages: 0)
        metadataTask = Task {
            defer {
                if operation == metadataOperation {
                    metadataTask = nil
                    metadataProgress = nil
                }
            }
            do {
                let client = try coremailClient(account, password(for: account))
                let snapshot = try await client.syncMetadata { [weak self] progress in
                    await self?.updateMetadataProgress(progress, operation: operation)
                }
                guard operation == metadataOperation, !locked else { return }
                mailboxTask?.cancel()
                stateID = UUID()
                syncing = false
                showingOfflineMetadata = false
                applyMetadata(snapshot, preferred: selectedFolder, replaceFolders: true)
                metadataSyncStatus = "已同步 \(snapshot.folders.count) 个文件夹的 \(snapshot.rows.values.reduce(0) { $0 + $1.count }) 封邮件摘要"
            } catch is CancellationError {
                if operation == metadataOperation { metadataSyncStatus = "已取消摘要同步" }
            } catch {
                if operation == metadataOperation && !Task.isCancelled { metadataSyncStatus = "摘要同步失败：\(error.localizedDescription)" }
            }
        }
    }

    func cancelMetadataSync() { metadataTask?.cancel() }

    private func updateMetadataProgress(_ progress: MetadataSyncProgress, operation: UUID) {
        if operation == metadataOperation { metadataProgress = progress }
    }

    private func resetMetadataSync() {
        cancelMetadataSync()
        metadataOperation = UUID()
        metadataTask = nil
        metadataSyncStatus = nil
        metadataProgress = nil
    }

    private func applyMetadata(_ snapshot: MailMetadata, preferred: MailFolder?, replaceFolders: Bool) {
        metadataSyncedAt = snapshot.completedAt
        metadataFolders = Set(snapshot.rows.keys)
        if replaceFolders || folders.isEmpty { folders = snapshot.folders }
        let selection = preferred.flatMap { folder in folders.first { $0.id == folder.id } } ?? folders.first
        if let selection, let rows = snapshot.rows[selection.id] {
            selectedFolder = selection
            if searchQuery == nil { summaries = rows }
            more = false
            if let selectedMail, !summaries.contains(where: { $0.id == selectedMail }) { read(nil) }
        }
        unreadCounts.merge(snapshot.rows.mapValues { $0.lazy.filter(\.unread).count }) { _, count in count }
        updateBadge()
    }

    private func discardMetadata(for account: Account) {
        if let coremail {
            Task { try? await coremail.discardMetadata() }
        } else {
            try? MailMetadataFile(account: account).remove()
        }
    }

    func saveAccount(_ value: Account, password: String) throws {
        guard !locked else { throw MailError("请先解锁 Coremail。") }
        try value.validate()
        let encoded = try JSONEncoder().encode(value)
        let accountChanged = account.map { MailMetadataFile(account: $0).url } != MailMetadataFile(account: value).url
        let credential: String
        if password.isEmpty { credential = try sessionPassword.value(for: value) }
        else {
            try PasswordStore.save(password, for: value)
            credential = password
        }
        if let prior = account {
            if prior.keychainAccount != value.keychainAccount { PasswordStore.remove(prior) }
            if MailMetadataFile(account: prior).url != MailMetadataFile(account: value).url { discardMetadata(for: prior) }
            if prior != value || !password.isEmpty { resetMetadataSync() }
        }
        if account?.keychainAccount != value.keychainAccount { draft = nil }
        else if coremail?.matches(value, password: credential) != true { draft?.replacing = nil }
        if accountChanged {
            automaticMetadataPending = true
            serverDisplayName = nil
        }
        profileTask?.cancel()
        profileTask = nil
        account = value
        loadSignatures()
        sessionPassword.replace(credential, for: value)
        if coremail?.matches(value, password: credential) != true {
            stopPush()
            coremail = nil
        }
        preferences.set(encoded, forKey: "account")
        showSettings = false
        reset()
        refresh()
    }

    func removeAccount() {
        guard !locked else { return }
        resetMetadataSync()
        if let account {
            PasswordStore.remove(account)
            discardMetadata(for: account)
            if let coremail { Task { try? await coremail.clearBodyCache() } }
            else { try? MessageBodyCache(account: account).removeAll() }
        }
        sessionPassword.clear()
        stopPush()
        coremail = nil
        account = nil
        profileTask?.cancel()
        profileTask = nil
        serverDisplayName = nil
        loadSignatures()
        draft = nil
        preferences.removeObject(forKey: "account")
        preferences.removeObject(forKey: Self.recentKey)
        recentContacts = []
        showSettings = false
        searchQuery = nil
        reset()
    }

    func password(for account: Account) throws -> String {
        guard !locked, self.account == account else { throw MailError("请先解锁 Coremail 或重新选择账户。") }
        return try sessionPassword.value(for: account)
    }

    func refresh() {
        searchQuery = nil
        load(folder: selectedFolder, page: false, reloadFolders: true)
    }

    func choose(_ folder: MailFolder) {
        if selectedFolder?.id == folder.id && searchQuery == nil { return }
        searchQuery = nil
        load(folder: folder, page: false, reloadFolders: false)
    }

    func loadMore() {
        guard more, !syncing, searchQuery == nil else { return }
        load(folder: selectedFolder, page: true, reloadFolders: false)
    }

    private func load(folder: MailFolder?, page: Bool, reloadFolders: Bool) {
        guard !locked, let account else { return }
        if !page { reset(keepFolders: true) }
        if let folder { selectedFolder = folder }
        let current = stateID
        syncing = true
        notice = nil
        mailboxTask = Task {
            defer { if current == stateID { syncing = false } }
            var hasLocalRows = false
            do {
                let credential = Result { try self.password(for: account) }
                let client = try coremailClient(account, (try? credential.get()) ?? "")
                if let snapshot = await client.localMetadata() {
                    guard current == stateID, !Task.isCancelled else { return }
                    applyMetadata(snapshot, preferred: folder, replaceFolders: false)
                    hasLocalRows = currentFolderSynced
                }
                _ = try credential.get()
                if hasLocalRows && !reloadFolders { return }
                let initialFolders = folders
                let available = reloadFolders || initialFolders.isEmpty ? try await client.folders() : initialFolders
                guard let selection = folder.flatMap({ original in available.first { $0.id == original.id } })
                        ?? available.first else {
                    throw MailError("服务器没有返回可用的文件夹。")
                }
                let (rows, hasMore, arrivals) = try await client.list(selection.id, widen: page)
                guard current == stateID, !Task.isCancelled else { return }
                notify(arrivals)
                if reloadFolders, selection.role != .inbox, let inbox = available.first(where: { $0.role == .inbox }) {
                    if let result = try? await client.poll(nil, inbox: inbox.id),
                       current == stateID, !Task.isCancelled {
                        notify(result.arrivals)
                    }
                }
                let counts = await client.unreadCounts()
                guard current == stateID, !Task.isCancelled else { return }
                folders = available
                selectedFolder = selection
                unreadCounts = counts
                updateBadge()
                summaries = rows
                more = hasMore
                showingOfflineMetadata = false
                startPush()
                resolveDisplayName(account, using: client)
                if automaticMetadataPending { syncAllMetadata() }
            } catch {
                guard current == stateID, !Task.isCancelled else { return }
                if hasLocalRows { showingOfflineMetadata = true }
                else { self.error = error.localizedDescription }
            }
        }
    }

    private func resolveDisplayName(_ account: Account, using client: CoremailMailbox) {
        guard account.displayName.isEmpty, profileTask == nil else { return }
        profileTask = Task { [weak self] in
            let name = try? await client.ownDisplayName()
            guard !Task.isCancelled, let self, self.account == account, !locked else { return }
            profileTask = nil
            if let name { serverDisplayName = name }
        }
    }

    func relatedMail(to event: AgendaEvent) async -> [RelatedMail] {
        guard let account, !locked else { return [] }
        let credential = try? password(for: account)
        guard let client = try? coremailClient(account, credential ?? "") else { return [] }
        let matches = await client.relatedMail(to: event, allowRemote: credential != nil)
        return self.account == account && !locked ? matches : []
    }

    func openRelatedMail(_ result: RelatedMail) async {
        guard !locked, let account, let folder = folders.first(where: { $0.id == result.folder }) else {
            error = "找不到关联邮件所在的文件夹。"
            return
        }
        section = .mail
        choose(folder)
        await mailboxTask?.value
        guard self.account == account, selectedFolder?.id == folder.id, !locked else { return }
        if !summaries.contains(where: { $0.id == result.row.id }) { summaries.append(result.row) }
        read(result.row.id)
    }

    func clearMessageCache() async throws {
        guard let account, !locked else { return }
        if let coremail { try await coremail.clearBodyCache() }
        else { try MessageBodyCache(account: account).removeAll() }
    }

    func showsAttachment(for row: MailSummary) -> Bool {
        verifiedAttachments[row.id] ?? row.hasAttachment
    }

    func read(_ uid: UInt32?) {
        readTask?.cancel()
        readID = UUID()
        let current = readID
        selectedMail = uid
        message = nil
        reading = false
        guard !locked, let account, let uid, let folder = selectedFolder else { return }
        reading = true
        readTask = Task {
            defer { if current == readID { reading = false } }
            do {
                let password = try? self.password(for: account)
                let unread = summaries.first { $0.id == uid }?.unread == true
                let client = try coremailClient(account, password ?? "")
                let data = try await client.message(uid, allowDownload: password != nil)
                guard current == readID, !Task.isCancelled else { return }
                let parsed = await Task.detached(priority: .userInitiated) { MIME.message(data) }.value
                guard current == readID, !Task.isCancelled else { return }
                if parsed.securityError == nil {
                    verifiedAttachments[uid] = !parsed.attachments.isEmpty
                }
                message = parsed
                reading = false
                let marked = unread && password != nil ? (try? await client.setRead(uid, true)) != nil : false
                guard current == readID, !Task.isCancelled else { return }
                if marked, let index = summaries.firstIndex(where: { $0.id == uid }), summaries[index].unread {
                    summaries[index].unread = false
                    adjustUnread(folder.id, by: -1)
                }
            } catch {
                if current == readID && !Task.isCancelled { self.error = error.localizedDescription }
            }
        }
    }

    func compose(_ action: ComposeAction? = nil) {
        guard !locked else { return }
        guard let account else { showSettings = true; return }
        guard draft == nil else { composeRequest += 1; return }
        if let action, let message {
            guard message.securityError == nil || action == .forwardAsAttachment else {
                error = "解密邮件后才能引用正文或附带原附件。"
                return
            }
            if action == .editDraft {
                var edited = Draft(draft: message, replacing: selectedFolder.flatMap { folder in
                    selectedMail.map { (folder: folder.id, uid: $0) }
                })
                if let html = message.html, let rich = Self.attributed(html: html, images: message.inlineImages) {
                    edited.richBody = rich
                    edited.body = rich.string
                }
                draft = edited
            } else {
                var reply = Draft(message: message, account: account, action: action)
                applyDefaultSignature(to: &reply)
                draft = reply
            }
        } else {
            var new = Draft()
            applyDefaultSignature(to: &new)
            draft = new
        }
    }

    /// Starts a new message from a mailto: link.
    func compose(mailto url: URL) {
        guard !locked, account != nil else { return }
        guard draft == nil else { composeRequest += 1; return }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        var new = Draft()
        applyDefaultSignature(to: &new)
        let address = components?.path.removingPercentEncoding ?? ""
        new.to = MailAddress.parse(address).filter { MailAddress.isValid($0.email) }
        for item in components?.queryItems ?? [] {
            let value = item.value ?? ""
            switch item.name.lowercased() {
            case "subject": new.subject = value
            case "cc": new.cc = MailAddress.parse(value).filter { MailAddress.isValid($0.email) }
            case "body":
                let text = NSMutableAttributedString(string: value)
                if let signature = new.richBody { text.append(signature) }
                new.body = text.string
                new.richBody = text
            default: break
            }
        }
        draft = new
    }

    private static func attributed(html: String, images: [InlineImage]) -> NSAttributedString? {
        guard let parsed = try? MailImageAttachment.editableDraft(html, images: images) else { return nil }
        var defaultColors: [NSRange] = []
        parsed.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: parsed.length)) { value, span, _ in
            if let color = value as? NSColor, let rgb = color.usingColorSpace(.sRGB),
               rgb.redComponent < 0.02, rgb.greenComponent < 0.02, rgb.blueComponent < 0.02 {
                defaultColors.append(span)
            }
        }
        for span in defaultColors { parsed.addAttribute(.foregroundColor, value: NSColor.labelColor, range: span) }
        return parsed
    }

    func send() async {
        guard !locked, !sending, !savingDraft, let draft, let account else { return }
        sending = true
        defer { sending = false }
        do {
            let client = try coremailClient(account, password(for: account))
            try await client.send(draft)
            if self.draft?.id == draft.id { self.draft = nil }
            let removed = await removeReplacedDraft(draft, using: client)
            if self.account == account, !locked {
                notice = removed ? "邮件已发送" : "邮件已发送，旧草稿仍保留在草稿箱。"
                // Push only reports new inbox mail, so show the server's sent copy right away.
                if selectedFolder?.role == .sent, searchQuery == nil {
                    try? await Task.sleep(for: .seconds(1))
                    await poll(force: true)
                }
            }
        } catch {
            if self.account == account, !locked { self.error = error.localizedDescription }
        }
    }

    /// Saves the draft to the server drafts folder and returns whether it was saved.
    @discardableResult
    func saveDraft(_ updated: Draft, close: Bool = false) async -> Bool {
        guard !locked, !sending, !savingDraft, draft?.id == updated.id, let account else { return false }
        guard let folder = draftsFolder else {
            error = "服务器没有可识别的草稿箱文件夹。"
            return false
        }
        var current = updated
        savingDraft = true
        defer { savingDraft = false }
        do {
            current.htmlBody = try RichEditor.exportHTML(current.richBody, plain: current.body)
            let client = try coremailClient(account, password(for: account))
            let uid = try await client.saveDraft(current, in: folder.id)
            var removed = true
            if current.replacing?.uid != uid {
                removed = await removeReplacedDraft(current, using: client)
                current.replacing = (folder: folder.id, uid: uid)
            }
            if draft?.id == current.id { draft = close ? nil : current }
            if self.account == account, !locked {
                if removed {
                    notice = "草稿已保存到「\(folder.display)」"
                } else {
                    notice = "已保存新草稿，旧版本仍保留在草稿箱。"
                }
                if selectedFolder?.id == folder.id { await poll(force: true) }
            }
            return true
        } catch {
            if self.account == account, !locked { self.error = error.localizedDescription }
            return false
        }
    }

    private func removeReplacedDraft(_ draft: Draft, using client: CoremailMailbox) async -> Bool {
        guard let source = draft.replacing else { return true }
        do {
            try await client.delete(source.uid, permanently: true, in: source.folder)
            if coremail === client, selectedFolder?.id == source.folder {
                summaries.removeAll { $0.id == source.uid }
                if selectedMail == source.uid { read(nil) }
            }
            return true
        } catch {
            return false
        }
    }

    // MARK: - Message actions

    func perform(_ action: MailAction, on target: UInt32? = nil) {
        guard !locked, let account, selectedFolder != nil,
              let uid = target ?? selectedMail, let index = summaries.firstIndex(where: { $0.id == uid }) else { return }
        let original = summaries[index]
        guard let folder = self.folder(of: original) else { return }
        var destination: MailFolder?
        var removes = false
        switch action {
        case .markRead(let read):
            guard original.unread == read else { return }
            summaries[index].unread = !read
            adjustUnread(folder.id, by: read ? -1 : 1)
        case .flag(let flagged):
            summaries[index].flagged = flagged
        case .delete:
            removes = true
            if folder.role != .trash { destination = trashFolder }
        case .move(let target):
            guard target.id != folder.id else { return }
            removes = true
            destination = target
        }
        if removes {
            let next = summaries.indices.contains(index + 1) ? summaries[index + 1].id
                : index > 0 ? summaries[index - 1].id : nil
            summaries.remove(at: index)
            if original.unread {
                adjustUnread(folder.id, by: -1)
                if let destination { adjustUnread(destination.id, by: 1) }
            }
            if selectedMail == uid { read(next) }
        }
        let current = stateID
        Task {
            do {
                let password = try self.password(for: account)
                let client = try coremailClient(account, password)
                switch action {
                case .markRead(let read): try await client.setRead(uid, read)
                case .flag(let flagged): try await client.setFlag(uid, flagged)
                case .delete: try await client.delete(uid, permanently: folder.role == .trash)
                case .move(let target): try await client.move(uid, to: target.id)
                }
                guard current == stateID else { return }
                if removes {
                    notice = destination.map { "已移到「\($0.display)」" }
                        ?? (folder.role == .trash ? "邮件已彻底删除" : "已移到「已删除」")
                }
            } catch {
                guard current == stateID else { return }
                self.error = error.localizedDescription
                refresh()
            }
        }
    }

    // MARK: - Search

    /// Runs the search box query: local headers and cached bodies first, then the server
    /// (which can also match bodies), merged into one list.
    func search(_ text: String, scope: MailSearchScope? = nil) {
        let term = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !locked, let account, let folder = selectedFolder else { return }
        guard !term.isEmpty else {
            if searchQuery != nil { refresh() }
            return
        }
        let query = MailSearchQuery(term)
        let scope = scope ?? searchScope
        rememberSearch(term)
        reset(keepFolders: true)
        selectedFolder = folder
        searchQuery = term
        activeSearchScope = scope
        let targets = scope == .all && !folders.isEmpty ? folders.map(\.id) : [folder.id]
        syncing = true
        let current = stateID
        mailboxTask = Task {
            defer { if current == stateID { syncing = false } }
            do {
                let credential = try? self.password(for: account)
                let client = try coremailClient(account, credential ?? "")
                let local = await client.localRows(in: targets)
                var results = local.filter { query.matches($0) }
                let candidates = local.filter { query.needsBody($0) }
                if !candidates.isEmpty {
                    let bodies = await client.cachedBodies(candidates.map(\.id))
                    results += candidates.filter { row in bodies[row.id].map { query.matches(row, body: $0) } ?? false }
                }
                guard current == stateID, !Task.isCancelled else { return }
                summaries = SearchResults.merge([], results)
                guard let keyword = query.serverKeyword else { return }
                guard credential != nil else {
                    searchStatus = "仅本地结果"
                    return
                }
                activeSearch = (query, keyword)
                searchPages = Dictionary(uniqueKeysWithValues: targets.map { ($0, 0) })
                await searchServer(using: client, state: current)
            } catch {
                if current == stateID && !Task.isCancelled { self.error = error.localizedDescription }
            }
        }
    }

    /// Fetches the next page of server results for every folder that has more.
    func loadMoreSearchResults() {
        guard searchHasMore, !syncing, !locked, let account, activeSearch != nil else { return }
        syncing = true
        let current = stateID
        mailboxTask = Task {
            defer { if current == stateID { syncing = false } }
            do {
                let client = try coremailClient(account, password(for: account))
                await searchServer(using: client, state: current)
            } catch {
                if current == stateID && !Task.isCancelled { self.error = error.localizedDescription }
            }
        }
    }

    private func searchServer(using client: CoremailMailbox, state current: UUID) async {
        guard let (query, keyword) = activeSearch else { return }
        let pages = searchPages
        searchStatus = "正在搜索服务器…"
        var failed = 0
        var added = 0
        await withTaskGroup(of: (String, Result<(rows: [MailSummary], next: Int?), Error>).self) { group in
            var queue = pages.sorted { $0.key < $1.key }[...]
            func enqueue(_ group: inout TaskGroup<(String, Result<(rows: [MailSummary], next: Int?), Error>)>) {
                guard let (folder, start) = queue.popFirst() else { return }
                group.addTask {
                    do { return (folder, .success(try await client.search(keyword, in: folder, start: start))) }
                    catch { return (folder, .failure(error)) }
                }
            }
            // A few folders at a time, so a large mailbox does not flood the server.
            for _ in 0..<4 { enqueue(&group) }
            while let (folder, result) = await group.next() {
                enqueue(&group)
                guard current == stateID, !Task.isCancelled else { continue }
                switch result {
                case .success(let page):
                    searchPages[folder] = page.next
                    let rows = page.rows.filter { query.matches($0, trustServer: true) }
                    let before = summaries.count
                    summaries = SearchResults.merge(summaries, rows)
                    added += summaries.count - before
                case .failure:
                    failed += 1
                    searchPages[folder] = nil
                }
            }
        }
        guard current == stateID, !Task.isCancelled else { return }
        searchHasMore = !searchPages.isEmpty
        if failed == pages.count && pages.count > 0 {
            searchStatus = "服务器搜索失败"
        } else if failed > 0 {
            searchStatus = "部分文件夹搜索失败"
        } else {
            searchStatus = nil
        }
    }

    private var searchPages: [String: Int] {
        get { searchPageStarts }
        set { searchPageStarts = newValue.compactMapValues { $0 } }
    }

    /// The folder a row lives in: its own folder in search results, otherwise the open folder.
    func folder(of row: MailSummary) -> MailFolder? {
        if searchQuery != nil, let fid = row.serverFID, let folder = folders.first(where: { $0.coremailFID == fid }) {
            return folder
        }
        return selectedFolder
    }

    func folder(containing uid: UInt32) -> MailFolder? {
        summaries.first { $0.id == uid }.flatMap(folder(of:)) ?? selectedFolder
    }

    // MARK: - Recent searches

    private var recentSearchKey: String? {
        account.map { RecentSearches.key + "." + $0.keychainAccount }
    }

    var recentSearches: [String] {
        recentSearchKey.flatMap { preferences.stringArray(forKey: $0) } ?? []
    }

    private func rememberSearch(_ term: String) {
        guard let key = recentSearchKey else { return }
        objectWillChange.send()
        preferences.set(RecentSearches.adding(term, to: recentSearches), forKey: key)
    }

    func clearRecentSearches() {
        guard let key = recentSearchKey else { return }
        objectWillChange.send()
        preferences.removeObject(forKey: key)
    }

    // MARK: - Background refresh

    func updatePushPreference() {
        if preferences.bool(forKey: Self.pushKey) { startPush() }
        else { stopPush() }
    }

    private func startPush() {
        guard pushTask == nil, !locked, preferences.bool(forKey: Self.pushKey),
              let client = coremail, folders.contains(where: { $0.role == .inbox }) else { return }
        let generation = pushGeneration
        pushTask = Task { [weak self] in
            var retry = 5.0
            while !Task.isCancelled {
                do {
                    try await client.listenForMail { [weak self] signal in
                        await self?.receivePush(signal, generation: generation)
                    }
                } catch {
                    guard !Task.isCancelled else { return }
                }
                guard let wasConnected = self?.pushDisconnected(generation: generation) else { return }
                if wasConnected { retry = 5 }
                try? await Task.sleep(for: .seconds(retry))
                retry = min(retry * 2, 300)
            }
        }
    }

    private func stopPush() {
        pushGeneration = UUID()
        pushTask?.cancel()
        pushTask = nil
        pushRefresh?.cancel()
        pushRefresh = nil
        pushRefreshPending = false
        pushConnected = false
    }

    private func pushDisconnected(generation: UUID) -> Bool? {
        guard generation == pushGeneration else { return nil }
        let wasConnected = pushConnected
        pushConnected = false
        return wasConnected
    }

    private func receivePush(_ signal: CoremailPush.Signal, generation: UUID) {
        guard generation == pushGeneration, !locked else { return }
        if case .ready = signal { pushConnected = true }
        // Coalesce bursts without cancelling an inbox check already in flight.
        pushRefreshPending = true
        guard pushRefresh == nil else { return }
        pushRefresh = Task { [weak self] in
            while !Task.isCancelled, self?.pushRefreshPending == true {
                self?.pushRefreshPending = false
                try? await Task.sleep(for: .milliseconds(350))
                while !Task.isCancelled, self?.syncing == true || self?.polling == true {
                    try? await Task.sleep(for: .milliseconds(500))
                }
                guard !Task.isCancelled else { return }
                self?.pushRefreshPending = false
                await self?.poll()
            }
            guard !Task.isCancelled else { return }
            self?.pushRefresh = nil
        }
    }

    func schedulePolling() {
        pollTask?.cancel()
        let minutes = preferences.integer(forKey: Self.pollKey)
        guard minutes > 0 else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(minutes * 60))
                guard !Task.isCancelled else { return }
                await self?.poll()
            }
        }
    }

    /// Fetches new messages and unread counts without disturbing the current selection.
    func poll(force: Bool = false) async {
        guard !locked, !polling, force || !syncing,
              let account, let folder = selectedFolder else { return }
        polling = true
        defer { polling = false }
        let current = stateID
        let inbox = folders.first { $0.role == .inbox }
        do {
            let client = try coremailClient(account, password(for: account))
            let visibleFolder = searchQuery == nil ? folder.id : nil
            let result = try await client.poll(visibleFolder, inbox: inbox?.id)
            guard !locked, coremail === client else { return }
            notify(result.arrivals)
            let counts = await client.unreadCounts()
            guard current == stateID, !Task.isCancelled else { return }
            unreadCounts = counts
            showingOfflineMetadata = false
            updateBadge()
            if visibleFolder != nil, searchQuery == nil, result.rows != summaries {
                summaries = result.rows
                if let selectedMail, !summaries.contains(where: { $0.id == selectedMail }) { read(nil) }
            }
        } catch {
            if current == stateID, currentFolderSynced, !Task.isCancelled { showingOfflineMetadata = true }
        }
    }

    private func adjustUnread(_ folder: String, by delta: Int) {
        guard let value = unreadCounts[folder] else { return }
        unreadCounts[folder] = max(0, value + delta)
        updateBadge()
    }

    private func updateBadge() {
        let count = locked ? 0 : inboxUnread
        NSApp?.dockTile.badgeLabel = count > 0 ? (count > 999 ? "999+" : String(count)) : nil
    }

    static var notificationsAvailable: Bool { Bundle.main.bundlePath.hasSuffix(".app") }

    func updateNotificationStatus() async {
        guard Self.notificationsAvailable else {
            notificationStatus = "请从 Coremail.app 启动以使用系统通知。"
            return
        }
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        canRequestNotifications = settings.authorizationStatus == .notDetermined
        switch settings.authorizationStatus {
        case .notDetermined:
            notificationStatus = "尚未获得系统通知授权。"
        case .denied:
            notificationStatus = "系统通知已关闭，可在「系统设置 → 通知 → Coremail」开启。"
        default:
            notificationStatus = settings.alertSetting == .enabled
                ? "系统通知已授权。"
                : "横幅已关闭，可在「系统设置 → 通知 → Coremail」调整。"
        }
    }

    func requestNotificationPermission() async {
        await updateNotificationStatus()
        guard canRequestNotifications, preferences.bool(forKey: Self.notifyKey) else { return }
        do {
            _ = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
            await updateNotificationStatus()
        } catch {
            notificationStatus = "无法申请通知权限：\(error.localizedDescription)"
        }
    }

    private func notify(_ arrivals: [MailSummary]) {
        guard !arrivals.isEmpty, Self.notificationsAvailable, preferences.bool(forKey: Self.notifyKey) else { return }
        let center = UNUserNotificationCenter.current()
        let shown = arrivals.prefix(3)
        for mail in shown {
            let content = UNMutableNotificationContent()
            content.title = mail.from.isEmpty ? "新邮件" : mail.from
            content.body = mail.subject.isEmpty ? "（无主题）" : mail.subject
            content.sound = .default
            content.threadIdentifier = "inbox"
            center.add(UNNotificationRequest(identifier: "mail-\(mail.id)", content: content, trigger: nil))
        }
        if arrivals.count > shown.count {
            let content = UNMutableNotificationContent()
            content.title = "Coremail"
            content.body = "另有 \(arrivals.count - shown.count) 封新邮件"
            content.threadIdentifier = "inbox"
            center.add(UNNotificationRequest(identifier: "mail-more-\(UUID().uuidString)", content: content, trigger: nil))
        }
    }

    func setTouchID(_ enabled: Bool) async {
        guard !locked, enabled != touchEnabled else { return }
        do {
            try await authenticate(reason: enabled ? "启用 Touch ID 应用锁" : "关闭 Touch ID 应用锁")
            touchEnabled = enabled
            preferences.set(enabled, forKey: "touchID")
        } catch { self.error = error.localizedDescription }
    }

    func lock() {
        guard touchEnabled, !locked else { return }
        locked = true
        profileTask?.cancel()
        profileTask = nil
        stopPush()
        resetMetadataSync()
        showSettings = false
        section = .mail
        notice = nil
        error = nil
        searchQuery = nil
        reset()
        updateBadge()
    }

    func unlock() async {
        guard locked, !unlockInProgress else { return }
        unlockInProgress = true
        defer { unlockInProgress = false }
        do {
            try await authenticate(reason: "解锁 Coremail")
            locked = false
            refresh()
        } catch let failure as LAError where [.userCancel, .appCancel, .systemCancel].contains(failure.code) {
            // Dismissing the prompt just leaves the lock screen; it is not an error.
        } catch { self.error = error.localizedDescription }
    }

    private func authenticate(reason: String) async throws {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error),
              context.biometryType == .touchID else {
            throw MailError("此 Mac 需要设置可用的 Touch ID。\(error?.localizedDescription ?? "")")
        }
        context.localizedFallbackTitle = ""
        guard try await context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason) else {
            throw MailError("Touch ID 验证未完成。")
        }
    }

    private func reset(keepFolders: Bool = false) {
        mailboxTask?.cancel()
        readTask?.cancel()
        stateID = UUID()
        readID = UUID()
        syncing = false
        reading = false
        selectedMail = nil
        message = nil
        summaries = []
        more = false
        if !keepFolders {
            metadataSyncedAt = nil
            metadataFolders = []
            showingOfflineMetadata = false
            folders = []
            selectedFolder = nil
            unreadCounts = [:]
            updateBadge()
        }
    }
}

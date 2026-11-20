import AppKit
import QuickLook
import SwiftUI
import UniformTypeIdentifiers
import WebKit

struct MailWindow: View {
    @ObservedObject var store: MailStore
    @State private var search = ""
    @State private var initialized = false
    @State private var groupingDate = Date()
    @AppStorage("mailDateSections") private var dateSections = Data()
    @State private var collapsedFolders: Set<String> = []
    @State private var dropFolder: String?
    @State private var confirmDelete: UInt32?
    @Environment(\.openWindow) private var openWindow
    @StateObject private var agenda = Agenda()
    @StateObject private var contacts = ContactsModel()
    @ObservedObject private var updater = Updater.shared

    /// The filter term, applied after typing pauses so large folders are not rescanned per keystroke.
    @State private var appliedSearch = ""
    @State private var listCache = MailListCache()

    private var listTerm: String {
        store.searchQuery == nil ? appliedSearch.trimmingCharacters(in: .whitespacesAndNewlines) : ""
    }

    var body: some View {
        Group {
            if store.locked {
                ContentUnavailableView {
                    Label("邮箱已锁定", systemImage: "lock")
                } description: {
                    Text("使用 Touch ID 验证后继续。")
                } actions: {
                    Button {
                        Task { await store.unlock() }
                    } label: {
                        Label("使用 Touch ID 解锁", systemImage: "touchid")
                    }.buttonStyle(.borderedProminent).controlSize(.large).disabled(store.unlockInProgress)
                }
            } else if store.account == nil {
                ContentUnavailableView {
                    Label("添加邮箱账户", systemImage: "tray")
                } description: {
                    Text("使用邮箱地址和客户端专用密码连接 Coremail。")
                } actions: {
                    Button("添加账户…") { store.showSettings = true }
                        .buttonStyle(.borderedProminent).controlSize(.large)
                }
            } else {
                columns
            }
        }
        // Keep the titlebar surface continuous across the rail and split-view columns.
        .toolbarBackground(Color(nsColor: .windowBackgroundColor), for: .windowToolbar)
        .toolbarBackground(.visible, for: .windowToolbar)
        .toolbar {
            if !store.locked && store.account != nil && store.section != .mail {
                mailActions
            }
        }
        .background {
            if !store.locked && store.account != nil && store.section == .mail {
                toolbarAccessory
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let notice = store.notice, !store.locked {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text(notice).lineLimit(2)
                    Spacer()
                    Button("关闭", systemImage: "xmark") { store.notice = nil }
                        .labelStyle(.iconOnly).buttonStyle(.plain).foregroundStyle(.secondary)
                }
                .font(.callout).padding(.horizontal, 14).padding(.vertical, 9)
                .background(.bar)
                .overlay(alignment: .top) { Divider() }
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .task(id: notice) {
                    try? await Task.sleep(for: .seconds(6))
                    if store.notice == notice { withAnimation { store.notice = nil } }
                }
            }
        }
        .animation(.easeOut(duration: 0.2), value: store.notice)
        .task { await store.requestNotificationPermission() }
        .task {
            guard !initialized else { return }
            initialized = true
            if store.locked {
                // Ask for Touch ID right away instead of waiting for the unlock button.
                await store.unlock()
            } else {
                store.refresh()
            }
        }
        .onChange(of: store.selectedFolder) { _, _ in if store.searchQuery == nil { search = "" } }
        .onChange(of: store.contactFocus) { _, address in
            guard let address else { return }
            contacts.focus(address)
            store.contactFocus = nil
        }
        .onChange(of: search) { _, value in
            if value.isEmpty && store.searchQuery != nil { store.refresh() }
        }
        .onChange(of: store.searchScope) { _, scope in
            if let query = store.searchQuery { store.search(query, scope: scope) }
        }
        .task(id: search) {
            if !search.isEmpty && store.summaries.count > 500 {
                try? await Task.sleep(for: .milliseconds(200))
                guard !Task.isCancelled else { return }
            }
            appliedSearch = search
        }
        .sheet(isPresented: $store.showSettings) { MailSettings(store: store) }
        .onChange(of: store.composeRequest) { _, _ in openWindow(id: "compose") }

        .alert("Coremail", isPresented: Binding(
            get: { store.error != nil },
            set: { if !$0 { store.error = nil } }
        )) {
            Button("好") { store.error = nil }
        } message: {
            Text(store.error ?? "")
        }
        .confirmationDialog("彻底删除这封邮件？", isPresented: Binding(
            get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }
        ), titleVisibility: .visible) {
            Button("彻底删除", role: .destructive) {
                if let uid = confirmDelete { store.perform(.delete, on: uid) }
                confirmDelete = nil
            }
        } message: {
            Text("邮件将从服务器上永久移除，无法恢复。")
        }
    }

    /// Moves to trash, or asks first when the message would be removed permanently.
    private func delete(_ uid: UInt32?) {
        guard let uid = uid ?? store.selectedMail else { return }
        if store.folder(containing: uid)?.role == .trash || store.trashFolder == nil { confirmDelete = uid }
        else { store.perform(.delete, on: uid) }
    }

    private var columns: some View {
        HStack(spacing: 0) {
            SectionRail(store: store)
            switch store.section {
            case .mail: mailSplit
            case .contacts:
                NavigationSplitView {
                    ContactsPane(store: store, model: contacts)
                        .navigationSplitViewColumnWidth(min: 260, ideal: 320, max: 440)
                } detail: {
                    ContactCard(store: store, model: contacts)
                }
            case .calendar:
                NavigationSplitView {
                    CalendarPane(agenda: agenda, hasAccount: store.account != nil)
                        .navigationSplitViewColumnWidth(min: 250, ideal: 280, max: 340)
                } detail: {
                    AgendaView(account: store.account, password: store.password(for:), agenda: agenda,
                               relatedMail: store.relatedMail(to:), openRelatedMail: store.openRelatedMail(_:))
                }
            }
        }
    }

    private var toolbarAccessory: MailToolbarAccessory {
        MailToolbarAccessory(store: store, search: $search, updateShown: updater.notice != nil)
    }

    private var mailActions: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            UpdateNotice()
            Button { store.compose() } label: { Label("写信", systemImage: "square.and.pencil") }
                .help("写信（⌘N）")
            Button { store.refresh() } label: { Label("收信", systemImage: "arrow.clockwise") }
                .disabled(store.syncing)
                .help("收信（⇧⌘R）")
        }
    }

    private var mailSplit: some View {
        NavigationSplitView {
            sidebar
        } content: {
            mailList
                .navigationSplitViewColumnWidth(min: 280, ideal: 340, max: 460)
        } detail: {
            Group {
                if store.reading {
                    ProgressView("正在读取邮件…").frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let message = store.message {
                    Reader(store: store, message: message, delete: { delete(nil) })
                        .id(store.selectedMail)
                } else {
                    ContentUnavailableView {
                        Label(store.summaries.isEmpty ? "没有选中邮件" : "选择一封邮件", systemImage: "envelope.open")
                    } description: {
                        if store.inboxUnread > 0 { Text("收件箱有 \(store.inboxUnread) 封未读邮件") }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 380, ideal: 560)

        }
    }

    private var sidebar: some View {
        List(selection: Binding(get: { store.selectedFolder?.id }, set: { id in
            if let folder = store.folders.first(where: { $0.id == id }) { store.choose(folder) }
        })) {
            Section {
                ForEach(FolderOutline.rows(store.folders, collapsed: collapsedFolders)) { row in
                    if let folder = row.folder {
                        folderRow(row)
                            .badge(store.unreadCounts[folder.id] ?? 0)
                            .tag(folder.id)
                            .dropDestination(for: String.self) { items, _ in
                                let uids = items.compactMap(MailRow.uid(fromDrag:))
                                guard !uids.isEmpty, folder.id != store.selectedFolder?.id else { return false }
                                for uid in uids { store.perform(.move(folder), on: uid) }
                                return true
                            } isTargeted: { dropFolder = $0 ? folder.id : (dropFolder == folder.id ? nil : dropFolder) }
                            .listRowBackground(dropFolder == folder.id
                                               ? RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.22)).padding(.horizontal, 8)
                                               : nil)
                    } else {
                        folderRow(row).selectionDisabled()
                    }
                }
            } header: {
                if let email = store.account?.email {
                    let name = store.senderDisplayName
                    Text(name.isEmpty ? email : name)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(name.isEmpty ? .middle : .tail)
                        .padding(.top, 6)
                        .padding(.bottom, 2)
                        .help(MailAddress(name: name, email: email).full)
                }
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 300)
        .overlay {
            if store.folders.isEmpty && store.syncing { ProgressView().controlSize(.small) }
        }
    }

    private var mailList: some View {
        let (rows, grouped) = listCache.rows(store.summaries, revision: store.summariesRevision,
                                             term: listTerm, day: groupingDate)
        let searching = store.searchQuery != nil || !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let highlights = searching ? MailSearchQuery(store.searchQuery ?? listTerm).highlights : []
        let sectionKey = [store.account?.keychainAccount ?? "", store.selectedFolder?.id ?? "", searching ? "search" : "folder"].joined(separator: "\u{0}")
        let saved = listCache.sections(dateSections)
        let collapsed = saved[sectionKey] ?? (searching ? [] : [.thisMonth, .earlier])
        return VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(store.selectedFolder?.display ?? "邮件").font(.headline).lineLimit(1)
                    Text(listCaption).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                if store.syncing { ProgressView().controlSize(.small) }
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            if let query = store.searchQuery {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass")
                        Text("「\(query)」· \(store.activeSearchScope.title)").lineLimit(1)
                        Spacer()
                        Button("清除") { search = ""; store.refresh() }.buttonStyle(.link)
                    }
                    if let status = store.searchStatus {
                        Text(status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .font(.callout)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Color.accentColor.opacity(0.1), in: .rect(cornerRadius: 7))
                .padding(.horizontal, 12).padding(.bottom, 8)
            } else if MailSearchQuery(search).serverKeyword != nil {
                Button {
                    store.search(search)
                } label: {
                    Label("搜索服务器", systemImage: "magnifyingglass.circle")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.borderless).font(.callout)
                .padding(.horizontal, 16).padding(.bottom, 8)
            }
            Divider()
            List(selection: Binding(get: { store.selectedMail }, set: { store.read($0) })) {
                ForEach(MailDate.Group.allCases, id: \.self) { group in
                    if let groupRows = grouped[group] {
                        let isCollapsed = collapsed.contains(group)
                        Section {
                            if !isCollapsed { ForEach(groupRows) { mailListRow($0, highlights: highlights) } }
                        } header: {
                            Button {
                                var updated = collapsed
                                if isCollapsed { updated.remove(group) }
                                else { updated.insert(group) }
                                var preferences = saved
                                preferences[sectionKey] = updated
                                if let encoded = try? JSONEncoder().encode(preferences) {
                                    dateSections = encoded
                                }
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                                        .font(.caption2.weight(.semibold))
                                        .frame(width: 11)
                                    Text(group.rawValue).fontWeight(.semibold)
                                    Spacer()
                                    Text(groupRows.count.formatted()).monospacedDigit()
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("\(isCollapsed ? "展开" : "收起")\(group.rawValue)，\(groupRows.count) 封")
                        }
                    }
                }
                if store.searchHasMore && store.searchQuery != nil {
                    HStack {
                        Spacer()
                        Button("载入更多") { store.loadMoreSearchResults() }
                            .buttonStyle(.borderless)
                            .disabled(store.syncing)
                        Spacer()
                    }
                    .padding(.vertical, 6)
                    .selectionDisabled()
                }
                if store.more && store.searchQuery == nil {
                    HStack {
                        Spacer()
                        Button("载入较早邮件") { store.loadMore() }
                            .buttonStyle(.borderless)
                            .disabled(store.syncing)
                        Spacer()
                    }
                    .padding(.vertical, 6)
                    .selectionDisabled()
                }
            }
            .listStyle(.inset)
            .alternatingRowBackgrounds(.disabled)
            .onDeleteCommand { delete(nil) }
            .overlay {
                if rows.isEmpty, !store.syncing, !store.more, !store.searchHasMore {
                    if store.searchQuery != nil || !search.isEmpty {
                        ContentUnavailableView.search(text: store.searchQuery ?? search)
                    } else {
                        ContentUnavailableView("没有邮件", systemImage: "tray")
                    }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in
            groupingDate = Date()
        }
    }

    private func mailListRow(_ row: MailSummary, highlights: [String] = []) -> some View {
        let folder = store.folder(of: row)
        let showsFolder = store.searchQuery != nil && store.activeSearchScope == .all
        return MailRow(row: row, showRecipients: folder?.role == .sent || folder?.role == .drafts,
                showsAttachment: store.showsAttachment(for: row), highlights: highlights,
                folderName: showsFolder ? folder?.display : nil)
            .tag(row.id)
            .draggable(MailRow.dragValue(row.id))
            .contextMenu { rowMenu(row) }
            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                Button(role: .destructive) { delete(row.id) } label: { Label("删除", systemImage: "trash") }
                Button { store.perform(.flag(!row.flagged), on: row.id) } label: {
                    Label(row.flagged ? "取消旗标" : "旗标", systemImage: row.flagged ? "flag.slash" : "flag")
                }.tint(.orange)
            }
            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                Button { store.perform(.markRead(row.unread), on: row.id) } label: {
                    Label(row.unread ? "标为已读" : "标为未读",
                          systemImage: row.unread ? "envelope.open" : "envelope.badge")
                }.tint(.accentColor)
            }
    }

    private var listCaption: String {
        let count = store.summaries.count
        return store.searchQuery == nil ? "\(count) 封" : "\(count) 个结果"
    }

    @ViewBuilder
    private func rowMenu(_ row: MailSummary) -> some View {
        Button(row.unread ? "标为已读" : "标为未读", systemImage: row.unread ? "envelope.open" : "envelope.badge") {
            store.perform(.markRead(row.unread), on: row.id)
        }
        Button(row.flagged ? "取消旗标" : "添加旗标", systemImage: row.flagged ? "flag.slash" : "flag") {
            store.perform(.flag(!row.flagged), on: row.id)
        }
        Divider()
        MoveMenu(store: store, uid: row.id)
        if let junk = store.junkFolder, store.folder(of: row)?.id != junk.id {
            Button("标为垃圾邮件", systemImage: "xmark.bin") { store.perform(.move(junk), on: row.id) }
        }
        Divider()
        Button("删除", systemImage: "trash", role: .destructive) { delete(row.id) }
    }

    private func folderRow(_ row: FolderOutline.Row) -> some View {
        HStack(spacing: 4) {
            Group {
                if row.hasChildren {
                    let collapsed = collapsedFolders.contains(row.id)
                    Button {
                        withAnimation(.easeOut(duration: 0.15)) {
                            if collapsed { collapsedFolders.remove(row.id) }
                            else { collapsedFolders.insert(row.id) }
                        }
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .rotationEffect(.degrees(collapsed ? 0 : 90))
                            .frame(width: 13, height: 20)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(collapsed ? "展开 \(row.name)" : "收起 \(row.name)")
                } else {
                    Color.clear.frame(width: 13, height: 20).accessibilityHidden(true)
                }
            }
            Label(row.name, systemImage: row.icon).lineLimit(1)
                .help(row.folder?.name ?? row.name)
            Spacer(minLength: 0)
        }
        .padding(.leading, CGFloat(min(row.depth, 12) * 14))
        .contentShape(Rectangle())
    }
}

private struct MailToolbarAccessory: NSViewRepresentable {
    let store: MailStore
    @Binding var search: String
    /// Changes when the update icon appears or goes, so the accessory is resized.
    let updateShown: Bool

    final class Anchor: NSView {
        let accessory = NSTitlebarAccessoryViewController()
        private weak var installedWindow: NSWindow?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            uninstall()
            guard let window else { return }
            window.addTitlebarAccessoryViewController(accessory)
            installedWindow = window
        }

        func uninstall() {
            if let installedWindow,
               let index = installedWindow.titlebarAccessoryViewControllers.firstIndex(of: accessory) {
                installedWindow.removeTitlebarAccessoryViewController(at: index)
            }
            installedWindow = nil
        }
    }

    func makeNSView(context: Context) -> Anchor {
        let anchor = Anchor()
        let host = NSHostingView(rootView: MailToolbarControls(store: store, search: $search))
        host.frame.size = host.fittingSize
        anchor.accessory.view = host
        anchor.accessory.layoutAttribute = .right
        return anchor
    }

    func updateNSView(_ anchor: Anchor, context: Context) {
        // The update icon comes and goes; let the accessory follow the controls' width.
        guard let host = anchor.accessory.view as? NSHostingView<MailToolbarControls> else { return }
        DispatchQueue.main.async {
            host.layoutSubtreeIfNeeded()
            if host.frame.size != host.fittingSize { host.frame.size = host.fittingSize }
        }
    }

    static func dismantleNSView(_ anchor: Anchor, coordinator: ()) {
        anchor.uninstall()
    }
}

private struct MailToolbarControls: View {
    @ObservedObject var store: MailStore
    @Binding var search: String
    @FocusState private var searching: Bool

    var body: some View {
        HStack(spacing: 10) {
            UpdateNotice()
            Button { store.compose() } label: { Label("写信", systemImage: "square.and.pencil") }
                .help("写信（⌘N）")
            Button { store.refresh() } label: { Label("收信", systemImage: "arrow.clockwise") }
                .disabled(store.syncing)
                .help("收信（⇧⌘R）")
            SearchFilterMenu(store: store, search: $search)
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索", text: $search)
                    .textFieldStyle(.plain)
                    .focused($searching)
                    .onSubmit { store.search(search) }
                Button("清除搜索", systemImage: "xmark.circle.fill") { search = "" }
                    .foregroundStyle(.secondary)
                    .opacity(search.isEmpty ? 0 : 1)
                    .disabled(search.isEmpty)
                    .accessibilityHidden(search.isEmpty)
            }
            .padding(.horizontal, 8)
            .frame(width: 280, height: 24)
            .background(.background, in: .rect(cornerRadius: 6))
            .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(.separator) }
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .padding(.horizontal, 8)
        .frame(height: 28)
        .onReceive(NotificationCenter.default.publisher(for: .focusMailSearch)) { _ in
            searching = true
        }
    }
}

/// Filters, scope, recent searches and syntax help for the search box.
private struct SearchFilterMenu: View {
    @ObservedObject var store: MailStore
    @Binding var search: String

    private static let filters: [(title: String, token: String, icon: String)] = [
        ("未读", "is:unread", "envelope.badge"),
        ("已加旗标", "is:flagged", "flag"),
        ("有附件", "has:attachment", "paperclip")
    ]

    private var active: Bool {
        Self.filters.contains { MailSearchQuery.contains(token: $0.token, in: search) }
    }

    var body: some View {
        Menu {
            Section("筛选") {
                ForEach(Self.filters, id: \.token) { filter in
                    Toggle(isOn: Binding(
                        get: { MailSearchQuery.contains(token: filter.token, in: search) },
                        set: { _ in apply(MailSearchQuery.toggling(token: filter.token, in: search)) }
                    )) { Label(filter.title, systemImage: filter.icon) }
                }
            }
            Picker("搜索范围", selection: $store.searchScope) {
                ForEach(MailSearchScope.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.inline)
            let recent = store.recentSearches
            if !recent.isEmpty {
                Section("最近搜索") {
                    ForEach(recent, id: \.self) { term in
                        Button(term) { search = term; store.search(term) }
                    }
                    Button("清除最近搜索") { store.clearRecentSearches() }
                }
            }
        } label: {
            Label("筛选", systemImage: active ? "line.3.horizontal.decrease.circle.fill"
                                                    : "line.3.horizontal.decrease.circle")
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .help("筛选")
    }

    private func apply(_ text: String) {
        search = text
        // Results already on screen came from a search; run it again with the new filters.
        if store.searchQuery != nil { store.search(text) }
    }
}

extension Notification.Name {
    static let focusMailSearch = Self("Coremail.focusMailSearch")
}

/// Folder picker shared by the list's context menu and the reader.
struct MoveMenu: View {
    @ObservedObject var store: MailStore
    let uid: UInt32?

    var body: some View {
        Menu {
            ForEach(store.folders.filter { $0.id != store.selectedFolder?.id }) { folder in
                Button { store.perform(.move(folder), on: uid) } label: {
                    Label(folder.role == nil ? folder.name : folder.display, systemImage: folder.icon)
                }
            }
        } label: {
            Label("移动到", systemImage: "folder")
        }
    }
}

private struct MailRow: View {
    let row: MailSummary
    let showRecipients: Bool
    let showsAttachment: Bool
    var highlights: [String] = []
    var folderName: String?

    /// `text` with every search word marked.
    static func highlighted(_ text: String, _ words: [String]) -> AttributedString {
        var result = AttributedString(text)
        for word in words where !word.isEmpty {
            var searchRange = text.startIndex..<text.endIndex
            while let found = text.range(of: word, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                                         range: searchRange), !found.isEmpty {
                if let span = Range(found, in: result) {
                    result[span].backgroundColor = Color.yellow.opacity(0.35)
                }
                searchRange = found.upperBound..<text.endIndex
            }
        }
        return result
    }

    static func dragValue(_ uid: UInt32) -> String { "coremail-uid:\(uid)" }
    static func uid(fromDrag value: String) -> UInt32? {
        value.hasPrefix("coremail-uid:") ? UInt32(value.dropFirst(13)) : nil
    }

    private var person: String {
        if showRecipients {
            let names = row.recipients.map(\.display)
            return names.isEmpty ? "（无收件人）" : "收件人：" + names.joined(separator: "、")
        }
        return row.from.isEmpty ? "未知发件人" : row.from
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle().fill(row.unread ? Color.accentColor : .clear)
                .frame(width: 8, height: 8).padding(.top, 5)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(Self.highlighted(person, highlights))
                        .font(.body.weight(row.unread ? .semibold : .medium))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if showsAttachment {
                        Image(systemName: "paperclip").font(.caption).foregroundStyle(.secondary)
                            .accessibilityLabel("有附件")
                    }
                    if row.flagged {
                        Image(systemName: "flag.fill").font(.caption).foregroundStyle(.orange)
                            .accessibilityLabel("已加旗标")
                    }
                    if let date = row.date {
                        Text(MailDate.short(date))
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            .help(date.formatted(date: .complete, time: .shortened))
                    }
                }
                Text(Self.highlighted(row.subject.isEmpty ? "（无主题）" : row.subject, highlights))
                    .font(.callout)
                    .foregroundStyle(row.unread ? .primary : .secondary)
                    .lineLimit(2)
                if let folderName {
                    Label(folderName, systemImage: "folder")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityValue(row.unread ? "未读" : "")
    }
}

struct Avatar: View {
    let address: MailAddress?
    var size: CGFloat = 36

    var body: some View {
        let seed = (address?.email.lowercased() ?? "").unicodeScalars.reduce(UInt32(5381)) { ($0 &* 33) &+ $1.value }
        let hue = Double(seed % 360) / 360
        Circle()
            .fill(LinearGradient(colors: [Color(hue: hue, saturation: 0.45, brightness: 0.85),
                                          Color(hue: hue, saturation: 0.6, brightness: 0.65)],
                                 startPoint: .top, endPoint: .bottom))
            .frame(width: size, height: size)
            .overlay {
                Text(address?.initials ?? "?")
                    .font(.system(size: size * 0.38, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .minimumScaleFactor(0.5)
                    .padding(3)
            }
            .accessibilityHidden(true)
    }
}

private struct Reader: View {
    @ObservedObject var store: MailStore
    let message: Message
    let delete: () -> Void
    @State private var loadRemoteImages = false
    @State private var previewURL: URL?
    @State private var showAllRecipients = false
    @State private var headerHeight: CGFloat = 160
    private let page: MailHTML?

    init(store: MailStore, message: Message, delete: @escaping () -> Void) {
        self.store = store
        self.message = message
        self.delete = delete
        page = message.html.map { MailHTML(html: $0, images: message.inlineImages, location: message.htmlLocation) }
    }

    private var summary: MailSummary? { store.selectedSummary }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            actionBar
            Divider()
            // Long recipient lists and many attachments scroll inside the header instead of
            // growing the column past the window and pushing the toolbar off screen.
            ScrollView(.vertical) {
                header.onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { headerHeight = $0 }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: min(max(headerHeight, 1), 300))
            Divider()
            if let page {
                SafeHTML(page: page, loadRemoteImages: loadRemoteImages, mailto: store.compose(mailto:))
            } else {
                ScrollView {
                    Text(Self.linked(message.plain ?? message.html.map(MIME.plainText) ?? ""))
                        .font(.body).lineSpacing(3).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 24).padding(.vertical, 18)
                }
            }
        }
        .quickLookPreview($previewURL)
        .environment(\.openURL, OpenURLAction { url in
            if url.scheme?.lowercased() == "mailto" { store.compose(mailto: url); return .handled }
            return .systemAction
        })
    }

    private var actionBar: some View {
        HStack(spacing: 6) {
            if store.isDraftsFolder {
                Button { store.compose(.editDraft) } label: { Label("编辑草稿", systemImage: "pencil") }
                    .buttonStyle(.borderedProminent)
            }
            ControlGroup {
                Button { store.compose(.reply) } label: { Label("回复", systemImage: "arrowshape.turn.up.left") }
                    .help("回复（⌘R）")
                Button { store.compose(.replyAll) } label: { Label("回复全部", systemImage: "arrowshape.turn.up.left.2") }
                    .help("回复全部（⌥⌘R）")
                attachmentActionMenu(.replyWithAttachments, label: "回复全部选项")
            }
            .fixedSize()
            ControlGroup {
                Button { store.compose(.forward) } label: { Label("转发", systemImage: "arrowshape.turn.up.right") }
                    .help("转发（⇧⌘F）")
                attachmentActionMenu(.forwardAsAttachment, label: "转发选项")
            }
            .fixedSize()
            Spacer(minLength: 8)
            if let summary {
                Button { store.perform(.markRead(summary.unread)) } label: {
                    Label(summary.unread ? "标为已读" : "标为未读", systemImage: summary.unread ? "envelope.open" : "envelope.badge")
                }.help(summary.unread ? "标为已读（⇧⌘U）" : "标为未读（⇧⌘U）")
                Button { store.perform(.flag(!summary.flagged)) } label: {
                    Label(summary.flagged ? "取消旗标" : "旗标", systemImage: summary.flagged ? "flag.fill" : "flag")
                }
                .foregroundStyle(summary.flagged ? AnyShapeStyle(.orange) : AnyShapeStyle(.primary))
                .help("旗标（⇧⌘L）")
            }
            MoveMenu(store: store, uid: nil).menuIndicator(.hidden).fixedSize().help("移动到文件夹")
            Button(role: .destructive, action: delete) { Label("删除", systemImage: "trash") }
                .help("删除（⌘⌫）")
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .controlSize(.large)
        .padding(.horizontal, 16).padding(.vertical, 8)
    }

    private func attachmentActionMenu(_ action: ComposeAction, label: String) -> some View {
        Menu {
            Button(action.title) { store.compose(action) }
        } label: {
            Label(label, systemImage: "chevron.down")
                .font(.caption.weight(.semibold))
        }
        .menuIndicator(.hidden)
        .help(label)
    }

    private var header: some View {
        let sender = message.from.first.map(store.displayingAccountName(for:))
        return VStack(alignment: .leading, spacing: 10) {
            Text(message.subject.isEmpty ? "（无主题）" : message.subject)
                .font(.title2.weight(.semibold)).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .top, spacing: 11) {
                Avatar(address: sender, size: 40)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline) {
                        if let sender {
                            PersonChip(store: store, address: sender, prominent: true)
                            if !sender.name.isEmpty {
                                Text(sender.email).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                                    .lineLimit(1)
                            }
                        } else {
                            Text("未知发件人").font(.headline)
                        }
                        Spacer(minLength: 8)
                        if let date = message.date {
                            Text(date.formatted(date: .abbreviated, time: .shortened))
                                .font(.callout).foregroundStyle(.secondary)
                                .help(date.formatted(date: .complete, time: .standard))
                        }
                    }
                    recipientLine("收件人", message.to)
                    recipientLine("抄送", message.cc)
                    recipientLine("密送", message.bcc)
                }
            }
            securityBadges
            if let page, page.hasRemoteImages, !loadRemoteImages {
                HStack(spacing: 8) {
                    Image(systemName: "photo.badge.exclamationmark").foregroundStyle(.secondary)
                    Text("为保护隐私，已阻止远程图片。").foregroundStyle(.secondary)
                    Button("载入远程图片") { loadRemoteImages = true }.buttonStyle(.link)
                }
                .font(.callout)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 7))
            }
            if !message.attachments.isEmpty { attachments }
        }
        .padding(.horizontal, 22).padding(.vertical, 14)
    }

    @ViewBuilder
    private func recipientLine(_ title: String, _ list: [MailAddress]) -> some View {
        if !list.isEmpty {
            let collapsed = !showAllRecipients && list.count > MailAddress.collapsedCount
            let shown = collapsed ? Array(list.prefix(MailAddress.collapsedCount)) : list
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(title + "：").font(.callout).foregroundStyle(.secondary).fixedSize()
                WrapLayout(spacing: 0, lineSpacing: 3) {
                    ForEach(Array(shown.enumerated()), id: \.offset) { index, address in
                        PersonChip(store: store, address: address,
                                   separator: index < shown.count - 1 ? "、" : "")
                    }
                    if collapsed {
                        Button(" 等 \(list.count) 人") { showAllRecipients = true }
                            .buttonStyle(.link).font(.callout)
                    } else if showAllRecipients && list.count > MailAddress.collapsedCount {
                        Button(" 收起") { showAllRecipients = false }.buttonStyle(.link).font(.callout)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var securityBadges: some View {
        let items: [(String, String, Color)] = [
            message.securityError.map { ($0, "exclamationmark.lock", Color.orange) },
            message.securityWarning.map { ($0, "exclamationmark.shield", Color.orange) },
            message.securityError == nil && message.encrypted ? ("S/MIME 已解密", "lock.shield", Color.green) : nil,
            message.signature.map { ($0, "signature", Color.secondary) }
        ].compactMap { $0 }
        if !items.isEmpty {
            HStack(spacing: 8) {
                ForEach(items, id: \.0) { item in
                    Label(item.0, systemImage: item.1)
                        .font(.caption).foregroundStyle(item.2)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(item.2.opacity(0.12), in: .capsule)
                }
            }
        }
    }

    private var attachments: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("\(message.attachments.count) 个附件 · \(ByteCountFormatter.string(fromByteCount: Int64(message.attachments.reduce(0) { $0 + $1.data.count }), countStyle: .file))")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if message.attachments.count > 1 {
                    Button("全部保存…") { saveAll() }.buttonStyle(.link).font(.caption)
                }
            }
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(message.attachments) { attachment in
                        AttachmentChip(attachment: attachment)
                            .onTapGesture(count: 2) { open(attachment) }
                            .contextMenu { attachmentMenu(attachment) }
                            .overlay(alignment: .trailing) {
                                Menu { attachmentMenu(attachment) } label: { Image(systemName: "chevron.down").accessibilityLabel("附件操作") }
                                    .menuStyle(.borderlessButton).menuIndicator(.hidden)
                                    .frame(width: 22, height: 22).padding(.trailing, 4)
                            }
                    }
                }
                .padding(.bottom, 2)
            }
            .scrollIndicators(.hidden)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func attachmentMenu(_ attachment: Attachment) -> some View {
        Button("快速查看", systemImage: "eye") { previewURL = temporaryFile(attachment) }
        Button("打开", systemImage: "arrow.up.forward.app") { open(attachment) }
        Button("保存附件…", systemImage: "square.and.arrow.down") { save(attachment, openInCalendar: false) }
        if attachment.calendar {
            Button("添加到日历…", systemImage: "calendar.badge.plus") { save(attachment, openInCalendar: true) }
        }
    }

    private func temporaryFile(_ attachment: Attachment) -> URL? {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("Coremail-Attachments", isDirectory: true)
            .appendingPathComponent(attachment.id.uuidString, isDirectory: true)
        let url = folder.appendingPathComponent(attachment.safeName)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: url.path) { try attachment.data.write(to: url, options: .atomic) }
            try Attachment.quarantine(url, sender: message.from.first?.email)
            return url
        } catch {
            store.error = error.localizedDescription
            return nil
        }
    }

    private func open(_ attachment: Attachment) {
        if let url = temporaryFile(attachment) { NSWorkspace.shared.open(url) }
    }

    private func save(_ attachment: Attachment, openInCalendar: Bool) {
        let dialog = NSSavePanel()
        dialog.nameFieldStringValue = attachment.safeName
        if openInCalendar { dialog.allowedContentTypes = [.calendarEvent] }
        dialog.begin { result in
            guard result == .OK, let url = dialog.url else { return }
            do {
                try attachment.data.write(to: url, options: .atomic)
                try Attachment.quarantine(url, sender: message.from.first?.email)
                if openInCalendar { NSWorkspace.shared.open(url) }
            } catch { store.error = error.localizedDescription }
        }
    }

    private func saveAll() {
        let dialog = NSOpenPanel()
        dialog.canChooseDirectories = true
        dialog.canChooseFiles = false
        dialog.canCreateDirectories = true
        dialog.prompt = "保存"
        dialog.message = "选择保存全部附件的文件夹"
        dialog.begin { result in
            guard result == .OK, let folder = dialog.url else { return }
            do {
                for attachment in message.attachments {
                    var url = folder.appendingPathComponent(attachment.safeName)
                    var index = 2
                    while FileManager.default.fileExists(atPath: url.path) {
                        let base = (attachment.safeName as NSString).deletingPathExtension
                        let ext = (attachment.safeName as NSString).pathExtension
                        url = folder.appendingPathComponent(ext.isEmpty ? "\(base) \(index)" : "\(base) \(index).\(ext)")
                        index += 1
                    }
                    try attachment.data.write(to: url, options: .withoutOverwriting)
                    try Attachment.quarantine(url, sender: message.from.first?.email)
                }
                store.notice = "已保存 \(message.attachments.count) 个附件"
            } catch { store.error = error.localizedDescription }
        }
    }

    /// Plain-text bodies get clickable web and mail links.
    static func linked(_ text: String) -> AttributedString {
        var output = AttributedString(text)
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return output }
        for match in detector.matches(in: text, range: NSRange(text.startIndex..., in: text)).prefix(500) {
            guard let url = match.url, ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? ""),
                  let range = Range(match.range, in: text),
                  let lower = AttributedString.Index(range.lowerBound, within: output),
                  let upper = AttributedString.Index(range.upperBound, within: output) else { continue }
            output[lower..<upper].link = url
        }
        return output
    }
}

private struct AttachmentChip: View {
    let attachment: Attachment

    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: icon).resizable().frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(attachment.safeName).font(.callout).lineLimit(1).truncationMode(.middle)
                Text(ByteCountFormatter.string(fromByteCount: Int64(attachment.data.count), countStyle: .file))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .frame(maxWidth: 170, alignment: .leading)
            Color.clear.frame(width: 18, height: 1)
        }
        .padding(.leading, 8).padding(.vertical, 6).padding(.trailing, 4)
        .frame(height: 44)
        .background(.quaternary.opacity(0.6), in: .rect(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(.separator.opacity(0.6)) }
        .contentShape(.rect(cornerRadius: 8))
        .help("双击打开 · \(attachment.safeName)")
    }

    private var icon: NSImage {
        let ext = (attachment.safeName as NSString).pathExtension
        let type = UTType(filenameExtension: ext) ?? UTType(mimeType: attachment.type) ?? .data
        return NSWorkspace.shared.icon(for: type)
    }
}

struct SafeHTML: NSViewRepresentable {
    let page: MailHTML
    let loadRemoteImages: Bool
    var mailto: ((URL) -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView { context.coordinator.makeWebView() }

    func updateNSView(_ web: WKWebView, context: Context) {
        context.coordinator.mailto = mailto
        context.coordinator.load(page, into: web, allowRemote: loadRemoteImages)
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKURLSchemeHandler {
        private var html: String?
        private var loadRemote = false
        private var resources: [String: InlineImage] = [:]
        var mailto: ((URL) -> Void)?

        @MainActor
        func makeWebView() -> WKWebView {
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            configuration.defaultWebpagePreferences.allowsContentJavaScript = false
            configuration.setURLSchemeHandler(self, forURLScheme: "coremail-image")
            let sizing = "const sizingRoot = document;\n" + ImageSizing.javascript + """
                for (const image of document.images) {
                    const [width, height, cellLimit] = imageDimensions(image);
                    if (cellLimit) image.style.setProperty('max-width', 'min(100%, ' + width + 'px)', 'important');
                    else if (width > 0) image.style.width = width + 'px';
                    else if (height > 0) {
                        const fitHeight = () => {
                            if (image.naturalHeight > 0) image.style.width = (height * image.naturalWidth / image.naturalHeight) + 'px';
                        };
                        image.addEventListener('load', fitHeight);
                        fitHeight();
                    }
                }
                """
            configuration.userContentController.addUserScript(WKUserScript(source: sizing, injectionTime: .atDocumentEnd,
                forMainFrameOnly: true, in: .defaultClient))
            let web = WKWebView(frame: .zero, configuration: configuration)
            web.navigationDelegate = self
            web.allowsMagnification = true
            return web
        }

        @MainActor
        func load(_ page: MailHTML, into web: WKWebView, allowRemote: Bool) {
            guard html != page.content || loadRemote != allowRemote else { return }
            html = page.content
            loadRemote = allowRemote
            resources = page.resources
            let sources = "data: coremail-image:" + (allowRemote ? " https: http:" : "")
            let policy = "default-src 'none'; img-src \(sources); style-src 'unsafe-inline'; font-src data:; base-uri 'none'; form-action 'none'; frame-src 'none';"
            // Mail HTML is authored for a light page; forcing a white sheet keeps dark text readable in Dark Mode.
            let head = """
                <!doctype html><meta charset="utf-8"><meta name="referrer" content="no-referrer">
                <meta http-equiv="Content-Security-Policy" content="\(policy)">
                <meta name="color-scheme" content="light only">
                <meta name="viewport" content="width=device-width, initial-scale=1">
                <style>
                html{background:#fff;color:#1d1d1f}
                body{font:14px/1.55 -apple-system,"PingFang SC","Helvetica Neue",sans-serif;margin:18px 24px;overflow-wrap:anywhere;-webkit-text-size-adjust:none}
                img{max-width:100% !important;height:auto !important;object-fit:contain} table{max-width:100%} pre{white-space:pre-wrap}
                blockquote{margin:0 0 0 .4em;padding-left:.9em;border-left:3px solid #d0d0d5;color:#555}
                a{color:#0a64d8}
                </style>
                """
            web.loadHTMLString(head + page.content, baseURL: nil)
        }

        func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
            guard let url = task.request.url, url.host == "inline", let resource = resources[url.lastPathComponent] else {
                task.didFailWithError(URLError(.resourceUnavailable))
                return
            }
            let response = URLResponse(url: url, mimeType: resource.mediaType,
                                       expectedContentLength: resource.bytes.count, textEncodingName: nil)
            task.didReceive(response)
            task.didReceive(resource.bytes)
            task.didFinish()
        }

        func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = action.request.url else { decisionHandler(.cancel); return }
            if action.navigationType == .linkActivated, ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "") {
                if url.scheme?.lowercased() == "mailto", let mailto { mailto(url) }
                else { NSWorkspace.shared.open(url) }
                decisionHandler(.cancel)
            } else {
                decisionHandler(action.navigationType == .other && url.absoluteString == "about:blank" ? .allow : .cancel)
            }
        }
    }
}


/// Memoizes the filtered and date-grouped list. Held in @State as a reference so filling
/// it during `body` does not invalidate the view.
final class MailListCache {
    private struct Key: Equatable {
        let revision: Int
        let term: String
        let day: Date
    }
    private var key: Key?
    private var value: (rows: [MailSummary], grouped: [MailDate.Group: [MailSummary]]) = ([], [:])
    private var sectionData: Data?
    private var sectionValue: [String: Set<MailDate.Group>] = [:]

    func rows(_ summaries: [MailSummary], revision: Int, term: String,
              day: Date) -> (rows: [MailSummary], grouped: [MailDate.Group: [MailSummary]]) {
        let key = Key(revision: revision, term: term, day: day)
        if key == self.key { return value }
        let query = MailSearchQuery(term)
        let rows = query.isEmpty ? summaries : summaries.filter { query.matches($0) }
        value = (rows, MailDate.groups(rows, now: day))
        self.key = key
        return value
    }

    func sections(_ data: Data) -> [String: Set<MailDate.Group>] {
        if data != sectionData {
            sectionValue = (try? JSONDecoder().decode([String: Set<MailDate.Group>].self, from: data)) ?? [:]
            sectionData = data
        }
        return sectionValue
    }
}

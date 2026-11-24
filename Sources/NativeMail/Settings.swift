import AppKit
import SwiftUI

/// The app's Settings window (⌘,). Each pane is a tab in the system settings toolbar.
struct MailSettings: View {
    @ObservedObject var store: MailStore
    @AppStorage("settingsTab") private var tab = Tab.account

    enum Tab: String {
        case account, incoming, compose, appearance, storage, updates
    }

    var body: some View {
        Group {
            if store.locked {
                ContentUnavailableView("邮箱已锁定", systemImage: "lock",
                                       description: Text("解锁后才能查看和修改设置。"))
            } else {
                TabView(selection: $tab) {
                    AccountSettings(store: store)
                        .tabItem { Label("账户", systemImage: "person.crop.circle") }
                        .tag(Tab.account)
                    IncomingSettings(store: store)
                        .tabItem { Label("收信", systemImage: "tray.and.arrow.down") }
                        .tag(Tab.incoming)
                    SignatureSettings(store: store)
                        .tabItem { Label("写信", systemImage: "signature") }
                        .tag(Tab.compose)
                    AppearanceSettings()
                        .tabItem { Label("外观", systemImage: "paintpalette") }
                        .tag(Tab.appearance)
                    StorageSettings(store: store)
                        .tabItem { Label("存储", systemImage: "internaldrive") }
                        .tag(Tab.storage)
                    UpdateSettings()
                        .tabItem { Label("更新", systemImage: "arrow.down.circle") }
                        .tag(Tab.updates)
                }
            }
        }
        .frame(width: 560, height: 480)
    }
}

// MARK: - 账户

private struct AccountSettings: View {
    @ObservedObject var store: MailStore
    @State private var account: Account
    @State private var password = ""
    @State private var error: String?
    @State private var confirmRemoval = false
    @State private var authenticating = false
    @State private var showConnectionCheck = false

    init(store: MailStore) {
        self.store = store
        _account = State(initialValue: store.account ?? Account())
    }

    private var edited: Bool {
        store.account == nil || account != store.account || !password.isEmpty
    }

    var body: some View {
        Form {
            Section {
                TextField("邮箱地址", text: $account.email, prompt: Text("name@example.com"))
                SecureField("密码或授权码", text: $password, prompt: Text(store.account == nil ? "" : "不修改请留空"))
                TextField("服务器域名", text: $account.host, prompt: Text("mail.example.com"))
            } header: {
                Text("账户")
            } footer: {
                HStack {
                    if store.account != nil {
                        Button("检查服务器…") { showConnectionCheck = true }
                    }
                    Spacer()
                    if store.account != nil {
                        Button("还原") { revert() }.disabled(!edited)
                    }
                    Button(store.account == nil ? "保存并连接" : "保存") { save() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!edited || store.sending)
                }
            }
            if let error {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red).textSelection(.enabled)
                }
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
            if store.account != nil {
                Section {
                    Button("移除账户…", role: .destructive) { confirmRemoval = true }
                        .disabled(store.sending)
                } footer: {
                    Text("删除这款应用保存的登录设置和钥匙串凭据，服务器上的邮件会保留。")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: store.account) { _, _ in revert() }
        .sheet(isPresented: $showConnectionCheck) {
            if let saved = store.account { ConnectionCheck(account: saved, password: store.password(for:)) }
        }
        .confirmationDialog("移除邮箱账户？", isPresented: $confirmRemoval, titleVisibility: .visible) {
            Button("移除账户", role: .destructive) { store.removeAccount() }
        } message: {
            Text("将删除这款应用保存的登录设置和钥匙串凭据。服务器上的邮件会保留。")
        }
    }

    private func revert() {
        account = store.account ?? Account()
        password = ""
        error = nil
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
            error = nil
        } catch { self.error = error.localizedDescription }
    }
}

// MARK: - 收信与通知

private struct IncomingSettings: View {
    @ObservedObject var store: MailStore
    @AppStorage(MailStore.pollKey) private var pollMinutes = 5
    @AppStorage(MailStore.pushKey) private var listenForNewMail = true
    @AppStorage(MailStore.notifyKey) private var notify = true

    var body: some View {
        Form {
            Section("收信") {
                Toggle(isOn: $listenForNewMail) {
                    Text("实时监听新邮件")
                    if listenForNewMail, store.account != nil {
                        Text(store.pushConnected ? "推送已连接" : "正在连接推送 · 定时检查仍可使用")
                    }
                }
                .onChange(of: listenForNewMail) { _, _ in store.updatePushPreference() }
                Picker("定时检查新邮件", selection: $pollMinutes) {
                    Text("手动").tag(0)
                    Text("每 1 分钟").tag(1)
                    Text("每 5 分钟").tag(5)
                    Text("每 15 分钟").tag(15)
                    Text("每 30 分钟").tag(30)
                }
                .onChange(of: pollMinutes) { _, _ in store.schedulePolling() }
            }
            Section("通知") {
                Toggle(isOn: $notify) {
                    Text("新邮件通知")
                    if notify, let status = store.notificationStatus { Text(status) }
                }
                .onChange(of: notify) { _, enabled in
                    if enabled { Task { await store.requestNotificationPermission() } }
                }
                if notify && store.canRequestNotifications {
                    Button("申请系统通知权限") {
                        Task { await store.requestNotificationPermission() }
                    }
                }
            }
            Section("本地邮件摘要") {
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
                }
                LabeledContent {
                    Button(store.syncingMetadata ? "取消同步" : "同步全部邮件摘要") {
                        if store.syncingMetadata { store.cancelMetadataSync() }
                        else { store.syncAllMetadata() }
                    }
                    .disabled(store.account == nil)
                } label: {
                    Text("上次全量同步")
                    Text(store.metadataSyncStatus ?? store.metadataSyncedAt?.formatted() ?? "从未")
                }
            }
        }
        .formStyle(.grouped)
        .task { await store.updateNotificationStatus() }
    }
}

// MARK: - 外观

private struct AppearanceSettings: View {
    @AppStorage(MailAppearance.key) private var appearance: MailAppearance = .system

    var body: some View {
        Form {
            Section {
                Picker("外观", selection: $appearance) {
                    Text("跟随系统").tag(MailAppearance.system)
                    Text("浅色").tag(MailAppearance.light)
                    Text("深色").tag(MailAppearance.dark)
                }
            }
            AppIconSettings()
        }
        .formStyle(.grouped)
    }
}

// MARK: - 数据存储

private struct StorageSettings: View {
    @ObservedObject var store: MailStore
    @State private var sizes: [URL: Int64]?
    @State private var refresh = 0
    @State private var confirmCacheClear = false
    @State private var cacheStatus: String?

    var body: some View {
        Form {
            Section {
                LabeledContent("本地总占用", value: size([MailStorage.directory, MailStorage.messages]))
            }
            Section("位置") {
                path("应用数据", MailStorage.directory)
                path("本地邮件摘要", MailStorage.metadata)
                path("邮件签名", MailStorage.signatures)
                path("邮件缓存", MailStorage.messages)
            }
            Section {
                LabeledContent {
                    Button("清理邮件缓存…") { confirmCacheClear = true }
                        .disabled(store.account == nil)
                } label: {
                    Text("已下载的正文和附件")
                    if let cacheStatus { Text(cacheStatus) }
                }
            }
        }
        .formStyle(.grouped)
        .task(id: refresh) {
            sizes = nil
            let scan = Task.detached(priority: .utility) {
                var sizes: [URL: Int64] = [:]
                for directory in [MailStorage.directory, MailStorage.metadata, MailStorage.signatures, MailStorage.messages] {
                    sizes[directory] = MailStorage.occupiedBytes(at: directory)
                }
                return sizes
            }
            let result = await withTaskCancellationHandler { await scan.value } onCancel: { scan.cancel() }
            if !Task.isCancelled { sizes = result }
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
                    refresh += 1
                }
            }
        } message: {
            Text("清理当前账户已下载的正文和附件。下一次打开这些邮件时会重新下载。")
        }
    }

    private func path(_ title: String, _ directory: URL) -> some View {
        LabeledContent {
            HStack(spacing: 8) {
                Text(size([directory])).monospacedDigit()
                Button("在访达中显示", systemImage: "folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([directory])
                }
                .labelStyle(.iconOnly).buttonStyle(.borderless)
                .help(directory.path)
            }
        } label: {
            Text(title)
            Text(directory.path).textSelection(.enabled).truncationMode(.middle)
        }
    }

    private func size(_ directories: [URL]) -> String {
        guard let sizes else { return "正在计算…" }
        let values = directories.compactMap { sizes[$0] }
        guard values.count == directories.count else { return "无法读取" }
        return ByteCountFormatter.string(fromByteCount: values.reduce(0, +), countStyle: .file)
    }
}

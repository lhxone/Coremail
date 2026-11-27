import AppKit
import Combine
import SwiftUI
import UserNotifications

@main
struct NativeMailApp: App {
    @NSApplicationDelegateAdaptor(MailAppDelegate.self) private var delegate
    @Environment(\.openWindow) private var openWindow
    @AppStorage(MailAppearance.key) private var appearance: MailAppearance = .system
    @StateObject private var store = MailStore()
    @FocusedValue(\.readerMessage) private var readerMessage

    var body: some Scene {
        // A single main window: sheets and the selection live in one shared store.
        Window("Coremail", id: "main") {
            MailWindow(store: store)
                .preferredColorScheme(appearance.colorScheme)
                .frame(minWidth: 900, minHeight: 560)
                .onOpenURL { url in
                    guard url.scheme == "coremail", url.host == "inbox" else { return }
                    openWindow(id: "main")
                    store.section = .mail
                    if let account = store.account {
                        store.notificationTarget = MailNotificationTarget(account: account.keychainAccount, row: nil)
                    }
                    NSApp.activate(ignoringOtherApps: true)
                }
                .onAppear {
                    delegate.configure(store: store) { openWindow(id: "main") }
                }
        }
        .windowToolbarStyle(.unified(showsTitle: false))
        .defaultSize(width: 1240, height: 780)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("检查更新…") {
                    Updater.shared.check(userInitiated: true)
                    openWindow(id: UpdateView.windowID)
                }
            }
            CommandGroup(replacing: .newItem) {
                Button("新邮件") { store.compose() }
                    .keyboardShortcut("n")
                    .disabled(store.locked)
            }
            CommandGroup(after: .windowArrangement) {
                Button("显示主窗口") { openWindow(id: "main") }
                    .keyboardShortcut("0")
            }
            CommandGroup(after: .appSettings) {
                Button("锁定邮箱") { store.lock() }
                    .keyboardShortcut("l", modifiers: [.command, .option])
                    .disabled(!store.touchEnabled || store.locked)
            }
            CommandGroup(after: .textEditing) {
                Button("搜索邮件") {
                    openWindow(id: "main")
                    NotificationCenter.default.post(name: .focusMailSearch, object: nil)
                }
                .keyboardShortcut("f")
                .disabled(store.locked || store.account == nil || store.section != .mail)
            }
            CommandMenu("邮件") {
                Button("收取新邮件") { store.refresh() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                    .disabled(store.account == nil || store.locked)
                Divider()
                Button("回复") { store.compose(.reply, source: readerMessage) }
                    .keyboardShortcut("r")
                    .disabled((readerMessage == nil && store.message == nil) || store.locked)
                Button("回复全部") { store.compose(.replyAll, source: readerMessage) }
                    .keyboardShortcut("r", modifiers: [.command, .option])
                    .disabled((readerMessage == nil && store.message == nil) || store.locked)
                Button("转发") { store.compose(.forward, source: readerMessage) }
                    .keyboardShortcut("f", modifiers: [.command, .shift])
                    .disabled((readerMessage == nil && store.message == nil) || store.locked)
                Button("编辑草稿") { store.compose(.editDraft) }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                    .disabled(store.message == nil || store.locked || !store.isDraftsFolder)
                Divider()
                Button(store.selectedSummary?.unread == true ? "标为已读" : "标为未读") {
                    if let summary = store.selectedSummary { store.perform(.markRead(summary.unread)) }
                }
                .keyboardShortcut("u", modifiers: [.command, .shift])
                .disabled(store.selectedSummary == nil || store.locked)
                Button(store.selectedSummary?.flagged == true ? "取消旗标" : "添加旗标") {
                    if let summary = store.selectedSummary { store.perform(.flag(!summary.flagged)) }
                }
                .keyboardShortcut("l", modifiers: [.command, .shift])
                .disabled(store.selectedSummary == nil || store.locked)
                Button("移到废纸篓") { store.perform(.delete) }
                    .keyboardShortcut(.delete, modifiers: [.command])
                    .disabled(store.selectedSummary == nil || store.locked || store.trashFolder == nil
                              || store.selectedFolder?.role == .trash)
                Button("标为垃圾邮件") { if let junk = store.junkFolder { store.perform(.move(junk)) } }
                    .keyboardShortcut("j", modifiers: [.command, .shift])
                    .disabled(store.selectedSummary == nil || store.locked || store.junkFolder == nil
                              || store.selectedFolder?.role == .junk)
                if let archive = store.archiveFolder {
                    Button("存档") { store.perform(.move(archive)) }
                        .keyboardShortcut("a", modifiers: [.command, .control])
                        .disabled(store.selectedSummary == nil || store.locked || store.selectedFolder?.id == archive.id)
                }
                Divider()
                Button("邮件") { store.section = .mail }
                    .keyboardShortcut("1", modifiers: .command)
                    .disabled(store.locked)
                Button("联系人") { store.section = .contacts }
                    .keyboardShortcut("2", modifiers: .command)
                    .disabled(store.locked)
                Button("日历") { store.section = .calendar }
                    .keyboardShortcut("3", modifiers: .command)
                    .disabled(store.locked)
            }
        }
        WindowGroup("邮件", id: "reader", for: MailReaderTarget.self) { $target in
            if let target {
                MailReaderWindow(store: store, target: target)
                    .preferredColorScheme(appearance.colorScheme)
            }
        }
        .defaultSize(width: 860, height: 780)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commandsRemoved()
        // Composing, replying and forwarding happen in their own window.
        Window("写邮件", id: "compose") {
            ComposeWindow(store: store)
                .preferredColorScheme(appearance.colorScheme)
        }
        .windowToolbarStyle(.unified(showsTitle: false))
        .defaultSize(width: 860, height: 820)
        .defaultPosition(.center)
        Window("软件更新", id: UpdateView.windowID) {
            UpdateView()
                .preferredColorScheme(appearance.colorScheme)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
        // The system settings window: ⌘, and the app menu's 「设置…」 come with it.
        Settings {
            MailSettings(store: store)
                .preferredColorScheme(appearance.colorScheme)
        }
    }
}

@MainActor
private final class MailAppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private var showMainWindow: (() -> Void)?
    private var pendingTarget: MailNotificationTarget?
    private weak var store: MailStore?
    private var workspaceObservers: Set<AnyCancellable> = []

    func applicationWillFinishLaunching(_ notification: Notification) {
        if MailStore.notificationsAvailable {
            UNUserNotificationCenter.current().delegate = self
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let icon = CustomAppIcon.current { NSApp.applicationIconImage = icon }
        Updater.shared.startAutomaticChecks()
    }

    func configure(store: MailStore, showMainWindow: @escaping () -> Void) {
        self.showMainWindow = showMainWindow
        self.store = store
        if let pendingTarget {
            store.notificationTarget = pendingTarget
            self.pendingTarget = nil
        }
        guard workspaceObservers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        for event in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            center.publisher(for: event).sink { [weak store] _ in
                Task { @MainActor in store?.lock() }
            }.store(in: &workspaceObservers)
        }
        center.publisher(for: NSWorkspace.didWakeNotification).sink { [weak store] _ in
            Task { await store?.poll() }
        }.store(in: &workspaceObservers)
    }

    /// Lets coalesced summary writes reach disk before the process exits.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let store else { return .terminateNow }
        Task { @MainActor in
            await store.flushPendingWrites()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        guard let showMainWindow else { return true }
        showMainWindow()
        return false
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier else { return }
        let info = response.notification.request.content.userInfo
        let account = info["account"] as? String
        let row = (info["row"] as? Data).flatMap { try? JSONDecoder().decode(MailSummary.self, from: $0) }
        await MainActor.run {
            if let account {
                let target = MailNotificationTarget(account: account, row: row)
                if let store { store.notificationTarget = target } else { pendingTarget = target }
            }
            showMainWindow?()
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}

enum MailAppearance: String {
    static let key = "mailAppearance"

    case system, light, dark

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

import SwiftUI

extension AppRelease: Identifiable {
    var id: String { tag }
}

/// The 「软件更新」 window: check result, release notes, download and install.
struct UpdateView: View {
    @ObservedObject var updater = Updater.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.title3.weight(.semibold))
                    Text(subtitle).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            if let release {
                ScrollView {
                    Text(Self.notes(release.notes))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                .frame(minHeight: 140, maxHeight: 260)
                .background(.background.secondary, in: .rect(cornerRadius: 8))
            }
            if case .downloading(_, let progress) = updater.phase {
                ProgressView(value: progress) { Text("正在下载…") }
            }
            HStack {
                actions
            }
        }
        .padding(20)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var release: AppRelease? {
        switch updater.phase {
        case .available(let release), .downloading(let release, _), .ready(let release): release
        default: updater.prompt
        }
    }

    private var title: String {
        switch updater.phase {
        case .idle, .checking: "正在检查更新…"
        case .upToDate: "Coremail 已是最新版本"
        case .available(let release), .downloading(let release, _): "Coremail \(release.version) 可用"
        case .ready(let release): "Coremail \(release.version) 已准备好"
        case .failed: "无法完成更新"
        }
    }

    private var subtitle: String {
        switch updater.phase {
        case .idle, .checking: "正在连接 GitHub。"
        case .upToDate: "当前版本 \(updater.currentVersion)。"
        case .available, .downloading: "当前版本 \(updater.currentVersion)。下载后会校验签名，确认与当前应用来自同一开发者。"
        case .ready: "签名已校验。重新启动后完成更新，未发送的写信内容会先保存。"
        case .failed(let message): message
        }
    }

    @ViewBuilder
    private var actions: some View {
        switch updater.phase {
        case .idle, .checking:
            ProgressView().controlSize(.small)
            Spacer()
            Button("关闭") { dismiss() }
        case .upToDate:
            Spacer()
            Button("好") { dismiss() }.keyboardShortcut(.defaultAction)
        case .available(let release):
            Button("跳过此版本") { updater.skip(release); dismiss() }
            Spacer()
            Button("以后再说") { updater.prompt = nil; dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("下载并安装") { updater.download(release) }
                .keyboardShortcut(.defaultAction)
        case .downloading:
            Spacer()
            Button("取消") { updater.cancelDownload() }.keyboardShortcut(.cancelAction)
        case .ready:
            Spacer()
            Button("以后再说") { updater.prompt = nil; dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("安装并重新启动") { updater.installAndRelaunch() }
                .keyboardShortcut(.defaultAction)
        case .failed:
            if let release = updater.prompt {
                Button("在浏览器中打开") { openURL(release.page) }
            }
            Spacer()
            Button("关闭") { dismiss() }
            Button("重试") { updater.check(userInitiated: true) }.keyboardShortcut(.defaultAction)
        }
    }

    /// Release notes are Markdown; keep line breaks and render inline styles and links.
    static func notes(_ text: String) -> AttributedString {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return AttributedString("此版本没有更新说明。") }
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: trimmed, options: options)) ?? AttributedString(trimmed)
    }
}

/// The 「软件更新」 settings tab.
struct UpdateSettings: View {
    @ObservedObject var updater = Updater.shared
    @AppStorage(Updater.autoCheckKey) private var autoCheck = true
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Form {
            Section {
                LabeledContent("当前版本", value: updater.currentVersion)
                Toggle("自动检查更新", isOn: $autoCheck)
                LabeledContent("上次检查") {
                    Text(updater.lastChecked?.formatted(date: .abbreviated, time: .shortened) ?? "从未")
                }
                HStack {
                    Spacer()
                    Button("立即检查更新") {
                        updater.check(userInitiated: true)
                        openWindow(id: UpdateView.windowID)
                    }
                }
            } header: {
                Text("软件更新")
            } footer: {
                Text("从 GitHub（\(Updater.repository)）的正式发布获取新版本，安装前校验签名。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

extension UpdateView {
    static let windowID = "update"
}

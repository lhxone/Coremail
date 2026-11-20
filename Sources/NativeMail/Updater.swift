import AppKit
import Foundation
import Security

/// A dotted version such as `0.3.1` (a leading `v` is ignored).
struct AppVersion: Comparable, CustomStringConvertible {
    let parts: [Int]

    init?(_ text: String) {
        var text = text.trimmingCharacters(in: .whitespaces)
        if text.first == "v" || text.first == "V" { text.removeFirst() }
        let parts = text.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard !parts.isEmpty, parts.count <= 4, parts.allSatisfy({ ($0 ?? -1) >= 0 }) else { return nil }
        self.parts = parts.compactMap { $0 }
    }

    var description: String { parts.map(String.init).joined(separator: ".") }

    static func < (lhs: Self, rhs: Self) -> Bool {
        let count = max(lhs.parts.count, rhs.parts.count)
        for index in 0..<count {
            let left = index < lhs.parts.count ? lhs.parts[index] : 0
            let right = index < rhs.parts.count ? rhs.parts[index] : 0
            if left != right { return left < right }
        }
        return false
    }

    static func == (lhs: Self, rhs: Self) -> Bool { !(lhs < rhs) && !(rhs < lhs) }

    static var current: AppVersion? {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String).flatMap(AppVersion.init)
    }
}

/// The newest published GitHub release and its app archive.
struct AppRelease: Equatable {
    let version: AppVersion
    let tag: String
    let notes: String
    let page: URL
    let archive: URL
    let archiveSize: Int
    let published: Date?

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.tag == rhs.tag && lhs.archive == rhs.archive }

    /// Reads `GET /repos/{owner}/{repo}/releases/latest`. Returns nil for drafts, pre-releases,
    /// tags that are not versions, or releases without a `Coremail-*.zip` asset.
    static func parse(_ data: Data) throws -> AppRelease? {
        struct Asset: Decodable {
            let name: String
            let browser_download_url: URL
            let size: Int
        }
        struct Payload: Decodable {
            let tag_name: String
            let body: String?
            let html_url: URL
            let draft: Bool
            let prerelease: Bool
            let published_at: Date?
            let assets: [Asset]
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let payload = try decoder.decode(Payload.self, from: data)
        guard !payload.draft, !payload.prerelease, let version = AppVersion(payload.tag_name),
              let asset = payload.assets.first(where: {
                  $0.name.hasPrefix("Coremail") && $0.name.lowercased().hasSuffix(".zip")
              }),
              asset.browser_download_url.scheme == "https" else { return nil }
        return AppRelease(version: version, tag: payload.tag_name, notes: payload.body ?? "",
                          page: payload.html_url, archive: asset.browser_download_url,
                          archiveSize: asset.size, published: payload.published_at)
    }
}

extension AppRelease {
    /// From the page `releases/latest` redirects to (`…/releases/tag/v0.4.0`), with the archive at its
    /// conventional name. Notes are not available this way, so they link to the release page.
    init?(redirectedTo url: URL, repository: String) {
        let parts = url.pathComponents
        guard url.host == "github.com", parts.count >= 2, parts[parts.count - 2] == "tag",
              url.path.hasPrefix("/\(repository)/releases/tag/"),
              let tag = parts.last, let version = AppVersion(tag),
              let archive = URL(string: "https://github.com/\(repository)/releases/download/\(tag)/Coremail-\(version)-macOS.zip")
        else { return nil }
        self.init(version: version, tag: tag, notes: "更新说明见 [GitHub 发布页](\(url.absoluteString))。",
                  page: url, archive: archive, archiveSize: 0, published: nil)
    }
}

/// Checks that a downloaded app is the same app, signed by the same developer, as the running one.
enum UpdateVerifier {
    /// The running app's designated requirement, or nil when it is ad-hoc signed (no stable identity).
    static func runningRequirement() throws -> SecRequirement {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else {
            throw MailError("无法读取当前应用的签名。")
        }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else {
            throw MailError("无法读取当前应用的签名。")
        }
        return try requirement(of: staticCode)
    }

    static func requirement(ofApp url: URL) throws -> SecRequirement {
        try requirement(of: staticCode(url))
    }

    private static func requirement(of code: SecStaticCode) throws -> SecRequirement {
        var info: CFDictionary?
        SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info)
        let team = (info as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String
        guard team?.isEmpty == false else {
            throw MailError("当前应用使用临时签名，无法验证更新包。请用开发者证书重新打包，或手动下载新版本。")
        }
        var requirement: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(code, [], &requirement) == errSecSuccess, let requirement else {
            throw MailError("无法读取当前应用的签名要求。")
        }
        return requirement
    }

    private static func staticCode(_ url: URL) throws -> SecStaticCode {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else {
            throw MailError("更新包不是有效的应用。")
        }
        return code
    }

    /// Throws unless `app` is intact, has the expected bundle id and version, and satisfies `requirement`.
    static func verify(_ app: URL, bundleID: String, version: AppVersion, requirement: SecRequirement) throws {
        guard let bundle = Bundle(url: app), bundle.bundleIdentifier == bundleID else {
            throw MailError("更新包的应用标识不符。")
        }
        guard let shipped = (bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
                .flatMap(AppVersion.init), shipped == version else {
            throw MailError("更新包的版本号与发布版本不一致。")
        }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        let status = SecStaticCodeCheckValidity(try staticCode(app), flags, requirement)
        guard status == errSecSuccess else {
            throw MailError("更新包的签名无效或不是同一开发者签名（\(status)），已拒绝安装。")
        }
    }
}

@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()

    static let repository = "lhxone/Coremail"
    static let autoCheckKey = "autoCheckUpdates"
    static let skippedKey = "skippedUpdateVersion"
    static let lastCheckKey = "lastUpdateCheck"
    private static let checkInterval: TimeInterval = 24 * 60 * 60

    enum Phase: Equatable {
        case idle
        case checking
        case upToDate
        case available(AppRelease)
        case downloading(AppRelease, Double)
        case ready(AppRelease)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    /// Set when the update window should be shown.
    @Published var prompt: AppRelease?
    @Published private(set) var lastChecked: Date?

    private let preferences = UserDefaults.standard
    private var task: Task<Void, Never>?
    private var timer: Task<Void, Never>?
    private var staged: (release: AppRelease, app: URL, folder: URL)?

    private init() {
        preferences.register(defaults: [Self.autoCheckKey: true])
        lastChecked = preferences.object(forKey: Self.lastCheckKey) as? Date
    }

    var currentVersion: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        return build.map { "\(short) (\($0))" } ?? short
    }

    /// Starts the daily background check; the first one runs shortly after launch.
    func startAutomaticChecks() {
        guard timer == nil, Bundle.main.bundlePath.hasSuffix(".app") else { return }
        timer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            while !Task.isCancelled {
                guard let self else { return }
                if self.preferences.bool(forKey: Self.autoCheckKey),
                   Date().timeIntervalSince(self.lastChecked ?? .distantPast) >= Self.checkInterval {
                    self.check(userInitiated: false)
                }
                try? await Task.sleep(for: .seconds(60 * 60))
            }
        }
    }

    func check(userInitiated: Bool) {
        switch phase {
        case .checking, .downloading: return
        case .ready(let release):
            if userInitiated { prompt = release }
            return
        default: break
        }
        phase = .checking
        task = Task {
            do {
                let release = try await fetchLatest()
                lastChecked = Date()
                preferences.set(lastChecked, forKey: Self.lastCheckKey)
                guard let release, let current = AppVersion.current, current < release.version else {
                    phase = .upToDate
                    return
                }
                phase = .available(release)
                let skipped = preferences.string(forKey: Self.skippedKey).flatMap(AppVersion.init)
                if userInitiated || skipped != release.version { prompt = release }
            } catch {
                phase = userInitiated ? .failed(error.localizedDescription) : .idle
            }
        }
    }

    func skip(_ release: AppRelease) {
        preferences.set(release.version.description, forKey: Self.skippedKey)
        prompt = nil
    }

    private func fetchLatest() async throws -> AppRelease? {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repository)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Coremail-macOS-Updater", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 404 { return nil } // No release published yet.
        if status == 200 { return try AppRelease.parse(data) }
        // The API allows 60 anonymous requests an hour per IP, which a shared proxy can use up.
        // The release page is not rate limited: it redirects to the newest tag.
        return try await fetchLatestFromPage() ?? { throw MailError("检查更新失败（HTTP \(status)）。") }()
    }

    private func fetchLatestFromPage() async throws -> AppRelease? {
        var request = URLRequest(url: URL(string: "https://github.com/\(Self.repository)/releases/latest")!)
        request.httpMethod = "HEAD"
        request.setValue("Coremail-macOS-Updater", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let final = response.url else { return nil }
        return AppRelease(redirectedTo: final, repository: Self.repository)
    }

    // MARK: - Download and install

    func download(_ release: AppRelease) {
        if case .downloading = phase { return }
        let requirement: SecRequirement
        do {
            requirement = try UpdateVerifier.runningRequirement()
            try checkInstallLocation()
        } catch {
            phase = .failed(error.localizedDescription)
            return
        }
        phase = .downloading(release, 0)
        let bundleID = Bundle.main.bundleIdentifier ?? ""
        task = Task {
            let folder = FileManager.default.temporaryDirectory
                .appendingPathComponent("CoremailUpdate-\(UUID().uuidString)", isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let archive = folder.appendingPathComponent("update.zip")
                try await Self.fetch(release, to: archive) { progress in
                    await Updater.shared.reportDownload(release, progress)
                }
                let app = try await Task.detached(priority: .userInitiated) { () throws -> URL in
                    let expanded = folder.appendingPathComponent("expanded", isDirectory: true)
                    try Self.run("/usr/bin/ditto", ["-x", "-k", archive.path, expanded.path])
                    let apps = try FileManager.default.contentsOfDirectory(at: expanded, includingPropertiesForKeys: nil)
                        .filter { $0.pathExtension == "app" }
                    guard apps.count == 1, let app = apps.first else { throw MailError("更新包里没有找到应用。") }
                    try UpdateVerifier.verify(app, bundleID: bundleID, version: release.version, requirement: requirement)
                    // Downloads are quarantined, which would make macOS run the new version from a
                    // translocated read-only copy. The signature was just checked, so clear the flag.
                    try Self.run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", app.path])
                    return app
                }.value
                try Task.checkCancellation()
                staged = (release, app, folder)
                phase = .ready(release)
            } catch {
                try? FileManager.default.removeItem(at: folder)
                phase = Task.isCancelled ? .available(release) : .failed(error.localizedDescription)
            }
        }
    }

    private func reportDownload(_ release: AppRelease, _ progress: Double) {
        if case .downloading = phase { phase = .downloading(release, progress) }
    }

    func cancelDownload() {
        task?.cancel()
    }

    /// Streams the archive to disk off the main actor, reporting progress in 1% steps.
    nonisolated private static func fetch(_ release: AppRelease, to destination: URL,
                                          progress report: @escaping @Sendable (Double) async -> Void) async throws {
        var request = URLRequest(url: release.archive)
        request.setValue("Coremail-macOS-Updater", forHTTPHeaderField: "User-Agent")
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw MailError("下载更新失败。") }
        let expected = response.expectedContentLength > 0 ? Int(response.expectedContentLength) : release.archiveSize
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }
        var buffer = Data()
        buffer.reserveCapacity(1 << 20)
        var received = 0
        var reported = 0.0
        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= 1 << 18 {
                try handle.write(contentsOf: buffer)
                received += buffer.count
                buffer.removeAll(keepingCapacity: true)
                if expected > 0 {
                    let progress = min(1, Double(received) / Double(expected))
                    if progress - reported >= 0.01 { reported = progress; await report(progress) }
                }
            }
        }
        try handle.write(contentsOf: buffer)
    }

    /// Replaces the running app with the verified update once it has quit, then opens the new version.
    func installAndRelaunch() {
        guard let staged, case .ready = phase else { return }
        let target = Bundle.main.bundleURL
        let script = staged.folder.appendingPathComponent("install.sh")
        let body = """
        #!/bin/sh
        # $1 pid  $2 installed app  $3 new app  $4 work folder
        while kill -0 "$1" 2>/dev/null; do sleep 0.2; done
        if mv "$2" "$4/previous.app"; then
            if mv "$3" "$2"; then
                rm -rf "$4/previous.app"
            else
                mv "$4/previous.app" "$2"
            fi
        fi
        open "$2"
        rm -rf "$4"
        """
        do {
            try body.write(to: script, atomically: true, encoding: .utf8)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = [script.path, String(ProcessInfo.processInfo.processIdentifier),
                                 target.path, staged.app.path, staged.folder.path]
            try process.run()
        } catch {
            phase = .failed("无法启动安装：\(error.localizedDescription)")
            return
        }
        NSApp.terminate(nil)
    }

    private func checkInstallLocation() throws {
        let path = Bundle.main.bundlePath
        guard path.hasSuffix(".app") else { throw MailError("只有打包后的应用才能自动更新。") }
        if path.contains("/AppTranslocation/") {
            throw MailError("请先把 Coremail 移到「应用程序」文件夹再更新。")
        }
        let parent = (path as NSString).deletingLastPathComponent
        guard FileManager.default.isWritableFile(atPath: parent) else {
            throw MailError("没有权限替换「\(parent)」中的应用，请手动下载新版本。")
        }
    }

    nonisolated private static func run(_ tool: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw MailError("准备更新失败（\((tool as NSString).lastPathComponent) \(process.terminationStatus)）。")
        }
    }
}

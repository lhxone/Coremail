import XCTest
@testable import NativeMail

final class UpdaterTests: XCTestCase {
    func testVersionsCompareNumerically() throws {
        let v = { (text: String) in try XCTUnwrap(AppVersion(text)) }
        XCTAssertLessThan(try v("0.3.0"), try v("0.3.1"))
        XCTAssertLessThan(try v("0.9"), try v("0.10"))
        XCTAssertLessThan(try v("1.2"), try v("1.2.1"))
        XCTAssertEqual(try v("v1.2.0"), try v("1.2"))
        XCTAssertFalse(try v("2.0") < v("1.9.9"))
        XCTAssertNil(AppVersion("1.x"))
        XCTAssertNil(AppVersion(""))
        XCTAssertNil(AppVersion("1..2"))
    }

    private func payload(tag: String = "v0.4.0", draft: Bool = false, prerelease: Bool = false,
                         assets: [(String, String)] = [("Coremail-0.4.0-macOS.zip", "https://github.com/a/b/releases/download/v0.4.0/Coremail-0.4.0-macOS.zip")]) -> Data {
        let list = assets.map { ["name": $0.0, "browser_download_url": $0.1, "size": 1234] as [String: Any] }
        let object: [String: Any] = [
            "tag_name": tag, "body": "- **修复** 搜索", "html_url": "https://github.com/a/b/releases/tag/\(tag)",
            "draft": draft, "prerelease": prerelease, "published_at": "2026-11-20T08:00:00Z", "assets": list
        ]
        return try! JSONSerialization.data(withJSONObject: object)
    }

    func testReleaseParsingPicksTheAppArchive() throws {
        let release = try XCTUnwrap(AppRelease.parse(payload(assets: [
            ("checksums.txt", "https://example.com/c.txt"),
            ("Coremail-0.4.0-macOS.zip", "https://example.com/Coremail.zip")
        ])))
        XCTAssertEqual(release.version.description, "0.4.0")
        XCTAssertEqual(release.archive.absoluteString, "https://example.com/Coremail.zip")
        XCTAssertEqual(release.archiveSize, 1234)
        XCTAssertNotNil(release.published)
    }

    func testReleaseParsingRejectsUnusableReleases() throws {
        XCTAssertNil(try AppRelease.parse(payload(draft: true)))
        XCTAssertNil(try AppRelease.parse(payload(prerelease: true)))
        XCTAssertNil(try AppRelease.parse(payload(tag: "nightly")))
        XCTAssertNil(try AppRelease.parse(payload(assets: [])))
        XCTAssertNil(try AppRelease.parse(payload(assets: [("Coremail.zip", "http://example.com/plain.zip")])),
                     "archives must come over HTTPS")
    }

    func testReleasePageRedirectGivesVersionAndArchive() throws {
        let page = try XCTUnwrap(URL(string: "https://github.com/lhxone/Coremail/releases/tag/v0.4.0"))
        let release = try XCTUnwrap(AppRelease(redirectedTo: page, repository: "lhxone/Coremail"))
        XCTAssertEqual(release.version.description, "0.4.0")
        XCTAssertEqual(release.archive.absoluteString,
                       "https://github.com/lhxone/Coremail/releases/download/v0.4.0/Coremail-0.4.0-macOS.zip")
        // No release yet: GitHub stays on /releases.
        XCTAssertNil(AppRelease(redirectedTo: URL(string: "https://github.com/lhxone/Coremail/releases")!, repository: "lhxone/Coremail"))
        XCTAssertNil(AppRelease(redirectedTo: URL(string: "https://github.com/other/repo/releases/tag/v9.0")!, repository: "lhxone/Coremail"))
        XCTAssertNil(AppRelease(redirectedTo: URL(string: "https://github.com/lhxone/Coremail/releases/tag/nightly")!, repository: "lhxone/Coremail"))
    }

    func testReleaseNotesRenderMarkdown() {
        XCTAssertEqual(String(UpdateView.notes("- **修复** 搜索").characters), "- 修复 搜索")
        XCTAssertEqual(String(UpdateView.notes("  ").characters), "此版本没有更新说明。")
    }

    /// Uses the locally built app: a signed copy passes, an ad-hoc re-signed copy is refused.
    func testVerifierAcceptsOnlyTheSameDeveloper() throws {
        let built = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("dist/Coremail.app")
        guard FileManager.default.fileExists(atPath: built.path),
              let requirement = try? UpdateVerifier.requirement(ofApp: built) else {
            throw XCTSkip("需要先用开发者证书运行 Scripts/build-app.sh")
        }
        let bundle = try XCTUnwrap(Bundle(url: built))
        let id = try XCTUnwrap(bundle.bundleIdentifier)
        let version = try XCTUnwrap((bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
            .flatMap(AppVersion.init))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let copy = root.appendingPathComponent("Coremail.app")
        try run("/usr/bin/ditto", built.path, copy.path)
        XCTAssertNoThrow(try UpdateVerifier.verify(copy, bundleID: id, version: version, requirement: requirement))
        XCTAssertThrowsError(try UpdateVerifier.verify(copy, bundleID: id, version: AppVersion("99.0")!, requirement: requirement))
        XCTAssertThrowsError(try UpdateVerifier.verify(copy, bundleID: "com.example.other", version: version, requirement: requirement))

        let forged = root.appendingPathComponent("Forged/Coremail.app")
        try FileManager.default.createDirectory(at: forged.deletingLastPathComponent(), withIntermediateDirectories: true)
        try run("/usr/bin/ditto", built.path, forged.path)
        try run("/usr/bin/codesign", "--force", "--sign", "-", "--identifier", id, forged.path)
        XCTAssertThrowsError(try UpdateVerifier.verify(forged, bundleID: id, version: version, requirement: requirement))
        XCTAssertThrowsError(try UpdateVerifier.requirement(ofApp: forged), "ad-hoc builds cannot be update sources")

        let tampered = root.appendingPathComponent("Tampered/Coremail.app")
        try FileManager.default.createDirectory(at: tampered.deletingLastPathComponent(), withIntermediateDirectories: true)
        try run("/usr/bin/ditto", built.path, tampered.path)
        try Data("x".utf8).write(to: tampered.appendingPathComponent("Contents/Resources/extra.txt"))
        XCTAssertThrowsError(try UpdateVerifier.verify(tampered, bundleID: id, version: version, requirement: requirement))
    }

    private func run(_ tool: String, _ arguments: String...) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "\(tool) \(arguments)")
    }
}

import XCTest
import WidgetShared

final class WidgetSnapshotTests: XCTestCase {
    func testSnapshotReplacesVisibleCountWhenLockedOrSignedOut() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("snapshot.json")
        try WidgetSnapshot(unread: 12, state: "ready").save(to: url)
        XCTAssertEqual(WidgetSnapshot.load(from: url)?.unread, 12)
        for state in ["locked", "signedOut"] {
            try WidgetSnapshot(unread: nil, state: state).save(to: url)
            let loaded = try XCTUnwrap(WidgetSnapshot.load(from: url))
            XCTAssertNil(loaded.unread)
            XCTAssertEqual(loaded.state, state)
        }
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
    }

    func testMissingAndCorruptSnapshotsAreUnavailable() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertNil(WidgetSnapshot.load(from: url))
        try Data("invalid".utf8).write(to: url)
        XCTAssertNil(WidgetSnapshot.load(from: url))
        XCTAssertEqual(WidgetSnapshot(unread: -1, state: "ready").unread, 0)
    }
}

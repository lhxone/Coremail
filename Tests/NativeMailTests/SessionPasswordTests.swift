import XCTest
@testable import NativeMail

final class SessionPasswordTests: XCTestCase {
    func testRepeatedRequestsReuseCredentialAndChangingAccountsReloads() throws {
        var cache = SessionPassword()
        var first = Account()
        first.email = "first@example.com"
        var second = Account()
        second.email = "second@example.com"
        var reads = 0
        let load: (Account) throws -> String = { account in
            reads += 1
            return "fixture-for-" + account.email
        }

        XCTAssertEqual(try cache.value(for: first, load: load), "fixture-for-first@example.com")
        XCTAssertEqual(try cache.value(for: first, load: load), "fixture-for-first@example.com")
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(try cache.value(for: second, load: load), "fixture-for-second@example.com")
        XCTAssertEqual(reads, 2)
        cache.replace("new-fixture", for: second)
        XCTAssertEqual(try cache.value(for: second, load: load), "new-fixture")
        XCTAssertEqual(reads, 2)
        cache.clear()
        XCTAssertEqual(try cache.value(for: second, load: load), "fixture-for-second@example.com")
        XCTAssertEqual(reads, 3)
    }
}

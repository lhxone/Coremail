import Foundation
import XCTest
@testable import NativeMail

final class CoremailPushTests: XCTestCase {
    func testEngineIOHandshakeReadsOnlyTheOpenPacket() throws {
        let open = #"0{"sid":"transport-id","upgrades":["websocket"],"pingInterval":30000,"pingTimeout":60000}"#
        let data = Data("\(open.utf8.count):\(open)2:40".utf8)
        let handshake = try CoremailPush.Handshake.decode(data)
        XCTAssertEqual(handshake.sid, "transport-id")
        XCTAssertEqual(handshake.pingInterval, 30_000)
        XCTAssertEqual(handshake.pingTimeout, 60_000)
        XCTAssertThrowsError(try CoremailPush.Handshake.decode(Data(data.prefix(15))))
    }

    func testSocketIOEventsPreserveTheSubscriptionTopic() throws {
        let topic = "/example.com/onstat/mail/user@example.com/in_mail"
        let subscribe = try CoremailPush.event("subscribe", ["topic": topic])
        XCTAssertEqual(CoremailPush.eventFields(subscribe)?.name, "subscribe")
        XCTAssertEqual(CoremailPush.eventFields(subscribe)?.fields["topic"] as? String, topic)
        XCTAssertNil(CoremailPush.eventFields("3probe"))
        XCTAssertNil(CoremailPush.eventFields("42["))
    }
}

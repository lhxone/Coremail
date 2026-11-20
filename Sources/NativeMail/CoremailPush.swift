import Foundation
import os

/// Engine.IO 3 transport used by Coremail's Socket.IO mailbox subscription.
struct CoremailPush {
    struct Handshake: Decodable {
        let sid: String
        let upgrades: [String]
        let pingInterval: Int
        let pingTimeout: Int

        static func decode(_ data: Data) throws -> Self {
            // b64=1 asks Engine.IO to use length-prefixed text framing.
            guard let separator = data.firstIndex(of: 58),
                  let length = Int(String(decoding: data[..<separator], as: UTF8.self)),
                  length > 1, length <= 4096, data.count - separator - 1 >= length,
                  data[separator + 1] == 48 else { throw URLError(.cannotParseResponse) }
            let open = try JSONDecoder().decode(Self.self, from: data[(separator + 2)..<(separator + 1 + length)])
            guard !open.sid.isEmpty, open.upgrades.contains("websocket"),
                  (1_000...120_000).contains(open.pingInterval),
                  (1_000...120_000).contains(open.pingTimeout) else { throw URLError(.cannotParseResponse) }
            return open
        }
    }

    enum Signal: Sendable { case ready, mail }

    static func event(_ name: String, _ fields: [String: String]) throws -> String {
        "42" + String(decoding: try JSONSerialization.data(withJSONObject: [name, fields]), as: UTF8.self)
    }

    static func eventFields(_ packet: String) -> (name: String, fields: [String: Any])? {
        guard packet.hasPrefix("42["),
              let items = try? JSONSerialization.jsonObject(with: Data(packet.dropFirst(2).utf8)) as? [Any],
              let name = items.first as? String else { return nil }
        return (name, items.dropFirst().first as? [String: Any] ?? [:])
    }

    static func listen(socket: URLSessionWebSocketTask, handshake: Handshake,
                       rootConnected: Bool, auth: String, topic: String,
                       onSignal: @escaping @Sendable (Signal) async -> Void) async throws {
        let clock = ContinuousClock()
        let lastPong = OSAllocatedUnfairLock(initialState: clock.now)
        let ready = OSAllocatedUnfairLock(initialState: false)
        let started = clock.now
        let interval = Duration.milliseconds(handshake.pingInterval)
        let timeout = Duration.milliseconds(handshake.pingTimeout)
        socket.maximumMessageSize = 256 * 1024
        defer { socket.cancel(with: .goingAway, reason: nil) }
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            socket.resume()
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    while !Task.isCancelled {
                        try await Task.sleep(for: interval)
                        guard ready.withLock({ $0 }) || started.duration(to: clock.now) < .seconds(30),
                              lastPong.withLock({ $0.duration(to: clock.now) }) <= interval + timeout else {
                            socket.cancel(with: .goingAway, reason: nil)
                            throw URLError(.timedOut)
                        }
                        try await socket.send(.string("2"))
                    }
                }
                group.addTask {
                    try await socket.send(.string("2probe"))
                    var authenticated = false
                    var authSent = false
                    var upgraded = false
                    var connected = rootConnected
                    while !Task.isCancelled {
                        guard case .string(let packet) = try await socket.receive() else { continue }
                        switch packet {
                        case "3probe":
                            try await socket.send(.string("5"))
                            upgraded = true
                        case "40":
                            connected = true
                        case "2":
                            try await socket.send(.string("3"))
                        case "3":
                            lastPong.withLock { $0 = clock.now }
                        case "1", "41":
                            throw URLError(.networkConnectionLost)
                        default:
                            if packet.hasPrefix("44") { throw URLError(.userAuthenticationRequired) }
                            guard let event = eventFields(packet) else { continue }
                            switch event.name {
                            case "ready" where authSent && !authenticated:
                                try await socket.send(.string(try Self.event("subscribe", ["topic": topic])))
                                authenticated = true
                                ready.withLock { $0 = true }
                                await onSignal(.ready)
                            case "message" where authenticated && event.fields["topic"] as? String == topic:
                                await onSignal(.mail)
                            case "bridge_error", "connect_error", "error":
                                throw URLError(.userAuthenticationRequired)
                            default:
                                break
                            }
                        }
                        if upgraded && connected && !authSent {
                            try await socket.send(.string(auth))
                            authSent = true
                        }
                    }
                }
                defer {
                    socket.cancel(with: .goingAway, reason: nil)
                    group.cancelAll()
                }
                try await group.next()
            }
        } onCancel: {
            socket.cancel(with: .goingAway, reason: nil)
        }
    }
}

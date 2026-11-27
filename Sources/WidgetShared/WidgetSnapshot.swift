import Foundation

public struct WidgetSnapshot: Codable, Equatable {
    public let unread: Int?
    public let state: String
    public let updatedAt: Date

    public init(unread: Int?, state: String, updatedAt: Date = Date()) {
        self.unread = unread.map { max(0, $0) }
        self.state = state
        self.updatedAt = updatedAt
    }

    public static let kind = "CoremailInbox"
    public static let inboxURL = URL(string: "coremail://inbox")!
    public static var fileURL: URL? {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "CoremailAppGroup") as? String,
              let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else { return nil }
        return container.appendingPathComponent("inbox-widget.json")
    }

    public static func load(from url: URL? = fileURL) -> WidgetSnapshot? {
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }

    public func save(to url: URL? = fileURL) throws {
        guard let url else { return }
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

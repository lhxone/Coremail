import CryptoKit
import Foundation

struct MailMetadata: Codable {
    let completedAt: Date
    let folders: [MailFolder]
    var rows: [String: [MailSummary]]
}

struct MetadataSyncProgress: Equatable {
    let folder: String
    let completed: Int
    let total: Int
    let messages: Int
}

struct MailMetadataFile {
    let url: URL

    init(account: Account, directory: URL? = nil) {
        let directory = directory ?? MailStorage.metadata
        let identity = [account.host.lowercased(), account.login, account.email.lowercased()].joined(separator: "\0")
        let filename = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        url = directory.appendingPathComponent(filename + ".json")
    }

    func load() throws -> MailMetadata? {
        do {
            return try JSONDecoder().decode(MailMetadata.self, from: Data(contentsOf: url))
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        }
    }

    func save(_ metadata: MailMetadata) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(metadata).write(to: url, options: .atomic)
    }

    func remove() throws {
        do { try FileManager.default.removeItem(at: url) }
        catch let error as CocoaError where error.code == .fileNoSuchFile {}
    }
}

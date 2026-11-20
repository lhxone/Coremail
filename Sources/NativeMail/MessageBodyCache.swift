import CryptoKit
import Foundation

struct MessageBodyCache {
    static let maxAge: TimeInterval = 30 * 24 * 60 * 60
    static let maxBytes = 256 * 1024 * 1024
    let directory: URL

    init(account: Account, root: URL = MailStorage.messages) {
        directory = MailMetadataFile(account: account, directory: root).url.deletingPathExtension()
    }

    private func file(_ id: String) -> URL {
        let name = SHA256.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(name + ".eml")
    }

    func load(_ id: String) -> Data? {
        let url = file(id)
        guard let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate else { return nil }
        guard Date().timeIntervalSince(modified) < Self.maxAge else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        guard let bytes = try? Data(contentsOf: url), !bytes.isEmpty else { return nil }
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        return bytes
    }

    /// Reads a cached body without counting it as a recent use (used by search).
    func peek(_ id: String) -> Data? {
        let url = file(id)
        guard let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
              Date().timeIntervalSince(modified) < Self.maxAge,
              let bytes = try? Data(contentsOf: url), !bytes.isEmpty else { return nil }
        return bytes
    }

    /// The ids among `ids` that have a cached body, from one directory listing.
    func cachedIDs(among ids: [String]) -> Set<String> {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return [] }
        let present = Set(names)
        return Set(ids.filter { present.contains(file($0).lastPathComponent) })
    }

    func save(_ bytes: Data, id: String) throws {
        guard bytes.count <= Self.maxBytes else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try bytes.write(to: file(id), options: .atomic)
        prune()
    }

    func removeAll() throws {
        do { try FileManager.default.removeItem(at: directory) }
        catch let error as CocoaError where error.code == .fileNoSuchFile {}
    }

    private func prune() {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory,
                                includingPropertiesForKeys: Array(keys), options: .skipsHiddenFiles) else { return }
        let cutoff = Date().addingTimeInterval(-Self.maxAge)
        var bytes = 0
        for file in files.compactMap({ url -> (url: URL, touched: Date, size: Int)? in
            guard url.pathExtension == "eml", let values = try? url.resourceValues(forKeys: keys),
                  let touched = values.contentModificationDate, let size = values.fileSize else { return nil }
            return (url, touched, size)
        }).sorted(by: { $0.touched > $1.touched }) {
            if file.touched < cutoff || bytes + file.size > Self.maxBytes {
                try? FileManager.default.removeItem(at: file.url)
            } else {
                bytes += file.size
            }
        }
    }
}

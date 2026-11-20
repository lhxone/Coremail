import Foundation

enum MailStorage {
    static let directory = URL.applicationSupportDirectory
        .appendingPathComponent("com.native-mail.coremail", isDirectory: true)
    static let metadata = directory.appendingPathComponent("Metadata", isDirectory: true)
    static let messages = URL.cachesDirectory
        .appendingPathComponent("com.native-mail.coremail/Messages", isDirectory: true)
    static let signatures = directory.appendingPathComponent("Signatures", isDirectory: true)

    static func occupiedBytes(at directory: URL) -> Int64? {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        var readError: Error?
        guard let files = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: Array(keys),
            errorHandler: { _, error in
                readError = error
                return false
            }
        ) else { return nil }

        var bytes: Int64 = 0
        for case let file as URL in files {
            guard !Task.isCancelled, let values = try? file.resourceValues(forKeys: keys) else { return nil }
            guard values.isRegularFile == true else { continue }
            guard let size = values.totalFileAllocatedSize ?? values.fileAllocatedSize else { return nil }
            bytes += Int64(size)
        }
        if let error = readError as NSError? {
            return error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError && bytes == 0
                && !FileManager.default.fileExists(atPath: directory.path) ? 0 : nil
        }
        return bytes
    }
}

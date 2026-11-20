import Foundation
import Security

struct SessionPassword {
    private var stored: (account: String, password: String)?

    mutating func value(for account: Account, load: (Account) throws -> String = PasswordStore.read) throws -> String {
        if let stored, stored.account == account.keychainAccount { return stored.password }
        let password = try load(account)
        replace(password, for: account)
        return password
    }

    mutating func replace(_ password: String, for account: Account) {
        stored = (account.keychainAccount, password)
    }

    mutating func clear() { stored = nil }
}

enum PasswordStore {
    private static func query(_ account: Account) -> [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: "com.native-mail.coremail.account",
         kSecAttrAccount: account.keychainAccount]
    }

    static func read(_ account: Account) throws -> String {
        var request = query(account)
        request[kSecMatchLimit] = kSecMatchLimitOne
        request[kSecReturnData] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { throw MailError("请在账户设置里输入邮箱密码或客户端授权码。") }
        guard status == errSecSuccess, let data = result as? Data,
              let password = String(data: data, encoding: .utf8) else {
            throw MailError("无法读取钥匙串中的邮箱凭据（\(status)）。")
        }
        return password
    }

    static func save(_ password: String, for account: Account) throws {
        guard !password.isEmpty, !password.utf8.contains(where: { [0, 10, 13].contains($0) }) else {
            throw MailError("请输入有效的邮箱密码或客户端授权码。")
        }
        let data = Data(password.utf8)
        var request = query(account)
        var status = SecItemUpdate(request as CFDictionary, [kSecValueData: data] as CFDictionary)
        if status == errSecItemNotFound {
            request[kSecValueData] = data
            request[kSecAttrLabel] = "Coremail · \(account.email)"
            status = SecItemAdd(request as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw MailError("无法保存邮箱凭据（\(status)）。")
        }
    }

    static func remove(_ account: Account) {
        SecItemDelete(query(account) as CFDictionary)
    }
}

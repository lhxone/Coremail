import Foundation

enum CompanyDirectory {
    static func decode(_ value: Any) throws -> [ContactChoice] {
        guard let rows = value as? [[String: Any]] else {
            throw MailError("企业通讯录返回的搜索结果格式异常。")
        }
        var seen = Set<String>()
        return rows.compactMap { row in
            guard let email = row["email"] as? String, MailAddress.isValid(email),
                  seen.insert(email.lowercased()).inserted else { return nil }
            let name = row["true_name"] as? String ?? row["nick_name"] as? String ?? ""
            return ContactChoice(name: name, email: email)
        }
    }
}

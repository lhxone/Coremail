import Foundation
import Security

/// Coremail HTTPS session. JSON calls use text/x-json and the authenticated sid/Cookie pair.
final class CoremailSession: @unchecked Sendable {
    let account: Account
    private let password: String
    private let origin: URL
    private let session: URLSession
    private let longSession: URLSession
    private let cookies: HTTPCookieStorage
    private let redirectPolicy = SameOriginRedirects()
    private let sessionLock = NSLock()
    private var sid: String?
    private var pushEmail: String?
    private var serverDisplayName: String?
    private var serverPersonalName: String?
    private var pushOrganization: String?
    private var cookieName = "Coremail"

    init(account: Account, password: String, protocolClasses: [AnyClass]? = nil) throws {
        try account.validate()
        guard let url = URL(string: "https://\(account.host)") else { throw MailError("服务器地址无效。") }
        self.account = account
        self.password = password
        self.origin = url
        guard let cookies = URLSessionConfiguration.ephemeral.httpCookieStorage else {
            throw MailError("无法初始化 Coremail 会话。")
        }
        self.cookies = cookies
        func make(_ resource: TimeInterval) -> URLSession {
            let configuration = URLSessionConfiguration.ephemeral
            if let protocolClasses { configuration.protocolClasses = protocolClasses }
            configuration.httpCookieStorage = nil
            configuration.httpShouldSetCookies = false
            configuration.urlCredentialStorage = nil
            configuration.urlCache = nil
            configuration.timeoutIntervalForRequest = 20
            configuration.timeoutIntervalForResource = resource
            configuration.tlsMinimumSupportedProtocolVersion = .TLSv12
            return URLSession(configuration: configuration)
        }
        session = make(30)
        longSession = make(300)
    }

    func matches(_ account: Account, password: String) -> Bool {
        self.account == account && self.password == password
    }

    private func endpoint(_ function: String, extra: [URLQueryItem], sid: String?, path: String = "coremail/s/json") throws -> URL {
        var components = URLComponents(url: origin.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        var items = [URLQueryItem(name: "func", value: function)]
        items += extra
        if let sid { items.append(URLQueryItem(name: "sid", value: sid)) }
        components.queryItems = items
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let url = components.url, url.host?.lowercased() == origin.host?.lowercased() else {
            throw MailError("无法构造 Coremail 请求地址。")
        }
        return url
    }

    @discardableResult
    func call(_ function: String, body: [String: Any] = [:]) async throws -> Any {
        try await callEnvelope(function, body: body)["var"] ?? NSNull()
    }

    func callEnvelope(_ function: String, body: [String: Any]) async throws -> [String: Any] {
        let sid = sessionLock.withLock { self.sid }
        return try await post(function, body: JSONSerialization.data(withJSONObject: body),
                              contentType: "text/x-json", extra: [], sid: sid)
    }

    func upload(_ attachment: Attachment, composeID: String) async throws -> [String: Any] {
        let name = attachment.safeName
        let type = attachment.type.range(of: #"^[A-Za-z0-9.+-]+/[A-Za-z0-9.+-]+$"#, options: .regularExpression) == nil
            ? "application/octet-stream" : attachment.type
        let preparation = try await call("upload:prepare", body: [
            "composeId": composeID, "attachmentId": -1, "fileName": name, "contentType": type,
            "size": attachment.data.count, "securityLevel": NSNull()
        ]) as? [String: Any]
        guard let id = preparation?["attachmentId"] as? Int, id > 0 else {
            throw MailError("服务器未确认附件上传编号。")
        }
        let boundary = "Coremail-" + UUID().uuidString
        let filename = name.replacingOccurrences(of: "\"", with: "%22")
        var body = Data(("--\(boundary)\r\nContent-Disposition: form-data; name=\"undefined\"; filename=\"\(filename)\"\r\n"
                         + "Content-Type: \(type)\r\n\r\n").utf8)
        body.append(attachment.data)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        let sid = sessionLock.withLock { self.sid }
        let envelope = try await post(
            "directData", body: body, contentType: "multipart/form-data; boundary=\(boundary)",
            extra: [.init(name: "composeId", value: composeID), .init(name: "attachmentId", value: String(id)),
                    .init(name: "offset", value: "0")],
            sid: sid, long: true, path: "coremail/XT/jsp/upload.jsp"
        )
        guard let uploaded = envelope["var"] as? [String: Any],
              uploaded["attachmentId"] as? Int == id, uploaded["actualSize"] as? Int == attachment.data.count else {
            throw MailError("服务器未确认附件「\(name)」已完整上传。")
        }
        return ["id": id, "type": "upload", "name": name, "displayName": name,
                "size": attachment.data.count, "securityLevel": NSNull()]
    }

    func submitEML(_ eml: Data, composeID: String, asDraft: Bool) async throws -> [String: Any] {
        let boundary = "Coremail-" + UUID().uuidString
        let action = asDraft ? "save" : "deliver"
        var body = Data((
            "--\(boundary)\r\nContent-Disposition: form-data; name=\"action\"\r\n\r\n\(action)\r\n"
            + "--\(boundary)\r\nContent-Disposition: form-data; name=\"lettercontent\"; filename=\"file.eml\"\r\n"
            + "Content-Type: message/rfc822\r\n\r\n"
        ).utf8)
        body.append(eml)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        let sid = sessionLock.withLock { self.sid }
        return try await post("mbox:composeF", body: body, contentType: "multipart/form-data; boundary=\(boundary)",
                              extra: [.init(name: "composeId", value: composeID), .init(name: "uid", value: account.login)],
                              sid: sid, long: true)
    }

    private func post(_ function: String, body: Data, contentType: String, extra: [URLQueryItem],
                      sid: String?, long: Bool = false, path: String = "coremail/s/json") async throws -> [String: Any] {
        var request = URLRequest(url: try endpoint(function, extra: extra, sid: sid, path: path))
        request.httpMethod = "POST"
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        setHeaders(on: &request)
        request.httpBody = body
        let (data, raw) = try await (long ? longSession : session).data(for: request, delegate: redirectPolicy)
        guard let response = raw as? HTTPURLResponse else { throw MailError("Coremail 返回了无效响应。") }
        receiveCookies(from: response)
        guard data.count <= 24 * 1024 * 1024 else { throw MailError("Coremail 返回的数据过大。") }
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let code = object["code"] as? String else {
            throw MailError("Coremail 响应格式异常（HTTP \(response.statusCode)）。")
        }
        if code == "FA_INVALID_SESSION" || code == "FA_SECURITY" { invalidate(sid) }
        guard code == "S_OK" else { throw Self.error(code: code, object: object) }
        guard (200..<300).contains(response.statusCode) else {
            throw MailError("Coremail 请求失败（HTTP \(response.statusCode)）。")
        }
        return object
    }

    private func setHeaders(on request: inout URLRequest) {
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        guard let url = request.url, let matching = cookies.cookies(for: url) else { return }
        for (name, value) in HTTPCookie.requestHeaderFields(with: matching) {
            request.setValue(value, forHTTPHeaderField: name)
        }
    }

    private func receiveCookies(from response: HTTPURLResponse) {
        guard let url = response.url, url.host == origin.host, url.scheme == origin.scheme else { return }
        let headers = response.allHeaderFields.reduce(into: [String: String]()) { fields, entry in
            if let name = entry.key as? String, let value = entry.value as? String { fields[name] = value }
        }
        let received = HTTPCookie.cookies(withResponseHeaderFields: headers, for: url)
        cookies.setCookies(received, for: url, mainDocumentURL: origin)
    }

    private func invalidate(_ sid: String?) {
        sessionLock.withLock { if self.sid == sid { self.sid = nil } }
    }

    /// GET 原始字节（getMessageData download 返回 message/rfc822）。
    func fetch(_ function: String, extra: [URLQueryItem], long: Bool = true) async throws -> Data {
        let sid = sessionLock.withLock { self.sid }
        let url = try endpoint(function, extra: extra, sid: sid)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        setHeaders(on: &request)
        let (data, raw) = try await (long ? longSession : session).data(for: request, delegate: redirectPolicy)
        guard let response = raw as? HTTPURLResponse else { throw MailError("Coremail 返回了无效响应。") }
        receiveCookies(from: response)
        if response.mimeType == "text/x-json" || response.mimeType == "application/json" {
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            let code = object["code"] as? String ?? "?"
            if code == "FA_INVALID_SESSION" || code == "FA_SECURITY" { invalidate(sid) }
            throw Self.error(code: code, object: object)
        }
        guard response.statusCode == 200 else {
            throw MailError("Coremail 读取数据失败（HTTP \(response.statusCode)）。")
        }
        return data
    }

    private static let userAgent = "L-CMClient_4.2.3.1614_MAC Chrome/109.0.5414.120"

    private static func error(code: String, object: [String: Any]) -> MailError {
        let summary = (object["messages"] as? [[String: Any]])?.first?["summary"] as? String
        switch code {
        case "FA_SECURITY": return MailError("Coremail 会话失效，请重新登录。")
        case "FA_UNAUTHORIZED", "FA_INVALID_PASSWORD": return MailError("Coremail 认证失败，请检查客户端专用密码。")
        case "FA_INVALID_SESSION": return MailError("Coremail 会话已过期，请重新登录。")
        case "FA_NO_RECEIPT": return MailError("服务器未收到有效的收件人，邮件未发送。请保留当前编辑内容并重新选择收件人后重试。")
        case "FA_WRONG_RECEIPT": return MailError("服务器拒绝了收件人地址，请检查收件人、抄送和密送中的邮箱地址。")
        case _ where code.hasPrefix("FA_USER_"): return MailError("账号被锁定或暂停，请稍后在网页版处理（\(code)）。")
        default:
            return MailError("Coremail 请求失败（\(code)\(summary.map { "：\($0)" } ?? "")）。")
        }
    }

    // MARK: 登录

    /// 执行 getPasswordKey → RSA 加密口令 → user:login。
    func login() async throws {
        let keyVar = try await post("user:getPasswordKey", body: Data("{}".utf8),
                                    contentType: "text/x-json", extra: [], sid: nil)
        guard let dict = keyVar["var"] as? [String: Any],
              let tempSid = dict["sid"] as? String,
              let key = dict["key"] as? [String: Any],
              (key["type"] as? String) == "RSA",
              let eHex = key["e"] as? String, let nHex = key["n"] as? String else {
            throw MailError("Coremail 登录初始化失败（未取得公钥）。")
        }
        let cipher = try Self.rsaEncrypt(password, eHex: eHex, nHex: nHex)
        let body = try JSONSerialization.data(withJSONObject: ["uid": account.login, "password": cipher])
        let result = try await post("user:login", body: body, contentType: "text/x-json", extra: [], sid: tempSid)
        guard let dict = result["var"] as? [String: Any], let newSid = dict["sid"] as? String, !newSid.isEmpty else {
            throw MailError("Coremail 登录未返回会话。")
        }
        sessionLock.withLock {
            sid = newSid
            pushEmail = dict["primaryEmail"] as? String
            serverDisplayName = Self.usableName(dict["displayName"] as? String ?? dict["display_name"] as? String)
            serverPersonalName = Self.usableName(dict["trueName"] as? String ?? dict["true_name"] as? String)
            pushOrganization = dict["ou"] as? String ?? dict["orgId"] as? String
            cookieName = dict["cookieName"] as? String ?? "Coremail"
        }
    }

    var identity: (email: String, name: String?, personalName: String?) {
        sessionLock.withLock { (pushEmail ?? account.email, serverDisplayName, serverPersonalName) }
    }

    static func usableName(_ value: String?) -> String? {
        guard let name = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty, !MailAddress.isValid(name),
              !name.contains(where: { $0.isNewline || $0 == "\0" }) else { return nil }
        return name
    }

    func listenForMail(_ onSignal: @escaping @Sendable (CoremailPush.Signal) async -> Void) async throws {
        let (sid, email, organization, cookieName) = sessionLock.withLock {
            (sid, pushEmail ?? account.email, pushOrganization, cookieName)
        }
        let cookieURL = origin.appendingPathComponent("coremail/s/json")
        guard let sid, let cookie = cookies.cookies(for: cookieURL)?.first(where: { $0.name == cookieName }),
              let domain = email.split(separator: "@").last else {
            throw URLError(.userAuthenticationRequired)
        }
        let auth = try CoremailPush.event("auth", [
            "username": email, "uid": email, "clientId": "fm_cm:\(sid)",
            "password": "{SES}\(sid):\(cookie.value)"
        ])
        let topic = "/\(organization ?? String(domain))/onstat/mail/\(email.lowercased())/in_mail"
        var url = URLComponents(url: origin, resolvingAgainstBaseURL: false)!
        url.path = "/socket.io/1/"
        url.queryItems = [.init(name: "EIO", value: "3"), .init(name: "transport", value: "polling"),
                          .init(name: "b64", value: "1"),
                          .init(name: "t", value: String(Int(Date().timeIntervalSince1970 * 1000)))]
        var request = URLRequest(url: url.url!)
        setHeaders(on: &request)
        let (data, response) = try await session.data(for: request, delegate: redirectPolicy)
        guard (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 8192 else {
            throw URLError(.badServerResponse)
        }
        let handshake = try CoremailPush.Handshake.decode(data)
        url.queryItems = [.init(name: "EIO", value: "3"), .init(name: "transport", value: "websocket"),
                          .init(name: "sid", value: handshake.sid)]
        var socketRequest = URLRequest(url: url.url!)
        setHeaders(on: &socketRequest)
        url.scheme = "wss"
        socketRequest.url = url.url
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.tlsMinimumSupportedProtocolVersion = .TLSv12
        let streamSession = URLSession(configuration: configuration, delegate: redirectPolicy, delegateQueue: nil)
        defer { streamSession.invalidateAndCancel() }
        try await CoremailPush.listen(socket: streamSession.webSocketTask(with: socketRequest),
                                      handshake: handshake, rootConnected: data.suffix(4) == Data("2:40".utf8),
                                      auth: auth, topic: topic, onSignal: onSignal)
    }

    var isLoggedIn: Bool { sessionLock.withLock { sid != nil } }

    /// RSA PKCS#1 v1.5 加密，输入 UTF-8 口令，输出十六进制串（与 Coremail 服务端约定一致）。
    static func rsaEncrypt(_ plaintext: String, eHex: String, nHex: String) throws -> String {
        guard let modulus = Data(hex: nHex), !modulus.isEmpty,
              let exponent = Data(hex: eHex), !exponent.isEmpty else {
            throw MailError("Coremail 公钥格式无效。")
        }
        let der = rsaPublicKeyDER(modulus: modulus, exponent: exponent)
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass: kSecAttrKeyClassPublic,
            kSecAttrKeySizeInBits: (modulus.count - (modulus.first == 0 ? 1 : 0)) * 8
        ]
        guard let secKey = SecKeyCreateWithData(der as CFData, attributes as CFDictionary, nil) else {
            throw MailError("Coremail 公钥导入失败。")
        }
        guard let cipher = SecKeyCreateEncryptedData(secKey, .rsaEncryptionPKCS1,
                                                     Data(plaintext.utf8) as CFData, nil) as Data? else {
            throw MailError("Coremail 口令加密失败。")
        }
        return cipher.map { String(format: "%02x", $0) }.joined()
    }

    /// 由裸 (modulus, exponent) 组装 PKCS#1 `RSAPublicKey` 的 DER（SecKeyCreateWithData 需要）。
    private static func rsaPublicKeyDER(modulus: Data, exponent: Data) -> Data {
        func integer(_ bytes: Data) -> Data {
            var value = bytes
            while value.count > 1 && value.first == 0 { value.removeFirst() }
            if let first = value.first, first & 0x80 != 0 { value.insert(0, at: 0) } // 保持正数
            return tlv(0x02, value)
        }
        func length(_ count: Int) -> Data {
            if count < 0x80 { return Data([UInt8(count)]) }
            var n = count, bytes: [UInt8] = []
            while n > 0 { bytes.insert(UInt8(n & 0xFF), at: 0); n >>= 8 }
            return Data([0x80 | UInt8(bytes.count)] + bytes)
        }
        func tlv(_ tag: UInt8, _ value: Data) -> Data { Data([tag]) + length(value.count) + value }
        return tlv(0x30, integer(modulus) + integer(exponent))
    }
}

private final class SameOriginRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let origin = task.originalRequest?.url, let target = request.url,
              target.scheme == "https", origin.host == target.host,
              (origin.port ?? 443) == (target.port ?? 443) else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}

private extension Data {
    /// 十六进制字符串转字节；非法输入返回 nil。
    init?(hex: String) {
        let chars = Array(hex.count.isMultiple(of: 2) ? hex : "0" + hex)
        var bytes = [UInt8](); bytes.reserveCapacity(chars.count / 2)
        var index = 0
        while index < chars.count {
            guard let high = chars[index].hexDigitValue, let low = chars[index + 1].hexDigitValue else { return nil }
            bytes.append(UInt8(high << 4 | low)); index += 2
        }
        self.init(bytes)
    }
}

// MARK: - 邮箱

/// Coremail 邮箱会话及邮件标识映射。
actor CoremailMailbox {
    private let session: CoremailSession
    private var resolvedOwnName: String?
    private var lastNameLookup: Date?
    private var loginTask: Task<Void, Error>?

    /// 分页窗口：每次「载入更早」增加的条数。
    static let pageSize = 50

    /// UInt32 ↔ Coremail 字符串 id（"fid:mid"）映射，满足 MailSummary.id 为 UInt32 的约定。
    private var idsByKey: [String: UInt32] = [:]
    private var keyByID: [UInt32: String] = [:]
    /// Folder number of each message key. The key's own prefix is a server shard, not a folder.
    private var fidByKey: [String: Int] = [:]
    private var nextID: UInt32 = 1
    /// 文件夹 fid（整数）映射：MailFolder.id(String) -> fid。
    private var fidByFolder: [String: Int] = [:]
    /// 每个文件夹已载入的条数（分页游标）。
    private var loaded: [String: Int] = [:]
    private var cache: [String: [MailSummary]] = [:]
    private var lastInboxIDs: Set<UInt32>?

    nonisolated let metadataFile: MailMetadataFile
    private let bodyCache: MessageBodyCache
    private var bodyDownloads: [String: (token: UUID, task: Task<Data, Error>)] = [:]
    /// Searchable text of cached bodies by mid; nil when the body cannot be searched (encrypted).
    private var bodyTexts: [String: String?] = [:]
    private var metadata: MailMetadata?
    private var metadataLoaded = false
    private var metadataDiscarded = false
    private var metadataBuilding = false
    private var metadataRevision = 0
    private var metadataSaveTask: Task<Void, Never>?
    private var metadataWrite: Task<Void, Never>?

    init(account: Account, password: String, protocolClasses: [AnyClass]? = nil, metadataDirectory: URL? = nil) throws {
        session = try CoremailSession(account: account, password: password, protocolClasses: protocolClasses)
        metadataFile = MailMetadataFile(account: account, directory: metadataDirectory)
        bodyCache = MessageBodyCache(account: account, root: metadataDirectory?.appendingPathComponent("Messages") ?? MailStorage.messages)
    }

    nonisolated func matches(_ account: Account, password: String) -> Bool {
        session.matches(account, password: password)
    }

    private func ensureLogin() async throws {
        if session.isLoggedIn { return }
        if let loginTask { return try await loginTask.value }
        let task = Task { try await session.login() }
        loginTask = task
        defer { loginTask = nil }
        try await task.value
    }

    func listenForMail(_ onSignal: @escaping @Sendable (CoremailPush.Signal) async -> Void) async throws {
        try await ensureLogin()
        try Task.checkCancellation()
        try await session.listenForMail(onSignal)
    }

    func identifier(_ key: String) -> UInt32 {
        if let id = idsByKey[key] { return id }
        let id = nextID
        nextID += 1
        idsByKey[key] = id
        keyByID[id] = key
        return id
    }

    // MARK: Local metadata

    func localMetadata() -> MailMetadata? {
        guard !metadataDiscarded else { return nil }
        if !metadataLoaded {
            metadataLoaded = true
            if var saved = try? metadataFile.load() {
                for folder in saved.folders {
                    let fid = folder.id == "INBOX" ? 1 : folder.id.split(separator: "/").last.flatMap { Int($0) }
                    if let fid, fidByFolder[folder.id] == nil { fidByFolder[folder.id] = fid }
                    saved.rows[folder.id] = saved.rows[folder.id]?.compactMap { row in
                        guard let key = row.serverID, Self.splitKey(key) != nil else { return nil }
                        var row = row
                        row.id = identifier(key)
                        row.fid = row.fid ?? fid
                        if let fid = row.fid { fidByKey[key] = fid }
                        return row
                    }
                }
                metadata = saved
            }
        }
        return metadata
    }

    func discardMetadata() async throws {
        metadataDiscarded = true
        metadata = nil
        metadataSaveTask?.cancel()
        metadataSaveTask = nil
        await metadataWrite?.value
        try metadataFile.remove()
    }

    func syncMetadata(progress: @Sendable (MetadataSyncProgress) async -> Void) async throws -> MailMetadata {
        guard !metadataBuilding, !metadataDiscarded else { throw MailError("邮箱摘要同步已开始或账户已变更。") }
        metadataBuilding = true
        defer { metadataBuilding = false }
        _ = localMetadata()
        let revision = metadataRevision
        let folders = try await folders()
        guard !folders.isEmpty else { throw MailError("服务器没有返回可用的文件夹。") }
        var rows: [String: [MailSummary]] = [:]
        var count = 0
        for (index, folder) in folders.enumerated() {
            let folderID = try fid(folder.id)
            var result: [MailSummary] = []
            var seen = Set<String>()
            var firstPage: [String] = []
            var start = 0
            while true {
                try Task.checkCancellation()
                await progress(.init(folder: folder.display, completed: index, total: folders.count,
                                     messages: count + result.count))
                let page = try await fetchList(fid: folderID, limit: Self.pageSize, start: start)
                if page.isEmpty { break }
                let keys = page.compactMap { $0["id"] as? String }
                guard keys.count == page.count, keys.allSatisfy({ seen.insert($0).inserted }) else {
                    throw MailError("同步「\(folder.display)」时列表发生变化，请重新同步。")
                }
                if start == 0 { firstPage = keys }
                let parsed = page.compactMap { summary($0, fid: folderID) }
                guard parsed.count == page.count else { throw MailError("服务器返回了无效的邮件标识。") }
                result += parsed
                start += page.count
            }
            if start > firstPage.count {
                let head = try await fetchList(fid: folderID, limit: Self.pageSize).compactMap { $0["id"] as? String }
                guard head == firstPage else {
                    throw MailError("同步「\(folder.display)」期间有新邮件或列表发生变化，请重新同步。")
                }
            }
            rows[folder.id] = result
            count += result.count
        }
        try Task.checkCancellation()
        guard !metadataDiscarded, revision == metadataRevision else {
            throw MailError("同步期间邮件状态发生变化，请重新同步。")
        }
        let snapshot = MailMetadata(completedAt: Date(), folders: folders, rows: rows)
        metadataSaveTask?.cancel()
        metadataSaveTask = nil
        try await writeMetadata(snapshot)
        metadata = snapshot
        return snapshot
    }

    private func recentWithMetadata(_ fresh: [MailSummary], folder: String, fid: Int, limit: Int) async throws -> [MailSummary] {
        guard let saved = metadata?.rows[folder] else { return fresh }
        var exhausted = fresh.count < limit
        if exhausted, !fresh.isEmpty, saved.count > fresh.count {
            // Some servers cap the response below the requested page size.
            exhausted = try await fetchList(fid: fid, limit: 1, start: fresh.count).isEmpty
        }
        let merged: [MailSummary]
        if exhausted {
            merged = fresh
        } else {
            let received = Set(fresh.map(\.id))
            let cutoff = fresh.last?.date ?? .distantPast
            merged = fresh + saved.filter { !received.contains($0.id) && ($0.date ?? .distantPast) <= cutoff }
        }
        if !metadataBuilding, merged != saved {
            metadata?.rows[folder] = merged
            persistMetadataChanges()
        }
        return merged
    }

    /// Coalesces local edits (read, flag, move) into one background write, rather than
    /// re-encoding the whole mailbox summary on every click.
    private func persistMetadataChanges() {
        guard metadata != nil, !metadataDiscarded, metadataSaveTask == nil else { return }
        metadataSaveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            await self?.flushMetadata()
        }
    }

    /// Writes pending summary changes now. Safe to call when nothing is pending.
    func flushMetadata() async {
        metadataSaveTask?.cancel()
        metadataSaveTask = nil
        guard let metadata, !metadataDiscarded else { return }
        try? await writeMetadata(metadata)
    }

    /// Writes run off the actor, one after another, so an older snapshot never lands last.
    private func writeMetadata(_ snapshot: MailMetadata) async throws {
        let previous = metadataWrite
        let file = metadataFile
        let write = Task.detached(priority: .utility) { () -> Error? in
            await previous?.value
            do { try file.save(snapshot); return nil } catch { return error }
        }
        metadataWrite = Task { _ = await write.value }
        if let error = await write.value { throw error }
    }

    // MARK: 文件夹

    func folders() async throws -> [MailFolder] {
        try await ensureLogin()
        guard let array = try await session.call("mbox:getAllFolders") as? [[String: Any]] else {
            throw MailError("Coremail 返回的文件夹格式异常。")
        }
        var folders: [MailFolder] = []
        var map: [String: Int] = [:]
        func walk(_ nodes: [[String: Any]], parent: String?) {
            for node in nodes {
                guard let fid = node["id"] as? Int else { continue }
                let rawName = (node["name"] as? String ?? String(fid))
                let folderID = parent.map { "\($0)/\(fid)" } ?? (fid == 1 ? "INBOX" : String(fid))
                map[folderID] = fid
                folders.append(MailFolder(id: folderID, name: rawName, delimiter: "/", role: Self.role(fid, name: rawName), nameIsLeaf: true))
                if let children = node["children"] as? [[String: Any]] { walk(children, parent: folderID) }
            }
        }
        walk(array, parent: nil)
        fidByFolder = map
        let live = Set(map.keys)
        cache = cache.filter { live.contains($0.key) }
        loaded = loaded.filter { live.contains($0.key) }
        folders.sort { left, right in
            if left.role == .inbox { return right.role != .inbox }
            if right.role == .inbox { return false }
            return left.name.localizedStandardCompare(right.name) == .orderedAscending
        }
        return folders
    }

    /// Coremail 固定系统夹 id → 角色。
    private static func role(_ fid: Int, name: String) -> MailFolderRole? {
        switch fid {
        case 1: return .inbox
        case 2: return .drafts
        case 3: return .sent
        case 4: return .trash
        case 5: return .junk
        default:
            let inferred = MailFolderRole.identify(id: String(fid), name: name, delimiter: nil, flags: [])
            return inferred == .archive ? .archive : nil
        }
    }

    private func fid(_ folder: String) throws -> Int {
        guard let fid = fidByFolder[folder] else { throw MailError("找不到文件夹，请刷新后重试。") }
        return fid
    }

    // MARK: 列表与分页

    /// 某夹邮件，最新在前。`widen` 多载入一页。
    func list(_ folder: String, widen: Bool) async throws -> (rows: [MailSummary], more: Bool, arrivals: [MailSummary]) {
        _ = localMetadata()
        try await ensureLogin()
        let fid = try fid(folder)
        let local = metadata?.rows[folder]
        if widen, local == nil, let page = try await nextPage(folder, fid: fid) { return page }
        let want = widen && local == nil ? (loaded[folder] ?? 0) + Self.pageSize : Self.pageSize
        let fresh = try await fetchList(fid: fid, limit: want).compactMap { summary($0, fid: fid) }
        let rows = try await recentWithMetadata(fresh, folder: folder, fid: fid, limit: want)
        loaded[folder] = fresh.count
        cache[folder] = rows
        try Task.checkCancellation()
        let arrivals = fid == 1 ? inboxArrivals(in: fresh) : []
        return (rows, local == nil && fresh.count >= want, arrivals) // 取满即可能还有更多
    }

    /// Fetches only the next page. A few already-loaded rows are requested again; if they no
    /// longer line up, the list changed underneath and the caller reloads from the top instead.
    private func nextPage(_ folder: String, fid: Int) async throws -> (rows: [MailSummary], more: Bool, arrivals: [MailSummary])? {
        guard let cached = cache[folder], let count = loaded[folder], count > 0, cached.count == count else { return nil }
        let overlap = min(5, count)
        let start = count - overlap
        let page = try await fetchList(fid: fid, limit: Self.pageSize + overlap, start: start)
        let keys = page.compactMap { $0["id"] as? String }
        guard keys.count == page.count, keys.count >= overlap,
              Array(keys.prefix(overlap)) == cached.suffix(overlap).map({ $0.serverID ?? "" }) else { return nil }
        let known = Set(cached.compactMap(\.serverID))
        let added = page.dropFirst(overlap).compactMap { summary($0, fid: fid) }.filter { !known.contains($0.serverID ?? "") }
        let rows = cached + added
        try Task.checkCancellation()
        loaded[folder] = rows.count
        cache[folder] = rows
        return (rows, page.count >= Self.pageSize + overlap, [])
    }

    /// 轮询：刷新当前夹与收件箱，返回收件箱新到未读用于通知。
    func poll(_ folder: String?, inbox: String?) async throws -> (rows: [MailSummary], arrivals: [MailSummary]) {
        try await ensureLogin()
        var arrivals: [MailSummary] = []
        for path in [folder == inbox ? nil : folder, inbox].compactMap({ $0 }) {
            guard let fid = fidByFolder[path] else { continue }
            let saved = metadata?.rows[path]
            let want = saved == nil ? max(loaded[path] ?? Self.pageSize, Self.pageSize) : Self.pageSize
            let fresh = try await fetchList(fid: fid, limit: want).compactMap { summary($0, fid: fid) }
            cache[path] = try await recentWithMetadata(fresh, folder: path, fid: fid, limit: want)
            loaded[path] = fresh.count
            try Task.checkCancellation()
            if path == inbox { arrivals = inboxArrivals(in: fresh) }
        }
        return (folder.flatMap { cache[$0] } ?? [], arrivals)
    }

    private func inboxArrivals(in rows: [MailSummary]) -> [MailSummary] {
        let latest = rows.prefix(Self.pageSize)
        let previous = lastInboxIDs
        lastInboxIDs = Set(latest.map(\.id))
        guard let previous else { return [] }
        // Rows below the first known message may simply have moved onto the first page.
        return latest.prefix { !previous.contains($0.id) }.filter(\.unread)
    }

    func unreadCounts() -> [String: Int] {
        cache.merging(metadata?.rows ?? [:]) { _, saved in saved }.mapValues { $0.filter(\.unread).count }
    }

    private func fetchList(fid: Int, limit: Int, start: Int = 0) async throws -> [[String: Any]] {
        let result = try await session.call("mbox:listMessages", body: [
            "fid": fid, "start": start, "limit": limit, "order": "receivedDate", "desc": true
        ])
        guard let array = result as? [[String: Any]] else { throw MailError("Coremail 返回的邮件列表格式异常。") }
        return array
    }

    /// 把一条 Coremail 邮件对象转成 MailSummary。所在文件夹取对象的 `fid`，没有时用请求的文件夹。
    private func summary(_ node: [String: Any], fid fallback: Int? = nil) -> MailSummary? {
        guard let key = node["id"] as? String, Self.splitKey(key) != nil else { return nil }
        let fid = (node["fid"] as? Int) ?? fallback
        if let fid { fidByKey[key] = fid }
        let flags = node["flags"] as? [String: Any] ?? [:]
        let read = flags["read"] as? Bool ?? false
        let sender = (node["from"] as? String).flatMap { MailAddress.parse($0).first }
        let to = (node["to"] as? String).map { MailAddress.parse($0) } ?? []
        let date = (node["receivedDate"] as? String ?? node["sentDate"] as? String).flatMap(Self.date)
        return MailSummary(
            id: identifier(key),
            subject: node["subject"] as? String ?? "",
            sender: sender,
            date: date,
            unread: !read,
            flagged: flags["flagged"] as? Bool ?? false,
            hasAttachment: flags["attached"] as? Bool == true,
            recipients: to, serverID: key, headerMessageID: node["hmid"] as? String, fid: fid)
    }

    /// Coremail 时间串 "YYYY-MM-DD HH:MM:SS"（本地时区）→ Date。
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()
    static func date(_ text: String) -> Date? { formatter.date(from: text) }

    // MARK: 读信

    /// 整封原始 RFC822，交给现有 MIME 解析。
    func message(_ id: UInt32, allowDownload: Bool = true) async throws -> Data {
        _ = localMetadata()
        guard let key = keyByID[id] else { throw MailError("邮件已不在列表中，请刷新。") }
        guard let (_, mid) = Self.splitKey(key) else { throw MailError("Coremail 邮件标识无效。") }
        // Drafts change, so their bodies are never cached.
        let draft = fidByKey[key] == 2
        if !draft, let cached = bodyCache.load(mid) { return cached }
        guard allowDownload else { throw MailError("这封邮件未缓存，请检查账户凭据后重试。") }
        if let existing = bodyDownloads[mid] { return try await existing.task.value }
        let token = UUID()
        let task = Task {
            try await ensureLogin()
            try Task.checkCancellation()
            let data = try await session.fetch("mbox:getMessageData",
                extra: [.init(name: "mid", value: mid), .init(name: "mode", value: "download")])
            try Task.checkCancellation()
            guard !data.isEmpty else { throw MailError("服务器没有返回这封邮件的原文。") }
            if !draft, bodyDownloads[mid]?.token == token { try? bodyCache.save(data, id: mid) }
            return data
        }
        bodyDownloads[mid] = (token, task)
        defer { if bodyDownloads[mid]?.token == token { bodyDownloads[mid] = nil } }
        return try await task.value
    }

    func clearBodyCache() throws {
        for download in bodyDownloads.values { download.task.cancel() }
        bodyDownloads.removeAll()
        bodyTexts.removeAll()
        try bodyCache.removeAll()
    }

    // MARK: 标志

    func setRead(_ id: UInt32, _ read: Bool) async throws {
        try await updateFlags(id, ["read": read]) { $0.unread = !read }
    }

    func setFlag(_ id: UInt32, _ flagged: Bool) async throws {
        try await updateFlags(id, ["flagged": flagged]) { $0.flagged = flagged }
    }

    private func updateFlags(_ id: UInt32, _ flags: [String: Bool], update: (inout MailSummary) -> Void) async throws {
        try await ensureLogin()
        guard let key = keyByID[id] else { throw MailError("邮件已不在列表中，请刷新。") }
        try await session.call("mbox:updateMessageInfos", body: ["ids": [key], "attrs": ["flags": flags]])
        metadataRevision += 1
        if let folder = folderForMessage(key), let index = metadata?.rows[folder]?.firstIndex(where: { $0.id == id }) {
            if var row = metadata?.rows[folder]?[index] {
                update(&row)
                metadata?.rows[folder]?[index] = row
                persistMetadataChanges()
            }
        }
        for (folder, rows) in cache {
            if let index = rows.firstIndex(where: { $0.id == id }) {
                var row = rows[index]; update(&row); cache[folder]?[index] = row
            }
        }
    }

    // MARK: 搜索

    /// 服务端全文搜索一个夹的一页；返回条目（已通过 getMessageInfos 补全）和下一页的偏移（没有更多时为 nil）。
    /// 生产验证（2026-11）：只有 `pattern` 生效且匹配正文，`keyword` 会被忽略；`start` 也被忽略，
    /// `limit` 生效，所以每页都从 0 取到 `start + limit`，再丢掉已拿到的部分。
    func search(_ term: String, in folder: String, start: Int = 0,
                limit: Int = searchPageSize) async throws -> SearchPage {
        try await ensureLogin()
        let fid = try fid(folder)
        let window = start + limit
        let result = try await session.call("mbox:searchMessages", body: [
            "fid": fid, "pattern": term, "start": 0, "limit": window,
            "order": "receivedDate", "desc": true, "returnTotal": true
        ])
        let all = (result as? [String]) ?? ((result as? [[String: Any]])?.compactMap { $0["id"] as? String } ?? [])
        let ids = Array(all.dropFirst(start))
        let next = all.count >= window ? all.count : nil
        guard !ids.isEmpty else { return SearchPage(rows: [], next: next) }
        let infos = try await session.call("mbox:getMessageInfos", body: ["ids": ids])
        let rows = (infos as? [[String: Any]])?.compactMap { summary($0, fid: fid) } ?? []
        let sorted = rows.sorted { ($0.date ?? .distantPast, $0.id) > ($1.date ?? .distantPast, $1.id) }
        return SearchPage(rows: sorted, next: next)
    }

    static let searchPageSize = 100

    /// 本地已知的条目：已载入的列表和全量同步的摘要，每封只出现一次。
    func localRows(in folders: [String]) -> [MailSummary] {
        _ = localMetadata()
        var seen = Set<UInt32>()
        var rows: [MailSummary] = []
        for folder in folders {
            for row in (cache[folder] ?? []) + (metadata?.rows[folder] ?? []) where seen.insert(row.id).inserted {
                rows.append(row)
            }
        }
        return rows
    }

    /// 已缓存正文的可搜索文本。只读本地缓存，不下载；解析结果留在内存里供下次搜索复用。
    func cachedBodies(_ ids: [UInt32]) async -> [UInt32: String] {
        var result: [UInt32: String] = [:]
        var pending: [(id: UInt32, mid: String)] = []
        for id in ids {
            guard let key = keyByID[id], let (_, mid) = Self.splitKey(key), fidByKey[key] != 2 else { continue }
            if let known = bodyTexts[mid] {
                if let known { result[id] = known }
            } else {
                pending.append((id, mid))
            }
        }
        guard !pending.isEmpty else { return result }
        let cache = bodyCache
        let parsed = await Task.detached(priority: .userInitiated) { () -> [ParsedBody] in
            let present = cache.cachedIDs(among: pending.map(\.mid))
            return pending.compactMap { item in
                // Bodies not cached yet are skipped and checked again next time.
                guard present.contains(item.mid), let raw = cache.peek(item.mid) else { return nil }
                return ParsedBody(id: item.id, mid: item.mid,
                                  text: MailSearchQuery.bodyText(raw).map { String($0.prefix(Self.bodyTextLimit)) })
            }
        }.value
        for item in parsed {
            bodyTexts[item.mid] = .some(item.text)
            if let text = item.text { result[item.id] = text }
        }
        return result
    }

    static let bodyTextLimit = 20_000

    private struct ParsedBody: Sendable {
        let id: UInt32
        let mid: String
        let text: String?
    }

    func relatedMail(to event: AgendaEvent, allowRemote: Bool) async -> [RelatedMail] {
        let saved = localMetadata()
        let local = (saved?.rows ?? [:]).merging(cache) { $0 + $1 }
        let matches = RelatedMail.matches(local, event: event)
        guard matches.isEmpty, allowRemote, !Task.isCancelled else { return matches }
        let query = String(RelatedMail.eventQuery(event.title).prefix(120))
        guard !query.isEmpty || event.sourceMessageID != nil else { return [] }
        let foldersToSearch = ["INBOX", "3"].filter { fidByFolder[$0] != nil }
        var remote: [String: [MailSummary]] = [:]
        if !query.isEmpty {
            for folder in foldersToSearch {
                guard !Task.isCancelled else { return [] }
                remote[folder] = try? await search(query, in: folder).rows
            }
        }
        return RelatedMail.matches(remote, event: event)
    }

    // MARK: 写信与草稿

    func send(_ draft: Draft) async throws {
        let messageID = MIME.outgoingMessageID(account: session.account, id: draft.id)
        let result = try await submit(draft, asDraft: false, messageID: messageID)
        let details = result["var"] as? [String: Any]
        if let sentID = (result["savedSent"] ?? details?["savedSent"]) as? String, !sentID.isEmpty { return }
        let rows = (try? await fetchList(fid: 3, limit: Self.pageSize)) ?? []
        guard rows.contains(where: { Self.matchesMessageID($0, messageID) }) else {
            throw MailError("服务器未确认邮件投递。请先检查「已发送」，再决定是否重试。")
        }
    }

    func saveDraft(_ draft: Draft, in folder: String) async throws -> UInt32 {
        let target = try fid(folder)
        let messageID = MIME.outgoingMessageID(account: session.account, id: UUID())
        let result = try await submit(draft, asDraft: true, messageID: messageID)
        let details = result["var"] as? [String: Any]
        let draftID = (result["draftId"] ?? details?["draftId"]) as? String
        // The server resolves a bare mid too, and answers with the full id.
        let key = draftID.flatMap { $0.isEmpty ? nil : $0 }
        if let key,
           let infos = (try? await session.call("mbox:getMessageInfos", body: ["ids": [key]])) as? [[String: Any]],
           let node = infos.first(where: { ($0["id"] as? String).map { $0 == key || Self.splitKey($0)?.1 == key } ?? false }),
           let row = summary(node, fid: target) {
            return row.id
        }

        let rows = try await fetchList(fid: target, limit: Self.pageSize)
        let matches = rows.filter { row in
            Self.matchesMessageID(row, messageID) || (key != nil && row["id"] as? String == key)
        }
        if matches.count == 1, let row = matches.first, let id = summary(row, fid: target)?.id { return id }
        throw MailError("服务器接受了提交，但草稿箱里找不到这封邮件。编辑内容已保留。")
    }

    private static func matchesMessageID(_ row: [String: Any], _ messageID: String) -> Bool {
        guard let header = row["hmid"] as? String else { return false }
        return header.trimmingCharacters(in: CharacterSet(charactersIn: "<>").union(.whitespacesAndNewlines)) == messageID
    }

    private static func composeAddress(_ address: MailAddress) -> String {
        let name = address.name.filter { !$0.isNewline && $0 != "\"" && $0 != "\\" && $0 != "\0" }
        return name.isEmpty ? address.email : "\"\(name)\" <\(address.email)>"
    }

    private func beginComposeSession() async throws -> String {
        let result = try await session.call("mbox:compose", body: [
            "action": "continue", "attrs": ["account": session.account.email, "saveSentCopy": true]
        ])
        guard let id = result as? String, !id.isEmpty else {
            throw MailError("Coremail 未返回写信会话。")
        }
        return id
    }

    private func submit(_ source: Draft, asDraft: Bool, messageID: String) async throws -> [String: Any] {
        let draft = try MIME.outgoingDraft(source, asDraft: asDraft)
        let (plain, html) = try MIME.outgoingBodies(draft)
        try await ensureLogin()
        var configured = session.account
        if configured.displayName.isEmpty {
            configured.displayName = session.identity.name ?? resolvedOwnName ?? session.identity.personalName ?? ""
        }
        let account = configured
        let sender = Self.composeAddress(MailAddress(name: account.displayName, email: account.email))
        let composeID = try await beginComposeSession()

        var fields: [String: Any] = [:]
        let eml: Data?
        // JSON compose uploads ordinary attachments only; CID resources must travel
        // with their HTML in a complete multipart/related MIME message.
        if draft.encrypt || draft.sign || !MIME.outgoingImages(draft, html: html).isEmpty {
            eml = try await Task.detached(priority: .userInitiated) {
                try MIME.outgoing(account: account, draft: draft, asDraft: asDraft, keepBcc: true, messageID: messageID).0
            }.value
        } else {
            eml = nil
            var attachments: [[String: Any]] = []
            for attachment in draft.attachments {
                try Task.checkCancellation()
                attachments.append(try await session.upload(attachment, composeID: composeID))
            }
            let extraHeaders = Dictionary(uniqueKeysWithValues:
                [("Message-ID", "<\(messageID)>")] + MIME.threadingHeaders(draft)
            )
            let attrs: [String: Any] = [
                "account": account.email, "from": sender,
                "to": draft.to.map(Self.composeAddress), "cc": draft.cc.map(Self.composeAddress),
                "bcc": draft.bcc.map(Self.composeAddress), "subject": draft.subject,
                "isHtml": html != nil, "content": html ?? plain, "charset": "UTF-8",
                "saveSentCopy": true, "attachments": attachments, "extraHeaders": extraHeaders
            ]
            fields = ["id": composeID, "action": asDraft ? "save" : "deliver", "attrs": attrs,
                      "returnInfo": true, "reorder": true]
        }
        if eml != nil {
            // composeF delivers an existing compose session. Its envelope is read
            // from that session, rather than inferred from the uploaded RFC822 headers.
            let extraHeaders = Dictionary(uniqueKeysWithValues:
                [("Message-ID", "<\(messageID)>")] + MIME.threadingHeaders(draft)
            )
            _ = try await session.call("mbox:compose", body: [
                "id": composeID, "action": "continue",
                "attrs": [
                    "account": account.email, "from": sender,
                    "to": draft.to.map(Self.composeAddress), "cc": draft.cc.map(Self.composeAddress),
                    "bcc": draft.bcc.map(Self.composeAddress), "subject": draft.subject,
                    "isHtml": html != nil, "content": html ?? plain, "charset": "UTF-8",
                    "saveSentCopy": true, "extraHeaders": extraHeaders
                ]
            ])
        }
        try Task.checkCancellation()
        do {
            if let eml { return try await session.submitEML(eml, composeID: composeID, asDraft: asDraft) }
            return try await session.callEnvelope("mbox:compose", body: fields)
        } catch let error as URLError where error.code == .timedOut || error.code == .networkConnectionLost {
            let folder = asDraft ? "草稿箱" : "已发送"
            throw MailError("连接在提交邮件时中断。请先检查「\(folder)」，再决定是否重试。")
        }
    }

    // MARK: 移动与删除

    func delete(_ id: UInt32, permanently: Bool, in folder: String? = nil) async throws {
        if !permanently { return try await move(id, toFID: 4) }
        try await ensureLogin()
        guard let key = keyByID[id] else { throw MailError("邮件已不在列表中，请刷新。") }
        if let folder, let known = fidByKey[key], known != (try fid(folder)) {
            throw MailError("草稿的位置已更改，请刷新。")
        }
        try await session.call("mbox:deleteMessages", body: ["ids": [key], "permanently": true])
        metadataRevision += 1
        if let folder = folderForMessage(key) {
            metadata?.rows[folder]?.removeAll { $0.id == id }
            persistMetadataChanges()
        }
        keyByID.removeValue(forKey: id)
        idsByKey.removeValue(forKey: key)
        fidByKey.removeValue(forKey: key)
        removeCached(id)
    }

    func move(_ id: UInt32, to folder: String) async throws {
        try await move(id, toFID: fid(folder))
    }

    private func move(_ id: UInt32, toFID target: Int) async throws {
        try await ensureLogin()
        guard let key = keyByID[id] else { throw MailError("邮件已不在列表中，请刷新。") }
        try await session.call("mbox:updateMessageInfos", body: ["ids": [key], "attrs": ["fid": target]])
        relocate(id, key: key, to: target)
    }

    /// A move keeps the message key; only its folder changes.
    private func relocate(_ id: UInt32, key: String, to target: Int) {
        let source = folderForMessage(key)
        fidByKey[key] = target
        metadataRevision += 1
        if let source {
            let row = metadata?.rows[source]?.first(where: { $0.id == id }) ?? cache[source]?.first(where: { $0.id == id })
            metadata?.rows[source]?.removeAll { $0.id == id }
            if var row, let folder = folderForMessage(key), var targetRows = metadata?.rows[folder] {
                row.fid = target
                targetRows.removeAll { $0.id == row.id }
                let date = row.date ?? .distantPast
                let index = targetRows.firstIndex { ($0.date ?? .distantPast) <= date } ?? targetRows.endIndex
                targetRows.insert(row, at: index)
                metadata?.rows[folder] = targetRows
            }
            persistMetadataChanges()
        }
        removeCached(id)
    }

    private func removeCached(_ id: UInt32) {
        for folder in Array(cache.keys) { cache[folder]?.removeAll { $0.id == id } }
    }

    private func folderForMessage(_ key: String) -> String? {
        guard let fid = fidByKey[key] else { return nil }
        return fidByFolder.first { $0.value == fid }?.key
    }

    private static func splitKey(_ key: String) -> (Int, String)? {
        let parts = key.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, let fid = Int(parts[0]), !parts[1].isEmpty else { return nil }
        return (fid, String(parts[1]))
    }

    func ownDisplayName() async throws -> String? {
        try await ensureLogin()
        let identity = session.identity
        if let name = identity.name ?? resolvedOwnName { return name }
        if let lastNameLookup, Date().timeIntervalSince(lastNameLookup) < 300 { return identity.personalName }
        lastNameLookup = Date()
        let email = MailAddress.isValid(identity.email) ? identity.email : session.account.email

        // Coremail's compose info exposes the default sender exactly as displayed by the server.
        // Only allocate a temporary compose session and read it; no message is saved or sent.
        if let id = try? await beginComposeSession(),
           let info = (try? await session.call("mbox:getComposeInfo", body: ["id": id])) as? [String: Any],
           let address = MailAddress.parse(info["account"] as? String ?? "").first(where: {
               $0.email.caseInsensitiveCompare(email) == .orderedSame ||
               $0.email.caseInsensitiveCompare(session.account.email) == .orderedSame
           }), let name = CoremailSession.usableName(address.name) {
            resolvedOwnName = name
            return name
        }
        if let name = identity.personalName { return name }
        let matches = try await directorySearch(email)
        let match = matches.first { $0.email.caseInsensitiveCompare(email) == .orderedSame }
        let name = CoremailSession.usableName(match?.name)
        resolvedOwnName = name
        return name
    }

    func directorySearch(_ term: String) async throws -> [ContactChoice] {
        guard term.utf8.count <= 256, !term.utf8.contains(0) else { throw MailError("联系人搜索词过长或含无效字符。") }
        try await ensureLogin()
        let result = try await session.call("oab:autoMatch", body: [
            "keyword": term, "limit": 30, "recursive": true,
            "attrIds": ["email", "true_name", "nick_name"]
        ])
        return try CompanyDirectory.decode(result)
    }

    func directoryAvatar(_ email: String) async throws -> Data {
        guard MailAddress.isValid(email) else { throw MailError("联系人邮箱无效。") }
        try await ensureLogin()
        return try await session.fetch("oab:getHeadImageData", extra: [.init(name: "uid", value: email)], long: false)
    }

    func checkDirectory() async throws {
        try await ensureLogin()
        try await session.call("oab:getDirectories")
    }
}

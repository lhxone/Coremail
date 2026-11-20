import Foundation

struct ServerHTTP {
    private final class RedirectDelegate: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    private static let session = makeSession(resource: 30)
    /// For whole messages with attachments, which can take minutes on a slow connection.
    private static let longSession = makeSession(resource: 300)

    private static func makeSession(resource: TimeInterval) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = resource
        configuration.tlsMinimumSupportedProtocolVersion = .TLSv12
        return URLSession(configuration: configuration, delegate: RedirectDelegate(), delegateQueue: nil)
    }

    let origin: URL
    private let authorization: String

    init(account: Account, password: String) throws {
        try account.validate()
        guard let url = URL(string: "https://\(account.host)"),
              !account.login.contains(":") else {
            throw MailError("服务器地址或登录名无效。")
        }
        origin = url
        authorization = "Basic " + Data((account.login + ":" + password).utf8).base64EncodedString()
    }

    func sameOrigin(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.host?.lowercased() == origin.host?.lowercased()
            && (url.port ?? 443) == (origin.port ?? 443) && url.user == nil && url.password == nil
    }

    func resolve(_ value: String, relativeTo root: URL? = nil) throws -> URL {
        guard !value.isEmpty, let url = URL(string: value, relativeTo: root ?? origin)?.absoluteURL,
              sameOrigin(url), url.fragment == nil else {
            throw MailError("服务器返回了其他域名或无效的服务地址。")
        }
        return url
    }

    func request(_ method: String, to start: URL, headers: [String: String] = [:],
                 body: Data? = nil, followRedirects: Bool = false,
                 long: Bool = false, timeout: TimeInterval = 15) async throws -> (Data, HTTPURLResponse) {
        var url = start
        for _ in 0..<6 {
            guard sameOrigin(url) else { throw MailError("服务器返回了其他域名的服务地址。") }
            var request = URLRequest(url: url)
            request.httpMethod = method
            request.setValue(authorization, forHTTPHeaderField: "Authorization")
            for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
            request.httpBody = body
            request.timeoutInterval = timeout
            let (data, raw) = try await (long ? Self.longSession : Self.session).data(for: request)
            guard let response = raw as? HTTPURLResponse else { throw MailError("服务器返回了无效的响应。") }
            if followRedirects, [301, 302, 303, 307, 308].contains(response.statusCode),
               let location = response.value(forHTTPHeaderField: "Location") {
                url = try resolve(location, relativeTo: url)
                continue
            }
            guard data.count <= (long ? 96 : 12) * 1024 * 1024 else { throw MailError("服务器返回的数据过大。") }
            return (data, response)
        }
        throw MailError("服务器进行了过多次重定向。")
    }
}

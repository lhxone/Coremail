import Foundation
import Security

enum SMIME {
    struct Decoded {
        let body: Data
        let encrypted: Bool
        let signature: String?
    }

    static func encrypt(_ data: Data, recipients: [String], sender: String) throws -> Data {
        let certs: [SecCertificate] = try keychainItems(kSecClassCertificate)
        let addresses = MailAddress.unique((recipients + [sender]).map { MailAddress(name: "", email: $0) })
        let selected = try addresses.map { address in
            let candidates = certs.filter { matches($0, address.email) && trusted($0, email: address.email) }
            let unique = Dictionary(grouping: candidates, by: { SecCertificateCopyData($0) as Data })
            guard unique.count == 1, let cert = candidates.first else {
                if unique.isEmpty { throw MailError("钥匙串中没有 \(address.email) 的受信任 S/MIME 证书。") }
                throw MailError("钥匙串中有多个适用于 \(address.email) 的 S/MIME 证书。请处理重复证书后重试。")
            }
            return cert
        }
        return try envelope(data, certificates: selected)
    }

    static func sign(_ data: Data, sender: String) throws -> Data {
        let identities: [SecIdentity] = try keychainItems(kSecClassIdentity)
        let candidates = identities.filter { identity in
            var certificate: SecCertificate?
            return SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess &&
                certificate.map { matches($0, sender) && trusted($0, email: sender) } == true
        }
        guard candidates.count == 1, let identity = candidates.first else {
            throw MailError("签名需要钥匙串中有一个与发件地址匹配的受信任证书及私钥。")
        }
        return try signContent(data, identity: identity)
    }

    static func signContent(_ data: Data, identity: SecIdentity) throws -> Data {
        var encoder: CMSEncoder?
        guard CMSEncoderCreate(&encoder) == errSecSuccess, let encoder,
              CMSEncoderSetSignerAlgorithm(encoder, kCMSEncoderDigestAlgorithmSHA256) == errSecSuccess,
              CMSEncoderAddSigners(encoder, identity) == errSecSuccess, !data.isEmpty else {
            throw MailError("无法初始化 S/MIME 签名。")
        }
        let status = data.withUnsafeBytes { CMSEncoderUpdateContent(encoder, $0.baseAddress!, $0.count) }
        var result: CFData?
        guard status == errSecSuccess, CMSEncoderCopyEncodedContent(encoder, &result) == errSecSuccess,
              let result else { throw MailError("无法生成 S/MIME 签名。") }
        return result as Data
    }

    static func envelope(_ data: Data, certificates: [SecCertificate]) throws -> Data {
        guard !data.isEmpty, !certificates.isEmpty else { throw MailError("S/MIME 加密缺少正文或收件人证书。") }
        let directory = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                                     appropriateFor: FileManager.default.temporaryDirectory, create: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let certPaths = try certificates.enumerated().map { index, certificate in
            let base64 = (SecCertificateCopyData(certificate) as Data).base64EncodedString(options: [.lineLength64Characters])
            let pem = "-----BEGIN CERTIFICATE-----\n" + base64 + "\n-----END CERTIFICATE-----\n"
            let url = directory.appendingPathComponent("recipient-\(index).pem")
            try pem.write(to: url, atomically: true, encoding: .utf8)
            return url.path
        }
        // The public macOS CMS encoder may select 3DES based on certificate capabilities.
        // Use the system CMS tool to require AES and keep the plaintext in process memory.
        let input = Pipe()
        let output = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        process.arguments = ["cms", "-encrypt", "-binary", "-aes-256-cbc", "-outform", "DER"] + certPaths
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.environment = ["PATH": "/usr/bin:/bin"]
        guard fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) == 0 else {
            throw MailError("无法打开 S/MIME 加密通道。")
        }
        try process.run()
        let writer = DispatchGroup()
        writer.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            defer {
                try? input.fileHandleForWriting.close()
                writer.leave()
            }
            try? input.fileHandleForWriting.write(contentsOf: data)
        }
        let result = output.fileHandleForReading.readDataToEndOfFile()
        writer.wait()
        process.waitUntilExit()
        guard process.terminationStatus == 0, !result.isEmpty else {
            throw MailError("无法用收件证书生成 AES-256 S/MIME 密文。请检查公钥证书用途。")
        }
        return result
    }

    static func decode(_ data: Data, sender: String?) throws -> Decoded {
        let decoder = try decoder(data)
        var content: CFData?
        let status = CMSDecoderCopyContent(decoder, &content)
        guard status == errSecSuccess, let content else {
            throw MailError("无法读取 S/MIME 内容。请检查钥匙串中的个人证书及私钥。")
        }
        var encrypted: DarwinBoolean = false
        CMSDecoderIsContentEncrypted(decoder, &encrypted)
        return Decoded(body: content as Data, encrypted: encrypted.boolValue,
                       signature: signature(decoder, sender: sender))
    }

    static func verify(_ data: Data, detached: Data, sender: String?) -> String {
        do {
            let decoder = try decoder(data, detached: detached)
            return signature(decoder, sender: sender) ?? "无法验证签名"
        } catch { return "无法验证签名" }
    }

    private static func decoder(_ data: Data, detached: Data? = nil) throws -> CMSDecoder {
        var decoder: CMSDecoder?
        guard CMSDecoderCreate(&decoder) == errSecSuccess, let decoder, !data.isEmpty else {
            throw MailError("无效的 S/MIME 邮件。")
        }
        if let detached { CMSDecoderSetDetachedContent(decoder, detached as CFData) }
        let status = data.withUnsafeBytes { CMSDecoderUpdateMessage(decoder, $0.baseAddress!, $0.count) }
        guard status == errSecSuccess, CMSDecoderFinalizeMessage(decoder) == errSecSuccess else {
            throw MailError("无法解码 S/MIME 邮件。请确认个人证书及私钥已导入钥匙串。")
        }
        return decoder
    }

    private static func signature(_ decoder: CMSDecoder, sender: String?) -> String? {
        var count = 0
        guard CMSDecoderGetNumSigners(decoder, &count) == errSecSuccess, count > 0 else { return nil }
        guard let sender, let policy = policy(sender) else { return "邮件没有可验证的发件地址" }
        for index in 0..<count {
            var result: CMSSignerStatus = .unsigned
            var certificate: SecCertificate?
            guard CMSDecoderCopySignerCert(decoder, index, &certificate) == errSecSuccess,
                  let certificate, matches(certificate, sender),
                  CMSDecoderCopySignerStatus(decoder, index, policy, true, &result, nil, nil) == errSecSuccess,
                  result == .valid else { return "签名验证失败或证书不受信任" }
        }
        return "签名有效"
    }

    private static func matches(_ certificate: SecCertificate, _ email: String) -> Bool {
        var addresses: CFArray?
        guard SecCertificateCopyEmailAddresses(certificate, &addresses) == errSecSuccess else { return false }
        return (addresses as? [String] ?? []).contains { $0.caseInsensitiveCompare(email) == .orderedSame }
    }

    private static func policy(_ email: String) -> SecPolicy? {
        SecPolicyCreateWithProperties(kSecPolicyAppleSMIME, [kSecPolicyName: email] as CFDictionary)
    }

    private static func trusted(_ certificate: SecCertificate, email: String) -> Bool {
        var trust: SecTrust?
        guard let policy = policy(email), SecTrustCreateWithCertificates(certificate, policy, &trust) == errSecSuccess,
              let trust else { return false }
        SecTrustSetNetworkFetchAllowed(trust, false)
        return SecTrustEvaluateWithError(trust, nil)
    }

    private static func keychainItems<T>(_ itemClass: CFString) throws -> [T] {
        let query = [kSecClass: itemClass, kSecMatchLimit: kSecMatchLimitAll, kSecReturnRef: true] as CFDictionary
        var items: CFTypeRef?
        let status = SecItemCopyMatching(query, &items)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else { throw MailError("无法访问证书钥匙串（\(status)）。") }
        return items as? [T] ?? []
    }
}

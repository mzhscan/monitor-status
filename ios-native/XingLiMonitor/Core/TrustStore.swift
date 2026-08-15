// TOFU 证书 pin + agent token 存储 —— 对齐 Flutter 版 trusted_certs.dart +
// store.dart 的 token 双写策略。
//
// Bundle ID 跟 Flutter 版相同（com.mzhhua.monitorstatus），所以直接读它写入的：
//   - NSUserDefaults: flutter.trusted_certs_v1（JSON map: url → SHA-256 指纹）
//   - NSUserDefaults: flutter.agent_token:<id>（iOS 兜底 token）
//   - Keychain: service=flutter_secure_storage_service, account=token:<id>

import Foundation
import Security
import CryptoKit

// MARK: - 受信任证书（TOFU）

enum TrustStore {
    static let certsKey = "flutter.trusted_certs_v1"

    /// 内存缓存：URLSessionDelegate 的 serverTrust challenge 是同步回调，
    /// 不能 await UserDefaults —— 跟 Dart TrustedCertCache 同一个思路。
    private(set) static var cache: [String: String] = [:]

    static func refreshCache() {
        cache = loadAll()
    }

    static func loadAll() -> [String: String] {
        guard let raw = UserDefaults.standard.string(forKey: certsKey),
              !raw.isEmpty,
              let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let m = obj as? [String: Any] else { return [:] }
        return m.compactMapValues { $0 as? String }
    }

    /// SHA-256 fingerprint of leaf cert DER：大写 hex，冒号分隔（跟 Dart 版一致）
    static func fingerprint(of cert: SecCertificate) -> String {
        let der = SecCertificateCopyData(cert) as Data
        let digest = SHA256.hash(data: der)
        return digest.map { String(format: "%02X", $0) }.joined(separator: ":")
    }

    static func isTrusted(origin: String, fingerprint: String) -> Bool {
        cache[origin] == fingerprint
    }

    static func trust(origin: String, fingerprint: String) {
        var m = loadAll()
        m[origin] = fingerprint
        save(m)
        refreshCache()
    }

    static func untrust(origin: String) {
        var m = loadAll()
        m.removeValue(forKey: origin)
        save(m)
        refreshCache()
    }

    private static func save(_ m: [String: String]) {
        if let data = try? JSONSerialization.data(withJSONObject: m),
           let str = String(data: data, encoding: .utf8) {
            UserDefaults.standard.set(str, forKey: certsKey)
        }
    }

    /// 对齐 Dart api.dart：issuer 子串匹配放行（Let's Encrypt / DigiCert 等）。
    /// 场景：iOS 严格 hostname 校验 + IP SAN 不认 → 系统校验失败但 CA 是主流
    /// 公签，用户主动填的 URL，token 仍做身份验证，trade-off 跟 Dart 版一致。
    static let trustedIssuerKeywords = [
        "Let's Encrypt", "ISRG", "DigiCert", "Sectigo", "Google Trust Services",
    ]

    static func issuerIsKnown(_ cert: SecCertificate) -> Bool {
        // Dart 版查 cert.issuer；iOS 没有 SecCertificateCopyNormalizedIssuerContent
        // （macOS only），用最小 ASN.1 DER 解析自己抽 issuer 各属性值做子串匹配。
        let issuer = issuerString(of: cert)
        return trustedIssuerKeywords.contains { issuer.contains($0) }
    }

    /// 从证书 DER 抽 issuer RDN 的所有属性值（O/CN/C 等）拼成串。
    /// Certificate ::= SEQ { tbs, sigAlg, sig }
    /// TBS ::= SEQ { [0]?version, serial, sigAlg, issuer, ... }
    static func issuerString(of cert: SecCertificate) -> String {
        let bytes = Array(SecCertificateCopyData(cert) as Data)
        guard let outer = ASN1.tlv(bytes, offset: 0), outer.0 == 0x30,
              let tbsTLV = ASN1.tlv(outer.1, offset: 0), tbsTLV.0 == 0x30 else { return "" }
        let tbs = tbsTLV.1
        var off = 0
        if let t = ASN1.tlv(tbs, offset: off), t.0 == 0xA0 { off = t.2 } // version [0] 可选
        if let t = ASN1.tlv(tbs, offset: off) { off = t.2 }              // serial
        if let t = ASN1.tlv(tbs, offset: off) { off = t.2 }              // sigAlg
        guard let issuerTLV = ASN1.tlv(tbs, offset: off), issuerTLV.0 == 0x30 else { return "" }
        var parts: [String] = []
        var i = 0
        let issuer = issuerTLV.1
        while let setTLV = ASN1.tlv(issuer, offset: i) {
            i = setTLV.2
            guard setTLV.0 == 0x31,
                  let attrTLV = ASN1.tlv(setTLV.1, offset: 0), attrTLV.0 == 0x30 else { continue }
            let attr = attrTLV.1
            guard let oidTLV = ASN1.tlv(attr, offset: 0), oidTLV.0 == 0x06,
                  let valTLV = ASN1.tlv(attr, offset: oidTLV.2) else { continue }
            if let s = String(bytes: valTLV.1, encoding: .utf8), !s.isEmpty {
                parts.append(s)
            }
        }
        return parts.joined(separator: " ")
    }
}

/// 最小 ASN.1 DER reader：只够抽证书 issuer 用
private enum ASN1 {
    /// 读 offset 处的 TLV：(tag, content, nextOffset)，损坏返回 nil
    static func tlv(_ b: [UInt8], offset: Int) -> (UInt8, [UInt8], Int)? {
        var i = offset
        guard i < b.count else { return nil }
        let tag = b[i]; i += 1
        guard i < b.count else { return nil }
        let first = b[i]; i += 1
        var len: Int
        if first < 0x80 {
            len = Int(first)
        } else {
            let n = Int(first & 0x7F)
            guard n > 0, n <= 4, i + n <= b.count else { return nil }
            len = 0
            for k in 0..<n { len = (len << 8) | Int(b[i + k]) }
            i += n
        }
        guard i + len <= b.count else { return nil }
        return (tag, Array(b[i..<(i + len)]), i + len)
    }
}

// MARK: - Agent token（Keychain 为主 + UserDefaults 兜底）

enum TokenStore {
    /// flutter_secure_storage 在 iOS 上的默认 Keychain service
    private static let keychainService = "flutter_secure_storage_service"

    static func keychainAccount(id: String) -> String { "token:\(id)" }
    static func defaultsKey(id: String) -> String { "flutter.agent_token:\(id)" }

    /// 读：Keychain → UserDefaults 兜底（对齐 Dart _loadToken）
    static func load(id: String) -> String? {
        if let t = readKeychain(id: id), !t.isEmpty { return t }
        let t = UserDefaults.standard.string(forKey: defaultsKey(id: id)) ?? ""
        return t.isEmpty ? nil : t
    }

    /// 写：双写 Keychain + UserDefaults（对齐 Dart _saveToken）
    static func save(id: String, token: String) {
        writeKeychain(id: id, token: token)
        UserDefaults.standard.set(token, forKey: defaultsKey(id: id))
    }

    static func delete(id: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount(id: id),
        ]
        SecItemDelete(query as CFDictionary)
        UserDefaults.standard.removeObject(forKey: defaultsKey(id: id))
    }

    private static func readKeychain(id: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount(id: id),
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func writeKeychain(id: String, token: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount(id: id),
        ]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = Data(token.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }
}

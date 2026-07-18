import Foundation
import Security

public struct WlocCertificateMaterial: Equatable, Sendable {
    public var certificateDER: Data
    public var privateKeyDER: Data

    public init(certificateDER: Data, privateKeyDER: Data) {
        self.certificateDER = certificateDER
        self.privateKeyDER = privateKeyDER
    }
}

public struct WlocDeviceCertificateStore: Sendable {
    private let service = "app.wloc.device-ca"
    private let accessGroup: String?

    public init(keychainAccessGroup: String? = nil) {
        accessGroup = keychainAccessGroup?.isEmpty == false ? keychainAccessGroup : nil
    }

    public func load() throws -> WlocCertificateMaterial? {
        let certificate = try load(account: "certificate-der")
        let privateKey = try load(account: "private-key-der")
        switch (certificate, privateKey) {
        case (nil, nil): return nil
        case let (.some(certificate), .some(privateKey)):
            return .init(certificateDER: certificate, privateKeyDER: privateKey)
        default:
            throw WlocCoreError.malformedInput("设备 CA 的证书与私钥不完整，请重新生成。")
        }
    }

    /// Persists both values and rolls back a newly written certificate when the
    /// private-key write fails. The private key is marked this-device-only.
    public func save(_ material: WlocCertificateMaterial) throws {
        guard !material.certificateDER.isEmpty, !material.privateKeyDER.isEmpty else {
            throw WlocCoreError.malformedInput("设备 CA 数据为空")
        }
        let previousCertificate = try load(account: "certificate-der")
        do {
            try save(material.certificateDER, account: "certificate-der")
            try save(material.privateKeyDER, account: "private-key-der")
        } catch {
            if let previousCertificate {
                try? save(previousCertificate, account: "certificate-der")
            } else {
                try? delete(account: "certificate-der")
            }
            throw error
        }
    }

    public func delete() throws {
        try delete(account: "certificate-der")
        try delete(account: "private-key-der")
    }

    private func save(_ data: Data, account: String) throws {
        var attributes = baseQuery(account: account)
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let update = SecItemUpdate(
                baseQuery(account: account) as CFDictionary,
                [kSecValueData as String: data] as CFDictionary
            )
            guard update == errSecSuccess else { throw ProfileRepositoryError.keychain(update) }
        } else if status != errSecSuccess {
            throw ProfileRepositoryError.keychain(status)
        }
    }

    private func load(account: String) throws -> Data? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &value)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = value as? Data else {
            throw ProfileRepositoryError.keychain(status)
        }
        return data
    }

    private func delete(account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ProfileRepositoryError.keychain(status)
        }
    }

    private func baseQuery(account: String) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
        return query
    }
}

public enum WlocCertificateProfile {
    public static func make(certificateDER: Data, identifierPrefix: String) throws -> Data {
        guard !certificateDER.isEmpty else { throw WlocCoreError.malformedInput("CA 证书为空") }
        let rootUUID = UUID().uuidString
        let profileUUID = UUID().uuidString
        let rootPayload: [String: Any] = [
            "PayloadCertificateFileName": "WLOC-Device-CA.cer",
            "PayloadContent": certificateDER,
            "PayloadDescription": "仅用于本机 WLOC 定位响应的两个 Apple 域名。",
            "PayloadDisplayName": "WLOC 设备根证书",
            "PayloadIdentifier": "\(identifierPrefix).ca.\(rootUUID)",
            "PayloadType": "com.apple.security.root",
            "PayloadUUID": rootUUID,
            "PayloadVersion": 1,
        ]
        let profile: [String: Any] = [
            "PayloadContent": [rootPayload],
            "PayloadDescription": "安装后还需在“设置 > 通用 > 关于本机 > 证书信任设置”中手动完全信任。",
            "PayloadDisplayName": "WLOC 设备证书",
            "PayloadIdentifier": "\(identifierPrefix).profile.\(profileUUID)",
            "PayloadOrganization": "WLOC Local Device",
            "PayloadRemovalDisallowed": false,
            "PayloadType": "Configuration",
            "PayloadUUID": profileUUID,
            "PayloadVersion": 1,
        ]
        return try PropertyListSerialization.data(fromPropertyList: profile, format: .xml, options: 0)
    }
}

import Foundation
import Security

public struct ProxyProfileMetadata: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var format: ProxyProfileFormat
    public var importedAt: Date
    public var configurationByteCount: Int

    public init(id: UUID, name: String, format: ProxyProfileFormat, importedAt: Date, configurationByteCount: Int) {
        self.id = id
        self.name = name
        self.format = format
        self.importedAt = importedAt
        self.configurationByteCount = configurationByteCount
    }
}

public enum ProfileRepositoryError: Error, LocalizedError, Equatable, Sendable {
    case unusableDraft
    case profileNotFound(UUID)
    case cannotDeleteActiveProfile
    case keychain(OSStatus)
    case persistenceFailed

    public var errorDescription: String? {
        switch self {
        case .unusableDraft: "配置兼容性报告含错误，不能启用。"
        case let .profileNotFound(id): "找不到配置：\(id.uuidString)"
        case .cannotDeleteActiveProfile: "不能删除当前正在使用的配置，请先切换。"
        case let .keychain(status):
            "Keychain 操作失败（\(status)）：\(SecCopyErrorMessageString(status, nil) as String? ?? "未知错误")"
        case .persistenceFailed: "App Group 元数据写入后校验失败，已回滚。"
        }
    }
}

/// Stores configuration bodies in the shared Keychain. Only non-secret metadata is
/// written to App Group preferences so both the app and Packet Tunnel can discover
/// the active profile without leaving credentials in a plist or diagnostic log.
public actor ProxyProfileRepository {
    public static let metadataKey = "wloc.proxy-profiles.v1"
    public static let activeProfileKey = WlocSharedStore.activeProfileKey

    private let defaults: UserDefaults
    private let vault: KeychainProfileVault
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(appGroupIdentifier: String, keychainAccessGroup: String? = nil) throws {
        guard let defaults = UserDefaults(suiteName: appGroupIdentifier) else {
            throw WlocCoreError.malformedInput("无法打开 App Group：\(appGroupIdentifier)")
        }
        self.defaults = defaults
        vault = KeychainProfileVault(accessGroup: keychainAccessGroup)
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    public func profiles() throws -> [ProxyProfileMetadata] {
        try loadMetadata().sorted { $0.importedAt > $1.importedAt }
    }

    public func activeProfileID() -> UUID? {
        defaults.string(forKey: Self.activeProfileKey).flatMap(UUID.init(uuidString:))
    }

    public func activeProfile() throws -> ProxyProfileMetadata? {
        guard let id = activeProfileID() else { return nil }
        return try loadMetadata().first { $0.id == id }
    }

    public func configuration(for id: UUID) throws -> Data {
        guard let data = try vault.load(id: id) else {
            throw ProfileRepositoryError.profileNotFound(id)
        }
        return data
    }

    public func activeConfiguration() throws -> Data? {
        guard let id = activeProfileID() else { return nil }
        return try configuration(for: id)
    }

    /// Saves the new secret first and only changes the active pointer after every
    /// persistence check succeeds. A failed import therefore leaves the old profile intact.
    @discardableResult
    public func commit(_ draft: ImportedProfileDraft, name: String? = nil, activate: Bool = true) throws -> ProxyProfileMetadata {
        guard draft.isUsable else { throw ProfileRepositoryError.unusableDraft }
        let cleanName = String((name ?? draft.suggestedName).trimmingCharacters(in: .whitespacesAndNewlines).prefix(60))
        let id = UUID()
        let metadata = ProxyProfileMetadata(
            id: id,
            name: cleanName.isEmpty ? "未命名配置" : cleanName,
            format: draft.format,
            importedAt: .now,
            configurationByteCount: draft.configuration.count
        )

        let oldMetadataData = defaults.data(forKey: Self.metadataKey)
        let oldActive = defaults.string(forKey: Self.activeProfileKey)
        do {
            try vault.save(draft.configuration, id: id)
            var metadataItems = try loadMetadata()
            metadataItems.append(metadata)
            try persistMetadata(metadataItems)
            if activate {
                defaults.set(id.uuidString, forKey: Self.activeProfileKey)
                guard defaults.string(forKey: Self.activeProfileKey) == id.uuidString else {
                    throw ProfileRepositoryError.persistenceFailed
                }
            }
            return metadata
        } catch {
            try? vault.delete(id: id)
            if let oldMetadataData {
                defaults.set(oldMetadataData, forKey: Self.metadataKey)
            } else {
                defaults.removeObject(forKey: Self.metadataKey)
            }
            if let oldActive {
                defaults.set(oldActive, forKey: Self.activeProfileKey)
            } else {
                defaults.removeObject(forKey: Self.activeProfileKey)
            }
            throw error
        }
    }

    public func activate(_ id: UUID) throws {
        guard try loadMetadata().contains(where: { $0.id == id }), try vault.load(id: id) != nil else {
            throw ProfileRepositoryError.profileNotFound(id)
        }
        let previous = defaults.string(forKey: Self.activeProfileKey)
        defaults.set(id.uuidString, forKey: Self.activeProfileKey)
        guard defaults.string(forKey: Self.activeProfileKey) == id.uuidString else {
            if let previous { defaults.set(previous, forKey: Self.activeProfileKey) }
            throw ProfileRepositoryError.persistenceFailed
        }
    }

    public func delete(_ id: UUID) throws {
        guard activeProfileID() != id else { throw ProfileRepositoryError.cannotDeleteActiveProfile }
        var metadataItems = try loadMetadata()
        guard metadataItems.contains(where: { $0.id == id }) else {
            throw ProfileRepositoryError.profileNotFound(id)
        }
        let oldMetadata = metadataItems
        metadataItems.removeAll { $0.id == id }
        try persistMetadata(metadataItems)
        do {
            try vault.delete(id: id)
        } catch {
            try? persistMetadata(oldMetadata)
            throw error
        }
    }

    private func loadMetadata() throws -> [ProxyProfileMetadata] {
        guard let data = defaults.data(forKey: Self.metadataKey) else { return [] }
        return try decoder.decode([ProxyProfileMetadata].self, from: data)
    }

    private func persistMetadata(_ metadata: [ProxyProfileMetadata]) throws {
        let data = try encoder.encode(metadata)
        defaults.set(data, forKey: Self.metadataKey)
        guard defaults.data(forKey: Self.metadataKey) == data else {
            throw ProfileRepositoryError.persistenceFailed
        }
    }
}

private struct KeychainProfileVault: Sendable {
    private let service = "app.wloc.proxy-profile"
    private let accessGroup: String?

    init(accessGroup: String?) {
        self.accessGroup = accessGroup?.isEmpty == false ? accessGroup : nil
    }

    func save(_ data: Data, id: UUID) throws {
        var add = baseQuery(id: id)
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let updateStatus = SecItemUpdate(
                baseQuery(id: id) as CFDictionary,
                [kSecValueData as String: data] as CFDictionary
            )
            guard updateStatus == errSecSuccess else { throw ProfileRepositoryError.keychain(updateStatus) }
        } else if status != errSecSuccess {
            throw ProfileRepositoryError.keychain(status)
        }
    }

    func load(id: UUID) throws -> Data? {
        var query = baseQuery(id: id)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw ProfileRepositoryError.keychain(status)
        }
        return data
    }

    func delete(id: UUID) throws {
        let status = SecItemDelete(baseQuery(id: id) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ProfileRepositoryError.keychain(status)
        }
    }

    private func baseQuery(id: UUID) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString,
        ]
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
        return query
    }
}

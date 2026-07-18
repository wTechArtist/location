import Foundation

enum AppEnvironment {
    static var appGroupIdentifier: String {
        requiredInfoValue("WlocAppGroupIdentifier")
    }

    static var keychainAccessGroup: String {
        requiredInfoValue("WlocKeychainAccessGroup")
    }

    static var packetTunnelBundleIdentifier: String {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else {
            preconditionFailure("主 App 缺少 bundle identifier")
        }
        return bundleIdentifier + ".PacketTunnel"
    }

    private static func requiredInfoValue(_ key: String) -> String {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String,
              !value.isEmpty,
              !value.contains("$(")
        else {
            preconditionFailure("Info.plist 缺少已展开的 \(key)")
        }
        return value
    }
}

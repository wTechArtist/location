import Foundation
import WlocCore

#if canImport(Libbox)
import Libbox
#endif

struct DeviceCertificateManager {
    let appGroupIdentifier: String
    let keychainAccessGroup: String

    func hasCertificate() throws -> Bool {
        try WlocDeviceCertificateStore(keychainAccessGroup: keychainAccessGroup).load() != nil
    }

    /// Generates the CA only when absent. The private key goes directly from Libbox
    /// into this-device-only Keychain storage and is never written to the profile file.
    func prepareInstallationProfile() throws -> URL {
        let store = WlocDeviceCertificateStore(keychainAccessGroup: keychainAccessGroup)
        let material: WlocCertificateMaterial
        if let existing = try store.load() {
            material = existing
        } else {
            #if canImport(Libbox)
            var generationError: NSError?
            guard let generated = LibboxGenerateWlocCA(&generationError),
                  let certificateDER = generated.certificateDER(),
                  let privateKeyDER = generated.privateKeyDER()
            else {
                throw generationError ?? DeviceCertificateError.generationFailed
            }
            material = .init(certificateDER: certificateDER, privateKeyDER: privateKeyDER)
            try store.save(material)
            #else
            throw DeviceCertificateError.libboxUnavailable
            #endif
        }

        let profile = try WlocCertificateProfile.make(
            certificateDER: material.certificateDER,
            identifierPrefix: Bundle.main.bundleIdentifier ?? "app.wloc"
        )
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("WLOC-CA", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("WLOC-Device-CA.mobileconfig")
        try profile.write(to: url, options: [.atomic, .completeFileProtection])
        return url
    }
}

enum DeviceCertificateError: Error, LocalizedError {
    case libboxUnavailable
    case generationFailed

    var errorDescription: String? {
        switch self {
        case .libboxUnavailable: "缺少 Libbox，无法生成设备 CA。"
        case .generationFailed: "生成设备 CA 失败。"
        }
    }
}

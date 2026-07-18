import Foundation
import NetworkExtension

@MainActor
final class TunnelController: ObservableObject {
    enum State: Equatable {
        case unavailable
        case disconnected
        case connecting
        case connected
        case disconnecting
        case reasserting

        var label: String {
            switch self {
            case .unavailable: "未安装"
            case .disconnected: "已断开"
            case .connecting: "连接中"
            case .connected: "已连接"
            case .disconnecting: "断开中"
            case .reasserting: "正在重连"
            }
        }
    }

    @Published private(set) var state: State = .unavailable
    @Published private(set) var lastError: String?

    private let providerBundleIdentifier: String
    private var manager: NETunnelProviderManager?
    private var statusObserver: NSObjectProtocol?

    init(providerBundleIdentifier: String) {
        self.providerBundleIdentifier = providerBundleIdentifier
        statusObserver = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshState() }
        }
    }

    deinit {
        if let statusObserver { NotificationCenter.default.removeObserver(statusObserver) }
    }

    func load() async {
        do {
            manager = try await loadInstalledManager()
            refreshState()
        } catch {
            lastError = error.localizedDescription
            state = .unavailable
        }
    }

    /// Creates the system VPN profile. iOS shows its mandatory authorization sheet
    /// the first time this method saves a manager.
    func installIfNeeded() async throws {
        if manager == nil { manager = try await loadInstalledManager() }
        if let manager {
            let tunnelProtocol = (manager.protocolConfiguration as? NETunnelProviderProtocol) ?? NETunnelProviderProtocol()
            var requiresSave = !manager.isEnabled
            if tunnelProtocol.providerBundleIdentifier != providerBundleIdentifier {
                tunnelProtocol.providerBundleIdentifier = providerBundleIdentifier
                requiresSave = true
            }
            if tunnelProtocol.serverAddress?.isEmpty != false {
                tunnelProtocol.serverAddress = "WLOC 本机隧道"
                requiresSave = true
            }
            if tunnelProtocol.providerConfiguration?["schemaVersion"] as? Int != 1 {
                tunnelProtocol.providerConfiguration = ["schemaVersion": 1]
                requiresSave = true
            }
            manager.protocolConfiguration = tunnelProtocol
            manager.localizedDescription = "WLOC"
            manager.isEnabled = true
            if requiresSave {
                try await save(manager)
                try await reload(manager)
            }
            refreshState()
            return
        }

        let newManager = NETunnelProviderManager()
        let tunnelProtocol = NETunnelProviderProtocol()
        tunnelProtocol.providerBundleIdentifier = providerBundleIdentifier
        tunnelProtocol.serverAddress = "WLOC 本机隧道"
        tunnelProtocol.providerConfiguration = ["schemaVersion": 1]
        newManager.protocolConfiguration = tunnelProtocol
        newManager.localizedDescription = "WLOC"
        newManager.isEnabled = true
        try await save(newManager)
        try await reload(newManager)
        manager = newManager
        refreshState()
    }

    func start() async throws {
        try await installIfNeeded()
        guard let manager else { throw TunnelControllerError.managerUnavailable }
        if manager.connection.status == .connected { return }
        do {
            try manager.connection.startVPNTunnel()
            try await wait(until: [.connected], timeout: 25)
        } catch {
            lastError = error.localizedDescription
            refreshState()
            throw error
        }
    }

    func stop() async throws {
        guard let manager else { return }
        if manager.connection.status == .disconnected || manager.connection.status == .invalid { return }
        manager.connection.stopVPNTunnel()
        try await wait(until: [.disconnected, .invalid], timeout: 15)
    }

    func restart() async throws {
        try await stop()
        try await start()
    }

    private func loadInstalledManager() async throws -> NETunnelProviderManager? {
        let managers: [NETunnelProviderManager] = try await withCheckedThrowingContinuation { continuation in
            NETunnelProviderManager.loadAllFromPreferences { managers, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: managers ?? []) }
            }
        }
        return managers.first { manager in
            (manager.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == providerBundleIdentifier
        }
    }

    private func save(_ manager: NETunnelProviderManager) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            manager.saveToPreferences { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: ()) }
            }
        }
    }

    private func reload(_ manager: NETunnelProviderManager) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            manager.loadFromPreferences { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: ()) }
            }
        }
    }

    private func wait(until targetStatuses: Set<NEVPNStatus>, timeout: TimeInterval) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(timeout))
        while clock.now < deadline {
            refreshState()
            guard let status = manager?.connection.status else { throw TunnelControllerError.managerUnavailable }
            if targetStatuses.contains(status) { return }
            if status == .invalid { throw TunnelControllerError.invalidConfiguration }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw TunnelControllerError.timeout
    }

    private func refreshState() {
        guard let status = manager?.connection.status else {
            state = .unavailable
            return
        }
        state = switch status {
        case .invalid: .unavailable
        case .disconnected: .disconnected
        case .connecting: .connecting
        case .connected: .connected
        case .reasserting: .reasserting
        case .disconnecting: .disconnecting
        @unknown default: .unavailable
        }
    }
}

enum TunnelControllerError: Error, LocalizedError {
    case managerUnavailable
    case invalidConfiguration
    case timeout

    var errorDescription: String? {
        switch self {
        case .managerUnavailable: "VPN 配置不可用。"
        case .invalidConfiguration: "VPN 配置已失效。"
        case .timeout: "等待 VPN 状态切换超时。"
        }
    }
}

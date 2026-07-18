#if canImport(Libbox)
import Foundation
import Libbox
import Network
import NetworkExtension
import os
import WlocCore

class WlocLibboxPacketTunnelProvider: NEPacketTunnelProvider {
    private static let logger = Logger(subsystem: "app.wloc", category: "PacketTunnel")

    fileprivate var commandServer: LibboxCommandServer?
    fileprivate lazy var platformInterface = WlocPlatformInterface(tunnel: self)
    private var wlocProxy: LibboxWlocProxy?
    private var responsePatcher: WlocResponsePatcherBridge?
    private var injectedConfiguration = ""

    override init() {
        super.init()
    }

    override func startTunnel(options _: [String: NSObject]?) async throws {
        let environment = try PacketTunnelEnvironment.load()
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: environment.appGroupIdentifier
        ) else {
            throw PacketTunnelError.appGroupUnavailable
        }
        let workingURL = containerURL.appendingPathComponent("Library/WlocWorking", isDirectory: true)
        let temporaryURL = containerURL.appendingPathComponent("Library/WlocTemp", isDirectory: true)
        try FileManager.default.createDirectory(at: workingURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: temporaryURL, withIntermediateDirectories: true)

        let repository = try ProxyProfileRepository(
            appGroupIdentifier: environment.appGroupIdentifier,
            keychainAccessGroup: environment.keychainAccessGroup
        )
        guard let configuration = try await repository.activeConfiguration(),
              let configurationText = String(data: configuration, encoding: .utf8)
        else {
            throw PacketTunnelError.missingActiveProfile
        }
        let certificateStore = WlocDeviceCertificateStore(keychainAccessGroup: environment.keychainAccessGroup)
        guard let certificate = try certificateStore.load() else {
            throw PacketTunnelError.missingDeviceCA
        }
        let sharedStore = try WlocSharedStore(appGroupIdentifier: environment.appGroupIdentifier)
        guard sharedStore.isCATrustConfirmed() else {
            throw PacketTunnelError.missingCATrustConfirmation
        }

        let setup = LibboxSetupOptions()
        setup.basePath = containerURL.path
        setup.workingPath = workingURL.path
        setup.tempPath = temporaryURL.path
        setup.logMaxLines = 3_000
        setup.debug = false
        var setupError: NSError?
        LibboxSetup(setup, &setupError)
        if let setupError { throw setupError }

        let patcher = try WlocResponsePatcherBridge(appGroupIdentifier: environment.appGroupIdentifier)
        var proxyError: NSError?
        guard let proxy = LibboxNewWlocProxy(
            certificate.certificateDER,
            certificate.privateKeyDER,
            patcher,
            &proxyError
        ) else {
            throw proxyError ?? PacketTunnelError.mitmStartupFailed
        }
        try proxy.start()
        guard proxy.port() > 0 else {
            try? proxy.close()
            throw PacketTunnelError.mitmStartupFailed
        }
        responsePatcher = patcher
        wlocProxy = proxy

        do {
            let injectedData = try WlocTunnelConfiguration.injectingLocalMITM(
                into: Data(configurationText.utf8),
                port: Int(proxy.port())
            )
            guard let injectedText = String(data: injectedData, encoding: .utf8) else {
                throw PacketTunnelError.invalidConfiguration
            }
            injectedConfiguration = injectedText
            var serverError: NSError?
            guard let server = LibboxNewCommandServer(platformInterface, platformInterface, &serverError) else {
                throw serverError ?? PacketTunnelError.libboxStartupFailed
            }
            commandServer = server
            try server.start()
            try startOrReloadService()
            Self.logger.notice("WLOC tunnel started; MITM port=\(proxy.port(), privacy: .public)")
        } catch {
            stopServices()
            throw error
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason) async {
        Self.logger.notice("WLOC tunnel stopping; reason=\(reason.rawValue, privacy: .public)")
        stopServices()
    }

    override func handleAppMessage(_ messageData: Data) async -> Data? {
        guard String(data: messageData, encoding: .utf8) == "reload" else {
            return "unsupported message".data(using: .utf8)
        }
        do {
            try startOrReloadService()
            return nil
        } catch {
            return error.localizedDescription.data(using: .utf8)
        }
    }

    fileprivate func startOrReloadService() throws {
        guard let commandServer, !injectedConfiguration.isEmpty else {
            throw PacketTunnelError.libboxStartupFailed
        }
        try commandServer.startOrReloadService(injectedConfiguration, options: LibboxOverrideOptions())
    }

    fileprivate func stopServices() {
        try? commandServer?.closeService()
        if let commandServer {
            commandServer.close()
        }
        commandServer = nil
        platformInterface.reset()
        try? wlocProxy?.close()
        wlocProxy = nil
        responsePatcher = nil
        injectedConfiguration = ""
    }

    fileprivate func writeLog(_ message: String) {
        Self.logger.info("\(message, privacy: .public)")
    }

}

private struct PacketTunnelEnvironment {
    var appGroupIdentifier: String
    var keychainAccessGroup: String

    static func load(bundle: Bundle = .main) throws -> PacketTunnelEnvironment {
        guard let appGroup = bundle.object(forInfoDictionaryKey: "WlocAppGroupIdentifier") as? String,
              let keychain = bundle.object(forInfoDictionaryKey: "WlocKeychainAccessGroup") as? String,
              !appGroup.isEmpty,
              !keychain.isEmpty,
              !appGroup.contains("$("),
              !keychain.contains("$(")
        else { throw PacketTunnelError.invalidEnvironment }
        return .init(appGroupIdentifier: appGroup, keychainAccessGroup: keychain)
    }
}

private final class WlocResponsePatcherBridge: NSObject, LibboxWlocResponsePatcherProtocol {
    private static let logger = Logger(subsystem: "app.wloc", category: "WlocMITM")
    private let store: WlocSharedStore

    init(appGroupIdentifier: String) throws {
        store = try WlocSharedStore(appGroupIdentifier: appGroupIdentifier)
    }

    func patchResponse(_ body: Data?) throws -> Data {
        guard let body else { throw PacketTunnelError.emptyWlocResponse }
        let target = try store.loadTarget()
        let result = try WlocProtobufPatcher.patch(body, target: target)
        Self.logger.notice(
            "patched mode=\(target.mode.rawValue, privacy: .public) locations=\(result.statistics.locations, privacy: .public) wifi=\(result.statistics.wifiMessages, privacy: .public) cell=\(result.statistics.cellMessages, privacy: .public)"
        )
        return result.data
    }

    func writeLog(_ message: String?) {
        guard let message else { return }
        Self.logger.info("\(message, privacy: .public)")
    }
}

private enum PacketTunnelError: Error, LocalizedError {
    case invalidEnvironment
    case appGroupUnavailable
    case missingActiveProfile
    case missingDeviceCA
    case missingCATrustConfirmation
    case mitmStartupFailed
    case libboxStartupFailed
    case missingTunInbound
    case invalidConfiguration
    case emptyWlocResponse

    var errorDescription: String? {
        switch self {
        case .invalidEnvironment: "Packet Tunnel 的 App Group/Keychain 配置无效。"
        case .appGroupUnavailable: "Packet Tunnel 无法访问 App Group 容器。"
        case .missingActiveProfile: "没有可用的活动代理配置。"
        case .missingDeviceCA: "尚未生成并安装本设备 WLOC CA。"
        case .missingCATrustConfirmation: "尚未确认本设备 WLOC CA 已安装并完全信任。"
        case .mitmStartupFailed: "WLOC 本地 TLS 代理启动失败。"
        case .libboxStartupFailed: "Libbox 代理服务启动失败。"
        case .missingTunInbound: "配置缺少 tun 入站。"
        case .invalidConfiguration: "无法生成 Packet Tunnel 配置。"
        case .emptyWlocResponse: "WLOC 响应正文为空。"
        }
    }
}

private final class WlocPlatformInterface: NSObject, LibboxPlatformInterfaceProtocol, LibboxCommandServerHandlerProtocol, @unchecked Sendable {
    private let tunnel: WlocLibboxPacketTunnelProvider
    private var networkSettings: NEPacketTunnelNetworkSettings?
    private var pathMonitor: NWPathMonitor?

    init(tunnel: WlocLibboxPacketTunnelProvider) {
        self.tunnel = tunnel
    }

    func openTun(_ options: LibboxTunOptionsProtocol?, ret0_: UnsafeMutablePointer<Int32>?) throws {
        try runBlocking { [self] in try await openTun(options, result: ret0_) }
    }

    private func openTun(_ options: LibboxTunOptionsProtocol?, result: UnsafeMutablePointer<Int32>?) async throws {
        guard let options, let result else { throw PacketTunnelError.invalidConfiguration }
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        settings.mtu = NSNumber(value: options.getMTU())

        let dnsServer = try options.getDNSServerAddress().value
        if options.getAutoRoute(), !dnsServer.isEmpty {
            let dns = NEDNSSettings(servers: [dnsServer])
            dns.matchDomains = [""]
            dns.matchDomainsNoSearch = true
            settings.dnsSettings = dns
        }

        let ipv4Addresses = options.getInet4Address()!
        var addresses4: [String] = []
        var masks4: [String] = []
        while ipv4Addresses.hasNext() {
            if let prefix = ipv4Addresses.next() {
                addresses4.append(prefix.address())
                masks4.append(prefix.mask())
            }
        }
        let ipv4 = NEIPv4Settings(addresses: addresses4, subnetMasks: masks4)
        var included4: [NEIPv4Route] = []
        let routes4 = options.getInet4RouteAddress()!
        while routes4.hasNext() {
            if let prefix = routes4.next() {
                included4.append(NEIPv4Route(destinationAddress: prefix.address(), subnetMask: prefix.mask()))
            }
        }
        if included4.isEmpty { included4 = [.default()] }
        var excluded4: [NEIPv4Route] = []
        let excludes4 = options.getInet4RouteExcludeAddress()!
        while excludes4.hasNext() {
            if let prefix = excludes4.next() {
                excluded4.append(NEIPv4Route(destinationAddress: prefix.address(), subnetMask: prefix.mask()))
            }
        }
        ipv4.includedRoutes = included4
        ipv4.excludedRoutes = excluded4
        settings.ipv4Settings = ipv4

        let ipv6Addresses = options.getInet6Address()!
        var addresses6: [String] = []
        var prefixes6: [NSNumber] = []
        while ipv6Addresses.hasNext() {
            if let prefix = ipv6Addresses.next() {
                addresses6.append(prefix.address())
                prefixes6.append(NSNumber(value: prefix.prefix()))
            }
        }
        if !addresses6.isEmpty {
            let ipv6 = NEIPv6Settings(addresses: addresses6, networkPrefixLengths: prefixes6)
            var included6: [NEIPv6Route] = []
            let routes6 = options.getInet6RouteAddress()!
            while routes6.hasNext() {
                if let prefix = routes6.next() {
                    included6.append(NEIPv6Route(destinationAddress: prefix.address(), networkPrefixLength: NSNumber(value: prefix.prefix())))
                }
            }
            if included6.isEmpty { included6 = [.default()] }
            var excluded6: [NEIPv6Route] = []
            let excludes6 = options.getInet6RouteExcludeAddress()!
            while excludes6.hasNext() {
                if let prefix = excludes6.next() {
                    excluded6.append(NEIPv6Route(destinationAddress: prefix.address(), networkPrefixLength: NSNumber(value: prefix.prefix())))
                }
            }
            ipv6.includedRoutes = included6
            ipv6.excludedRoutes = excluded6
            settings.ipv6Settings = ipv6
        }

        if options.isHTTPProxyEnabled() {
            let proxy = NEProxySettings()
            let server = NEProxyServer(address: options.getHTTPProxyServer(), port: Int(options.getHTTPProxyServerPort()))
            proxy.httpEnabled = true
            proxy.httpsEnabled = true
            proxy.httpServer = server
            proxy.httpsServer = server
            let matches = options.getHTTPProxyMatchDomain()!
            var matchDomains: [String] = []
            while matches.hasNext() { matchDomains.append(matches.next()) }
            proxy.matchDomains = matchDomains
            let bypasses = options.getHTTPProxyBypassDomain()!
            var bypassDomains: [String] = []
            while bypasses.hasNext() { bypassDomains.append(bypasses.next()) }
            proxy.exceptionList = bypassDomains
            settings.proxySettings = proxy
        }

        networkSettings = settings
        try await tunnel.setTunnelNetworkSettings(settings)
        if let fileDescriptor = tunnel.packetFlow.value(forKeyPath: "socket.fileDescriptor") as? Int32 {
            result.pointee = fileDescriptor
            return
        }
        let fallback = LibboxGetTunnelFileDescriptor()
        guard fallback != -1 else { throw PacketTunnelError.libboxStartupFailed }
        result.pointee = fallback
    }

    func usePlatformAutoDetectControl() -> Bool { false }
    func autoDetectControl(_: Int32) throws {}
    func useProcFS() -> Bool { false }

    func findConnectionOwner(
        _: Int32,
        sourceAddress _: String?,
        sourcePort _: Int32,
        destinationAddress _: String?,
        destinationPort _: Int32
    ) throws -> LibboxConnectionOwner {
        throw PacketTunnelError.libboxStartupFailed
    }

    func startDefaultInterfaceMonitor(_ listener: LibboxInterfaceUpdateListenerProtocol?) throws {
        guard let listener else { return }
        let monitor = NWPathMonitor()
        pathMonitor = monitor
        let ready = DispatchSemaphore(value: 0)
        var first = true
        monitor.pathUpdateHandler = { path in
            if let interface = path.availableInterfaces.first, path.status == .satisfied {
                listener.updateDefaultInterface(
                    interface.name,
                    interfaceIndex: Int32(interface.index),
                    isExpensive: path.isExpensive,
                    isConstrained: path.isConstrained
                )
            } else {
                listener.updateDefaultInterface("", interfaceIndex: -1, isExpensive: false, isConstrained: false)
            }
            if first { first = false; ready.signal() }
        }
        monitor.start(queue: .global(qos: .userInitiated))
        ready.wait()
    }

    func closeDefaultInterfaceMonitor(_: LibboxInterfaceUpdateListenerProtocol?) throws {
        pathMonitor?.cancel()
        pathMonitor = nil
    }

    func getInterfaces() throws -> LibboxNetworkInterfaceIteratorProtocol {
        let sources: [NWInterface]
        if let path = pathMonitor?.currentPath, path.status == .satisfied {
            sources = path.availableInterfaces
        } else {
            sources = []
        }
        let values: [LibboxNetworkInterface] = sources.map { source in
            let interface = LibboxNetworkInterface()
            interface.name = source.name
            interface.index = Int32(source.index)
            interface.type = switch source.type {
            case .wifi: LibboxInterfaceTypeWIFI
            case .cellular: LibboxInterfaceTypeCellular
            case .wiredEthernet: LibboxInterfaceTypeEthernet
            default: LibboxInterfaceTypeOther
            }
            return interface
        }
        return WlocNetworkInterfaceIterator(values)
    }

    func underNetworkExtension() -> Bool { true }
    func includeAllNetworks() -> Bool { false }
    func readWIFIState() -> LibboxWIFIState? { nil }
    func localDNSTransport() -> (any LibboxLocalDNSTransportProtocol)? { nil }
    func systemCertificates() -> (any LibboxStringIteratorProtocol)? { nil }
    func send(_: LibboxNotification?) throws {}

    func clearDNSCache() {
        guard let networkSettings else { return }
        try? runBlocking {
            try await self.tunnel.setTunnelNetworkSettings(nil)
            try await self.tunnel.setTunnelNetworkSettings(networkSettings)
        }
    }

    func serviceStop() throws { tunnel.stopServices() }
    func serviceReload() throws { try tunnel.startOrReloadService() }

    func getSystemProxyStatus() throws -> LibboxSystemProxyStatus {
        let status = LibboxSystemProxyStatus()
        status.available = networkSettings?.proxySettings?.httpServer != nil
        status.enabled = networkSettings?.proxySettings?.httpEnabled ?? false
        return status
    }

    func setSystemProxyEnabled(_ isEnabled: Bool) throws {
        guard let networkSettings, let proxy = networkSettings.proxySettings else { return }
        proxy.httpEnabled = isEnabled
        proxy.httpsEnabled = isEnabled
        networkSettings.proxySettings = proxy
        try runBlocking { try await self.tunnel.setTunnelNetworkSettings(networkSettings) }
    }

    func writeDebugMessage(_ message: String?) {
        if let message { tunnel.writeLog(message) }
    }

    func reset() {
        networkSettings = nil
        pathMonitor?.cancel()
        pathMonitor = nil
    }
}

private final class WlocNetworkInterfaceIterator: NSObject, LibboxNetworkInterfaceIteratorProtocol {
    private let values: [LibboxNetworkInterface]
    private var index = 0

    init(_ values: [LibboxNetworkInterface]) { self.values = values }

    func hasNext() -> Bool { index < values.count }

    func next() -> LibboxNetworkInterface? {
        guard index < values.count else { return nil }
        defer { index += 1 }
        return values[index]
    }
}

private func runBlocking<T>(_ operation: @escaping () async throws -> T) throws -> T {
    let semaphore = DispatchSemaphore(value: 0)
    let box = WlocBlockingResult<T>()
    Task.detached(priority: .userInitiated) {
        do { box.result = .success(try await operation()) }
        catch { box.result = .failure(error) }
        semaphore.signal()
    }
    semaphore.wait()
    return try box.result.get()
}

private func runBlocking(_ operation: @escaping () async -> Void) {
    let semaphore = DispatchSemaphore(value: 0)
    Task.detached(priority: .userInitiated) {
        await operation()
        semaphore.signal()
    }
    semaphore.wait()
}

private final class WlocBlockingResult<T>: @unchecked Sendable {
    var result: Result<T, Error>!
}
#endif

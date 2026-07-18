import CoreLocation
import Foundation
import SwiftUI
import WlocCore

@MainActor
final class AppModel: ObservableObject {
    enum LocationCycleStage: Equatable {
        case idle
        case preparing
        case waitingForLocationOff
        case startingVPN
        case waitingForLocationOn
        case verifying
        case completed(String)
        case failed(String)

        var isRunning: Bool {
            switch self {
            case .preparing, .waitingForLocationOff, .startingVPN, .waitingForLocationOn, .verifying: true
            default: false
            }
        }
    }

    struct AlertMessage: Identifiable {
        let id = UUID()
        var title: String
        var message: String
    }

    @Published var selectedCoordinate: WlocCoordinate?
    @Published var selectedName = ""
    @Published private(set) var places: [SavedPlace] = []
    @Published private(set) var profiles: [ProxyProfileMetadata] = []
    @Published private(set) var activeProfileID: UUID?
    @Published var importedDraft: ImportedProfileDraft?
    @Published var workflow: LocationCycleStage = .idle
    @Published var alert: AlertMessage?
    @Published private(set) var hasDeviceCA = false
    @Published private(set) var caTrustConfirmed = false
    @Published var certificateProfileURL: URL?
    @Published private(set) var tunnelDiagnostics: WlocTunnelDiagnostics?
    @Published var diagnosticsReportURL: URL?

    let tunnel: TunnelController
    let location = LocationMonitor()

    private let sharedStore: WlocSharedStore
    private let profileRepository: ProxyProfileRepository
    private let certificateManager: DeviceCertificateManager
    private var pendingTarget: WlocTarget?
    private var previousTarget: WlocTarget = .passthrough
    private var started = false

    init() {
        do {
            sharedStore = try WlocSharedStore(appGroupIdentifier: AppEnvironment.appGroupIdentifier)
            profileRepository = try ProxyProfileRepository(
                appGroupIdentifier: AppEnvironment.appGroupIdentifier,
                keychainAccessGroup: AppEnvironment.keychainAccessGroup
            )
        } catch {
            preconditionFailure("共享存储初始化失败：\(error.localizedDescription)")
        }
        tunnel = TunnelController(providerBundleIdentifier: AppEnvironment.packetTunnelBundleIdentifier)
        certificateManager = DeviceCertificateManager(
            appGroupIdentifier: AppEnvironment.appGroupIdentifier,
            keychainAccessGroup: AppEnvironment.keychainAccessGroup
        )
    }

    func start() async {
        guard !started else { return }
        started = true
        do {
            places = try sharedStore.loadPlaces()
            let target = try sharedStore.loadTarget()
            if target.mode == .override, let coordinate = target.coordinate {
                selectedCoordinate = coordinate
            }
            try await refreshProfiles()
            hasDeviceCA = try certificateManager.hasCertificate()
            caTrustConfirmed = sharedStore.isCATrustConfirmed()
            tunnelDiagnostics = try sharedStore.loadTunnelDiagnostics()
        } catch {
            present(error, title: "载入失败")
        }
        await tunnel.load()
        location.requestAccessAndLocation()
        await recoverLocationCycleIfNeeded()
    }

    func select(_ coordinate: WlocCoordinate, name: String = "") {
        selectedCoordinate = coordinate
        selectedName = String(name.prefix(60))
    }

    func selectCurrentDeviceLocation() {
        guard let coordinate = location.lastLocation?.coordinate,
              let converted = try? WlocCoordinate(latitude: coordinate.latitude, longitude: coordinate.longitude)
        else {
            location.requestAccessAndLocation()
            presentMessage(title: "尚未取得位置", message: "已重新请求系统定位，请稍后再试。")
            return
        }
        select(converted, name: "当前设备位置")
    }

    func saveSelectedPlace() {
        guard let selectedCoordinate else { return }
        let name = selectedName.trimmingCharacters(in: .whitespacesAndNewlines)
        places.insert(SavedPlace(name: name.isEmpty ? coordinateLabel(selectedCoordinate) : name, coordinate: selectedCoordinate), at: 0)
        places = Array(places.prefix(100))
        do { try sharedStore.savePlaces(places) } catch { present(error, title: "收藏失败") }
    }

    func deletePlaces(at offsets: IndexSet) {
        places.remove(atOffsets: offsets)
        do { try sharedStore.savePlaces(places) } catch { present(error, title: "删除失败") }
    }

    func resolveMapInput(_ input: String) async {
        do {
            let parsed = try await MapLinkParser.resolve(input)
            select(parsed.coordinate, name: parsed.name)
        } catch {
            present(error, title: "地图链接解析失败")
        }
    }

    func previewImport(from url: URL) {
        let hasAccess = url.startAccessingSecurityScopedResource()
        defer { if hasAccess { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            importedDraft = try ProxyProfileImporter.importConfiguration(data, sourceName: url.lastPathComponent)
        } catch {
            present(error, title: "配置导入失败")
        }
    }

    func commitImportedProfile(name: String? = nil) async {
        guard let importedDraft else { return }
        do {
            try LibboxConfigurationValidator.validate(importedDraft.configuration)
            let profile = try await profileRepository.commit(importedDraft, name: name, activate: false)
            do {
                try await activateProfileAndReload(profile.id)
            } catch {
                self.importedDraft = nil
                try? await refreshProfiles()
                throw WlocCoreError.malformedInput(
                    "配置已安全保存但未能启用；此前活动配置未被覆盖。\(error.localizedDescription)"
                )
            }
            self.importedDraft = nil
            try await refreshProfiles()
            presentMessage(title: "配置已导入", message: "凭据已写入共享 Keychain；启用指针只在完整写入成功后才切换。")
        } catch {
            present(error, title: "无法启用配置")
        }
    }

    func prepareCertificateProfile() {
        do {
            certificateProfileURL = try certificateManager.prepareInstallationProfile()
            hasDeviceCA = true
            sharedStore.setCATrustConfirmed(false)
            caTrustConfirmed = false
        } catch {
            present(error, title: "证书生成失败")
        }
    }

    func confirmCertificateTrust() {
        guard hasDeviceCA else {
            presentMessage(title: "尚未生成证书", message: "请先生成并分享安装描述文件。")
            return
        }
        sharedStore.setCATrustConfirmed(true)
        caTrustConfirmed = true
    }

    func refreshTunnelDiagnostics() {
        do {
            tunnelDiagnostics = try sharedStore.loadTunnelDiagnostics()
        } catch {
            present(error, title: "读取诊断失败")
        }
    }

    func prepareDiagnosticsReport() {
        do {
            tunnelDiagnostics = try sharedStore.loadTunnelDiagnostics()
            let activeProfile = profiles.first { $0.id == activeProfileID }
            let report = DiagnosticsReport(
                exportedAt: .now,
                appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
                appBuild: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
                tunnelState: tunnel.state.label,
                activeProfileFormat: activeProfile?.format.rawValue,
                diagnostics: tunnelDiagnostics
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("wloc-diagnostics-\(Int(Date().timeIntervalSince1970)).json")
            try encoder.encode(report).write(to: url, options: .atomic)
            diagnosticsReportURL = url
        } catch {
            present(error, title: "生成诊断失败")
        }
    }

    func activateProfile(_ id: UUID) async {
        do {
            let configuration = try await profileRepository.configuration(for: id)
            try LibboxConfigurationValidator.validate(configuration)
            try await activateProfileAndReload(id)
            try await refreshProfiles()
        } catch {
            try? await refreshProfiles()
            present(error, title: "切换配置失败")
        }
    }

    func deleteProfile(_ id: UUID) async {
        do {
            try await profileRepository.delete(id)
            try await refreshProfiles()
        } catch {
            present(error, title: "删除配置失败")
        }
    }

    func applySelectedLocation() async {
        guard let selectedCoordinate else {
            presentMessage(title: "还没有选点", message: "请先点击地图或搜索一个位置。")
            return
        }
        do {
            try await beginLocationCycle(target: WlocTarget(mode: .override, coordinate: selectedCoordinate))
        } catch {
            present(error, title: "无法开始切换")
        }
    }

    func restoreRealLocation() async {
        do {
            try await beginLocationCycle(target: .passthrough)
        } catch {
            present(error, title: "无法开始恢复")
        }
    }

    func continueLocationCycle() async {
        switch workflow {
        case .waitingForLocationOff:
            guard !location.servicesEnabled else {
                presentMessage(
                    title: "定位服务仍然开启",
                    message: "请在“设置 > 隐私与安全性 > 定位服务”中关闭总开关，再回到 WLOC。"
                )
                return
            }
            await startVPNAfterLocationWasDisabled()
        case .waitingForLocationOn:
            guard location.servicesEnabled else {
                presentMessage(title: "定位服务仍然关闭", message: "请重新开启系统定位服务，再回到 WLOC。")
                return
            }
            do {
                if tunnel.state != .connected { try await tunnel.start() }
                guard tunnel.state == .connected else { throw TunnelControllerError.timeout }
                guard let pendingTarget else { throw WlocCoreError.malformedInput("缺少待核验的定位目标") }
                workflow = .verifying
                let actualLocation = try await location.freshLocation()
                let verification = try verify(actualLocation, target: pendingTarget)
                if verification.succeeded {
                    workflow = .completed(verification.message)
                } else {
                    workflow = .failed(verification.message)
                }
                try? sharedStore.saveLocationCycleCheckpoint(nil)
                self.pendingTarget = nil
            } catch {
                try? sharedStore.saveLocationCycleCheckpoint(nil)
                pendingTarget = nil
                workflow = .failed("定位服务与 VPN 已开启，但无法证明定位切换生效：\(error.localizedDescription)")
            }
        default:
            break
        }
    }

    func resumeAfterReturningFromSettings() async {
        refreshTunnelDiagnostics()
        guard workflow == .waitingForLocationOff || workflow == .waitingForLocationOn else { return }
        await continueLocationCycle()
    }

    func dismissFinishedWorkflow() {
        switch workflow {
        case .completed, .failed: workflow = .idle
        default: break
        }
    }

    func cancelLocationCycle() async {
        guard workflow.isRunning else { return }
        pendingTarget = nil
        do {
            try sharedStore.saveTarget(previousTarget)
            try sharedStore.saveLocationCycleCheckpoint(nil)
            try await reloadTunnelForPersistedState()
            workflow = .idle
        } catch {
            workflow = .failed("取消切换时无法完整恢复此前状态：\(error.localizedDescription)")
        }
    }

    private func beginLocationCycle(target: WlocTarget) async throws {
        guard hasDeviceCA, caTrustConfirmed else {
            throw WlocCoreError.malformedInput("请先安装 WLOC CA，并在系统证书信任设置中完全信任后回来确认。")
        }
        guard activeProfileID != nil, try await profileRepository.activeConfiguration() != nil else {
            throw WlocCoreError.malformedInput("请先导入并启用一个代理配置。")
        }
        workflow = .preparing
        previousTarget = try sharedStore.loadTarget()
        pendingTarget = target
        do {
            try saveLocationCycleCheckpoint(stage: .waitingForLocationOff)
            try await captureRealLocationBaselineIfNeeded(target: target, previousTarget: previousTarget)
            try await tunnel.stop()
            try sharedStore.saveTarget(target)
            if location.servicesEnabled {
                workflow = .waitingForLocationOff
            } else {
                await startVPNAfterLocationWasDisabled()
            }
        } catch {
            await rollbackAfterFailure(error)
        }
    }

    private func startVPNAfterLocationWasDisabled() async {
        workflow = .startingVPN
        do {
            try await tunnel.start()
            try saveLocationCycleCheckpoint(stage: .waitingForLocationOn)
            workflow = .waitingForLocationOn
        } catch {
            await rollbackAfterFailure(error)
        }
    }

    private func rollbackAfterFailure(_ originalError: Error) async {
        pendingTarget = nil
        do {
            try sharedStore.saveTarget(previousTarget)
            try sharedStore.saveLocationCycleCheckpoint(nil)
            try await reloadTunnelForPersistedState()
            workflow = .idle
            present(originalError, title: "切换失败，已回滚")
        } catch let rollbackError {
            workflow = .failed(
                "定位切换失败，且自动回滚未完成。原始错误：\(originalError.localizedDescription)；回滚错误：\(rollbackError.localizedDescription)"
            )
        }
    }

    private func activateProfileAndReload(_ id: UUID) async throws {
        let previousProfileID = await profileRepository.activeProfileID()
        try await profileRepository.activate(id)
        guard tunnel.state != .disconnected, tunnel.state != .unavailable else { return }

        do {
            try await tunnel.restart()
        } catch let activationError {
            guard let previousProfileID, previousProfileID != id else { throw activationError }
            do {
                try await profileRepository.activate(previousProfileID)
                try await reloadTunnelForPersistedState()
            } catch let rollbackError {
                throw WlocCoreError.malformedInput(
                    "新配置启动失败（\(activationError.localizedDescription)），恢复此前配置也失败：\(rollbackError.localizedDescription)"
                )
            }
            throw WlocCoreError.malformedInput(
                "新配置启动失败，已恢复此前活动配置：\(activationError.localizedDescription)"
            )
        }
    }

    private func reloadTunnelForPersistedState() async throws {
        try await tunnel.restart()
    }

    private func saveLocationCycleCheckpoint(stage: LocationCycleCheckpoint.Stage) throws {
        guard let pendingTarget else {
            throw WlocCoreError.malformedInput("缺少待恢复的定位目标")
        }
        try sharedStore.saveLocationCycleCheckpoint(
            .init(stage: stage, pendingTarget: pendingTarget, previousTarget: previousTarget)
        )
    }

    private func recoverLocationCycleIfNeeded() async {
        let checkpoint: LocationCycleCheckpoint
        do {
            guard let savedCheckpoint = try sharedStore.loadLocationCycleCheckpoint() else { return }
            checkpoint = savedCheckpoint
        } catch {
            try? sharedStore.saveLocationCycleCheckpoint(nil)
            workflow = .failed("无法读取上次定位切换状态，已停止自动继续：\(error.localizedDescription)")
            return
        }

        pendingTarget = checkpoint.pendingTarget
        previousTarget = checkpoint.previousTarget
        do {
            switch checkpoint.stage {
            case .waitingForLocationOff:
                workflow = .preparing
                try await tunnel.stop()
                try await captureRealLocationBaselineIfNeeded(
                    target: checkpoint.pendingTarget,
                    previousTarget: checkpoint.previousTarget
                )
                try sharedStore.saveTarget(checkpoint.pendingTarget)
                if location.servicesEnabled {
                    workflow = .waitingForLocationOff
                } else {
                    await startVPNAfterLocationWasDisabled()
                }
            case .waitingForLocationOn:
                try sharedStore.saveTarget(checkpoint.pendingTarget)
                if tunnel.state != .connected {
                    try await reloadTunnelForPersistedState()
                }
                workflow = .waitingForLocationOn
                if location.servicesEnabled {
                    switch location.authorizationStatus {
                    case .authorizedAlways, .authorizedWhenInUse:
                        await continueLocationCycle()
                    default:
                        break
                    }
                }
            }
        } catch {
            await rollbackAfterFailure(error)
        }
    }

    private func captureRealLocationBaselineIfNeeded(
        target: WlocTarget,
        previousTarget: WlocTarget
    ) async throws {
        guard target.mode == .override,
              previousTarget.mode == .passthrough,
              location.servicesEnabled
        else { return }

        let realLocation = try await location.freshLocation()
        let coordinate = try WlocCoordinate(
            latitude: realLocation.coordinate.latitude,
            longitude: realLocation.coordinate.longitude
        )
        try sharedStore.saveRealLocationBaseline(
            .init(coordinate: coordinate, capturedAt: realLocation.timestamp)
        )
    }

    private func refreshProfiles() async throws {
        profiles = try await profileRepository.profiles()
        activeProfileID = await profileRepository.activeProfileID()
    }

    private func verify(_ actual: CLLocation, target: WlocTarget) throws -> (succeeded: Bool, message: String) {
        let actualCoordinate = try WlocCoordinate(
            latitude: actual.coordinate.latitude,
            longitude: actual.coordinate.longitude
        )
        let accuracyAllowance = max(0, actual.horizontalAccuracy) * 2

        if target.mode == .override, let expected = target.coordinate {
            let distance = distance(from: actualCoordinate, to: expected)
            let threshold = max(150, Double(target.accuracy) * 5, accuracyAllowance)
            if distance <= threshold {
                return (
                    true,
                    String(format: "目标定位已核验：回读距离目标 %.0f 米（阈值 %.0f 米）；定位服务与 VPN 均已开启。", distance, threshold)
                )
            }
            return (
                false,
                String(format: "目标定位未生效：系统回读位置距离目标 %.0f 米，超过 %.0f 米阈值。VPN 已连接，但不能据此误报成功。", distance, threshold)
            )
        }

        if previousTarget.mode == .passthrough {
            return (true, "已取得切换后的新系统定位；当前为透传模式，定位服务与 VPN 均已开启。")
        }

        let fakeDistance = previousTarget.coordinate.map { distance(from: actualCoordinate, to: $0) }
        let fakeThreshold = max(250, Double(previousTarget.accuracy) * 5, accuracyAllowance)
        if let fakeDistance, fakeDistance > fakeThreshold {
            return (
                true,
                String(format: "真实定位已核验：新位置与原虚拟位置相距 %.0f 米；定位服务与 VPN 均已开启。", fakeDistance)
            )
        }

        if let baseline = try sharedStore.loadRealLocationBaseline() {
            let baselineDistance = distance(from: actualCoordinate, to: baseline.coordinate)
            let baselineThreshold = max(3_000, accuracyAllowance)
            if baselineDistance <= baselineThreshold {
                return (
                    true,
                    String(format: "真实定位已核验：新位置距切换前真实基线 %.0f 米；定位服务与 VPN 均已开启。", baselineDistance)
                )
            }
        }

        return (
            false,
            "已切换为真实定位透传，且定位服务与 VPN 均已开启；但回读位置无法与原虚拟位置或已保存真实基线区分，因此不宣称恢复已验证。"
        )
    }

    private func distance(from lhs: WlocCoordinate, to rhs: WlocCoordinate) -> CLLocationDistance {
        CLLocation(latitude: lhs.latitude, longitude: lhs.longitude)
            .distance(from: CLLocation(latitude: rhs.latitude, longitude: rhs.longitude))
    }

    private func coordinateLabel(_ coordinate: WlocCoordinate) -> String {
        String(format: "%.6f, %.6f", coordinate.latitude, coordinate.longitude)
    }

    private func present(_ error: Error, title: String) {
        alert = AlertMessage(title: title, message: error.localizedDescription)
    }

    private func presentMessage(title: String, message: String) {
        alert = AlertMessage(title: title, message: message)
    }
}

private struct DiagnosticsReport: Encodable {
    let schemaVersion = 1
    var exportedAt: Date
    var appVersion: String
    var appBuild: String
    var tunnelState: String
    var activeProfileFormat: String?
    var diagnostics: WlocTunnelDiagnostics?
}

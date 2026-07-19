import CoreLocation
import Foundation
import SwiftUI
import UIKit
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
        case rollingBack
        case completed(String)
        case failed(String)

        var isRunning: Bool {
            switch self {
            case .preparing, .waitingForLocationOff, .startingVPN, .waitingForLocationOn, .verifying, .rollingBack:
                true
            default:
                false
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
    @Published var workflow: LocationCycleStage = .idle
    @Published var alert: AlertMessage?
    @Published private(set) var shadowrocketInstalled = false
    @Published private(set) var shadowrocketSetupConfirmed = false
    @Published private(set) var shadowrocketLastCommand = "尚未发送"
    @Published private(set) var moduleStatus = "尚未检测"
    @Published private(set) var remoteTarget: WlocTarget?
    @Published var moduleFileURL: URL?
    @Published var configurationFileURL: URL?
    @Published private(set) var locationVerification: LocationVerificationEvidence?
    @Published var diagnosticsReportURL: URL?

    let location = LocationMonitor()

    private let store = WlocSharedStore()
    private let bridge = ShadowrocketWlocBridge()
    private let shadowrocket = ShadowrocketController()
    private var pendingTarget: WlocTarget?
    private var previousTarget: WlocTarget = .passthrough
    private var started = false

    func start() async {
        guard !started else { return }
        started = true
        do {
            places = try store.loadPlaces()
            let target = try store.loadTarget()
            if target.mode == .override, let coordinate = target.coordinate {
                selectedCoordinate = coordinate
            }
            locationVerification = try store.loadLocationVerification()
            shadowrocketSetupConfirmed = store.isShadowrocketSetupConfirmed()
        } catch {
            present(error, title: "载入失败")
        }
        moduleFileURL = Bundle.main.url(forResource: "wloc", withExtension: "module")
        refreshShadowrocketAvailability()
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
        places.insert(
            SavedPlace(name: name.isEmpty ? coordinateLabel(selectedCoordinate) : name, coordinate: selectedCoordinate),
            at: 0
        )
        places = Array(places.prefix(100))
        do { try store.savePlaces(places) } catch { present(error, title: "收藏失败") }
    }

    func deletePlaces(at offsets: IndexSet) {
        places.remove(atOffsets: offsets)
        do { try store.savePlaces(places) } catch { present(error, title: "删除失败") }
    }

    func resolveMapInput(_ input: String) async {
        do {
            let parsed = try await MapLinkParser.resolve(input)
            select(parsed.coordinate, name: parsed.name)
        } catch {
            present(error, title: "地图链接解析失败")
        }
    }

    func refreshShadowrocketAvailability() {
        shadowrocketInstalled = shadowrocket.isInstalled
    }

    func setShadowrocketSetupConfirmed(_ confirmed: Bool) {
        store.setShadowrocketSetupConfirmed(confirmed)
        shadowrocketSetupConfirmed = confirmed
    }

    func refreshShadowrocketModuleStatus(showErrors: Bool = false) async {
        refreshShadowrocketAvailability()
        guard shadowrocketInstalled else {
            moduleStatus = "未安装 Shadowrocket"
            remoteTarget = nil
            return
        }
        do {
            let target = try await bridge.currentTarget()
            remoteTarget = target
            moduleStatus = target.mode == .override ? "模块可用 · 已保存坐标" : "模块可用 · 真实定位透传"
        } catch {
            remoteTarget = nil
            moduleStatus = "模块不可用"
            if showErrors { present(error, title: "模块检测失败") }
        }
    }

    func openShadowrocket() async {
        await sendManualCommand(.open)
    }

    func requestShadowrocketConnect() async {
        await sendManualCommand(.connect)
    }

    func requestShadowrocketDisconnect() async {
        await sendManualCommand(.disconnect)
    }

    func prepareShadowrocketImport(from url: URL) {
        configurationFileURL = nil
        let hasAccess = url.startAccessingSecurityScopedResource()
        defer { if hasAccess { url.stopAccessingSecurityScopedResource() } }
        do {
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values.isRegularFile == true else {
                throw WlocCoreError.malformedInput("请选择一个配置文件")
            }
            if let size = values.fileSize, size > 20 * 1_024 * 1_024 {
                throw WlocCoreError.malformedInput("配置文件超过 20 MB")
            }
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("shadowrocket-import-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let destination = directory.appendingPathComponent(url.lastPathComponent)
            try FileManager.default.copyItem(at: url, to: destination)
            configurationFileURL = destination
        } catch {
            present(error, title: "无法准备配置文件")
        }
    }

    func prepareDiagnosticsReport() {
        do {
            locationVerification = try store.loadLocationVerification()
            let device = UIDevice.current
            let report = DiagnosticsReport(
                exportedAt: .now,
                appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
                appBuild: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
                deviceModel: device.model,
                systemName: device.systemName,
                systemVersion: device.systemVersion,
                shadowrocketInstalled: shadowrocketInstalled,
                setupConfirmed: shadowrocketSetupConfirmed,
                lastCommand: shadowrocketLastCommand,
                moduleStatus: moduleStatus,
                currentTarget: try store.loadTarget(),
                remoteTarget: remoteTarget,
                locationVerification: locationVerification
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
            await startShadowrocketAfterLocationWasDisabled()
        case .waitingForLocationOn:
            guard location.servicesEnabled else {
                presentMessage(title: "定位服务仍然关闭", message: "请重新开启系统定位服务，再回到 WLOC。")
                return
            }
            await finishLocationCycle()
        default:
            break
        }
    }

    func resumeAfterReturningFromSettings() async {
        refreshShadowrocketAvailability()
        switch workflow {
        case .waitingForLocationOff where !location.servicesEnabled:
            await startShadowrocketAfterLocationWasDisabled()
        case .waitingForLocationOn where location.servicesEnabled:
            await finishLocationCycle()
        case .rollingBack:
            await completeRollback()
        default:
            break
        }
    }

    func dismissFinishedWorkflow() {
        switch workflow {
        case .completed, .failed: workflow = .idle
        default: break
        }
    }

    func cancelLocationCycle() async {
        guard workflow.isRunning, pendingTarget != nil else { return }
        workflow = .rollingBack
        do {
            try saveLocationCycleCheckpoint(stage: .rollingBack)
            try await sendShadowrocket(.connect)
        } catch {
            workflow = .failed("无法启动自动回滚：\(error.localizedDescription)。请先手动连接 Shadowrocket，再重新打开 WLOC。")
        }
    }

    private func beginLocationCycle(target: WlocTarget) async throws {
        refreshShadowrocketAvailability()
        guard shadowrocketInstalled else { throw ShadowrocketControllerError.notInstalled }
        guard shadowrocketSetupConfirmed else {
            throw WlocCoreError.malformedInput("请先在“Shadowrocket 设置”中导入并启用 WLOC 模块、完全信任其 MITM 证书，然后勾选一次性确认。")
        }

        workflow = .preparing
        do {
            previousTarget = try await bridge.currentTarget()
        } catch {
            workflow = .idle
            throw error
        }
        remoteTarget = previousTarget
        pendingTarget = target
        do {
            try store.saveLocationVerification(nil)
            locationVerification = nil
            try saveLocationCycleCheckpoint(stage: .waitingForLocationOff)
            try await captureRealLocationBaselineIfNeeded(target: target, previousTarget: previousTarget)
            try await bridge.apply(target)
            remoteTarget = target
            moduleStatus = target.mode == .override ? "模块可用 · 已保存坐标" : "模块可用 · 真实定位透传"
            try store.saveTarget(target)
            workflow = .waitingForLocationOff
            try await sendShadowrocket(.disconnect)
        } catch {
            await rollbackAfterFailure(error)
        }
    }

    private func startShadowrocketAfterLocationWasDisabled() async {
        workflow = .startingVPN
        do {
            try saveLocationCycleCheckpoint(stage: .waitingForLocationOn)
            workflow = .waitingForLocationOn
            try await sendShadowrocket(.connect)
        } catch {
            workflow = .failed("未能向 Shadowrocket 发出连接指令：\(error.localizedDescription)。目标状态已写入，但不会报告切换完成。")
        }
    }

    private func finishLocationCycle() async {
        guard let pendingTarget else {
            workflow = .failed("缺少待核验的定位目标。")
            return
        }
        workflow = .verifying
        do {
            let confirmed = try await bridge.currentTarget()
            guard confirmed.sameRemoteValue(as: pendingTarget) else {
                throw ShadowrocketWlocBridgeError.targetMismatch(expected: pendingTarget, actual: confirmed)
            }
            remoteTarget = confirmed
            moduleStatus = pendingTarget.mode == .override ? "模块可用 · 已保存坐标" : "模块可用 · 真实定位透传"
            let actualLocation = try await location.freshLocation()
            let verification = try verify(actualLocation, target: pendingTarget)
            try store.saveLocationVerification(verification)
            locationVerification = verification
            try store.saveLocationCycleCheckpoint(nil)
            self.pendingTarget = nil
            workflow = verification.succeeded ? .completed(verification.message) : .failed(verification.message)
        } catch {
            let verification = LocationVerificationEvidence(
                target: pendingTarget,
                actualCoordinate: nil,
                horizontalAccuracy: nil,
                distanceMeters: nil,
                thresholdMeters: nil,
                succeeded: false,
                message: "已发出 Shadowrocket 连接指令，但本次没有取得完整的模块与定位回读证据。"
            )
            try? store.saveLocationVerification(verification)
            locationVerification = verification
            try? store.saveLocationCycleCheckpoint(nil)
            self.pendingTarget = nil
            workflow = .failed("无法证明定位切换生效：\(error.localizedDescription)")
        }
    }

    private func rollbackAfterFailure(_ originalError: Error) async {
        do {
            try await bridge.apply(previousTarget)
            try store.saveTarget(previousTarget)
            try store.saveLocationCycleCheckpoint(nil)
            pendingTarget = nil
            workflow = .idle
            present(originalError, title: "切换失败，已回滚模块坐标")
        } catch {
            do {
                try saveLocationCycleCheckpoint(stage: .rollingBack)
                workflow = .rollingBack
                try await sendShadowrocket(.connect)
            } catch let recoveryError {
                workflow = .failed(
                    "切换失败且自动回滚尚未完成。原始错误：\(originalError.localizedDescription)；恢复错误：\(recoveryError.localizedDescription)"
                )
            }
        }
    }

    private func completeRollback() async {
        do {
            try await Task.sleep(for: .milliseconds(500))
            try await bridge.apply(previousTarget)
            remoteTarget = previousTarget
            try store.saveTarget(previousTarget)
            try store.saveLocationCycleCheckpoint(nil)
            pendingTarget = nil
            let locationReminder = location.servicesEnabled ? "" : " 系统定位服务仍处于关闭状态，请手动重新开启。"
            workflow = .completed("已恢复此前的 Shadowrocket 模块坐标状态，并已发出连接指令。\(locationReminder)")
        } catch {
            workflow = .failed("自动回滚未完成：\(error.localizedDescription)。请保持 Shadowrocket 已连接后返回 WLOC 重试。")
        }
    }

    private func sendShadowrocket(_ command: ShadowrocketController.Command) async throws {
        try await shadowrocket.send(command)
        shadowrocketLastCommand = "已发出“\(command.label)”指令"
    }

    private func sendManualCommand(_ command: ShadowrocketController.Command) async {
        do {
            try await sendShadowrocket(command)
        } catch {
            present(error, title: "Shadowrocket 操作失败")
        }
    }

    private func saveLocationCycleCheckpoint(stage: LocationCycleCheckpoint.Stage) throws {
        guard let pendingTarget else {
            throw WlocCoreError.malformedInput("缺少待恢复的定位目标")
        }
        try store.saveLocationCycleCheckpoint(
            .init(stage: stage, pendingTarget: pendingTarget, previousTarget: previousTarget)
        )
    }

    private func recoverLocationCycleIfNeeded() async {
        let checkpoint: LocationCycleCheckpoint
        do {
            guard let saved = try store.loadLocationCycleCheckpoint() else { return }
            checkpoint = saved
        } catch {
            try? store.saveLocationCycleCheckpoint(nil)
            workflow = .failed("无法读取上次定位切换状态，已停止自动继续：\(error.localizedDescription)")
            return
        }

        pendingTarget = checkpoint.pendingTarget
        previousTarget = checkpoint.previousTarget
        switch checkpoint.stage {
        case .waitingForLocationOff:
            workflow = .waitingForLocationOff
            if !location.servicesEnabled { await startShadowrocketAfterLocationWasDisabled() }
        case .waitingForLocationOn:
            workflow = .waitingForLocationOn
            if location.servicesEnabled { await finishLocationCycle() }
        case .rollingBack:
            workflow = .rollingBack
            await completeRollback()
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
        try store.saveRealLocationBaseline(.init(coordinate: coordinate, capturedAt: realLocation.timestamp))
    }

    private func verify(_ actual: CLLocation, target: WlocTarget) throws -> LocationVerificationEvidence {
        let actualCoordinate = try WlocCoordinate(
            latitude: actual.coordinate.latitude,
            longitude: actual.coordinate.longitude
        )
        let baseline = target.mode == .passthrough ? try store.loadRealLocationBaseline() : nil
        return LocationVerifier.evaluate(
            actualCoordinate: actualCoordinate,
            horizontalAccuracy: actual.horizontalAccuracy,
            target: target,
            previousTarget: previousTarget,
            realLocationBaseline: baseline
        )
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

private extension WlocTarget {
    func sameRemoteValue(as other: WlocTarget) -> Bool {
        guard mode == other.mode else { return false }
        if mode == .passthrough { return true }
        guard let lhs = coordinate, let rhs = other.coordinate else { return false }
        return abs(lhs.latitude - rhs.latitude) < 0.000_000_1
            && abs(lhs.longitude - rhs.longitude) < 0.000_000_1
            && accuracy == other.accuracy
    }
}

private struct DiagnosticsReport: Encodable {
    let schemaVersion = 3
    var exportedAt: Date
    var appVersion: String
    var appBuild: String
    var deviceModel: String
    var systemName: String
    var systemVersion: String
    var shadowrocketInstalled: Bool
    var setupConfirmed: Bool
    var lastCommand: String
    var moduleStatus: String
    var currentTarget: WlocTarget
    var remoteTarget: WlocTarget?
    var locationVerification: LocationVerificationEvidence?
}

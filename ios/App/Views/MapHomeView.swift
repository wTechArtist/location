import MapKit
import SwiftUI
import WlocCore

struct MapHomeView: View {
    @EnvironmentObject private var model: AppModel
    @State private var cameraPosition: MapCameraPosition = .automatic
    @State private var showSearch = false
    @State private var showProfiles = false
    @State private var showPlaces = false

    var body: some View {
        NavigationStack {
            MapReader { proxy in
                Map(position: $cameraPosition) {
                    UserAnnotation()
                    if let coordinate = model.selectedCoordinate {
                        Marker(
                            model.selectedName.isEmpty ? "目标位置" : model.selectedName,
                            coordinate: CLLocationCoordinate2D(latitude: coordinate.latitude, longitude: coordinate.longitude)
                        )
                        .tint(.red)
                    }
                }
                .mapStyle(.standard(elevation: .realistic))
                .mapControls {
                    MapCompass()
                    MapScaleView()
                    MapPitchToggle()
                }
                .onTapGesture { point in
                    guard let coordinate = proxy.convert(point, from: .local),
                          let target = try? WlocCoordinate(latitude: coordinate.latitude, longitude: coordinate.longitude)
                    else { return }
                    model.select(target)
                }
                .accessibilityIdentifier("wloc.map")
                .ignoresSafeArea(edges: .top)
            }
            .overlay(alignment: .top) { topControls }
            .safeAreaInset(edge: .bottom, spacing: 0) { locationCard }
            .overlay { workflowOverlay }
            .navigationBarHidden(true)
        }
        .sheet(isPresented: $showSearch) { LocationSearchView(cameraPosition: $cameraPosition) }
        .sheet(isPresented: $showProfiles) { ProfileManagementView() }
        .sheet(isPresented: $showPlaces) { SavedPlacesView(cameraPosition: $cameraPosition) }
    }

    private var topControls: some View {
        HStack(spacing: 10) {
            Button { showSearch = true } label: {
                Label("搜索", systemImage: "magnifyingglass")
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("wloc.search")

            Spacer()

            Button { model.selectCurrentDeviceLocation() } label: {
                Image(systemName: "location.fill")
            }
            .accessibilityIdentifier("wloc.current-location")
            Button { showPlaces = true } label: {
                Image(systemName: "star.fill")
            }
            .accessibilityIdentifier("wloc.saved-places")
            Button { showProfiles = true } label: {
                Image(systemName: "network")
            }
            .accessibilityIdentifier("wloc.settings")
        }
        .buttonStyle(.bordered)
        .padding()
        .background(.ultraThinMaterial, in: Capsule())
        .padding(.horizontal)
        .padding(.top, 4)
    }

    private var locationCard: some View {
        VStack(spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.selectedName.isEmpty ? "地图选点" : model.selectedName)
                        .font(.headline)
                    if let coordinate = model.selectedCoordinate {
                        Text(String(format: "%.6f, %.6f", coordinate.latitude, coordinate.longitude))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("wloc.selected-coordinate")
                    } else {
                        Text("点击地图选择目标位置")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Label(model.moduleStatus, systemImage: model.shadowrocketInstalled ? "paperplane.circle.fill" : "paperplane.circle")
                    .font(.caption)
                    .foregroundStyle(model.moduleStatus.hasPrefix("模块可用") ? .green : .secondary)
            }

            HStack {
                Button { model.saveSelectedPlace() } label: {
                    Label("收藏", systemImage: "star")
                }
                .disabled(model.selectedCoordinate == nil)

                Spacer()

                Button("恢复真实定位", role: .destructive) {
                    Task { await model.restoreRealLocation() }
                }
                .accessibilityIdentifier("wloc.restore-location")
                .disabled(model.workflow.isRunning)
                Button("确定定位") {
                    Task { await model.applySelectedLocation() }
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("wloc.apply-location")
                .disabled(model.selectedCoordinate == nil || model.workflow.isRunning)
            }
            .buttonStyle(.bordered)
        }
        .padding()
        .background(.regularMaterial)
    }

    @ViewBuilder
    private var workflowOverlay: some View {
        switch model.workflow {
        case .idle:
            EmptyView()
        case .preparing:
            WorkflowPanel(title: "正在准备", message: "正在通过 Shadowrocket 模块写入并回查目标坐标。", showsProgress: true)
                .accessibilityIdentifier("wloc.workflow.preparing")
        case .startingVPN:
            WorkflowPanel(title: "正在连接 Shadowrocket", message: "WLOC 正在向 Shadowrocket 发出连接指令。iOS 可能会暂时切换到 Shadowrocket。", showsProgress: true)
                .accessibilityIdentifier("wloc.workflow.starting-vpn")
        case .verifying:
            WorkflowPanel(title: "正在核验定位", message: "正在回查 Shadowrocket 模块，并把新的系统定位与目标坐标或真实位置基线做距离比对。", showsProgress: true)
                .accessibilityIdentifier("wloc.workflow.verifying")
        case .rollingBack:
            WorkflowPanel(title: "正在回滚", message: "正在重新连接 Shadowrocket 并恢复操作前的模块坐标状态。", showsProgress: true)
                .accessibilityIdentifier("wloc.workflow.rolling-back")
        case .waitingForLocationOff:
            WorkflowPanel(
                title: "请关闭系统定位服务",
                message: "前往“设置 > 隐私与安全性 > 定位服务”，关闭总开关后返回。App 无权代替你操作这个系统开关。",
                primaryTitle: "我已关闭，继续",
                primaryAction: { Task { await model.continueLocationCycle() } },
                cancelAction: { Task { await model.cancelLocationCycle() } }
            )
            .accessibilityIdentifier("wloc.workflow.location-off")
        case .waitingForLocationOn:
            WorkflowPanel(
                title: "请重新开启定位服务",
                message: "已向 Shadowrocket 发出连接指令。现在开启系统定位服务并返回，App 会核验模块响应和系统定位；实际 VPN 开关请以 Shadowrocket/iOS 状态为准。",
                primaryTitle: "我已开启，完成",
                primaryAction: { Task { await model.continueLocationCycle() } },
                cancelAction: { Task { await model.cancelLocationCycle() } }
            )
            .accessibilityIdentifier("wloc.workflow.location-on")
        case let .completed(message):
            WorkflowPanel(
                title: "切换完成",
                message: message,
                primaryTitle: "完成",
                primaryAction: { model.dismissFinishedWorkflow() }
            )
            .accessibilityIdentifier("wloc.workflow.completed")
        case let .failed(message):
            WorkflowPanel(
                title: "未能验证切换生效",
                message: message,
                primaryTitle: "知道了",
                primaryAction: { model.dismissFinishedWorkflow() }
            )
            .accessibilityIdentifier("wloc.workflow.failed")
        }
    }
}

private struct WorkflowPanel: View {
    var title: String
    var message: String
    var showsProgress = false
    var primaryTitle: String?
    var primaryAction: (() -> Void)?
    var cancelAction: (() -> Void)?

    var body: some View {
        ZStack {
            Color.black.opacity(0.32).ignoresSafeArea()
            VStack(spacing: 16) {
                if showsProgress { ProgressView() }
                Text(title).font(.title3.bold())
                Text(message).multilineTextAlignment(.center).foregroundStyle(.secondary)
                if let primaryTitle, let primaryAction {
                    Button(primaryTitle, action: primaryAction)
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("wloc.workflow.primary")
                }
                if let cancelAction {
                    Button("取消并回滚", role: .cancel, action: cancelAction)
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("wloc.workflow.cancel")
                }
            }
            .padding(24)
            .frame(maxWidth: 360)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
            .padding()
        }
    }
}

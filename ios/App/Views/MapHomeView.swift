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

            Spacer()

            Button { model.selectCurrentDeviceLocation() } label: {
                Image(systemName: "location.fill")
            }
            Button { showPlaces = true } label: {
                Image(systemName: "star.fill")
            }
            Button { showProfiles = true } label: {
                Image(systemName: "network")
            }
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
                    } else {
                        Text("点击地图选择目标位置")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Label(model.tunnel.state.label, systemImage: model.tunnel.state == .connected ? "lock.shield.fill" : "lock.slash")
                    .font(.caption)
                    .foregroundStyle(model.tunnel.state == .connected ? .green : .secondary)
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
                Button("确定定位") {
                    Task { await model.applySelectedLocation() }
                }
                .buttonStyle(.borderedProminent)
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
            WorkflowPanel(title: "正在准备", message: "正在安全断开 WLOC VPN 并保存目标状态。", showsProgress: true)
        case .startingVPN:
            WorkflowPanel(title: "正在启动 VPN", message: "首次使用时 iOS 会要求手动允许添加 VPN 配置。", showsProgress: true)
        case .verifying:
            WorkflowPanel(title: "正在核验定位", message: "正在请求一条新的系统定位，并与目标坐标或真实位置基线做距离比对。", showsProgress: true)
        case .waitingForLocationOff:
            WorkflowPanel(
                title: "请关闭系统定位服务",
                message: "前往“设置 > 隐私与安全性 > 定位服务”，关闭总开关后返回。App 无权代替你操作这个系统开关。",
                primaryTitle: "我已关闭，继续",
                primaryAction: { Task { await model.continueLocationCycle() } },
                cancelAction: { Task { await model.cancelLocationCycle() } }
            )
        case .waitingForLocationOn:
            WorkflowPanel(
                title: "请重新开启定位服务",
                message: "WLOC VPN 已自动启动。现在开启系统定位服务并返回，App 会确认定位和 VPN 最终都处于开启状态。",
                primaryTitle: "我已开启，完成",
                primaryAction: { Task { await model.continueLocationCycle() } },
                cancelAction: { Task { await model.cancelLocationCycle() } }
            )
        case let .completed(message):
            WorkflowPanel(
                title: "切换完成",
                message: message,
                primaryTitle: "完成",
                primaryAction: { model.dismissFinishedWorkflow() }
            )
        case let .failed(message):
            WorkflowPanel(
                title: "未能验证切换生效",
                message: message,
                primaryTitle: "知道了",
                primaryAction: { model.dismissFinishedWorkflow() }
            )
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
                }
                if let cancelAction {
                    Button("取消并回滚", role: .cancel, action: cancelAction)
                        .buttonStyle(.bordered)
                }
            }
            .padding(24)
            .frame(maxWidth: 360)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
            .padding()
        }
    }
}

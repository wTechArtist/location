import MapKit
import SwiftUI
import WlocCore

struct LocationSearchView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Binding var cameraPosition: MapCameraPosition
    @State private var query = ""
    @State private var results: [MKMapItem] = []
    @State private var isSearching = false
    @State private var linkOrCoordinate = ""

    var body: some View {
        NavigationStack {
            List {
                Section("地图搜索") {
                    TextField("地点、地址", text: $query)
                        .textInputAutocapitalization(.never)
                        .onSubmit { Task { await search() } }
                    if isSearching { ProgressView() }
                    ForEach(results, id: \.self) { item in
                        Button {
                            choose(item)
                        } label: {
                            VStack(alignment: .leading) {
                                Text(item.name ?? "未命名位置")
                                Text(item.placemark.title ?? "")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                Section("地图链接或坐标") {
                    TextField("粘贴 Apple/高德链接或纬度,经度", text: $linkOrCoordinate, axis: .vertical)
                        .textInputAutocapitalization(.never)
                    Button("解析并选择") {
                        Task {
                            await model.resolveMapInput(linkOrCoordinate)
                            if let coordinate = model.selectedCoordinate {
                                moveCamera(to: coordinate)
                                dismiss()
                            }
                        }
                    }
                    .disabled(linkOrCoordinate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .navigationTitle("选择位置")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
        }
    }

    private func search() async {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        isSearching = true
        defer { isSearching = false }
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        do {
            results = try await MKLocalSearch(request: request).start().mapItems
        } catch {
            model.alert = .init(title: "搜索失败", message: error.localizedDescription)
        }
    }

    private func choose(_ item: MKMapItem) {
        let coordinate = item.placemark.coordinate
        guard let mapCoordinate = try? WlocCoordinate(
            latitude: coordinate.latitude,
            longitude: coordinate.longitude
        ),
        let target = try? CoordinateConversion.gcj02ToWGS84(mapCoordinate)
        else { return }
        model.select(target, name: item.name ?? "")
        moveCamera(to: target)
        dismiss()
    }

    private func moveCamera(to coordinate: WlocCoordinate) {
        let displayCoordinate = (try? CoordinateConversion.wgs84ToGCJ02(coordinate)) ?? coordinate
        cameraPosition = .region(MKCoordinateRegion(
            center: CLLocationCoordinate2D(
                latitude: displayCoordinate.latitude,
                longitude: displayCoordinate.longitude
            ),
            span: MKCoordinateSpan(latitudeDelta: 0.03, longitudeDelta: 0.03)
        ))
    }
}

import MapKit
import SwiftUI
import WlocCore

struct SavedPlacesView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Binding var cameraPosition: MapCameraPosition

    var body: some View {
        NavigationStack {
            List {
                if model.places.isEmpty {
                    ContentUnavailableView("还没有收藏", systemImage: "star", description: Text("在地图上选点后点击收藏。"))
                }
                ForEach(model.places) { place in
                    Button {
                        model.select(place.coordinate, name: place.name)
                        cameraPosition = .region(MKCoordinateRegion(
                            center: CLLocationCoordinate2D(latitude: place.coordinate.latitude, longitude: place.coordinate.longitude),
                            span: MKCoordinateSpan(latitudeDelta: 0.03, longitudeDelta: 0.03)
                        ))
                        dismiss()
                    } label: {
                        VStack(alignment: .leading) {
                            Text(place.name)
                            Text(String(format: "%.6f, %.6f", place.coordinate.latitude, place.coordinate.longitude))
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .onDelete(perform: model.deletePlaces)
            }
            .navigationTitle("收藏位置")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
        }
    }
}

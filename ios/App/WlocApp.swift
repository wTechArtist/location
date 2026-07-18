import SwiftUI

@main
struct WlocApp: App {
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            MapHomeView()
                .environmentObject(model)
                .task { await model.start() }
                .onOpenURL { url in
                    Task { await model.resolveMapInput(url.absoluteString) }
                }
                .onChange(of: scenePhase) { _, phase in
                    guard phase == .active else { return }
                    Task { await model.resumeAfterReturningFromSettings() }
                }
                .alert(item: $model.alert) { alert in
                    Alert(title: Text(alert.title), message: Text(alert.message), dismissButton: .default(Text("好")))
                }
        }
    }
}

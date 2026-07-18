import Foundation
import Testing
@testable import WlocCore

@Suite("Shared state persistence")
struct SharedStoreTests {
    @Test("location workflow checkpoint round-trips and clears")
    func locationCycleCheckpointRoundTrip() throws {
        let suiteName = "app.wloc.tests.\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }

        let store = try WlocSharedStore(appGroupIdentifier: suiteName)
        let coordinate = try WlocCoordinate(latitude: 22.3193, longitude: 114.1694)
        let pending = try WlocTarget(mode: .override, coordinate: coordinate, updatedAt: .distantPast)
        let previous = WlocTarget.passthrough
        let checkpoint = LocationCycleCheckpoint(
            stage: .waitingForLocationOff,
            pendingTarget: pending,
            previousTarget: previous,
            createdAt: .distantPast
        )

        try store.saveLocationCycleCheckpoint(checkpoint)
        #expect(try store.loadLocationCycleCheckpoint() == checkpoint)

        try store.saveLocationCycleCheckpoint(nil)
        #expect(try store.loadLocationCycleCheckpoint() == nil)
    }
}

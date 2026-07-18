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
        let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)
        let coordinate = try WlocCoordinate(latitude: 22.3193, longitude: 114.1694)
        let pending = try WlocTarget(mode: .override, coordinate: coordinate, updatedAt: fixedDate)
        let previous = try WlocTarget(mode: .passthrough, coordinate: nil, updatedAt: fixedDate)
        let checkpoint = LocationCycleCheckpoint(
            stage: .waitingForLocationOff,
            pendingTarget: pending,
            previousTarget: previous,
            createdAt: fixedDate
        )

        try store.saveLocationCycleCheckpoint(checkpoint)
        #expect(try store.loadLocationCycleCheckpoint() == checkpoint)

        try store.saveLocationCycleCheckpoint(nil)
        #expect(try store.loadLocationCycleCheckpoint() == nil)
    }

    @Test("tunnel diagnostics round-trip without proxy credentials")
    func tunnelDiagnosticsRoundTrip() throws {
        let suiteName = "app.wloc.tests.\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }

        let store = try WlocSharedStore(appGroupIdentifier: suiteName)
        let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)
        let diagnostics = WlocTunnelDiagnostics(
            sessionID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            startedAt: fixedDate,
            stoppedAt: fixedDate,
            lastPatchedAt: fixedDate,
            lastTargetMode: .override,
            responseCount: 3,
            locations: 4,
            wifiMessages: 2,
            cellMessages: 1,
            skippedMessages: 0
        )

        try store.saveTunnelDiagnostics(diagnostics)
        #expect(try store.loadTunnelDiagnostics() == diagnostics)

        try store.saveTunnelDiagnostics(nil)
        #expect(try store.loadTunnelDiagnostics() == nil)
    }
}

import Foundation
import Testing
@testable import WlocCore

@Suite("Shared state persistence")
struct SharedStoreTests {
    @Test("location workflow checkpoint round-trips and clears")
    func locationCycleCheckpointRoundTrip() throws {
        let suiteName = "app.wloc.tests.\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }

        let store = WlocSharedStore(defaults: try #require(UserDefaults(suiteName: suiteName)))
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

    @Test("location verification evidence round-trips and clears")
    func locationVerificationRoundTrip() throws {
        let suiteName = "app.wloc.tests.\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }

        let store = WlocSharedStore(defaults: try #require(UserDefaults(suiteName: suiteName)))
        let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)
        let targetCoordinate = try WlocCoordinate(latitude: 22.3193, longitude: 114.1694)
        let actualCoordinate = try WlocCoordinate(latitude: 22.3194, longitude: 114.1695)
        let target = try WlocTarget(mode: .override, coordinate: targetCoordinate, updatedAt: fixedDate)
        let evidence = LocationVerificationEvidence(
            verifiedAt: fixedDate,
            target: target,
            actualCoordinate: actualCoordinate,
            horizontalAccuracy: 35,
            distanceMeters: 15,
            thresholdMeters: 150,
            succeeded: true,
            message: "目标定位已核验"
        )

        try store.saveLocationVerification(evidence)
        #expect(try store.loadLocationVerification() == evidence)

        try store.saveLocationVerification(nil)
        #expect(try store.loadLocationVerification() == nil)
    }

    @Test("concurrent target reads and writes remain decodable")
    func concurrentReadWrite() async throws {
        let suiteName = "app.wloc.tests.\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }

        let store = WlocSharedStore(defaults: try #require(UserDefaults(suiteName: suiteName)))
        let coordinate = try WlocCoordinate(latitude: 22.3193, longitude: 114.1694)

        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0 ..< 100 {
                group.addTask {
                    let target = try WlocTarget(mode: .override, coordinate: coordinate, accuracy: 25 + index)
                    try store.saveTarget(target)
                    _ = try store.loadTarget()

                }
            }
            try await group.waitForAll()
        }

        #expect(try store.loadTarget().mode == .override)
    }
}

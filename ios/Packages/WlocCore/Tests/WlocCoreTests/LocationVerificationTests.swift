import Foundation
import Testing
@testable import WlocCore

@Suite("Location verification evidence")
struct LocationVerificationTests {
    @Test("override succeeds only inside its evidence threshold")
    func overrideThreshold() throws {
        let target = try override(latitude: 22.3193, longitude: 114.1694)
        let nearby = try coordinate(latitude: 22.3194, longitude: 114.1695)
        let farAway = try coordinate(latitude: 22.3293, longitude: 114.1794)

        let success = LocationVerifier.evaluate(
            actualCoordinate: nearby,
            horizontalAccuracy: 10,
            target: target,
            previousTarget: .passthrough
        )
        #expect(success.succeeded)
        #expect(success.distanceMeters! < success.thresholdMeters!)

        let failure = LocationVerifier.evaluate(
            actualCoordinate: farAway,
            horizontalAccuracy: 10,
            target: target,
            previousTarget: .passthrough
        )
        #expect(!failure.succeeded)
        #expect(failure.distanceMeters! > failure.thresholdMeters!)
    }

    @Test("imprecise system evidence cannot expand the target threshold")
    func accuracyThreshold() throws {
        let target = try override(latitude: 51.5, longitude: -0.12, accuracy: 25)
        let actual = try coordinate(latitude: 51.503, longitude: -0.12)
        let result = LocationVerifier.evaluate(
            actualCoordinate: actual,
            horizontalAccuracy: 200,
            target: target,
            previousTarget: .passthrough
        )

        #expect(result.thresholdMeters == 25)
        #expect(!result.succeeded)
    }

    @Test("override rejects a coordinate outside its declared 25 metre radius")
    func strictOverrideRadius() throws {
        let target = try override(latitude: 23.132739, longitude: 113.259172)
        let actual = try coordinate(latitude: 23.133189, longitude: 113.259172)
        let result = LocationVerifier.evaluate(
            actualCoordinate: actual,
            horizontalAccuracy: 10,
            target: target,
            previousTarget: .passthrough
        )

        #expect(result.thresholdMeters == 25)
        #expect(result.distanceMeters! > 45)
        #expect(!result.succeeded)
    }

    @Test("restore succeeds when the fresh location differs from the old fake")
    func restoreAwayFromFake() throws {
        let previous = try override(latitude: 35.6762, longitude: 139.6503)
        let actual = try coordinate(latitude: 22.3193, longitude: 114.1694)
        let result = LocationVerifier.evaluate(
            actualCoordinate: actual,
            horizontalAccuracy: 20,
            target: .passthrough,
            previousTarget: previous
        )

        #expect(result.succeeded)
        #expect(result.message.contains("与原虚拟位置相距"))
    }

    @Test("restore can use the pre-switch real baseline")
    func restoreUsingBaseline() throws {
        let fake = try override(latitude: 22.3193, longitude: 114.1694)
        let real = try coordinate(latitude: 22.31931, longitude: 114.16941)
        let baseline = RealLocationBaseline(coordinate: real)
        let result = LocationVerifier.evaluate(
            actualCoordinate: real,
            horizontalAccuracy: 15,
            target: .passthrough,
            previousTarget: fake,
            realLocationBaseline: baseline
        )

        #expect(result.succeeded)
        #expect(result.message.contains("真实基线"))
    }

    @Test("restore refuses success when evidence cannot distinguish the old fake")
    func restoreWithoutEvidence() throws {
        let fake = try override(latitude: 22.3193, longitude: 114.1694)
        let actual = try coordinate(latitude: 22.31931, longitude: 114.16941)
        let result = LocationVerifier.evaluate(
            actualCoordinate: actual,
            horizontalAccuracy: 15,
            target: .passthrough,
            previousTarget: fake
        )

        #expect(!result.succeeded)
        #expect(result.message.contains("不宣称恢复已验证"))
    }

    @Test("an already-passthrough module needs a fresh location but no fake-distance proof")
    func alreadyPassthrough() throws {
        let result = LocationVerifier.evaluate(
            actualCoordinate: try coordinate(latitude: 0, longitude: 0),
            horizontalAccuracy: -1,
            target: .passthrough,
            previousTarget: .passthrough
        )

        #expect(result.succeeded)
        #expect(result.distanceMeters == nil)
    }

    @Test("distance calculation handles the international date line")
    func dateLine() throws {
        let target = try override(latitude: 0, longitude: 179.99995)
        let actual = try coordinate(latitude: 0, longitude: -179.99995)
        let result = LocationVerifier.evaluate(
            actualCoordinate: actual,
            horizontalAccuracy: 5,
            target: target,
            previousTarget: .passthrough
        )

        #expect(result.succeeded)
        #expect(result.distanceMeters! < 25)
    }

    private func coordinate(latitude: Double, longitude: Double) throws -> WlocCoordinate {
        try WlocCoordinate(latitude: latitude, longitude: longitude)
    }

    private func override(latitude: Double, longitude: Double, accuracy: Int = 25) throws -> WlocTarget {
        try WlocTarget(
            mode: .override,
            coordinate: coordinate(latitude: latitude, longitude: longitude),
            accuracy: accuracy
        )
    }
}

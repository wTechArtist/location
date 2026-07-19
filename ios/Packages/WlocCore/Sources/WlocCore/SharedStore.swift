import Foundation

public final class WlocSharedStore: @unchecked Sendable {
    public static let targetKey = "wloc.target.v1"
    public static let placesKey = "wloc.places.v1"
    public static let realLocationBaselineKey = "wloc.real-location-baseline.v1"
    public static let locationCycleCheckpointKey = "wloc.location-cycle-checkpoint.v1"
    public static let locationVerificationKey = "wloc.location-verification.v1"
    public static let shadowrocketSetupConfirmedKey = "wloc.shadowrocket-setup-confirmed.v1"

    private let defaults: UserDefaults
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let lock = NSLock()

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    public func loadTarget() throws -> WlocTarget {
        try withLock {
            guard let data = defaults.data(forKey: Self.targetKey) else {
                return .passthrough
            }
            return try decoder.decode(WlocTarget.self, from: data)
        }
    }

    public func saveTarget(_ target: WlocTarget) throws {
        try withLock {
            defaults.set(try encoder.encode(target), forKey: Self.targetKey)
        }
    }

    public func loadPlaces() throws -> [SavedPlace] {
        try withLock {
            guard let data = defaults.data(forKey: Self.placesKey) else {
                return []
            }
            return try decoder.decode([SavedPlace].self, from: data)
        }
    }

    public func savePlaces(_ places: [SavedPlace]) throws {
        try withLock {
            defaults.set(try encoder.encode(places), forKey: Self.placesKey)
        }
    }

    public func loadRealLocationBaseline() throws -> RealLocationBaseline? {
        try withLock {
            guard let data = defaults.data(forKey: Self.realLocationBaselineKey) else { return nil }
            return try decoder.decode(RealLocationBaseline.self, from: data)
        }
    }

    public func saveRealLocationBaseline(_ baseline: RealLocationBaseline?) throws {
        try withLock {
            if let baseline {
                defaults.set(try encoder.encode(baseline), forKey: Self.realLocationBaselineKey)
            } else {
                defaults.removeObject(forKey: Self.realLocationBaselineKey)
            }
        }
    }

    public func isShadowrocketSetupConfirmed() -> Bool {
        withLock {
            defaults.bool(forKey: Self.shadowrocketSetupConfirmedKey)
        }
    }

    public func setShadowrocketSetupConfirmed(_ confirmed: Bool) {
        withLock {
            defaults.set(confirmed, forKey: Self.shadowrocketSetupConfirmedKey)
        }
    }

    public func loadLocationCycleCheckpoint() throws -> LocationCycleCheckpoint? {
        try withLock {
            guard let data = defaults.data(forKey: Self.locationCycleCheckpointKey) else { return nil }
            return try decoder.decode(LocationCycleCheckpoint.self, from: data)
        }
    }

    public func saveLocationCycleCheckpoint(_ checkpoint: LocationCycleCheckpoint?) throws {
        try withLock {
            if let checkpoint {
                defaults.set(try encoder.encode(checkpoint), forKey: Self.locationCycleCheckpointKey)
            } else {
                defaults.removeObject(forKey: Self.locationCycleCheckpointKey)
            }
        }
    }

    public func loadLocationVerification() throws -> LocationVerificationEvidence? {
        try withLock {
            guard let data = defaults.data(forKey: Self.locationVerificationKey) else { return nil }
            return try decoder.decode(LocationVerificationEvidence.self, from: data)
        }
    }

    public func saveLocationVerification(_ verification: LocationVerificationEvidence?) throws {
        try withLock {
            if let verification {
                defaults.set(try encoder.encode(verification), forKey: Self.locationVerificationKey)
            } else {
                defaults.removeObject(forKey: Self.locationVerificationKey)
            }
        }
    }

    private func withLock<T>(_ operation: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try operation()
    }
}

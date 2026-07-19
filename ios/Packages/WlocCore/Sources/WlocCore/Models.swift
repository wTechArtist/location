import Foundation

public struct WlocCoordinate: Codable, Hashable, Sendable {
    public var latitude: Double
    public var longitude: Double

    public init(latitude: Double, longitude: Double) throws {
        guard latitude.isFinite, (-90.0 ... 90.0).contains(latitude) else {
            throw WlocCoreError.invalidLatitude(latitude)
        }
        guard longitude.isFinite, (-180.0 ... 180.0).contains(longitude) else {
            throw WlocCoreError.invalidLongitude(longitude)
        }
        self.latitude = latitude
        self.longitude = longitude
    }
}

public struct WlocTarget: Codable, Hashable, Sendable {
    public enum Mode: String, Codable, Sendable {
        case passthrough
        case override
    }

    public var mode: Mode
    public var coordinate: WlocCoordinate?
    public var accuracy: Int
    public var updatedAt: Date

    public init(mode: Mode, coordinate: WlocCoordinate?, accuracy: Int = 25, updatedAt: Date = .now) throws {
        guard (1 ... 10_000).contains(accuracy) else {
            throw WlocCoreError.invalidAccuracy(accuracy)
        }
        if mode == .override, coordinate == nil {
            throw WlocCoreError.missingCoordinate
        }
        self.mode = mode
        self.coordinate = coordinate
        self.accuracy = accuracy
        self.updatedAt = updatedAt
    }

    public static var passthrough: WlocTarget {
        try! WlocTarget(mode: .passthrough, coordinate: nil)
    }
}

public struct SavedPlace: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var coordinate: WlocCoordinate
    public var createdAt: Date

    public init(id: UUID = UUID(), name: String, coordinate: WlocCoordinate, createdAt: Date = .now) {
        self.id = id
        self.name = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(30))
        self.coordinate = coordinate
        self.createdAt = createdAt
    }
}

public struct RealLocationBaseline: Codable, Hashable, Sendable {
    public var coordinate: WlocCoordinate
    public var capturedAt: Date

    public init(coordinate: WlocCoordinate, capturedAt: Date = .now) {
        self.coordinate = coordinate
        self.capturedAt = capturedAt
    }
}

public struct LocationCycleCheckpoint: Codable, Hashable, Sendable {
    public enum Stage: String, Codable, Sendable {
        case waitingForLocationOff
        case waitingForLocationOn
        case rollingBack
    }

    public var stage: Stage
    public var pendingTarget: WlocTarget
    public var previousTarget: WlocTarget
    public var createdAt: Date

    public init(
        stage: Stage,
        pendingTarget: WlocTarget,
        previousTarget: WlocTarget,
        createdAt: Date = .now
    ) {
        self.stage = stage
        self.pendingTarget = pendingTarget
        self.previousTarget = previousTarget
        self.createdAt = createdAt
    }
}

public struct LocationVerificationEvidence: Codable, Equatable, Sendable {
    public var verifiedAt: Date
    public var target: WlocTarget
    public var actualCoordinate: WlocCoordinate?
    public var horizontalAccuracy: Double?
    public var distanceMeters: Double?
    public var thresholdMeters: Double?
    public var succeeded: Bool
    public var message: String

    public init(
        verifiedAt: Date = .now,
        target: WlocTarget,
        actualCoordinate: WlocCoordinate?,
        horizontalAccuracy: Double?,
        distanceMeters: Double?,
        thresholdMeters: Double?,
        succeeded: Bool,
        message: String
    ) {
        self.verifiedAt = verifiedAt
        self.target = target
        self.actualCoordinate = actualCoordinate
        self.horizontalAccuracy = horizontalAccuracy
        self.distanceMeters = distanceMeters
        self.thresholdMeters = thresholdMeters
        self.succeeded = succeeded
        self.message = String(message.prefix(500))
    }
}

public enum WlocCoreError: Error, LocalizedError, Equatable, Sendable {
    case invalidLatitude(Double)
    case invalidLongitude(Double)
    case invalidAccuracy(Int)
    case missingCoordinate
    case malformedInput(String)
    case unsupportedFormat(String)

    public var errorDescription: String? {
        switch self {
        case let .invalidLatitude(value): "纬度超出范围：\(value)"
        case let .invalidLongitude(value): "经度超出范围：\(value)"
        case let .invalidAccuracy(value): "精度超出范围：\(value)"
        case .missingCoordinate: "覆盖模式缺少坐标"
        case let .malformedInput(message): "输入格式错误：\(message)"
        case let .unsupportedFormat(format): "暂不支持的格式：\(format)"
        }
    }
}

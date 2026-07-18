import Foundation

public enum CoordinateConversion {
    private static let a = 6_378_245.0
    private static let ee = 0.00669342162296594323

    public static func gcj02ToWGS84(_ coordinate: WlocCoordinate) throws -> WlocCoordinate {
        guard !outsideChina(coordinate) else { return coordinate }
        var latitude = coordinate.latitude
        var longitude = coordinate.longitude
        for _ in 0 ..< 6 {
            let projected = try wgs84ToGCJ02(WlocCoordinate(latitude: latitude, longitude: longitude))
            let latitudeError = projected.latitude - coordinate.latitude
            let longitudeError = projected.longitude - coordinate.longitude
            if abs(latitudeError) < 1e-9, abs(longitudeError) < 1e-9 { break }
            latitude -= latitudeError
            longitude -= longitudeError
        }
        return try WlocCoordinate(latitude: rounded6(latitude), longitude: rounded6(longitude))
    }

    public static func wgs84ToGCJ02(_ coordinate: WlocCoordinate) throws -> WlocCoordinate {
        guard !outsideChina(coordinate) else { return coordinate }
        var latitudeDelta = transformLatitude(coordinate.longitude - 105.0, coordinate.latitude - 35.0)
        var longitudeDelta = transformLongitude(coordinate.longitude - 105.0, coordinate.latitude - 35.0)
        let radians = coordinate.latitude / 180.0 * .pi
        var magic = sin(radians)
        magic = 1 - ee * magic * magic
        let squareRoot = sqrt(magic)
        latitudeDelta = latitudeDelta * 180.0 / ((a * (1 - ee) / (magic * squareRoot)) * .pi)
        longitudeDelta = longitudeDelta * 180.0 / ((a / squareRoot * cos(radians)) * .pi)
        return try WlocCoordinate(
            latitude: coordinate.latitude + latitudeDelta,
            longitude: coordinate.longitude + longitudeDelta
        )
    }

    public static func rounded6(_ value: Double) -> Double {
        (value * 1_000_000).rounded() / 1_000_000
    }

    private static func outsideChina(_ coordinate: WlocCoordinate) -> Bool {
        coordinate.longitude < 72.004 || coordinate.longitude > 137.8347 ||
            coordinate.latitude < 0.8293 || coordinate.latitude > 55.8271
    }

    private static func transformLatitude(_ x: Double, _ y: Double) -> Double {
        var result = -100 + 2 * x + 3 * y + 0.2 * y * y + 0.1 * x * y + 0.2 * sqrt(abs(x))
        result += (20 * sin(6 * x * .pi) + 20 * sin(2 * x * .pi)) * 2 / 3
        result += (20 * sin(y * .pi) + 40 * sin(y / 3 * .pi)) * 2 / 3
        result += (160 * sin(y / 12 * .pi) + 320 * sin(y * .pi / 30)) * 2 / 3
        return result
    }

    private static func transformLongitude(_ x: Double, _ y: Double) -> Double {
        var result = 300 + x + 2 * y + 0.1 * x * x + 0.1 * x * y + 0.1 * sqrt(abs(x))
        result += (20 * sin(6 * x * .pi) + 20 * sin(2 * x * .pi)) * 2 / 3
        result += (20 * sin(x * .pi) + 40 * sin(x / 3 * .pi)) * 2 / 3
        result += (150 * sin(x / 12 * .pi) + 300 * sin(x / 30 * .pi)) * 2 / 3
        return result
    }
}

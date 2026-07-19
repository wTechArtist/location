import Testing
@testable import WlocCore

@Suite("MapKit coordinate conversion")
struct CoordinateConversionTests {
    @Test("Guangzhou MapKit GCJ-02 point becomes the WGS-84 module target")
    func guangzhouMapPoint() throws {
        // This is the coordinate shown by MapKit in the user's failing Guangzhou case.
        let mapCoordinate = try WlocCoordinate(latitude: 23.130061, longitude: 113.264499)

        let target = try CoordinateConversion.gcj02ToWGS84(mapCoordinate)

        #expect(abs(target.latitude - 23.132739) < 0.000001)
        #expect(abs(target.longitude - 113.259172) < 0.000001)

        let displayedAgain = try CoordinateConversion.wgs84ToGCJ02(target)
        #expect(abs(displayedAgain.latitude - mapCoordinate.latitude) < 0.000001)
        #expect(abs(displayedAgain.longitude - mapCoordinate.longitude) < 0.000001)
    }

    @Test("Coordinates outside mainland map bounds remain unchanged")
    func outsideChina() throws {
        let london = try WlocCoordinate(latitude: 51.5074, longitude: -0.1278)

        #expect(try CoordinateConversion.gcj02ToWGS84(london) == london)
        #expect(try CoordinateConversion.wgs84ToGCJ02(london) == london)
    }
}

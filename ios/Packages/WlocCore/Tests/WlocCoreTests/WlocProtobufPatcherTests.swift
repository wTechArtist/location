import XCTest
@testable import WlocCore

final class WlocProtobufPatcherTests: XCTestCase {
    func testPatchesFramedWiFiLocationAndPreservesUnknownFields() throws {
        let originalLocation = message([
            varintField(1, signed: 22.544577),
            varintField(2, signed: 113.94114),
            varintField(3, value: 65),
            varintField(9, value: 7),
        ])
        let wifi = message([
            bytesField(1, Array("aa:bb:cc:dd:ee:ff".utf8)),
            bytesField(2, originalLocation),
        ])
        let payload = message([bytesField(2, wifi), varintField(30, value: 99)])
        let framed = frame(payload)
        let coordinate = try WlocCoordinate(latitude: 31.230416, longitude: 121.473701)

        let result = try WlocProtobufPatcher.patch(Data(framed), coordinate: coordinate, accuracy: 18)

        let expectedLocation = message([
            varintField(1, signed: coordinate.latitude),
            varintField(2, signed: coordinate.longitude),
            varintField(3, value: 18),
            varintField(9, value: 7),
        ])
        let expectedWiFi = message([
            bytesField(1, Array("aa:bb:cc:dd:ee:ff".utf8)),
            bytesField(2, expectedLocation),
        ])
        let expectedPayload = message([bytesField(2, expectedWiFi), varintField(30, value: 99)])

        XCTAssertEqual(result.data, Data(frame(expectedPayload)))
        XCTAssertEqual(result.frameOffset, 0)
        XCTAssertEqual(result.statistics, WlocPatchStatistics(wifiMessages: 1, cellMessages: 0, locations: 1, skippedMessages: 0))
    }

    func testPatchesRawCellLocationWithNegativeCoordinates() throws {
        let location = message([
            varintField(1, signed: 1.25),
            varintField(2, signed: 2.5),
            varintField(3, value: 25),
        ])
        let cell = message([bytesField(5, location), varintField(8, value: 1)])
        let root = message([bytesField(22, cell)])
        let coordinate = try WlocCoordinate(latitude: -33.86882, longitude: -151.209296)

        let result = try WlocProtobufPatcher.patch(Data(root), coordinate: coordinate, accuracy: 42)

        let expectedLocation = message([
            varintField(1, signed: coordinate.latitude),
            varintField(2, signed: coordinate.longitude),
            varintField(3, value: 42),
        ])
        let expectedCell = message([bytesField(5, expectedLocation), varintField(8, value: 1)])
        XCTAssertEqual(result.data, Data(message([bytesField(22, expectedCell)])))
        XCTAssertNil(result.frameOffset)
        XCTAssertEqual(result.statistics.cellMessages, 1)
        XCTAssertEqual(result.statistics.locations, 1)
    }

    func testPassthroughDoesNotRequireAParsableBody() throws {
        let body = Data([0xde, 0xad, 0xbe, 0xef])
        let result = try WlocProtobufPatcher.patch(body, target: .passthrough)
        XCTAssertEqual(result.data, body)
        XCTAssertEqual(result.statistics, .init())
    }

    func testRejectsBodyWithoutPatchableLocation() throws {
        let coordinate = try WlocCoordinate(latitude: 1, longitude: 2)
        XCTAssertThrowsError(try WlocProtobufPatcher.patch(Data(repeating: 0, count: 32), coordinate: coordinate))
    }
}

private func frame(_ payload: [UInt8]) -> [UInt8] {
    [UInt8](repeating: 0, count: 8) + [UInt8((payload.count >> 8) & 0xff), UInt8(payload.count & 0xff)] + payload
}

private func message(_ fields: [[UInt8]]) -> [UInt8] {
    fields.flatMap { $0 }
}

private func bytesField(_ number: Int, _ bytes: [UInt8]) -> [UInt8] {
    encodeVarint(UInt64(number << 3 | 2)) + encodeVarint(UInt64(bytes.count)) + bytes
}

private func varintField(_ number: Int, value: UInt64) -> [UInt8] {
    encodeVarint(UInt64(number << 3)) + encodeVarint(value)
}

private func varintField(_ number: Int, signed coordinate: Double) -> [UInt8] {
    let scaled = Int64((coordinate * 100_000_000).rounded())
    return varintField(number, value: UInt64(bitPattern: scaled))
}

private func encodeVarint(_ value: UInt64) -> [UInt8] {
    var remaining = value
    var bytes: [UInt8] = []
    repeat {
        var byte = UInt8(remaining & 0x7f)
        remaining >>= 7
        if remaining != 0 { byte |= 0x80 }
        bytes.append(byte)
    } while remaining != 0
    return bytes
}

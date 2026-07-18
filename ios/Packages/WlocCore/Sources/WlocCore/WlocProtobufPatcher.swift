import Foundation

public struct WlocPatchStatistics: Equatable, Sendable {
    public var wifiMessages: Int
    public var cellMessages: Int
    public var locations: Int
    public var skippedMessages: Int

    public init(wifiMessages: Int = 0, cellMessages: Int = 0, locations: Int = 0, skippedMessages: Int = 0) {
        self.wifiMessages = wifiMessages
        self.cellMessages = cellMessages
        self.locations = locations
        self.skippedMessages = skippedMessages
    }
}

public struct WlocPatchResult: Equatable, Sendable {
    public var data: Data
    public var statistics: WlocPatchStatistics
    public var frameOffset: Int?

    public init(data: Data, statistics: WlocPatchStatistics, frameOffset: Int?) {
        self.data = data
        self.statistics = statistics
        self.frameOffset = frameOffset
    }
}

/// Rewrites the coordinates in Apple's binary Wi-Fi/cell location response.
///
/// The tunnel's HTTP layer is responsible for TLS interception and gzip decoding. This
/// type deliberately has no networking or certificate dependencies, which keeps the
/// binary transformation deterministic and independently testable.
public enum WlocProtobufPatcher {
    public static func patch(_ data: Data, target: WlocTarget) throws -> WlocPatchResult {
        guard target.mode == .override, let coordinate = target.coordinate else {
            return WlocPatchResult(data: data, statistics: .init(), frameOffset: nil)
        }
        return try patch(data, coordinate: coordinate, accuracy: target.accuracy)
    }

    public static func patch(_ data: Data, coordinate: WlocCoordinate, accuracy: Int = 25) throws -> WlocPatchResult {
        guard (1 ... 10_000).contains(accuracy) else {
            throw WlocCoreError.invalidAccuracy(accuracy)
        }
        let input = [UInt8](data)
        guard input.count >= 10 else {
            throw WlocCoreError.malformedInput("WLOC 响应长度不足：\(input.count)")
        }

        var attemptedErrors: [String] = []
        let maximumFrameOffset = min(96, max(0, input.count - 10))
        var offsets = stride(from: 0, through: min(16, maximumFrameOffset), by: 2).map { $0 }
        offsets.append(contentsOf: (0 ... maximumFrameOffset).filter { !offsets.contains($0) })

        for offset in offsets {
            var statistics = WlocPatchStatistics()
            do {
                let patched = try patchFrame(
                    input,
                    baseOffset: offset,
                    coordinate: coordinate,
                    accuracy: accuracy,
                    statistics: &statistics
                )
                return WlocPatchResult(data: Data(patched), statistics: statistics, frameOffset: offset)
            } catch {
                if attemptedErrors.count < 6 {
                    attemptedErrors.append("@\(offset): \(error.localizedDescription)")
                }
            }
        }

        do {
            var statistics = WlocPatchStatistics()
            let patched = try patchRawFallback(
                input,
                coordinate: coordinate,
                accuracy: accuracy,
                statistics: &statistics
            )
            return WlocPatchResult(data: Data(patched), statistics: statistics, frameOffset: nil)
        } catch {
            attemptedErrors.append("raw: \(error.localizedDescription)")
        }

        throw WlocCoreError.malformedInput("未找到可修改的 WLOC 数据；\(attemptedErrors.joined(separator: " | "))")
    }
}

private extension WlocProtobufPatcher {
    enum ProtoValue {
        case varint(UInt64)
        case bytes([UInt8])
    }

    struct ProtoField {
        var fieldNumber: Int
        var wireType: Int
        var value: ProtoValue
        var raw: [UInt8]
    }

    static func patchFrame(
        _ input: [UInt8],
        baseOffset: Int,
        coordinate: WlocCoordinate,
        accuracy: Int,
        statistics: inout WlocPatchStatistics
    ) throws -> [UInt8] {
        guard baseOffset >= 0, input.count >= baseOffset + 10 else {
            throw WlocCoreError.malformedInput("帧头越界")
        }
        let payloadLength = (Int(input[baseOffset + 8]) << 8) | Int(input[baseOffset + 9])
        guard payloadLength > 0 else {
            throw WlocCoreError.malformedInput("帧负载为空")
        }
        let payloadStart = baseOffset + 10
        let payloadEnd = payloadStart + payloadLength
        guard payloadEnd <= input.count else {
            throw WlocCoreError.malformedInput("帧长度 \(payloadLength) 超出响应边界")
        }

        let before = statistics
        let originalPayload = Array(input[payloadStart ..< payloadEnd])
        let patchedPayload = try patchRoot(
            originalPayload,
            coordinate: coordinate,
            accuracy: accuracy,
            statistics: &statistics
        )
        guard didPatch(before: before, after: statistics), patchedPayload != originalPayload else {
            statistics = before
            throw WlocCoreError.malformedInput("帧可解析但不含可修改的 WLOC 位置")
        }
        guard patchedPayload.count <= Int(UInt16.max) else {
            statistics = before
            throw WlocCoreError.malformedInput("修改后的帧超过 65535 字节")
        }

        var output = Array(input[..<(baseOffset + 8)])
        output.append(UInt8((patchedPayload.count >> 8) & 0xff))
        output.append(UInt8(patchedPayload.count & 0xff))
        output.append(contentsOf: patchedPayload)
        output.append(contentsOf: input[payloadEnd...])
        return output
    }

    static func patchRawFallback(
        _ input: [UInt8],
        coordinate: WlocCoordinate,
        accuracy: Int,
        statistics: inout WlocPatchStatistics
    ) throws -> [UInt8] {
        let maximumOffset = min(256, input.count)
        var errors: [String] = []
        for offset in 0 ... maximumOffset {
            let before = statistics
            do {
                let original = Array(input[offset...])
                let patched = try patchRoot(
                    original,
                    coordinate: coordinate,
                    accuracy: accuracy,
                    statistics: &statistics
                )
                if didPatch(before: before, after: statistics), patched != original {
                    return Array(input[..<offset]) + patched
                }
                statistics = before
            } catch {
                statistics = before
                if errors.count < 6 {
                    errors.append("@\(offset): \(error.localizedDescription)")
                }
            }
        }
        throw WlocCoreError.malformedInput("原始 protobuf 扫描失败；\(errors.joined(separator: " | "))")
    }

    static func patchRoot(
        _ bytes: [UInt8],
        coordinate: WlocCoordinate,
        accuracy: Int,
        statistics: inout WlocPatchStatistics
    ) throws -> [UInt8] {
        let fields = try decodeFields(bytes)
        var output: [UInt8] = []
        for field in fields {
            switch (field.fieldNumber, field.wireType, field.value) {
            case (2, 2, let .bytes(value)):
                let patched = patchWiFiMessage(
                    value,
                    coordinate: coordinate,
                    accuracy: accuracy,
                    statistics: &statistics
                )
                output.append(contentsOf: encodeBytesField(number: field.fieldNumber, value: patched))
            case (22, 2, let .bytes(value)), (24, 2, let .bytes(value)):
                let patched = patchCellMessage(
                    value,
                    coordinate: coordinate,
                    accuracy: accuracy,
                    statistics: &statistics
                )
                output.append(contentsOf: encodeBytesField(number: field.fieldNumber, value: patched))
            default:
                output.append(contentsOf: field.raw)
            }
        }
        return output
    }

    static func patchWiFiMessage(
        _ bytes: [UInt8],
        coordinate: WlocCoordinate,
        accuracy: Int,
        statistics: inout WlocPatchStatistics
    ) -> [UInt8] {
        guard let fields = try? decodeFields(bytes), fields.contains(where: isMACAddressField) else {
            return bytes
        }
        var didModify = false
        var output: [UInt8] = []
        for field in fields {
            if field.fieldNumber == 2, field.wireType == 2, case let .bytes(value) = field.value {
                do {
                    let patched = try patchLocation(
                        value,
                        coordinate: coordinate,
                        accuracy: accuracy,
                        statistics: &statistics
                    )
                    didModify = didModify || patched != value
                    output.append(contentsOf: encodeBytesField(number: field.fieldNumber, value: patched))
                } catch {
                    statistics.skippedMessages += 1
                    output.append(contentsOf: field.raw)
                }
            } else {
                output.append(contentsOf: field.raw)
            }
        }
        if didModify {
            statistics.wifiMessages += 1
        }
        return output
    }

    static func patchCellMessage(
        _ bytes: [UInt8],
        coordinate: WlocCoordinate,
        accuracy: Int,
        statistics: inout WlocPatchStatistics
    ) -> [UInt8] {
        guard let fields = try? decodeFields(bytes) else { return bytes }
        var didModify = false
        var output: [UInt8] = []
        for field in fields {
            if field.fieldNumber == 5, field.wireType == 2, case let .bytes(value) = field.value {
                do {
                    let patched = try patchLocation(
                        value,
                        coordinate: coordinate,
                        accuracy: accuracy,
                        statistics: &statistics
                    )
                    didModify = didModify || patched != value
                    output.append(contentsOf: encodeBytesField(number: field.fieldNumber, value: patched))
                } catch {
                    statistics.skippedMessages += 1
                    output.append(contentsOf: field.raw)
                }
            } else {
                output.append(contentsOf: field.raw)
            }
        }
        if didModify {
            statistics.cellMessages += 1
        }
        return output
    }

    static func patchLocation(
        _ bytes: [UInt8],
        coordinate: WlocCoordinate,
        accuracy: Int,
        statistics: inout WlocPatchStatistics
    ) throws -> [UInt8] {
        let fields = try decodeFields(bytes)
        let hasLatitude = fields.contains { $0.fieldNumber == 1 && $0.wireType == 0 }
        let hasLongitude = fields.contains { $0.fieldNumber == 2 && $0.wireType == 0 }
        guard hasLatitude, hasLongitude else { return bytes }

        let latitude = UInt64(bitPattern: Int64((coordinate.latitude * 100_000_000).rounded()))
        let longitude = UInt64(bitPattern: Int64((coordinate.longitude * 100_000_000).rounded()))
        var output: [UInt8] = []
        for field in fields {
            switch (field.fieldNumber, field.wireType) {
            case (1, 0):
                output.append(contentsOf: encodeVarintField(number: 1, value: latitude))
            case (2, 0):
                output.append(contentsOf: encodeVarintField(number: 2, value: longitude))
            case (3, 0):
                output.append(contentsOf: encodeVarintField(number: 3, value: UInt64(accuracy)))
            default:
                output.append(contentsOf: field.raw)
            }
        }
        statistics.locations += 1
        return output
    }

    static func isMACAddressField(_ field: ProtoField) -> Bool {
        guard field.fieldNumber == 1, field.wireType == 2, case let .bytes(bytes) = field.value,
              let string = String(bytes: bytes, encoding: .ascii)
        else { return false }
        let components = string.split(separator: ":", omittingEmptySubsequences: false)
        guard components.count == 6 else { return false }
        return components.allSatisfy { component in
            guard (1 ... 2).contains(component.count) else { return false }
            return component.unicodeScalars.allSatisfy { scalar in
                (48 ... 57).contains(scalar.value) || (65 ... 70).contains(scalar.value) || (97 ... 102).contains(scalar.value)
            }
        }
    }

    static func didPatch(before: WlocPatchStatistics, after: WlocPatchStatistics) -> Bool {
        after.locations > before.locations ||
            after.wifiMessages > before.wifiMessages ||
            after.cellMessages > before.cellMessages
    }

    static func decodeFields(_ bytes: [UInt8]) throws -> [ProtoField] {
        var fields: [ProtoField] = []
        var offset = 0
        while offset < bytes.count {
            let fieldStart = offset
            let key = try readVarint(bytes, offset: &offset)
            let fieldNumber = Int(key >> 3)
            let wireType = Int(key & 0x07)
            guard fieldNumber > 0 else {
                throw WlocCoreError.malformedInput("protobuf 字段号为 0")
            }

            let value: ProtoValue
            switch wireType {
            case 0:
                value = .varint(try readVarint(bytes, offset: &offset))
            case 1:
                value = .bytes(try take(bytes, offset: &offset, count: 8))
            case 2:
                let length = try readVarint(bytes, offset: &offset)
                guard length <= UInt64(Int.max) else {
                    throw WlocCoreError.malformedInput("protobuf 字段过长")
                }
                value = .bytes(try take(bytes, offset: &offset, count: Int(length)))
            case 5:
                value = .bytes(try take(bytes, offset: &offset, count: 4))
            default:
                throw WlocCoreError.malformedInput("不支持的 protobuf wire type：\(wireType)")
            }
            fields.append(
                ProtoField(
                    fieldNumber: fieldNumber,
                    wireType: wireType,
                    value: value,
                    raw: Array(bytes[fieldStart ..< offset])
                )
            )
        }
        return fields
    }

    static func readVarint(_ bytes: [UInt8], offset: inout Int) throws -> UInt64 {
        var value: UInt64 = 0
        for index in 0 ..< 10 {
            guard offset < bytes.count else {
                throw WlocCoreError.malformedInput("protobuf varint 被截断")
            }
            let byte = bytes[offset]
            offset += 1
            if index == 9, byte > 1 {
                throw WlocCoreError.malformedInput("protobuf varint 溢出")
            }
            value |= UInt64(byte & 0x7f) << UInt64(index * 7)
            if byte & 0x80 == 0 { return value }
        }
        throw WlocCoreError.malformedInput("protobuf varint 过长")
    }

    static func take(_ bytes: [UInt8], offset: inout Int, count: Int) throws -> [UInt8] {
        guard count >= 0, offset <= bytes.count, count <= bytes.count - offset else {
            throw WlocCoreError.malformedInput("protobuf 字段被截断")
        }
        let end = offset + count
        defer { offset = end }
        return Array(bytes[offset ..< end])
    }

    static func encodeBytesField(number: Int, value: [UInt8]) -> [UInt8] {
        encodeVarint(UInt64(number << 3 | 2)) + encodeVarint(UInt64(value.count)) + value
    }

    static func encodeVarintField(number: Int, value: UInt64) -> [UInt8] {
        encodeVarint(UInt64(number << 3)) + encodeVarint(value)
    }

    static func encodeVarint(_ value: UInt64) -> [UInt8] {
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
}

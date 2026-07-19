import Foundation

public enum LocationVerifier {
    public static func evaluate(
        actualCoordinate: WlocCoordinate,
        horizontalAccuracy: Double,
        target: WlocTarget,
        previousTarget: WlocTarget,
        realLocationBaseline: RealLocationBaseline? = nil,
        verifiedAt: Date = .now
    ) -> LocationVerificationEvidence {
        let accuracyAllowance = max(0, horizontalAccuracy) * 2

        if target.mode == .override, let expected = target.coordinate {
            let distance = distanceMeters(from: actualCoordinate, to: expected)
            // A successful override must land inside the accuracy radius that the
            // module claims. A broad fixed floor previously allowed a visibly wrong
            // mainland map coordinate (for example, a GCJ-02/WGS-84 mismatch) to be
            // reported as successful.
            let threshold = Double(target.accuracy)
            let succeeded = distance <= threshold
            return LocationVerificationEvidence(
                verifiedAt: verifiedAt,
                target: target,
                actualCoordinate: actualCoordinate,
                horizontalAccuracy: horizontalAccuracy,
                distanceMeters: distance,
                thresholdMeters: threshold,
                succeeded: succeeded,
                message: succeeded
                    ? String(format: "目标定位已核验：Shadowrocket 模块坐标一致，系统回读距离目标 %.0f 米（阈值 %.0f 米）。", distance, threshold)
                    : String(format: "目标定位未生效：模块坐标已写入，但系统回读距离目标 %.0f 米，超过 %.0f 米阈值。", distance, threshold)
            )
        }

        if previousTarget.mode == .passthrough {
            return LocationVerificationEvidence(
                verifiedAt: verifiedAt,
                target: target,
                actualCoordinate: actualCoordinate,
                horizontalAccuracy: horizontalAccuracy,
                distanceMeters: nil,
                thresholdMeters: nil,
                succeeded: true,
                message: "Shadowrocket 模块已确认无保存坐标，并取得了新的系统定位；当前为真实定位透传。"
            )
        }

        let fakeDistance = previousTarget.coordinate.map { distanceMeters(from: actualCoordinate, to: $0) }
        let fakeThreshold = max(250, Double(previousTarget.accuracy) * 5, accuracyAllowance)
        if let fakeDistance, fakeDistance > fakeThreshold {
            return LocationVerificationEvidence(
                verifiedAt: verifiedAt,
                target: target,
                actualCoordinate: actualCoordinate,
                horizontalAccuracy: horizontalAccuracy,
                distanceMeters: fakeDistance,
                thresholdMeters: fakeThreshold,
                succeeded: true,
                message: String(format: "真实定位已核验：模块已清除坐标，新位置与原虚拟位置相距 %.0f 米。", fakeDistance)
            )
        }

        if let realLocationBaseline {
            let baselineDistance = distanceMeters(from: actualCoordinate, to: realLocationBaseline.coordinate)
            let baselineThreshold = max(3_000, accuracyAllowance)
            if baselineDistance <= baselineThreshold {
                return LocationVerificationEvidence(
                    verifiedAt: verifiedAt,
                    target: target,
                    actualCoordinate: actualCoordinate,
                    horizontalAccuracy: horizontalAccuracy,
                    distanceMeters: baselineDistance,
                    thresholdMeters: baselineThreshold,
                    succeeded: true,
                    message: String(format: "真实定位已核验：模块已清除坐标，新位置距切换前真实基线 %.0f 米。", baselineDistance)
                )
            }
        }

        return LocationVerificationEvidence(
            verifiedAt: verifiedAt,
            target: target,
            actualCoordinate: actualCoordinate,
            horizontalAccuracy: horizontalAccuracy,
            distanceMeters: fakeDistance,
            thresholdMeters: fakeThreshold,
            succeeded: false,
            message: "模块已切换为真实定位透传，但系统回读无法与原虚拟位置或真实基线区分，因此不宣称恢复已验证。"
        )
    }

    private static func distanceMeters(from lhs: WlocCoordinate, to rhs: WlocCoordinate) -> Double {
        let earthRadiusMeters = 6_371_008.8
        let latitude1 = lhs.latitude * .pi / 180
        let latitude2 = rhs.latitude * .pi / 180
        let latitudeDelta = (rhs.latitude - lhs.latitude) * .pi / 180
        let longitudeDelta = (rhs.longitude - lhs.longitude) * .pi / 180
        let haversine = pow(sin(latitudeDelta / 2), 2)
            + cos(latitude1) * cos(latitude2) * pow(sin(longitudeDelta / 2), 2)
        let centralAngle = 2 * atan2(sqrt(haversine), sqrt(max(0, 1 - haversine)))
        return earthRadiusMeters * centralAngle
    }
}

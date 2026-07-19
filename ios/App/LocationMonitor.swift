import CoreLocation
import Foundation
import OSLog

@MainActor
final class LocationMonitor: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var authorizationStatus: CLAuthorizationStatus
    @Published private(set) var lastLocation: CLLocation?
    @Published private(set) var errorMessage: String?

    private let manager = CLLocationManager()
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.weiweiliang.wloc.schemea",
        category: "Location"
    )

    override init() {
        authorizationStatus = manager.authorizationStatus
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
    }

    var servicesEnabled: Bool {
        CLLocationManager.locationServicesEnabled()
    }

    var accuracyAuthorization: CLAccuracyAuthorization {
        manager.accuracyAuthorization
    }

    func requestAccessAndLocation() {
        authorizationStatus = manager.authorizationStatus
        switch authorizationStatus {
        case .notDetermined:
            logger.notice("Requesting when-in-use location authorization")
            manager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse:
            errorMessage = nil
            manager.requestLocation()
        case .denied, .restricted:
            logger.error("Location request blocked by authorization status: \(self.authorizationStatus.rawValue)")
        @unknown default:
            logger.error("Location request blocked by unknown authorization status: \(self.authorizationStatus.rawValue)")
        }
    }

    func refreshAuthorizationAndLocation() {
        authorizationStatus = manager.authorizationStatus
        requestAccessAndLocation()
    }

    func freshLocation(timeout: Duration = .seconds(15)) async throws -> CLLocation {
        guard servicesEnabled else { throw LocationMonitorError.servicesDisabled }
        authorizationStatus = manager.authorizationStatus
        errorMessage = nil

        let requestedAt = Date()
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        var startedUpdates = false

        defer {
            if startedUpdates {
                manager.stopUpdatingLocation()
            }
        }

        requestAccessAndLocation()
        while clock.now < deadline {
            authorizationStatus = manager.authorizationStatus
            switch authorizationStatus {
            case .authorizedAlways, .authorizedWhenInUse:
                if !startedUpdates {
                    startedUpdates = true
                    logger.notice("Starting fresh location verification")
                    manager.startUpdatingLocation()
                }
            case .notDetermined:
                break
            case .denied, .restricted:
                throw LocationMonitorError.permissionRequired(status: authorizationStatus)
            @unknown default:
                throw LocationMonitorError.permissionRequired(status: authorizationStatus)
            }

            if let lastLocation,
               lastLocation.timestamp >= requestedAt.addingTimeInterval(-1),
               lastLocation.horizontalAccuracy >= 0
            {
                logger.notice(
                    "Fresh location received; accuracy=\(lastLocation.horizontalAccuracy, format: .fixed(precision: 1))"
                )
                return lastLocation
            }
            try await Task.sleep(for: .milliseconds(250))
        }

        logger.error(
            "Fresh location timed out; authorization=\(self.authorizationStatus.rawValue), lastError=\(self.errorMessage ?? "none", privacy: .public)"
        )
        throw LocationMonitorError.timeout
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor [weak self] in
            guard let self else { return }
            authorizationStatus = status
            logger.notice("Location authorization changed: \(status.rawValue)")
            if status == .authorizedAlways || status == .authorizedWhenInUse {
                errorMessage = nil
                self.manager.requestLocation()
            }
        }
    }

    nonisolated func locationManager(_: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let latestLocation = locations.last
        Task { @MainActor [weak self] in
            guard let self, let latestLocation else { return }
            lastLocation = latestLocation
            errorMessage = nil
            logger.debug(
                "Location callback; age=\(-latestLocation.timestamp.timeIntervalSinceNow, format: .fixed(precision: 1))s accuracy=\(latestLocation.horizontalAccuracy, format: .fixed(precision: 1))"
            )
        }
    }

    nonisolated func locationManager(_: CLLocationManager, didFailWithError error: Error) {
        let message = error.localizedDescription
        Task { @MainActor [weak self] in
            guard let self else { return }
            errorMessage = message
            logger.error("Location callback failed: \(message, privacy: .public)")
        }
    }
}

enum LocationMonitorError: Error, LocalizedError {
    case servicesDisabled
    case permissionRequired(status: CLAuthorizationStatus)
    case timeout

    var errorDescription: String? {
        switch self {
        case .servicesDisabled:
            "系统定位服务当前关闭。"
        case let .permissionRequired(status):
            "WLOC 当前没有定位权限（系统状态码 \(status.rawValue)）。请在系统设置中允许“使用 App 时”访问定位。"
        case .timeout:
            "等待新的系统定位结果超时。"
        }
    }
}

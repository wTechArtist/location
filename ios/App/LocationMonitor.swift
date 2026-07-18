import CoreLocation
import Foundation

@MainActor
final class LocationMonitor: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var authorizationStatus: CLAuthorizationStatus
    @Published private(set) var lastLocation: CLLocation?
    @Published private(set) var errorMessage: String?

    private let manager = CLLocationManager()

    override init() {
        authorizationStatus = manager.authorizationStatus
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    var servicesEnabled: Bool {
        CLLocationManager.locationServicesEnabled()
    }

    func requestAccessAndLocation() {
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse:
            manager.requestLocation()
        default:
            break
        }
    }

    func freshLocation(timeout: Duration = .seconds(15)) async throws -> CLLocation {
        guard servicesEnabled else { throw LocationMonitorError.servicesDisabled }
        guard manager.authorizationStatus == .authorizedAlways || manager.authorizationStatus == .authorizedWhenInUse else {
            requestAccessAndLocation()
            throw LocationMonitorError.permissionRequired
        }
        let requestedAt = Date()
        manager.requestLocation()
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if let lastLocation, lastLocation.timestamp >= requestedAt.addingTimeInterval(-1), lastLocation.horizontalAccuracy >= 0 {
                return lastLocation
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw LocationMonitorError.timeout
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor [weak self] in
            guard let self else { return }
            authorizationStatus = status
            if status == .authorizedAlways || status == .authorizedWhenInUse {
                self.manager.requestLocation()
            }
        }
    }

    nonisolated func locationManager(_: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let latestLocation = locations.last
        Task { @MainActor [weak self] in
            self?.lastLocation = latestLocation
        }
    }

    nonisolated func locationManager(_: CLLocationManager, didFailWithError error: Error) {
        let message = error.localizedDescription
        Task { @MainActor [weak self] in
            self?.errorMessage = message
        }
    }
}

enum LocationMonitorError: Error, LocalizedError {
    case servicesDisabled
    case permissionRequired
    case timeout

    var errorDescription: String? {
        switch self {
        case .servicesDisabled: "系统定位服务当前关闭。"
        case .permissionRequired: "需要允许 WLOC 使用定位，才能核验切换是否真正生效。"
        case .timeout: "等待新的系统定位结果超时。"
        }
    }
}

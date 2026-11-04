import CoreLocation
import Foundation

@MainActor
final class LocationService: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var last: CLLocation?
    @Published private(set) var place: String = ""
    @Published private(set) var authorized = false

    var onUpdate: ((CLLocation) -> Void)?

    private let manager = CLLocationManager()
    private let geocoder = CLGeocoder()
    private var lastGeocode: (CLLocation, Date)?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        manager.distanceFilter = 40
        manager.activityType = .otherNavigation
        manager.pausesLocationUpdatesAutomatically = false
        manager.allowsBackgroundLocationUpdates = true
    }

    func start() {
        switch manager.authorizationStatus {
        case .notDetermined: manager.requestWhenInUseAuthorization()
        default: break
        }
        manager.startUpdatingLocation()
        manager.startUpdatingHeading()
    }

    /// Durante la navegación: precisión máxima y actualizaciones continuas.
    func setNavigation(_ on: Bool) {
        manager.desiredAccuracy = on ? kCLLocationAccuracyBestForNavigation : kCLLocationAccuracyHundredMeters
        manager.distanceFilter = on ? kCLDistanceFilterNone : 40
        manager.activityType = on ? .automotiveNavigation : .otherNavigation
        manager.showsBackgroundLocationIndicator = on
    }

    /// Para el contexto del modelo.
    func snapshot() -> [String: Any]? {
        guard let l = last else { return nil }
        var d: [String: Any] = ["lat": l.coordinate.latitude, "lon": l.coordinate.longitude, "acc": l.horizontalAccuracy]
        if l.speed >= 0 { d["speed"] = l.speed }
        if l.course >= 0 { d["heading"] = l.course }
        if !place.isEmpty { d["place"] = place }
        return d
    }

    nonisolated func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
        let ok = m.authorizationStatus == .authorizedWhenInUse || m.authorizationStatus == .authorizedAlways
        Task { @MainActor in
            self.authorized = ok
            if ok { m.startUpdatingLocation() }
        }
    }

    nonisolated func locationManager(_ m: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        Task { @MainActor in
            self.last = loc
            self.onUpdate?(loc)
            self.maybeGeocode(loc)
        }
    }

    nonisolated func locationManager(_ m: CLLocationManager, didFailWithError error: Error) {}

    private func maybeGeocode(_ loc: CLLocation) {
        if let (prev, at) = lastGeocode, loc.distance(from: prev) < 250, Date().timeIntervalSince(at) < 300 { return }
        guard !geocoder.isGeocoding else { return }
        lastGeocode = (loc, Date())
        geocoder.reverseGeocodeLocation(loc, preferredLocale: Locale(identifier: "es_US")) { [weak self] marks, _ in
            guard let p = marks?.first else { return }
            let parts = [p.thoroughfare, p.subLocality, p.locality].compactMap { $0 }
            let text = parts.prefix(3).joined(separator: ", ")
            Task { @MainActor in self?.place = text }
        }
    }
}

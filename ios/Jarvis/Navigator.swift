import CoreLocation
import MapKit

/// Navegación giro a giro por voz con MapKit + GPS del iPhone.
@MainActor
final class Navigator: ObservableObject {
    @Published private(set) var active = false
    @Published private(set) var destinationName = ""
    @Published private(set) var nextInstruction = ""

    var speak: ((String) -> Void)?
    var onActiveChanged: ((Bool) -> Void)?

    private var route: MKRoute?
    private var routeCoords: [CLLocationCoordinate2D] = []
    private var destination: MKMapItem?
    private var mode: String = "driving"
    private var next = 1                 // índice del próximo giro
    private var announcedFar = false
    private var announcedNear = false
    private var minDist = Double.greatestFiniteMagnitude
    private var offRouteCount = 0
    private var lastReroute = Date.distantPast

    // MARK: Inicio / fin

    func start(destination query: String, mode: String, from loc: CLLocation?) async {
        guard let loc else { speak?("No tengo su ubicación todavía, señor."); return }
        self.mode = mode
        let req = MKLocalSearch.Request()
        req.naturalLanguageQuery = query
        req.region = MKCoordinateRegion(center: loc.coordinate, latitudinalMeters: 60_000, longitudinalMeters: 60_000)
        guard let item = try? await MKLocalSearch(request: req).start().mapItems.first else {
            speak?("No encontré \(query), señor."); return
        }
        destination = item
        destinationName = item.name ?? query
        guard await computeRoute(from: loc) else { speak?("No pude calcular la ruta a \(destinationName)."); return }
        setActive(true)
        guard let r = route else { return }
        let mins = max(1, Int((r.expectedTravelTime / 60).rounded()))
        speak?("Ruta a \(destinationName): \(mins) minutos, \(Self.spokenDistance(r.distance)). \(firstInstruction())")
    }

    func stop(announce: Bool = true) {
        guard active else { return }
        setActive(false)
        route = nil; routeCoords = []; destination = nil
        if announce { speak?("Navegación cancelada.") }
    }

    private func setActive(_ v: Bool) {
        active = v
        onActiveChanged?(v)
        if !v { nextInstruction = "" }
    }

    // MARK: Ruta

    private func computeRoute(from loc: CLLocation) async -> Bool {
        guard let destination else { return false }
        let req = MKDirections.Request()
        req.source = MKMapItem.forCurrentLocation()
        req.destination = destination
        req.transportType = mode == "walking" ? .walking : .automobile // MapKit no calcula rutas de tránsito
        guard let resp = try? await MKDirections(request: req).calculate(), let r = resp.routes.first else { return false }
        route = r
        routeCoords = r.polyline.coordinatesArray
        next = r.steps.firstIndex(where: { !$0.instructions.isEmpty && $0 !== r.steps.first }) ?? r.steps.count
        resetStepState()
        return true
    }

    private func resetStepState() {
        announcedFar = false; announcedNear = false
        minDist = .greatestFiniteMagnitude
        if let r = route, next < r.steps.count { nextInstruction = r.steps[next].instructions }
    }

    private func firstInstruction() -> String {
        guard let r = route, let s = r.steps.first(where: { !$0.instructions.isEmpty }) else { return "" }
        return s.instructions + "."
    }

    // MARK: Actualizaciones de GPS

    func update(_ loc: CLLocation) {
        guard active, let r = route else { return }
        let walking = mode == "walking"

        // ¿Llegó?
        if let end = routeCoords.last, loc.distance(from: CLLocation(latitude: end.latitude, longitude: end.longitude)) < (walking ? 20 : 35) {
            speak?("Ha llegado a su destino, señor.")
            stop(announce: false)
            return
        }

        // ¿Se salió de la ruta?
        let off = Self.distanceToPolyline(loc.coordinate, routeCoords)
        if off > (walking ? 45 : 80) {
            offRouteCount += 1
            if offRouteCount >= 4, Date().timeIntervalSince(lastReroute) > 20 {
                lastReroute = Date(); offRouteCount = 0
                speak?("Recalculando.")
                Task { _ = await self.computeRoute(from: loc) }
                return
            }
        } else { offRouteCount = 0 }

        guard next < r.steps.count else { return }
        let step = r.steps[next]
        guard let first = step.polyline.coordinatesArray.first else { next += 1; return }
        let d = loc.distance(from: CLLocation(latitude: first.latitude, longitude: first.longitude))
        let speed = max(0, loc.speed)
        let far = walking ? 90.0 : max(300.0, speed * 16)
        let near = walking ? 30.0 : max(90.0, speed * 6)
        minDist = min(minDist, d)

        if d <= near, !announcedNear {
            announcedNear = true; announcedFar = true
            speak?(step.instructions)
        } else if d <= far, !announcedFar {
            announcedFar = true
            speak?("En \(Self.spokenDistance(d)), \(Self.lowercasedFirst(step.instructions))")
        }
        // Pasó el giro
        if (d < (walking ? 12 : 25)) || (minDist < near && d > minDist + 45) {
            next += 1
            // salta pasos sin texto
            while next < r.steps.count, r.steps[next].instructions.isEmpty { next += 1 }
            resetStepState()
        }
    }

    // MARK: Utilidades

    static func spokenDistance(_ m: Double) -> String {
        if m < 950 { return "\(Int((m / 10).rounded() * 10)) metros" }
        let km = m / 1000
        let text = km < 10 ? String(format: "%.1f", km).replacingOccurrences(of: ".", with: " punto ") : "\(Int(km.rounded()))"
        return "\(text) kilómetros"
    }

    static func lowercasedFirst(_ s: String) -> String {
        guard let f = s.first else { return s }
        return f.lowercased() + s.dropFirst()
    }

    /// Distancia mínima (m) de un punto a una polilínea, proyectando sobre cada segmento.
    static func distanceToPolyline(_ p: CLLocationCoordinate2D, _ line: [CLLocationCoordinate2D]) -> Double {
        guard line.count > 1 else { return .greatestFiniteMagnitude }
        let mp = MKMapPoint(p)
        let scale = MKMetersPerMapPointAtLatitude(p.latitude)
        var best = Double.greatestFiniteMagnitude
        var a = MKMapPoint(line[0])
        for i in 1..<line.count {
            let b = MKMapPoint(line[i])
            let dx = b.x - a.x, dy = b.y - a.y
            let len2 = dx * dx + dy * dy
            var t = len2 == 0 ? 0 : ((mp.x - a.x) * dx + (mp.y - a.y) * dy) / len2
            t = max(0, min(1, t))
            let px = a.x + t * dx, py = a.y + t * dy
            let dist = ((mp.x - px) * (mp.x - px) + (mp.y - py) * (mp.y - py)).squareRoot() * scale
            best = min(best, dist)
            a = b
        }
        return best
    }
}

extension MKMultiPoint {
    var coordinatesArray: [CLLocationCoordinate2D] {
        var coords = [CLLocationCoordinate2D](repeating: kCLLocationCoordinate2DInvalid, count: pointCount)
        getCoordinates(&coords, range: NSRange(location: 0, length: pointCount))
        return coords
    }
}

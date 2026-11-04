import EventKit
import Foundation

enum CalendarError: LocalizedError {
    case denied, noCalendar, badDate
    var errorDescription: String? {
        switch self {
        case .denied: return "Sin permiso para el calendario (Ajustes de iOS → Jarvis → Calendarios)."
        case .noCalendar: return "No hay un calendario predeterminado en el iPhone."
        case .badDate: return "Fecha inválida."
        }
    }
}

/// Calendario del iPhone para Jarvis: leer la agenda y crear eventos (EventKit, iOS 17+).
@MainActor
final class CalendarService {
    private let store = EKEventStore()

    private func ensureAccess() async throws {
        if EKEventStore.authorizationStatus(for: .event) == .fullAccess { return }
        let granted = try await store.requestFullAccessToEvents()
        if !granted { throw CalendarError.denied }
    }

    private static func iso() -> ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = .current
        return f
    }

    /// start: "YYYY-MM-DD" (vacío = hoy). Devuelve una lista lista para JSON.
    func events(start: String, days: Int) async throws -> [[String: Any]] {
        try await ensureAccess()
        let cal = Calendar.current
        var from = cal.startOfDay(for: Date())
        if !start.isEmpty {
            let p = DateFormatter()
            p.calendar = Calendar(identifier: .gregorian)
            p.locale = Locale(identifier: "en_US_POSIX")
            p.timeZone = .current
            p.dateFormat = "yyyy-MM-dd"
            guard let d = p.date(from: start) else { throw CalendarError.badDate }
            from = d
        }
        guard let to = cal.date(byAdding: .day, value: max(1, min(14, days)), to: from) else { throw CalendarError.badDate }
        let predicate = store.predicateForEvents(withStart: from, end: to, calendars: nil)
        let f = Self.iso()
        return store.events(matching: predicate)
            .sorted { $0.startDate < $1.startDate }
            .prefix(40)
            .map { (e: EKEvent) -> [String: Any] in
                var d: [String: Any] = [
                    "title": e.title ?? "(sin título)",
                    "start": f.string(from: e.startDate),
                    "end": f.string(from: e.endDate),
                    "allDay": e.isAllDay,
                ]
                if let l = e.location, !l.isEmpty { d["location"] = l }
                return d
            }
    }

    /// start/end en ISO 8601 con zona (el servidor los manda en UTC).
    func add(title: String, start: String, end: String, location: String, notes: String) async throws -> [String: Any] {
        try await ensureAccess()
        let f = Self.iso()
        guard let s = f.date(from: start), let e = f.date(from: end), e > s else { throw CalendarError.badDate }
        guard let calendar = store.defaultCalendarForNewEvents else { throw CalendarError.noCalendar }
        let ev = EKEvent(eventStore: store)
        ev.title = title
        ev.startDate = s
        ev.endDate = e
        ev.calendar = calendar
        if !location.isEmpty { ev.location = location }
        if !notes.isEmpty { ev.notes = notes }
        try store.save(ev, span: .thisEvent)
        return ["id": ev.eventIdentifier ?? "", "calendar": calendar.title]
    }
}

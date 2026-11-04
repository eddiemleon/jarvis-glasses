import Foundation

/// Evento SSE del servidor (/chat y /events).
struct ServerEvent {
    var type: String
    var text: String?
    var audio: String?      // mp3 en base64; nil → usar voz local
    var name: String?
    var args: [String: Any]
    var source: String?
    var message: String?

    init?(jsonString: String) {
        guard let d = jsonString.data(using: .utf8),
              let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
              let t = o["type"] as? String else { return nil }
        type = t
        text = o["text"] as? String
        audio = o["audio"] as? String
        name = o["name"] as? String
        args = o["args"] as? [String: Any] ?? [:]
        source = o["source"] as? String
        message = o["message"] as? String
    }
}

enum BrainError: LocalizedError {
    case notConfigured
    case http(Int)
    var errorDescription: String? {
        switch self {
        case .notConfigured: return "Falta la dirección o el token del servidor (Ajustes)."
        case .http(let c): return c == 401 ? "El token no coincide con el del servidor." : "El servidor respondió \(c)."
        }
    }
}

final class Brain: @unchecked Sendable {
    private let chatSession: URLSession
    private let eventsSession: URLSession

    init() {
        let a = URLSessionConfiguration.default
        a.timeoutIntervalForRequest = 60
        a.timeoutIntervalForResource = 300
        chatSession = URLSession(configuration: a)

        let b = URLSessionConfiguration.default
        b.timeoutIntervalForRequest = 90          // el servidor manda un ping cada 20 s
        b.timeoutIntervalForResource = 60 * 60 * 24
        b.waitsForConnectivity = true
        eventsSession = URLSession(configuration: b)
    }

    static func baseURL() -> URL? {
        var s = Prefs.serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        return s.isEmpty ? nil : URL(string: s)
    }

    private func makeRequest(_ path: String, method: String, authed: Bool = true) throws -> URLRequest {
        guard let base = Self.baseURL(), (!authed || !Prefs.token.isEmpty) else { throw BrainError.notConfigured }
        var req = URLRequest(url: base.appendingPathComponent(path))
        req.httpMethod = method
        if authed { req.setValue("Bearer \(Prefs.token)", forHTTPHeaderField: "Authorization") }
        req.setValue(Prefs.sessionID, forHTTPHeaderField: "X-Session")
        return req
    }

    private static func events(from bytes: URLSession.AsyncBytes, into cont: AsyncThrowingStream<ServerEvent, Error>.Continuation) async throws {
        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            let payload = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            if let ev = ServerEvent(jsonString: payload) { cont.yield(ev) }
        }
    }

    /// Pregunta a Jarvis. Emite eventos speech / action / done / error en orden.
    func chat(text: String, context: [String: Any]) -> AsyncThrowingStream<ServerEvent, Error> {
        AsyncThrowingStream { cont in
            let task = Task {
                do {
                    var req = try makeRequest("chat", method: "POST")
                    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    req.httpBody = try JSONSerialization.data(withJSONObject: ["text": text, "context": context])
                    let (bytes, resp) = try await chatSession.bytes(for: req)
                    if let http = resp as? HTTPURLResponse, http.statusCode != 200 { throw BrainError.http(http.statusCode) }
                    try await Self.events(from: bytes, into: cont)
                    cont.finish()
                } catch {
                    cont.finish(throwing: error)
                }
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }

    /// Canal permanente de alertas (TradingView, WhatsApp...). Termina si se corta; el llamador reconecta.
    func alerts() -> AsyncThrowingStream<ServerEvent, Error> {
        AsyncThrowingStream { cont in
            let task = Task {
                do {
                    let req = try makeRequest("events", method: "GET")
                    let (bytes, resp) = try await eventsSession.bytes(for: req)
                    if let http = resp as? HTTPURLResponse, http.statusCode != 200 { throw BrainError.http(http.statusCode) }
                    try await Self.events(from: bytes, into: cont)
                    cont.finish()
                } catch {
                    cont.finish(throwing: error)
                }
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Utilidades de Ajustes

    func health() async -> String {
        do {
            let req = try makeRequest("health", method: "GET", authed: false)
            let (data, resp) = try await chatSession.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200,
                  let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return "El servidor respondió algo raro." }
            let tts = o["tts"] as? String ?? "?"
            let wa = (o["whatsapp"] as? Bool ?? false) ? "sí" : "no"
            let tv = (o["tradingview"] as? Bool ?? false) ? "sí" : "no"
            return "En línea · modelo \(o["model"] as? String ?? "?") · voz \(tts) · WhatsApp \(wa) · TradingView \(tv)"
        } catch {
            return "No conecta: \(error.localizedDescription)"
        }
    }

    func testAlert() async -> String {
        do {
            let req = try makeRequest("api/test-alert", method: "POST")
            let (_, resp) = try await chatSession.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            return code == 200 ? "Alerta enviada. Deberías oírla en unos segundos." : "El servidor respondió \(code)."
        } catch {
            return "Falló: \(error.localizedDescription)"
        }
    }
}

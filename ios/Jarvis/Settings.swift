import Foundation

/// Ajustes guardados en UserDefaults (las mismas claves las usa @AppStorage en las vistas).
enum K {
    static let serverURL = "serverURL"          // https://tu-servidor.com
    static let token = "token"                  // JARVIS_TOKEN del servidor
    static let followUp = "followUp"            // conversación continua sin repetir "Jarvis"
    static let readWhatsApp = "readWhatsApp"    // leer en voz alta el texto de los WhatsApp
    static let boostDB = "boostDB"              // refuerzo de volumen (dB) de la voz de Jarvis
    static let maxSystemVolume = "maxSystemVolume"
    static let voiceID = "voiceID"              // identificador de AVSpeechSynthesisVoice
    static let speechRate = "speechRate"
    static let listening = "listening"          // escucha de "Jarvis" activada
    static let locale = "locale"                // es-US, es-MX, es-ES...
    static let localVoice = "localVoice"        // voz de Jarvis dentro del iPhone (modelo propio)
    static let liveQuality = "liveQuality"      // transmisión en vivo: "fluida" | "equilibrada" | "maxima"
}

enum Settings {
    static let d = UserDefaults.standard

    static func registerDefaults() {
        d.register(defaults: [
            K.followUp: true,
            K.readWhatsApp: true,
            K.boostDB: 9.0,
            K.maxSystemVolume: true,
            K.localVoice: true,
            K.speechRate: 0.52,
            K.listening: true,
            K.locale: "es-US",
            K.liveQuality: "equilibrada",
        ])
    }

    static var serverURL: String { (d.string(forKey: K.serverURL) ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
    static var token: String { (d.string(forKey: K.token) ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
    static var followUp: Bool { d.bool(forKey: K.followUp) }
    static var readWhatsApp: Bool { d.bool(forKey: K.readWhatsApp) }
    static var boostDB: Float { Float(d.double(forKey: K.boostDB)) }
    static var maxSystemVolume: Bool { d.bool(forKey: K.maxSystemVolume) }
    static var localVoice: Bool { d.bool(forKey: K.localVoice) }
    static var voiceID: String { d.string(forKey: K.voiceID) ?? "" }
    static var speechRate: Float { Float(d.double(forKey: K.speechRate)) }
    static var listening: Bool { d.bool(forKey: K.listening) }
    static var locale: String { d.string(forKey: K.locale) ?? "es-US" }
    static var liveQuality: String { d.string(forKey: K.liveQuality) ?? "equilibrada" }

    /// ws(s)://host/ws a partir de lo que escribió el usuario.
    static var websocketURL: URL? {
        var s = serverURL
        guard !s.isEmpty else { return nil }
        if !s.contains("://") { s = "https://" + s }
        if s.hasPrefix("https://") { s = "wss://" + s.dropFirst(8) }
        else if s.hasPrefix("http://") { s = "ws://" + s.dropFirst(7) }
        while s.hasSuffix("/") { s.removeLast() }
        if !s.hasSuffix("/ws") { s += "/ws" }
        return URL(string: s)
    }

    static var httpBaseURL: URL? {
        guard let ws = websocketURL else { return nil }
        var s = ws.absoluteString
        if s.hasPrefix("wss://") { s = "https://" + s.dropFirst(6) }
        else if s.hasPrefix("ws://") { s = "http://" + s.dropFirst(5) }
        if s.hasSuffix("/ws") { s.removeLast(3) }
        return URL(string: s)
    }
}

import SwiftUI
import UIKit
import AVFoundation
import CoreLocation

enum JarvisState { case offline, idle, listening, thinking, speaking, alert, paused }

private struct Announcement { let text: String; let tone: AudioIO.Tone; let expectReply: Bool }

/// Orquestador: une audio de las gafas, "Jarvis", servidor/IA, voz, alertas, GPS, cámara y transmisión en vivo.
@MainActor
final class AppModel: ObservableObject {
    // UI
    @Published var state: JarvisState = .offline
    @Published var userText = ""
    @Published var assistantText = ""
    @Published var statusLine = ""
    @Published var micLevel: Float = 0
    @Published var outLevel: Float = 0
    @Published var serverConnected = false
    @Published var serverModel = ""
    @Published var routeName = "—"
    @Published var usingGlassesMic = false
    @Published var errorText: String?
    @Published var pausedUntil: Date?
    @Published var permissionsOK = false
    /// Idioma de la otra persona mientras el modo intérprete está activo.
    @Published var interpreterLocale: String?

    // Servicios
    let audio: AudioIO
    let speech = SpeechListener()
    let link = ServerLink()
    let location = LocationService()
    let navigator = Navigator()
    let glasses = GlassesService()
    let voice = GlassesVoice()
    let live = LiveService()
    let calendar = CalendarService()
    let speaker: Speaker

    // Estado interno
    private var started = false
    private var turnId: String?
    private var turnDone = false
    private var pending: [Announcement] = []
    private var announcing = false
    private var announceExpectsReply = false
    private var micActive = false
    private var resumeTimer: Task<Void, Never>?
    private var lastLocationSent = Date.distantPast
    private var lastLocationCoord: CLLocation?

    init() {
        let a = AudioIO()
        audio = a
        speaker = Speaker(audio: a)
        Settings.registerDefaults()
    }

    // MARK: Arranque

    func start() async {
        guard !started else { await resumeFromForeground(); return }
        started = true
        permissionsOK = await withCheckedContinuation { cont in SpeechListener.requestPermissions { cont.resume(returning: $0) } }
        guard permissionsOK else {
            errorText = "Faltan permisos de micrófono o reconocimiento de voz (Ajustes de iOS)."
            started = false
            return
        }
        wire()
        if let f = WearablesBoot.failure { errorText = f }
        location.start()
        glasses.startObserving()
        voice.start()
        link.connect()
        live.attach(link.outbox)
        applyListeningState()
        refreshRoute()
    }

    func resumeFromForeground() async {
        link.connect()
        if micActive { try? audio.start() }
        refreshRoute()
    }

    private func wire() {
        // --- Audio (hilo de audio → solo cosas @Sendable) ---
        let speechRef = speech
        let liveRef = live
        audio.onMicBuffer = { buf in
            speechRef.feed(buf)
            liveRef.feedAudio(buf)
        }
        let micGate = FrameThrottle(minInterval: 0.05)
        audio.onMicLevel = { [weak self] v in
            guard micGate.ok() else { return }
            Task { @MainActor in self?.micLevel = v }
        }
        let outGate = FrameThrottle(minInterval: 0.05)
        audio.onOutLevel = { [weak self] v in
            guard outGate.ok() else { return }
            Task { @MainActor in self?.outLevel = v }
        }
        audio.onRouteChanged = { [weak self] in
            Task { @MainActor in self?.refreshRoute() }
        }

        // --- Voz ("Jarvis") ---
        speech.onWake = { [weak self] after in Task { @MainActor in self?.handleWake(after) } }
        speech.onPartial = { [weak self] text in Task { @MainActor in self?.userText = text } }
        speech.onCommand = { [weak self] text in Task { @MainActor in self?.handleCommand(text) } }
        speech.onCaptureTimeout = { [weak self] in Task { @MainActor in self?.handleCaptureTimeout() } }
        speech.onInterpret = { [weak self] text in Task { @MainActor in self?.handleInterpret(text) } }
        speech.onInterpretExit = { [weak self] in Task { @MainActor in self?.handleInterpretExit() } }

        // --- Voz de salida ---
        speaker.onSpeakingChanged = { [weak self] speaking in
            guard let self else { return }
            if self.interpreterLocale != nil { self.speech.flush() } // no traducir la propia voz de Jarvis
            if speaking { if self.state != .alert { self.state = .speaking }; return }
            if self.announcing { self.announcing = false; self.afterAnnouncement() } else { self.checkTurnFinished() }
        }

        // --- Servidor ---
        link.onConnectionChanged = { [weak self] ok in
            guard let self else { return }
            self.serverConnected = ok
            if ok { self.sendLocation(force: true) }
            if !ok && self.state == .idle { self.statusLine = "Sin conexión con el servidor" }
            if ok { self.statusLine = "" }
        }
        link.onMessage = { [weak self] msg in self?.handleServer(msg) }

        // --- GPS / navegación ---
        location.onUpdate = { [weak self] loc in
            guard let self else { return }
            self.navigator.update(loc)
            self.sendLocation(force: false)
        }
        navigator.speak = { [weak self] text in self?.speakLocal(text) }
        navigator.onActiveChanged = { [weak self] on in self?.location.setNavigation(on) }

        // --- Hey Meta, abre Jarvis ---
        voice.onLaunch = { [weak self] in self?.handleLaunch() }
    }

    // MARK: Escucha (activar / pausar)

    var listeningDesired: Bool {
        guard Settings.listening else { return false }
        if let until = pausedUntil, until > Date() { return false }
        return true
    }

    /// Enciende o apaga el micrófono continuo. Apagado = las gafas vuelven a audio de música en calidad completa.
    func applyListeningState() {
        if interpreterLocale != nil { stopInterpreter() }
        if listeningDesired {
            if !micActive {
                do { try audio.start() } catch { errorText = "Audio: \(error.localizedDescription)" }
                speech.start(localeID: Settings.locale)
                micActive = true
            } else { speech.resumeWake() }
            if state == .paused || state == .offline { state = .idle }
        } else {
            speech.pause()
            if micActive && !speaker.speaking { shutdownMic() }
            state = .paused
        }
    }

    private func shutdownMic() {
        speech.stop()
        audio.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        micActive = false
    }

    func setListening(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: K.listening)
        if on { pausedUntil = nil; resumeTimer?.cancel() }
        applyListeningState()
    }

    func pauseListening(minutes: Int) {
        pausedUntil = Date().addingTimeInterval(Double(minutes) * 60)
        applyListeningState()
        resumeTimer?.cancel()
        resumeTimer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(minutes) * 60 * 1_000_000_000)
            guard !Task.isCancelled else { return }
            self?.pausedUntil = nil
            self?.applyListeningState()
        }
    }

    func refreshRoute() {
        routeName = audio.inputName
        usingGlassesMic = audio.usingBluetoothMic
    }

    // MARK: Flujo de conversación

    private func handleWake(_ initial: String) {
        if speaker.speaking || state == .thinking || state == .speaking { bargeIn() }
        audio.playTone(.wake)
        state = .listening
        userText = initial
        assistantText = ""
    }

    private func bargeIn() {
        speaker.stop()
        link.send(["type": "cancel"])
        turnId = nil
        turnDone = false
        announcing = false
    }

    private func handleCommand(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        userText = t
        assistantText = ""

        // Órdenes locales instantáneas (funcionan incluso sin servidor)
        let norm = SpeechListener.normalize(t)
        if ["para", "cancela", "silencio", "callate", "basta", "ya", "detente", "gracias"].contains(norm) {
            bargeIn()
            state = .idle
            return
        }

        guard link.connected else {
            speakLocal("No tengo conexión con mi servidor, señor.")
            return
        }
        state = .thinking
        statusLine = ""
        let id = UUID().uuidString
        turnId = id
        turnDone = false
        var msg: [String: Any] = ["type": "utterance", "id": id, "text": t,
                                  "glasses": glasses.deviceConnected ? "conectadas" : "sin enlace con el SDK"]
        if let loc = location.snapshot() { msg["location"] = loc }
        link.send(msg)

        // Seguro: si el servidor no responde en 40 s, vuelve a escuchar.
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 40_000_000_000)
            guard let self, self.turnId == id, self.state == .thinking else { return }
            self.turnId = nil
            self.speakLocal("No obtuve respuesta a tiempo, señor.")
        }
    }

    private func handleCaptureTimeout() {
        if state == .listening { state = .idle }
        processPending()
    }

    private func checkTurnFinished() {
        guard turnId != nil, turnDone, speaker.isIdle else { return }
        turnId = nil
        turnDone = false
        statusLine = ""
        state = .idle
        if processPending() { return }
        if interpreterLocale != nil { return } // en modo intérprete se sigue escuchando el otro idioma
        if Settings.followUp, listeningDesired {
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 450_000_000)
                guard let self, self.state == .idle else { return }
                self.state = .listening
                self.userText = ""
                self.speech.beginCapture(emptyTimeout: 7)
            }
        } else if !listeningDesired, micActive { shutdownMic() }
    }

    // MARK: Anuncios (alertas, WhatsApp, navegación, mensajes locales)

    func speakLocal(_ text: String) {
        if !micActive { try? audio.start() }
        if state == .idle || state == .paused || state == .alert {
            announcing = true
            state = .alert
        }
        speaker.enqueue(text)
    }

    private func announce(_ a: Announcement) {
        pending.append(a)
        processPending()
    }

    @discardableResult
    private func processPending() -> Bool {
        guard state == .idle || state == .paused, !pending.isEmpty, !announcing else { return false }
        let a = pending.removeFirst()
        if !micActive { try? audio.start() }
        announcing = true
        announceExpectsReply = a.expectReply
        state = .alert
        audio.playTone(a.tone)
        assistantText = a.text
        speaker.enqueue(a.text)
        return true
    }

    private func afterAnnouncement() {
        state = listeningDesired ? .idle : .paused
        if processPending() { return }
        if interpreterLocale != nil { announceExpectsReply = false; return }
        if announceExpectsReply, listeningDesired {
            announceExpectsReply = false
            state = .listening
            userText = ""
            speech.beginCapture(emptyTimeout: 8)
        } else if !listeningDesired, micActive { shutdownMic() }
    }

    // MARK: "Hey Meta, abre Jarvis"

    private func handleLaunch() {
        pausedUntil = nil
        UserDefaults.standard.set(true, forKey: K.listening)
        applyListeningState()
        audio.playTone(.wake)
        state = .listening
        userText = ""
        speech.beginCapture(emptyTimeout: 8)
    }

    // MARK: Mensajes del servidor

    private func handleServer(_ m: [String: Any]) {
        guard let type = m["type"] as? String else { return }
        switch type {
        case "ready":
            serverModel = (m["model"] as? String) ?? ""
            if let f = m["features"] as? [String: Any] { speaker.remoteTTSAvailable = (f["tts"] as? Bool) ?? false }
            if state == .offline { state = listeningDesired ? .idle : .paused }

        case "say":
            guard let id = m["id"] as? String, id == turnId, let t = m["text"] as? String else { return }
            assistantText += (assistantText.isEmpty ? "" : " ") + t
            speaker.enqueue(t)

        case "done":
            guard (m["id"] as? String) == turnId else { return }
            turnDone = true
            checkTurnFinished()

        case "status":
            let name = (m["name"] as? String) ?? ""
            statusLine = Self.toolLabel(name)

        case "alert":
            let text = (m["text"] as? String) ?? ""
            let source = (m["source"] as? String) ?? ""
            let prefix = source == "tradingview" ? "Alerta de TradingView. " : (source == "reminder" ? "Recordatorio. " : "")
            announce(Announcement(text: prefix + text, tone: .alert, expectReply: false))

        case "whatsapp_in":
            let name = (m["name"] as? String) ?? "alguien"
            let body = (m["text"] as? String) ?? ""
            let spoken = Settings.readWhatsApp ? "Mensaje de WhatsApp de \(name): \(String(body.prefix(280)))" : "Tiene un mensaje de WhatsApp de \(name)."
            announce(Announcement(text: spoken, tone: .alert, expectReply: true))

        case "capture_request":
            guard let reqId = m["reqId"] as? String else { return }
            Task { await self.doCapture(reqId: reqId) }

        case "navigate":
            let dest = (m["destination"] as? String) ?? ""
            let mode = (m["mode"] as? String) ?? "driving"
            Task { await self.navigator.start(destination: dest, mode: mode, from: self.location.last) }

        case "stop_navigation":
            navigator.stop()

        case "pause_listening":
            pauseListening(minutes: (m["minutes"] as? Int) ?? 10)

        case "set_volume":
            let level = Float((m["level"] as? Double) ?? 1)
            UserDefaults.standard.set(Double(max(0, (level - 0.3) / 0.7 * 18)), forKey: K.boostDB)
            audio.setBoost(dB: Settings.boostDB)
            if level >= 0.9 { SystemVolume.set(1.0) }

        // --- Transmisión en vivo ---
        case "live_link", "live_begin":
            guard let url = m["url"] as? String else { return }
            let exp = (m["expires"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) }
            Task { await self.live.begin(url: url, expires: exp, glasses: self.glasses, outbox: self.link.outbox) }
        case "live_viewers":
            live.setViewers((m["n"] as? Int) ?? 0)
        case "live_ended":
            live.end(glasses: glasses)
        case "live_stop_request":
            live.end(glasses: glasses)

        // --- Nuevas capacidades ---
        case "speak":
            // Traducción del modo intérprete (y cualquier frase directa del servidor).
            guard let t = m["text"] as? String, !t.isEmpty else { return }
            assistantText = t
            speakLocal(t)

        case "interpreter":
            if (m["on"] as? Bool) == true { startInterpreter(locale: (m["locale"] as? String) ?? "en-US") }
            else { stopInterpreter() }

        case "device_request":
            guard let reqId = m["reqId"] as? String, let action = m["action"] as? String else { return }
            let params = (m["params"] as? [String: Any]) ?? [:]
            Task { await self.handleDeviceRequest(reqId: reqId, action: action, params: params) }

        case "error":
            errorText = m["message"] as? String

        default: break
        }
    }

    private static func toolLabel(_ name: String) -> String {
        if name.contains("look") { return "Mirando…" }
        if name.contains("navigate") { return "Calculando ruta…" }
        if name.contains("whatsapp") { return "WhatsApp…" }
        if name.contains("web_search") { return "Buscando en la web…" }
        if name.contains("live") { return "Transmisión…" }
        if name.contains("calendar") { return "Calendario…" }
        if name.contains("visual") { return "Memoria visual…" }
        if name.contains("photo") { return "Foto en máxima calidad…" }
        if name.contains("routine") { return "Rutinas…" }
        return name.isEmpty ? "" : "Trabajando…"
    }

    private func doCapture(reqId: String) async {
        do {
            let data = try await glasses.captureJPEG()
            audio.playTone(.shutter)
            link.send(["type": "capture_result", "reqId": reqId, "imageBase64": data.base64EncodedString()])
        } catch {
            audio.playTone(.error)
            link.send(["type": "capture_result", "reqId": reqId, "error": error.localizedDescription])
        }
    }

    // MARK: Ubicación → servidor

    private func sendLocation(force: Bool) {
        guard link.connected, let snap = location.snapshot(), let loc = location.last else { return }
        let moved = lastLocationCoord.map { loc.distance(from: $0) } ?? .infinity
        guard force || moved > 100 || Date().timeIntervalSince(lastLocationSent) > 90 else { return }
        lastLocationSent = Date()
        lastLocationCoord = loc
        var m = snap
        m["type"] = "location"
        link.send(m)
    }

    // MARK: Acciones de la interfaz

    func pushToTalk() {
        if !micActive { try? audio.start(); speech.start(localeID: Settings.locale); micActive = true }
        if speaker.speaking || state == .thinking { bargeIn() }
        audio.playTone(.wake)
        state = .listening
        userText = ""
        speech.beginCapture(emptyTimeout: 8)
    }

    func testVoice() { speakLocal("Todos los sistemas en línea, señor. Le escucho fuerte y claro.") }

    func testCamera() async -> String? {
        do { _ = try await glasses.captureJPEG(); audio.playTone(.shutter); return nil }
        catch { return error.localizedDescription }
    }

    func startLive(minutes: Int) {
        guard link.connected else { errorText = "Sin conexión con el servidor."; return }
        link.send(["type": "live_start", "ttl": minutes])
    }

    func stopLive() {
        link.send(["type": "live_stop"])
        live.end(glasses: glasses)
    }

    // MARK: Foto en máxima calidad

    /// Foto a resolución completa: se guarda en Fotos y, si hay transmisión, se envía a quien esté mirando.
    private func fullPhoto() async throws -> [String: Any] {
        let raw = try await glasses.captureFullPhoto()
        audio.playTone(.shutter)
        guard let img = UIImage(data: raw) else { throw GlassesError.noFrame }
        UIImageWriteToSavedPhotosAlbum(img, nil, nil, nil)
        glasses.lastPhoto = img
        let width = Int(img.size.width * img.scale)
        let height = Int(img.size.height * img.scale)
        if live.isLive, let jpeg = img.jpegData(compressionQuality: 0.92) {
            var d = Data([0x03])
            d.append(jpeg)
            link.outbox.sendBinary(d, droppable: false)
        }
        return ["width": width, "height": height, "bytes": raw.count, "sharedLive": live.isLive]
    }

    func takeFullPhoto() async -> String? {
        do {
            let r = try await fullPhoto()
            let w = (r["width"] as? Int) ?? 0
            let h = (r["height"] as? Int) ?? 0
            return "Foto guardada en Fotos · \(w)×\(h)"
        } catch {
            audio.playTone(.error)
            return error.localizedDescription
        }
    }

    // MARK: Peticiones del servidor que resuelve el teléfono (calendario, foto)

    private func handleDeviceRequest(reqId: String, action: String, params: [String: Any]) async {
        var reply: [String: Any] = ["type": "device_result", "reqId": reqId]
        do {
            switch action {
            case "calendar_events":
                reply["data"] = try await calendar.events(start: (params["start"] as? String) ?? "",
                                                          days: (params["days"] as? Int) ?? 1)
            case "calendar_add":
                reply["data"] = try await calendar.add(title: (params["title"] as? String) ?? "Evento",
                                                       start: (params["start"] as? String) ?? "",
                                                       end: (params["end"] as? String) ?? "",
                                                       location: (params["location"] as? String) ?? "",
                                                       notes: (params["notes"] as? String) ?? "")
            case "photo_hd":
                reply["data"] = try await fullPhoto()
            default:
                throw NSError(domain: "Jarvis", code: 1, userInfo: [NSLocalizedDescriptionKey: "Acción no soportada: \(action)"])
            }
            reply["ok"] = true
        } catch {
            reply["ok"] = false
            reply["error"] = error.localizedDescription
        }
        link.send(reply)
    }

    // MARK: Modo intérprete

    private func startInterpreter(locale: String) {
        guard micActive else { speakLocal("Necesito la escucha activada para interpretar, señor."); return }
        interpreterLocale = locale
        speech.startInterpreter(localeID: locale)
    }

    func stopInterpreter() {
        guard interpreterLocale != nil else { return }
        interpreterLocale = nil
        speech.stopInterpreter(localeID: Settings.locale)
    }

    private func handleInterpret(_ text: String) {
        guard let loc = interpreterLocale, !speaker.speaking else { return }
        userText = text
        link.send(["type": "interpret", "text": text, "locale": loc])
    }

    /// Dijo "Jarvis" durante el modo intérprete: vuelve al español y escucha su orden.
    private func handleInterpretExit() {
        stopInterpreter()
        audio.playTone(.wake)
        speaker.stop()
        state = .listening
        userText = ""
        assistantText = ""
        speech.beginCapture(emptyTimeout: 8)
    }
}

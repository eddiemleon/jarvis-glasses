import AVFoundation
import Foundation
import Speech
import SwiftUI
import UIKit

enum Phase { case off, idle, capturing, thinking, speaking }

struct FeedItem: Identifiable {
    let id = UUID()
    let date = Date()
    let source: String
    let text: String
}

/// Banderas compartidas con el hilo de audio.
final class Flags: @unchecked Sendable {
    private let lock = NSLock()
    private var _capturing = false
    var capturing: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _capturing }
        set { lock.lock(); _capturing = newValue; lock.unlock() }
    }
}

/// Nivel de audio suavizado para animar el orbe (se lee en cada fotograma, sin republicar estado).
final class LevelMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var inTarget: Float = 0
    private var outTarget: Float = 0
    private var shown: Float = 0

    func pushIn(_ buf: AVAudioPCMBuffer) {
        guard let ch = buf.floatChannelData, buf.frameLength > 0 else { return }
        let n = Int(buf.frameLength)
        var sum: Float = 0
        for i in 0..<n { sum += ch[0][i] * ch[0][i] }
        let rms = (sum / Float(n)).squareRoot()
        lock.lock(); inTarget = max(inTarget, min(1, (rms * 9).squareRoot())); lock.unlock()
    }

    func pushOut(_ v: Float) {
        lock.lock(); outTarget = max(outTarget, v); lock.unlock()
    }

    func read(speaking: Bool) -> Float {
        lock.lock(); defer { lock.unlock() }
        let target = speaking ? outTarget : inTarget
        shown += (target - shown) * (target > shown ? 0.45 : 0.12)
        inTarget *= 0.88
        outTarget *= 0.88
        return shown
    }
}

@MainActor
final class Conductor: ObservableObject {
    @Published var phase: Phase = .off { didSet { if phase == .idle { flushDeferred() } } }
    @Published var caption = "Toca el orbe para despertar a Jarvis"
    @Published var userCaption = ""
    @Published var route = "Sin conexión de audio"
    @Published var glassesConnected = false
    @Published var wakeReady = false
    @Published var serverOnline = false
    @Published var navigating: String?
    @Published var feed: [FeedItem] = []
    @Published var unread = 0
    @Published var lastError: String?
    @Published var boost: Double = Prefs.boostDB {
        didSet { Prefs.boostDB = boost; audio.setBoost(boost) }
    }

    let meter = LevelMeter()
    private let audio = AudioIO()
    private let wake = WakeWord()
    private let capture = SpeechCapture()
    private let brain = Brain()
    private let nav = Navigator()
    private let flags = Flags()
    private let decodeQueue = DispatchQueue(label: "jarvis.decode")

    private var chatTask: Task<Void, Never>?
    private var eventsTask: Task<Void, Never>?
    private var speakGen = 0
    private var pendingItems = 0
    private var streamEnded = true
    private var deferred: [ServerEvent] = []

    private var idleHint: String { wakeReady ? "Di «Jarvis» o toca el orbe" : "Toca el orbe para hablar" }

    init() {
        let wake = self.wake, capture = self.capture, flags = self.flags, meter = self.meter
        audio.onMic = { buf in
            wake.feed(buf)
            if flags.capturing { capture.append(buf) }
            meter.pushIn(buf)
        }
        audio.onOutputLevel = { v in meter.pushOut(v) }
        audio.onRouteChange = { [weak self] in Task { @MainActor in self?.refreshRoute() } }

        wake.onWake = { [weak self] in Task { @MainActor in self?.handleWake() } }
        capture.onPartial = { [weak self] t in Task { @MainActor in self?.userCaption = t } }
        capture.onFinal = { [weak self] t in Task { @MainActor in self?.captureFinished(t) } }

        nav.onSpeak = { [weak self] t in self?.speakLocal(t) }
        nav.onDestinationChange = { [weak self] d in self?.navigating = d }
    }

    // MARK: - Arranque

    func start() async {
        guard phase == .off else { return }
        UIApplication.shared.isIdleTimerDisabled = true

        let micOK = await AVAudioApplication.requestRecordPermission()
        _ = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0 == .authorized) }
        }
        guard micOK else {
            lastError = "Sin permiso de micrófono. Actívalo en Ajustes de iOS."
            caption = "Necesito el micrófono para oírte"
            return
        }

        nav.start()
        do { try audio.start() }
        catch {
            lastError = "No pude iniciar el audio: \(error.localizedDescription)"
            return
        }
        audio.setBoost(boost)
        startWake()
        startEvents()
        refreshRoute()
        phase = .idle
        caption = idleHint
    }

    private func startWake() {
        do {
            try wake.start(accessKey: Prefs.porcupineKey, sensitivity: Prefs.sensitivity)
            wakeReady = true
            lastError = nil
        } catch {
            wakeReady = false
            lastError = error.localizedDescription
        }
        if phase == .idle { caption = idleHint }
    }

    /// Aplica cambios de Ajustes sin reiniciar la app.
    func reloadSettings() {
        guard phase != .off else { return }
        interruptOutput()
        capture.cancel(); flags.capturing = false
        audio.stop()
        do { try audio.start() } catch { lastError = error.localizedDescription }
        audio.setBoost(boost)
        wake.stop()
        startWake()
        startEvents()
        phase = .idle
    }

    func appBecameActive() {
        UIApplication.shared.isIdleTimerDisabled = true
        guard phase != .off else { return }
        if !audio.isRunning { try? audio.start() }
        refreshRoute()
    }

    func refreshRoute() {
        let r = AudioIO.routeSummary()
        route = r.name
        glassesConnected = r.glasses
    }

    // MARK: - Interacción

    func orbTapped() {
        switch phase {
        case .off: Task { await start() }
        case .idle: handleWake()
        case .capturing: capture.finishNow()
        case .thinking, .speaking:
            interruptOutput()
            phase = .idle
            caption = idleHint
        }
    }

    private func handleWake() {
        guard phase != .off, phase != .capturing else { return }
        interruptOutput()
        audio.earcon()
        beginCapture(followUp: false)
    }

    private func beginCapture(followUp: Bool) {
        phase = .capturing
        userCaption = ""
        caption = followUp ? "Te escucho…" : "Dime"
        capture.begin(localeID: Prefs.locale, noSpeechTimeout: followUp ? 5 : 7)
        flags.capturing = true
    }

    private func captureFinished(_ text: String) {
        guard phase == .capturing else { return }
        flags.capturing = false
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty || Self.isStopWord(t) {
            userCaption = ""
            caption = idleHint
            phase = .idle
            return
        }
        ask(t)
    }

    private static func isStopWord(_ s: String) -> Bool {
        let clean = s.lowercased().components(separatedBy: CharacterSet.letters.inverted).joined()
        return ["para", "basta", "silencio", "cancela", "cancelar", "olvidalo", "olvídalo", "nada", "nadaolvidalo", "yanada", "gracias"].contains(clean)
    }

    private func ask(_ text: String) {
        phase = .thinking
        caption = "…"
        userCaption = text
        streamEnded = false
        pendingItems = 0
        speakGen += 1
        let gen = speakGen

        chatTask?.cancel()
        chatTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await ev in self.brain.chat(text: text, context: self.makeContext()) {
                    if Task.isCancelled || gen != self.speakGen { return }
                    self.handle(ev, gen: gen)
                }
                if gen == self.speakGen { self.streamEnded = true; self.maybeFinish() }
            } catch {
                if Task.isCancelled || gen != self.speakGen { return }
                self.streamEnded = true
                self.failTurn(error)
            }
        }
    }

    private func makeContext() -> [String: Any] {
        let f = ISO8601DateFormatter()
        f.timeZone = .current
        f.formatOptions = [.withInternetDateTime]
        var c: [String: Any] = ["time": f.string(from: Date()), "timezone": TimeZone.current.identifier]
        if let l = nav.location {
            c["lat"] = l.coordinate.latitude
            c["lon"] = l.coordinate.longitude
            c["speed"] = max(0, l.speed)
        }
        return c
    }

    // MARK: - Eventos del servidor

    private func handle(_ ev: ServerEvent, gen: Int) {
        switch ev.type {
        case "speech":
            if let t = ev.text { enqueueSpeech(text: t, audio: ev.audio, gen: gen) }
        case "action":
            runAction(ev.name ?? "", ev.args)
        case "done":
            streamEnded = true
            maybeFinish()
        case "error":
            streamEnded = true
            failTurn(BrainError.http(500), detail: ev.message)
        default:
            break
        }
    }

    private func runAction(_ name: String, _ args: [String: Any]) {
        switch name {
        case "navigate":
            if let d = args["destination"] as? String { nav.navigate(to: d, mode: args["mode"] as? String ?? "auto") }
        case "stop_navigation":
            nav.stop(silent: true)
        case "set_boost":
            if let db = (args["db"] as? NSNumber)?.doubleValue { boost = max(0, min(20, db)) }
        default:
            break
        }
    }

    private func failTurn(_ error: Error, detail: String? = nil) {
        lastError = detail ?? error.localizedDescription
        speakLocal("No pude hablar con mi cerebro. Revisa la conexión del servidor.")
        if pendingItems == 0 { phase = .idle; caption = idleHint }
    }

    // MARK: - Voz

    private func enqueueSpeech(text: String, audio b64: String?, gen: Int) {
        guard gen == speakGen else { return }
        phase = .speaking
        caption = text
        pendingItems += 1
        decodeQueue.async { [weak self] in
            var buf = b64.flatMap { AudioIO.decode(base64: $0) }
            if buf == nil { buf = LocalVoice.blockingSynthesize(text) }   // respaldo: voz del sistema
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.playItem(buf, gen: gen) }
            }
        }
    }

    private func playItem(_ buf: AVAudioPCMBuffer?, gen: Int) {
        guard gen == speakGen else { return }
        guard let buf else { itemDone(gen); return }
        audio.schedule(buf) { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.itemDone(gen) }
            }
        }
    }

    private func itemDone(_ gen: Int) {
        guard gen == speakGen else { return }
        pendingItems = max(0, pendingItems - 1)
        maybeFinish()
    }

    private func maybeFinish() {
        guard streamEnded, pendingItems == 0 else { return }
        if phase == .speaking {
            userCaption = ""
            if Prefs.followUp {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    MainActor.assumeIsolated { [weak self] in
                        guard let self, self.phase == .speaking, self.streamEnded, self.pendingItems == 0 else { return }
                        self.beginCapture(followUp: true)
                    }
                }
            } else {
                phase = .idle
                caption = idleHint
            }
        } else if phase == .thinking {
            phase = .idle
            caption = idleHint
        }
    }

    private func interruptOutput() {
        speakGen += 1
        pendingItems = 0
        streamEnded = true
        chatTask?.cancel()
        audio.stopPlayback()
        LocalVoice.shared.stop()
    }

    /// Voz suelta (navegación, errores) que no altera el estado de la conversación.
    private func speakLocal(_ text: String) {
        decodeQueue.async { [weak self] in
            guard let buf = LocalVoice.blockingSynthesize(text) else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.audio.schedule(buf) {} }
            }
        }
    }

    private func playStandalone(_ ev: ServerEvent) {
        guard let text = ev.text else { return }
        decodeQueue.async { [weak self] in
            var buf = ev.audio.flatMap { AudioIO.decode(base64: $0) }
            if buf == nil { buf = LocalVoice.blockingSynthesize(text) }
            guard let buf else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.audio.schedule(buf) {} }
            }
        }
    }

    // MARK: - Alertas (TradingView, WhatsApp…)

    private func startEvents() {
        eventsTask?.cancel()
        eventsTask = Task { [weak self] in
            var delay: UInt64 = 1
            while !Task.isCancelled {
                guard let self else { return }
                do {
                    for try await ev in self.brain.alerts() {
                        self.serverOnline = true
                        delay = 1
                        self.handleAlert(ev)
                    }
                } catch {
                    // reconecta abajo
                }
                self.serverOnline = false
                try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
                delay = min(delay * 2, 30)
            }
        }
    }

    private func handleAlert(_ ev: ServerEvent) {
        guard ev.type == "alert", let text = ev.text else { return }
        feed.insert(FeedItem(source: ev.source ?? "alerta", text: text), at: 0)
        if feed.count > 50 { feed.removeLast() }
        unread += 1
        if phase == .capturing { deferred.append(ev) } else { playStandalone(ev) }
    }

    private func flushDeferred() {
        guard !deferred.isEmpty else { return }
        let items = deferred
        deferred.removeAll()
        items.forEach { playStandalone($0) }
    }

    func stopNavigation() { nav.stop(silent: false) }

    // MARK: - Ajustes: pruebas

    func testServer() async -> String { await brain.health() }
    func testAlert() async -> String { await brain.testAlert() }
}

import AVFoundation
import AudioToolbox
import MediaPlayer
import UIKit

/// Un solo AVAudioEngine para todo: micrófono de las gafas (Bluetooth HFP) → reconocimiento,
/// y voz de Jarvis → limitador con ganancia → parlantes de las gafas.
final class AudioIO: NSObject {
    static let playFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24000, channels: 1, interleaved: false)!

    let engine = AVAudioEngine()
    let player = AVAudioPlayerNode()
    private let limiter: AVAudioUnitEffect
    private var tapInstalled = false

    /// Llamado en el hilo de audio con cada buffer del micrófono.
    var onMicBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)?
    /// Niveles 0...1 (hilo de audio).
    var onMicLevel: (@Sendable (Float) -> Void)?
    var onOutLevel: (@Sendable (Float) -> Void)?
    /// Cambió la ruta o hubo una interrupción: el dueño debe reaccionar (p. ej. reiniciar el reconocimiento).
    var onRouteChanged: (@Sendable () -> Void)?

    /// MODO MÚSICA: mientras otra app reproduce audio (YouTube en Brave, etc.), Jarvis NO pone las gafas en
    /// "modo llamada" (HFP). Así la música o el video no se pausa ni baja de calidad; Jarvis escucha por el
    /// micrófono del iPhone y vuelve solo al micrófono de las gafas cuando la música lleva un rato detenida.
    private(set) var musicMode = false
    private var running = false
    /// Opciones con las que quedó configurada la sesión: no se vuelve a tocar si no cambian
    /// (reconfigurarla corta por un instante el audio de las demás apps).
    private var sessionOptions: AVAudioSession.CategoryOptions?
    private var lastRebuild = Date.distantPast
    private var rebuildPending = false
    private var musicTimer: DispatchSourceTimer?
    /// Diagnóstico del micrófono: cuándo se pidió y cuánto tardó en quedar en las gafas.
    private var askedAt: Date?
    private(set) var connectSeconds: Double?
    private(set) var retries = 0

    override init() {
        let desc = AudioComponentDescription(
            componentType: kAudioUnitType_Effect,
            componentSubType: kAudioUnitSubType_PeakLimiter,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0)
        limiter = AVAudioUnitEffect(audioComponentDescription: desc)
        super.init()
        engine.attach(player)
        engine.attach(limiter)
        engine.connect(player, to: limiter, format: Self.playFormat)
        engine.connect(limiter, to: engine.mainMixerNode, format: Self.playFormat)
        setBoost(dB: Settings.boostDB)

        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(routeChanged(_:)), name: AVAudioSession.routeChangeNotification, object: nil)
        nc.addObserver(self, selector: #selector(interruption(_:)), name: AVAudioSession.interruptionNotification, object: nil)
        nc.addObserver(self, selector: #selector(engineConfigChanged), name: .AVAudioEngineConfigurationChange, object: engine)
        nc.addObserver(self, selector: #selector(mediaReset), name: AVAudioSession.mediaServicesWereResetNotification, object: nil)

        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + 2, repeating: 2)
        t.setEventHandler { [weak self] in self?.checkOtherAudio() }
        t.resume()
        musicTimer = t
    }

    /// Modo FIJO (sin cambios automáticos): el micrófono queda activo siempre en el mismo dispositivo.
    /// Solo cambia si el usuario mueve el interruptor en Ajustes.
    private func checkOtherAudio() {
        guard running else { return }
        ensureGlassesMic()
        let want = Settings.musicFirst
        guard want != musicMode, !player.isPlaying else { return }
        rebuild(resetSession: true)   // start() aplica el modo nuevo
    }

    // MARK: Sesión

    func configureSession(force: Bool = false) throws {
        let s = AVAudioSession.sharedInstance()
        musicMode = Settings.musicFirst
        // Con música: sin HFP; las gafas siguen en alta calidad (A2DP) y la otra app no se interrumpe (micrófono del iPhone).
        // Sin música: .allowBluetooth = perfil HFP, único modo en que iOS usa el micrófono de las gafas.
        let opts: AVAudioSession.CategoryOptions = musicMode
            ? [.allowBluetoothA2DP, .defaultToSpeaker, .mixWithOthers]
            : [.allowBluetooth, .defaultToSpeaker, .mixWithOthers]
        if !force, sessionOptions == opts { return }   // ya está: no tocarla
        try s.setCategory(.playAndRecord, mode: .default, options: opts)
        try s.setActive(true, options: [])
        sessionOptions = opts
        askedAt = Date(); connectSeconds = nil
        preferGlassesInput()
    }

    /// Prefiere el micrófono Bluetooth de las gafas (si hay varios, el que diga Meta / Ray-Ban).
    func preferGlassesInput() {
        if musicMode { return }
        let s = AVAudioSession.sharedInstance()
        let hfp = (s.availableInputs ?? []).filter { $0.portType == .bluetoothHFP }
        let pick = hfp.first { $0.portName.localizedCaseInsensitiveContains("ray-ban") || $0.portName.localizedCaseInsensitiveContains("meta") } ?? hfp.first
        // Solo si hace falta: pedirlo de nuevo provoca otro cambio de ruta (y un corte de audio).
        if let pick, s.currentRoute.inputs.first?.uid != pick.uid { try? s.setPreferredInput(pick) }
    }

    /// Vigilante (cada 2 s): si las gafas están disponibles y el micrófono no está en ellas, lo vuelve a pedir.
    /// Así nunca se queda pegado en el micrófono del iPhone.
    private func ensureGlassesMic() {
        guard !musicMode else { return }
        if usingBluetoothMic {
            if connectSeconds == nil, let a = askedAt { connectSeconds = Date().timeIntervalSince(a); onRouteChanged?() }
            return
        }
        let s = AVAudioSession.sharedInstance()
        guard (s.availableInputs ?? []).contains(where: { $0.portType == .bluetoothHFP }) else { return }
        retries += 1
        preferGlassesInput()
        onRouteChanged?()
    }

    /// Una línea con los hechos (para una captura): entrada, salida, gafas disponibles, tiempo de conexión.
    var diagnostic: String {
        let s = AVAudioSession.sharedInstance()
        let inp = s.currentRoute.inputs.first.map { "\($0.portName) [\($0.portType.rawValue)]" } ?? "—"
        let out = s.currentRoute.outputs.first.map { "\($0.portName) [\($0.portType.rawValue)]" } ?? "—"
        let hfp = (s.availableInputs ?? []).filter { $0.portType == .bluetoothHFP }.map(\.portName)
        var t = "Mic: \(inp) · Sale: \(out) · Gafas disponibles: \(hfp.isEmpty ? "ninguna" : hfp.joined(separator: ", "))"
        t += " · Modo: \(musicMode ? "música (mic iPhone)" : "gafas") · \(Int(s.sampleRate)) Hz"
        if let c = connectSeconds { t += String(format: " · conectó en %.1f s", c) }
        if retries > 0 { t += " · reintentos \(retries)" }
        return t
    }

    var inputName: String { AVAudioSession.sharedInstance().currentRoute.inputs.first?.portName ?? "—" }
    var outputName: String { AVAudioSession.sharedInstance().currentRoute.outputs.first?.portName ?? "—" }
    var usingBluetoothMic: Bool { AVAudioSession.sharedInstance().currentRoute.inputs.contains { $0.portType == .bluetoothHFP } }

    // MARK: Motor

    func start() throws {
        running = true
        try configureSession()
        if !tapInstalled {
            let input = engine.inputNode
            input.installTap(onBus: 0, bufferSize: 2048, format: nil) { [weak self] buffer, _ in
                guard let self else { return }
                self.onMicBuffer?(buffer)
                self.onMicLevel?(Self.rms(buffer))
            }
            tapInstalled = true
            // Nivel de salida (para animar el orbe mientras habla).
            player.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buffer, _ in
                self?.onOutLevel?(Self.rms(buffer))
            }
        }
        if !engine.isRunning {
            engine.prepare()
            try engine.start()
        }
    }

    /// Reinicia el motor de audio. Peticiones seguidas se juntan en una sola y nunca más de una cada 2 s:
    /// cada reinicio corta un instante el audio de las demás apps.
    func rebuild(resetSession: Bool = false) {
        if resetSession { sessionOptions = nil }
        guard running, !rebuildPending else { return }
        rebuildPending = true
        let wait = max(0.3, 2.0 - Date().timeIntervalSince(lastRebuild))
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
            guard let self else { return }
            self.rebuildPending = false
            guard self.running else { return }
            self.lastRebuild = Date()
            if self.tapInstalled {
                self.engine.inputNode.removeTap(onBus: 0)
                self.player.removeTap(onBus: 0)
                self.tapInstalled = false
            }
            self.engine.stop()
            try? self.start()
            self.onRouteChanged?()
        }
    }

    func stop() {
        running = false
        sessionOptions = nil
        player.stop()
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            player.removeTap(onBus: 0)
            tapInstalled = false
        }
        engine.stop()
    }

    // MARK: Reproducción

    /// Refuerzo de volumen en dB (el limitador evita la distorsión).
    func setBoost(dB: Float) {
        let clamped = max(0, min(24, dB))
        AudioUnitSetParameter(limiter.audioUnit, AudioUnitParameterID(kLimiterParam_PreGain), kAudioUnitScope_Global, 0, clamped, 0)
    }

    func schedule(_ buffer: AVAudioPCMBuffer, completion: (@Sendable () -> Void)? = nil) {
        if !engine.isRunning { try? start() }
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { _ in completion?() }
        if !player.isPlaying { player.play() }
    }

    func stopPlayback() {
        player.stop()
    }

    /// Tonos cortos (confirmación de "Jarvis", foto, alerta) generados en código.
    func playTone(_ kind: Tone) {
        let sr = Self.playFormat.sampleRate
        var samples: [Float] = []
        func add(freq: Double, ms: Double, amp: Float) {
            let n = Int(sr * ms / 1000)
            for i in 0..<n {
                let t = Double(i) / sr
                let env = Float(min(1, Double(i) / (sr * 0.008))) * Float(min(1, Double(n - i) / (sr * 0.02)))
                samples.append(Float(sin(2 * .pi * freq * t)) * amp * env)
            }
        }
        switch kind {
        case .wake: add(freq: 880, ms: 70, amp: 0.55); add(freq: 1320, ms: 90, amp: 0.55)
        case .shutter: add(freq: 2400, ms: 25, amp: 0.5); add(freq: 1200, ms: 45, amp: 0.45)
        case .alert: add(freq: 1000, ms: 90, amp: 0.6); add(freq: 750, ms: 90, amp: 0.6); add(freq: 1000, ms: 110, amp: 0.6)
        case .error: add(freq: 300, ms: 160, amp: 0.55)
        }
        guard let buf = AVAudioPCMBuffer(pcmFormat: Self.playFormat, frameCapacity: AVAudioFrameCount(samples.count)) else { return }
        buf.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            buf.floatChannelData![0].update(from: src.baseAddress!, count: samples.count)
        }
        schedule(buf)
    }

    enum Tone { case wake, shutter, alert, error }

    // MARK: Utilidades

    static func rms(_ buffer: AVAudioPCMBuffer) -> Float {
        let n = Int(buffer.frameLength)
        guard n > 0 else { return 0 }
        var sum: Float = 0
        if let ch = buffer.floatChannelData {
            let p = ch[0]
            for i in 0..<n { sum += p[i] * p[i] }
        } else if let ch = buffer.int16ChannelData {
            let p = ch[0]
            for i in 0..<n { let v = Float(p[i]) / 32768; sum += v * v }
        } else { return 0 }
        let r = (sum / Float(n)).squareRoot()
        return min(1, r * 6)
    }

    /// Convierte cualquier buffer al formato de reproducción común.
    final class Converter {
        private var conv: AVAudioConverter?
        func convert(_ buf: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
            let dst = AudioIO.playFormat
            if buf.format == dst { return buf }
            if conv == nil { conv = AVAudioConverter(from: buf.format, to: dst) }
            guard let conv else { return nil }
            let cap = AVAudioFrameCount(Double(buf.frameLength) * dst.sampleRate / buf.format.sampleRate) + 2048
            guard let out = AVAudioPCMBuffer(pcmFormat: dst, frameCapacity: cap) else { return nil }
            var supplied = false
            var err: NSError?
            conv.convert(to: out, error: &err) { _, status in
                if supplied { status.pointee = .noDataNow; return nil }
                supplied = true
                status.pointee = .haveData
                return buf
            }
            return err == nil ? out : nil
        }
    }

    // MARK: Notificaciones

    @objc private func routeChanged(_ n: Notification) {
        // Solo interesa cuando se conecta o desconecta un dispositivo (las gafas). Los demás avisos los
        // provoca la propia app al configurar el audio y reaccionar a ellos crearía un bucle.
        let raw = n.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt ?? 0
        let reason = AVAudioSession.RouteChangeReason(rawValue: raw) ?? .unknown
        guard reason == .newDeviceAvailable || reason == .oldDeviceUnavailable else {
            // Otros cambios (p. ej. cuando el micrófono pasa a las gafas): solo se actualiza la pantalla.
            DispatchQueue.main.async { [weak self] in self?.onRouteChanged?() }
            return
        }
        DispatchQueue.main.async { [weak self] in
            self?.preferGlassesInput()
            self?.onRouteChanged?()
        }
    }
    @objc private func interruption(_ n: Notification) {
        guard let raw = n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        if type == .ended { DispatchQueue.main.async { [weak self] in self?.rebuild(resetSession: true) } }
    }
    @objc private func engineConfigChanged() {
        // Al conectarse/desconectarse el Bluetooth cambia el formato de entrada: hay que reinstalar el tap.
        DispatchQueue.main.async { [weak self] in self?.rebuild() }
    }
    @objc private func mediaReset() {
        DispatchQueue.main.async { [weak self] in self?.rebuild(resetSession: true) }
    }
}

/// Sube el volumen del sistema (ruta actual) usando un MPVolumeView invisible.
struct SystemVolume {
    static func set(_ level: Float) {
        DispatchQueue.main.async {
            guard let window = UIApplication.shared.connectedScenes
                .compactMap({ ($0 as? UIWindowScene)?.windows.first }).first else { return }
            let v = MPVolumeView(frame: CGRect(x: -2000, y: -2000, width: 10, height: 10))
            window.addSubview(v)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                (v.subviews.first { $0 is UISlider } as? UISlider)?.value = max(0, min(1, level))
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { v.removeFromSuperview() }
            }
        }
    }
}

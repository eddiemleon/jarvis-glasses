import Foundation
import Speech
import AVFoundation

/// Escucha continua (en el iPhone, por defecto sin enviar audio a ningún servidor) con dos usos:
///  1. Detecta la palabra "Jarvis" y captura lo que dices después, en la misma pasada de reconocimiento.
///  2. Modo conversación: captura una frase sin necesidad de decir "Jarvis" (seguimiento / botón).
final class SpeechListener: @unchecked Sendable {
    enum Mode { case wake, capture(fromWake: Bool), paused, interpret }

    // Callbacks (siempre en el hilo principal)
    var onWake: (@Sendable (String) -> Void)?
    var onPartial: (@Sendable (String) -> Void)?
    var onCommand: (@Sendable (String) -> Void)?
    var onCaptureTimeout: (@Sendable () -> Void)?
    var onStatus: (@Sendable (String) -> Void)?
    /// Modo intérprete: cada frase de la otra persona (en su idioma) y la salida al oír "Jarvis".
    var onInterpret: (@Sendable (String) -> Void)?
    var onInterpretExit: (@Sendable () -> Void)?
    /// Usted habla mientras Jarvis habla: se calla y lo escucha (la prioridad es suya).
    var onBargeIn: (@Sendable (String) -> Void)?

    private let queue = DispatchQueue(label: "jarvis.speech")
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var recognizer: SFSpeechRecognizer?
    private var mode: Mode = .wake
    private var taskStarted = Date()
    private var captureStarted = Date()
    private var lastText = ""
    private var lastChange = Date()
    private var timer: DispatchSourceTimer?
    private var failures = 0
    private var forceServer = false
    private var running = false
    // Interrupción por voz mientras Jarvis habla
    private var bargeOn = false
    private var bargeBase = 0
    private var wordCount = 0
    private var echoWords = Set<String>()
    private var captureOffset = 0

    // Tiempos (segundos)
    var endSilence: TimeInterval = 0.75   // como una llamada: responde apenas usted termina (antes 1.15 s)
    var emptyTimeoutWake: TimeInterval = 6
    var emptyTimeoutFollowUp: TimeInterval = 7
    var maxCapture: TimeInterval = 40
    var refreshAge: TimeInterval = 50

    // MARK: Permisos

    static func requestPermissions(_ done: @escaping (Bool) -> Void) {
        SFSpeechRecognizer.requestAuthorization { speech in
            AVAudioApplication.requestRecordPermission { mic in
                DispatchQueue.main.async { done(speech == .authorized && mic) }
            }
        }
    }

    // MARK: Ciclo de vida

    func start(localeID: String) {
        queue.async {
            self.recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeID)) ?? SFSpeechRecognizer()
            self.recognizer?.defaultTaskHint = .dictation
            self.running = true
            self.mode = .wake
            self.startTask()
            self.startTimer()
        }
    }

    func stop() {
        queue.async {
            self.running = false
            self.timer?.cancel(); self.timer = nil
            self.stopTask()
        }
    }

    /// Llamado desde el hilo de audio con cada buffer del micrófono.
    func feed(_ buffer: AVAudioPCMBuffer) {
        lock.lock(); let r = request; lock.unlock()
        r?.append(buffer)
    }

    // MARK: Control externo

    /// Captura una frase sin palabra de activación (seguimiento tras una respuesta, botón, "Hey Meta, abre Jarvis").
    func beginCapture(emptyTimeout: TimeInterval? = nil) {
        queue.async {
            guard self.running else { return }
            if let t = emptyTimeout { self.emptyTimeoutFollowUp = t }
            self.mode = .capture(fromWake: false)
            self.captureStarted = Date()
            self.lastText = ""
            self.lastChange = Date()
            self.startTask() // reconocimiento limpio: sin eco de lo que acaba de decir Jarvis
        }
    }

    func resumeWake() {
        queue.async {
            guard self.running else { return }
            self.mode = .wake
            self.startTask()
        }
    }

    func pause() {
        queue.async {
            self.mode = .paused
            self.stopTask()
        }
    }

    // MARK: Modo intérprete

    /// Escucha en el idioma de la otra persona y entrega cada frase completa. "Jarvis" sale del modo.
    func startInterpreter(localeID: String) {
        queue.async {
            guard self.running else { return }
            if let r = SFSpeechRecognizer(locale: Locale(identifier: localeID)) {
                r.defaultTaskHint = .dictation
                self.recognizer = r
            }
            self.mode = .interpret
            self.captureStarted = Date()
            self.startTask()
        }
    }

    /// Vuelve al idioma normal y a esperar "Jarvis".
    func stopInterpreter(localeID: String) {
        queue.async {
            self.recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeID)) ?? SFSpeechRecognizer()
            self.recognizer?.defaultTaskHint = .dictation
            if case .interpret = self.mode { self.mode = .wake }
            if self.running { self.startTask() }
        }
    }

    /// Descarta lo oído hasta ahora (p. ej. la propia voz de Jarvis diciendo la traducción).
    func flush() {
        queue.async {
            guard self.running, case .interpret = self.mode else { return }
            self.startTask()
        }
    }

    // MARK: Reconocimiento

    private func startTask() {
        stopTask()
        wordCount = 0; bargeBase = 0; captureOffset = 0
        guard running, let rec = recognizer, rec.isAvailable else {
            queue.asyncAfter(deadline: .now() + 2) { [weak self] in if self?.running == true, self?.task == nil { self?.startTask() } }
            return
        }
        if case .paused = mode { return }
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.taskHint = .dictation
        req.addsPunctuation = false
        req.contextualStrings = ["Jarvis", "Hey Jarvis", "oye Jarvis", "TradingView", "WhatsApp", "oro", "XAUUSD"]
        req.requiresOnDeviceRecognition = rec.supportsOnDeviceRecognition && !forceServer
        lock.lock(); request = req; lock.unlock()
        taskStarted = Date()
        lastText = ""
        lastChange = Date()
        task = rec.recognitionTask(with: req) { [weak self] result, error in
            self?.queue.async { self?.handle(result: result, error: error, for: req) }
        }
    }

    private func stopTask() {
        lock.lock(); let r = request; request = nil; lock.unlock()
        r?.endAudio()
        task?.cancel()
        task = nil
    }

    private func handle(result: SFSpeechRecognitionResult?, error: Error?, for req: SFSpeechAudioBufferRecognitionRequest) {
        lock.lock(); let current = request; lock.unlock()
        guard req === current else { return } // resultado de una tarea vieja
        if let result {
            failures = 0
            let segs = result.bestTranscription.segments.map { $0.substring }
            process(words: segs)
            if result.isFinal { restartSoon() }
        } else if error != nil {
            failures += 1
            if failures >= 3 && !forceServer { forceServer = true; onStatus?("Reconocimiento en servidor de Apple") }
            restartSoon(delay: min(3, 0.3 * Double(failures)))
        }
    }

    private func restartSoon(delay: TimeInterval = 0.15) {
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.running else { return }
            if case .paused = self.mode { return }
            self.startTask()
        }
    }

    /// Activa/desactiva la interrupción por voz. `echo` es lo que Jarvis está diciendo (para no confundir su propia voz con la suya).
    func setBargeIn(_ on: Bool, echo: String = "") {
        let ws = Self.echoSet(echo)
        queue.async { [weak self] in
            guard let self else { return }
            if on && !self.bargeOn { self.bargeBase = self.wordCount }
            self.bargeOn = on
            self.echoWords = ws
        }
    }

    /// true si lo oído es la propia voz de Jarvis (la mayoría de las palabras están en lo que él dice).
    private func isEcho(_ words: [String]) -> Bool { Self.isEcho(words, echo: echoWords) }

    static func isEcho(_ words: [String], echo: Set<String>) -> Bool {
        let ws = words.map { normalize($0) }.filter { !$0.isEmpty }
        guard !ws.isEmpty, !echo.isEmpty else { return false }
        let hits = ws.filter { echo.contains($0) }.count
        return Double(hits) / Double(ws.count) >= 0.6
    }

    /// ¿Lo nuevo que se oyó mientras Jarvis habla es usted interrumpiéndolo?
    static func isBargeIn(_ nuevas: [String], echo: Set<String>) -> Bool {
        let alto = ["para", "basta", "callate", "silencio", "detente", "espera", "alto", "no"].contains(normalize(nuevas.last ?? ""))
        return (nuevas.count >= 2 || alto) && lastWake(in: nuevas) == nil && !isEcho(nuevas, echo: echo)
    }

    static func echoSet(_ text: String) -> Set<String> {
        Set(text.split(whereSeparator: { !$0.isLetter }).map { normalize(String($0)) }.filter { !$0.isEmpty })
    }

    private func process(words: [String]) {
        wordCount = words.count
        switch mode {
        case .paused:
            return
        case .wake:
            if bargeOn, words.count > bargeBase {
                let nuevas = Array(words.dropFirst(bargeBase))
                // Dos palabras o más que no son el eco de Jarvis: usted lo está interrumpiendo.
                if Self.isBargeIn(nuevas, echo: echoWords) {
                    bargeOn = false
                    mode = .capture(fromWake: false)
                    captureStarted = Date()
                    lastText = ""
                    lastChange = Date()
                    let t = nuevas.joined(separator: " ")
                    DispatchQueue.main.async { self.onBargeIn?(t) }
                    // a partir de aquí cuenta solo lo que usted dice desde la interrupción
                    bargeBase = 0
                    updateCapture(t)
                    captureOffset = words.count - nuevas.count
                    return
                }
            }
            if let (idx, used) = Self.lastWake(in: words) {
                mode = .capture(fromWake: true)
                captureStarted = Date()
                lastText = ""
                lastChange = Date()
                let after = Array(words.dropFirst(idx + used)).joined(separator: " ")
                DispatchQueue.main.async { self.onWake?(after) }
                updateCapture(after)
            }
        case .capture(let fromWake):
            if fromWake {
                if let (idx, used) = Self.lastWake(in: words) {
                    updateCapture(Array(words.dropFirst(idx + used)).joined(separator: " "))
                }
            } else {
                updateCapture(Array(words.dropFirst(min(captureOffset, words.count))).joined(separator: " "))
            }
        case .interpret:
            if Self.lastWake(in: words) != nil {
                mode = .wake
                lastText = ""
                DispatchQueue.main.async { self.onInterpretExit?() }
                return
            }
            updateCapture(words.joined(separator: " "))
        }
    }

    private func updateCapture(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespaces)
        if t != lastText {
            lastText = t
            lastChange = Date()
            DispatchQueue.main.async { self.onPartial?(t) }
        }
    }

    // MARK: Temporizador (silencio, tiempos máximos, refresco)

    private func startTimer() {
        timer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 0.2, repeating: 0.2)
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    private func tick() {
        let now = Date()
        switch mode {
        case .paused:
            return
        case .wake:
            // El reconocimiento de Apple tiene límite de duración: se reinicia en un momento tranquilo.
            if now.timeIntervalSince(taskStarted) > refreshAge, now.timeIntervalSince(lastChange) > 1.5 { startTask() }
        case .capture(let fromWake):
            let silent = now.timeIntervalSince(lastChange)
            if !lastText.isEmpty {
                if silent >= endSilence || now.timeIntervalSince(captureStarted) > maxCapture { finish(with: lastText) }
            } else {
                let limit = fromWake ? emptyTimeoutWake : emptyTimeoutFollowUp
                if now.timeIntervalSince(captureStarted) > limit {
                    mode = .wake
                    startTask()
                    DispatchQueue.main.async { self.onCaptureTimeout?() }
                }
            }
        case .interpret:
            let silent = now.timeIntervalSince(lastChange)
            if !lastText.isEmpty {
                // Frase terminada (pausa corta) o muy larga: se manda a traducir y se sigue escuchando.
                if silent >= 0.9 || now.timeIntervalSince(captureStarted) > 20 {
                    let phrase = lastText
                    startTask()
                    captureStarted = now
                    DispatchQueue.main.async { self.onInterpret?(phrase) }
                }
            } else {
                captureStarted = now
                if now.timeIntervalSince(taskStarted) > refreshAge, silent > 1.5 { startTask() }
            }
        }
    }

    private func finish(with text: String) {
        mode = .wake
        startTask() // limpia el buffer; sigue escuchando "Jarvis" para poder interrumpir
        DispatchQueue.main.async { self.onCommand?(text) }
    }

    // MARK: Detección de "Jarvis"

    static func normalize(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
            .filter { $0.isLetter }
    }

    private static let variants: Set<String> = [
        "jarvis", "yarvis", "jarvi", "harvis", "garvis", "yarbis", "jarbis", "charvis", "jarvys", "jarvice", "yarvi", "jarviz",
    ]

    static func isJarvis(_ token: String) -> Bool {
        if variants.contains(token) { return true }
        if token.hasPrefix("jarvis") || token.hasPrefix("yarvis") { return true }
        guard token.count >= 5, token.count <= 7 else { return false }
        return levenshtein(token, "jarvis") <= 1 && token.first != "m" && token.first != "c" && token.first != "s"
    }

    /// Último "Jarvis" en la transcripción: (índice, cuántas palabras ocupa). Cubre "jar vis" partido en dos.
    static func lastWake(in words: [String]) -> (Int, Int)? {
        let n = words.map { normalize($0) }
        var i = n.count - 1
        while i >= 0 {
            if isJarvis(n[i]) { return (i, 1) }
            if i + 1 < n.count, isJarvis(n[i] + n[i + 1]) { return (i, 2) }
            i -= 1
        }
        return nil
    }

    static func levenshtein(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0...b.count)
        for i in 1...a.count {
            var cur = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            prev = cur
        }
        return prev[b.count]
    }
}

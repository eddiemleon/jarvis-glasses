import AVFoundation

/// Voz de Jarvis. Convierte cada frase a audio (voz de iOS, o ElevenLabs si el servidor la tiene),
/// la pasa por el limitador con ganancia y la reproduce en los parlantes de las gafas.
/// Las frases se sintetizan por adelantado mientras suena la anterior: no hay silencios entre frases.
@MainActor
final class Speaker {
    private let audio: AudioIO
    private struct Item { let text: String; let render: Task<[AVAudioPCMBuffer], Never> }
    private var queue: [Item] = []
    private var worker: Task<Void, Never>?
    private(set) var speaking = false

    /// true cuando empieza a hablar, false cuando termina todo lo encolado.
    var onSpeakingChanged: ((Bool) -> Void)?
    /// El servidor ofrece voz neuronal (ElevenLabs).
    var remoteTTSAvailable = false

    init(audio: AudioIO) { self.audio = audio }

    var isIdle: Bool { queue.isEmpty && !speaking }

    func enqueue(_ text: String) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        let remote = remoteTTSAvailable
        let task = Task.detached(priority: .userInitiated) { () -> [AVAudioPCMBuffer] in
            if remote, let r = await Speaker.renderRemote(clean), !r.isEmpty { return r }
            return await Speaker.renderSystem(clean)
        }
        queue.append(Item(text: clean, render: task))
        startWorker()
    }

    func stop() {
        queue.forEach { $0.render.cancel() }
        queue.removeAll()
        worker?.cancel()
        worker = nil
        audio.stopPlayback()
        if speaking { speaking = false; onSpeakingChanged?(false) }
    }

    // MARK: Cola de reproducción

    private func startWorker() {
        guard worker == nil else { return }
        if !speaking { speaking = true; onSpeakingChanged?(true) }
        if Settings.maxSystemVolume { SystemVolume.set(1.0) }
        audio.setBoost(dB: Settings.boostDB)
        worker = Task { [weak self] in
            while let self, !Task.isCancelled, !self.queue.isEmpty {
                let item = self.queue.removeFirst()
                let buffers = await item.render.value
                if Task.isCancelled { break }
                if buffers.isEmpty {
                    await Speaker.speakDirect(item.text) // plan B: voz del sistema, sin refuerzo
                } else {
                    await self.play(buffers)
                }
            }
            guard let self, !Task.isCancelled else { return }
            self.worker = nil
            self.speaking = false
            self.onSpeakingChanged?(false)
        }
    }

    private func play(_ buffers: [AVAudioPCMBuffer]) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let once = Once()
            let seconds = buffers.reduce(0.0) { $0 + Double($1.frameLength) / $1.format.sampleRate }
            for (i, b) in buffers.enumerated() {
                if i == buffers.count - 1 {
                    audio.schedule(b) { if once.fire() { cont.resume() } }
                } else {
                    audio.schedule(b)
                }
            }
            // Seguro por si el motor se detiene y nunca llama al completion.
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds + 3) { if once.fire() { cont.resume() } }
        }
    }

    // MARK: Voces

    /// Voces en español ordenadas por calidad (premium > mejorada > normal), prefiriendo el idioma elegido.
    nonisolated static func spanishVoices() -> [AVSpeechSynthesisVoice] {
        let pref = Settings.locale
        return AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("es") }
            .sorted { a, b in
                if a.quality.rawValue != b.quality.rawValue { return a.quality.rawValue > b.quality.rawValue }
                return (a.language == pref ? 1 : 0) > (b.language == pref ? 1 : 0)
            }
    }

    nonisolated private static func chosenVoice() -> AVSpeechSynthesisVoice? {
        let id = Settings.voiceID
        if !id.isEmpty, let v = AVSpeechSynthesisVoice(identifier: id) { return v }
        return spanishVoices().first ?? AVSpeechSynthesisVoice(language: Settings.locale)
    }

    nonisolated private static func makeUtterance(_ text: String) -> AVSpeechUtterance {
        let u = AVSpeechUtterance(string: text)
        u.voice = chosenVoice()
        u.rate = max(AVSpeechUtteranceMinimumSpeechRate, min(AVSpeechUtteranceMaximumSpeechRate, Settings.speechRate))
        u.pitchMultiplier = 0.9 // un poco más grave
        u.volume = 1
        return u
    }

    // MARK: Síntesis (fuera del hilo principal)

    private final class SynthBox: @unchecked Sendable { var synth: AVSpeechSynthesizer? }

    nonisolated private static func renderSystem(_ text: String) async -> [AVAudioPCMBuffer] {
        await withCheckedContinuation { (cont: CheckedContinuation<[AVAudioPCMBuffer], Never>) in
            let box = SynthBox()
            let synth = AVSpeechSynthesizer()
            box.synth = synth
            let once = Once()
            let converter = AudioIO.Converter()
            var out: [AVAudioPCMBuffer] = []
            synth.write(makeUtterance(text)) { buffer in
                guard let pcm = buffer as? AVAudioPCMBuffer else { return }
                if pcm.frameLength == 0 {
                    if once.fire() { box.synth = nil; cont.resume(returning: out) }
                    return
                }
                if let c = converter.convert(pcm) { out.append(c) }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 20) {
                if once.fire() { box.synth = nil; cont.resume(returning: out) }
            }
        }
    }

    nonisolated private static func renderRemote(_ text: String) async -> [AVAudioPCMBuffer]? {
        guard let base = Settings.httpBaseURL else { return nil }
        var req = URLRequest(url: base.appendingPathComponent("tts"))
        req.httpMethod = "POST"
        req.timeoutInterval = 12
        req.setValue("Bearer \(Settings.token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["text": text])
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200, !data.isEmpty else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp3")
        defer { try? FileManager.default.removeItem(at: url) }
        guard (try? data.write(to: url)) != nil, let file = try? AVAudioFile(forReading: url),
              let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: buf)) != nil,
              let converted = AudioIO.Converter().convert(buf) else { return nil }
        return [converted]
    }

    /// Plan B: habla con el sintetizador normal (sin refuerzo de volumen).
    private static func speakDirect(_ text: String) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let synth = AVSpeechSynthesizer()
            let helper = SpeakDelegate()
            synth.delegate = helper
            helper.onFinish = {
                _ = helper // mantiene vivo al delegado
                _ = synth  // y al sintetizador hasta que termine
                cont.resume()
            }
            synth.speak(makeUtterance(text))
        }
    }
}

/// Garantiza que una continuación se reanude una sola vez.
final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func fire() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}

private final class SpeakDelegate: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    var onFinish: (() -> Void)?
    func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) { let f = onFinish; onFinish = nil; f?() }
    func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel u: AVSpeechUtterance) { let f = onFinish; onFinish = nil; f?() }
}

import AVFoundation

/// Voz de Jarvis DENTRO del iPhone: modelo propio (entrenado con la voz clonada) que corre sin internet,
/// sin servidor y sin la PC. Genera cada frase en una fracción de segundo.
/// Archivos en la carpeta "VozJarvis" de la app: jarvis.onnx, tokens.txt, espeak-ng-data/, origen.txt.
final class LocalVoice: @unchecked Sendable {
    static let shared = LocalVoice()

    private let lock = NSLock()
    private var tts: SherpaOnnxOfflineTtsWrapper?
    private var triedLoad = false

    /// Carpeta del modelo dentro de la app.
    static var folder: URL? { Bundle.main.url(forResource: "VozJarvis", withExtension: nil) }

    /// "jarvis" cuando la app trae la voz entrenada de Jarvis (y no un modelo de prueba).
    static var origin: String {
        guard let f = folder, let s = try? String(contentsOf: f.appendingPathComponent("origen.txt"), encoding: .utf8) else { return "" }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// La voz local se usa si la app trae el modelo de Jarvis y el usuario no la desactivó.
    static var enabled: Bool { origin == "jarvis" && Settings.localVoice }

    /// Carga el modelo (una sola vez; tarda menos de un segundo). Devuelve false si no está.
    @discardableResult
    func load(folder: URL? = LocalVoice.folder) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if tts != nil { return true }
        if triedLoad && folder == LocalVoice.folder { return false }
        triedLoad = true
        guard let f = folder else { return false }
        let model = f.appendingPathComponent("jarvis.onnx").path
        let tokens = f.appendingPathComponent("tokens.txt").path
        let data = f.appendingPathComponent("espeak-ng-data").path
        guard FileManager.default.fileExists(atPath: model), FileManager.default.fileExists(atPath: tokens) else { return false }
        // noiseScale/noiseScaleW un poco más bajos: voz estable y clara, sin "temblores".
        let vits = sherpaOnnxOfflineTtsVitsModelConfig(model: model, lexicon: "", tokens: tokens, dataDir: data,
                                                       noiseScale: 0.6, noiseScaleW: 0.7, lengthScale: 1.0)
        let modelConfig = sherpaOnnxOfflineTtsModelConfig(vits: vits, numThreads: 2, debug: 0)
        var config = sherpaOnnxOfflineTtsConfig(model: modelConfig, maxNumSentences: 1)
        let w = SherpaOnnxOfflineTtsWrapper(config: &config)
        guard w.tts != nil else { return false }
        tts = w
        return true
    }

    /// Frase -> audio PCM (formato del modelo). nil si el modelo no está o falló.
    func render(_ text: String, speed: Float = 1.0) -> AVAudioPCMBuffer? {
        guard load() else { return nil }
        lock.lock(); defer { lock.unlock() }
        guard let tts else { return nil }
        let audio = tts.generate(text: text, sid: 0, speed: speed)
        let samples = audio.samples
        let rate = Double(audio.sampleRate)
        guard !samples.isEmpty, rate > 0,
              let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false),
              let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(samples.count)) else { return nil }
        buf.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            buf.floatChannelData![0].update(from: src.baseAddress!, count: samples.count)
        }
        return buf
    }
}

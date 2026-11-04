import Foundation
import Speech
import AVFoundation

/// Dictado en el teléfono (SFSpeechRecognizer, en el dispositivo cuando el idioma lo permite).
/// Alimentado con los mismos buffers del micrófono de las gafas. Termina solo por silencio.
final class SpeechCapture: @unchecked Sendable {
    var onPartial: (@Sendable (String) -> Void)?
    /// Se llama UNA vez por captura con el texto final ("" si no se oyó nada). No se llama tras cancel().
    var onFinal: (@Sendable (String) -> Void)?

    private let q = DispatchQueue(label: "jarvis.speech")
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var active = false
    private var heard = false
    private var latest = ""
    private var generation = 0
    private var silenceItem: DispatchWorkItem?
    private var noSpeechItem: DispatchWorkItem?
    private var maxItem: DispatchWorkItem?

    func begin(localeID: String, noSpeechTimeout: TimeInterval, endSilence: TimeInterval = 1.1) {
        q.async { [self] in
            finish(deliver: false)
            let rec = SFSpeechRecognizer(locale: Locale(identifier: localeID)) ?? SFSpeechRecognizer()
            guard let rec, rec.isAvailable else {
                let cb = onFinal
                DispatchQueue.main.async { cb?("") }
                return
            }
            let req = SFSpeechAudioBufferRecognitionRequest()
            req.shouldReportPartialResults = true
            if rec.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
            req.addsPunctuation = true

            recognizer = rec
            request = req
            latest = ""
            heard = false
            active = true
            generation += 1
            let gen = generation

            task = rec.recognitionTask(with: req) { [weak self] result, error in
                self?.q.async { self?.handle(result: result, error: error, gen: gen, endSilence: endSilence) }
            }

            noSpeechItem = schedule(after: noSpeechTimeout) { [self] in if !heard { finish(deliver: true) } }
            maxItem = schedule(after: 25) { [self] in finish(deliver: true) }
        }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        q.async { [self] in
            if active { request?.append(buffer) }
        }
    }

    /// Termina ahora entregando lo que se haya entendido.
    func finishNow() { q.async { [self] in finish(deliver: true) } }

    func cancel() { q.async { [self] in finish(deliver: false) } }

    // MARK: - interno (siempre en q)

    private func handle(result: SFSpeechRecognitionResult?, error: Error?, gen: Int, endSilence: TimeInterval) {
        guard gen == generation, active else { return }
        if let r = result {
            let text = r.bestTranscription.formattedString
            if text != latest {
                latest = text
                if !text.isEmpty {
                    heard = true
                    let cb = onPartial
                    DispatchQueue.main.async { cb?(text) }
                }
                silenceItem?.cancel()
                silenceItem = schedule(after: endSilence) { [self] in finish(deliver: true) }
            }
            if r.isFinal { finish(deliver: true) }
        } else if error != nil {
            finish(deliver: true)
        }
    }

    private func schedule(after: TimeInterval, _ block: @escaping () -> Void) -> DispatchWorkItem {
        let item = DispatchWorkItem(block: block)
        q.asyncAfter(deadline: .now() + after, execute: item)
        return item
    }

    private func finish(deliver: Bool) {
        guard active else { return }
        active = false
        silenceItem?.cancel(); noSpeechItem?.cancel(); maxItem?.cancel()
        silenceItem = nil; noSpeechItem = nil; maxItem = nil
        request?.endAudio()
        task?.cancel()
        request = nil; task = nil; recognizer = nil
        let text = latest.trimmingCharacters(in: .whitespacesAndNewlines)
        latest = ""
        if deliver {
            let cb = onFinal
            DispatchQueue.main.async { cb?(text) }
        }
    }
}

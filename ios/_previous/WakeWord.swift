import AVFoundation
import Foundation
#if canImport(Porcupine)
import Porcupine
#endif

enum WakeError: LocalizedError {
    case noKey, notLinked
    var errorDescription: String? {
        switch self {
        case .noKey: return "Falta la clave de Picovoice (Ajustes)."
        case .notLinked: return "El paquete Porcupine no está enlazado en el proyecto."
        }
    }
}

/// Detector de la palabra «Jarvis» 100 % en el teléfono (Picovoice Porcupine, palabra integrada).
/// Se alimenta con los buffers del micrófono de las gafas; no abre su propio micrófono.
final class WakeWord: @unchecked Sendable {
    var onWake: (@Sendable () -> Void)?

    private let queue = DispatchQueue(label: "jarvis.wake")
    private var converter: AVAudioConverter?
    private var converterRate: Double = 0
    private var pending = [Int16]()
    private var lastFire = Date.distantPast
    private var armed = false
    #if canImport(Porcupine)
    private var porcupine: Porcupine?
    #endif

    func start(accessKey: String, sensitivity: Float) throws {
        #if canImport(Porcupine)
        guard !accessKey.isEmpty else { throw WakeError.noKey }
        try queue.sync {
            porcupine = try Porcupine(accessKey: accessKey, keyword: .jarvis, sensitivity: sensitivity)
            pending.removeAll()
            converter = nil
            armed = true
        }
        #else
        throw WakeError.notLinked
        #endif
    }

    func stop() {
        queue.sync {
            armed = false
            #if canImport(Porcupine)
            porcupine = nil
            #endif
            pending.removeAll()
        }
    }

    func feed(_ mono: AVAudioPCMBuffer) {
        queue.async { [weak self] in self?.process(mono) }
    }

    private func process(_ buf: AVAudioPCMBuffer) {
        #if canImport(Porcupine)
        guard armed, let p = porcupine else { return }
        guard let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Double(Porcupine.sampleRate), channels: 1, interleaved: true) else { return }

        if converter == nil || converterRate != buf.format.sampleRate {
            converter = AVAudioConverter(from: buf.format, to: target)
            converterRate = buf.format.sampleRate
        }
        guard let conv = converter else { return }
        let cap = AVAudioFrameCount(Double(buf.frameLength) * target.sampleRate / buf.format.sampleRate) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: cap) else { return }

        var fed = false
        var err: NSError?
        conv.convert(to: out, error: &err) { _, status in
            if fed { status.pointee = .noDataNow; return nil }   // streaming: conserva el estado del remuestreo
            fed = true
            status.pointee = .haveData
            return buf
        }
        guard err == nil, out.frameLength > 0, let ch = out.int16ChannelData else { return }
        pending.append(contentsOf: UnsafeBufferPointer(start: ch[0], count: Int(out.frameLength)))

        let frame = Int(Porcupine.frameLength)
        while pending.count >= frame {
            let chunk = Array(pending.prefix(frame))
            pending.removeFirst(frame)
            do {
                if try p.process(pcm: chunk) >= 0, Date().timeIntervalSince(lastFire) > 1.5 {
                    lastFire = Date()
                    onWake?()
                }
            } catch {
                print("[wake] error: \(error)")
            }
        }
        #endif
    }
}

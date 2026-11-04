import AVFoundation
import Foundation

/// Voz de respaldo del sistema (cuando el servidor no manda audio) y para la navegación.
/// Se sintetiza a un buffer y se reproduce por el mismo motor, así recibe el refuerzo de volumen.
final class LocalVoice {
    static let shared = LocalVoice()
    private let synth = AVSpeechSynthesizer()

    /// Llamar en el hilo principal.
    func synthesize(_ text: String, completion: @escaping (AVAudioPCMBuffer?) -> Void) {
        let u = AVSpeechUtterance(string: text)
        u.voice = AVSpeechSynthesisVoice(language: Prefs.locale) ?? AVSpeechSynthesisVoice(language: "es-MX")
        u.rate = 0.53
        var pieces: [AVAudioPCMBuffer] = []
        var done = false
        synth.write(u) { buffer in
            guard !done else { return }
            if let pcm = buffer as? AVAudioPCMBuffer, pcm.frameLength > 0 {
                pieces.append(pcm)
                return
            }
            done = true
            completion(Self.concat(pieces).flatMap { AudioIO.normalize($0) })
        }
    }

    /// Para llamarlo desde una cola de fondo. Espera a que termine la síntesis (máx. 15 s).
    static func blockingSynthesize(_ text: String) -> AVAudioPCMBuffer? {
        let sem = DispatchSemaphore(value: 0)
        var result: AVAudioPCMBuffer?
        DispatchQueue.main.async {
            shared.synthesize(text) { b in
                result = b
                sem.signal()
            }
        }
        _ = sem.wait(timeout: .now() + 15)
        return result
    }

    func stop() {
        synth.stopSpeaking(at: .immediate)
    }

    private static func concat(_ bufs: [AVAudioPCMBuffer]) -> AVAudioPCMBuffer? {
        guard let first = bufs.first else { return nil }
        let total = bufs.reduce(0) { $0 + Int($1.frameLength) }
        guard let out = AVAudioPCMBuffer(pcmFormat: first.format, frameCapacity: AVAudioFrameCount(total)) else { return nil }
        let channels = Int(first.format.channelCount)
        var offset = 0
        for b in bufs {
            let n = Int(b.frameLength)
            switch first.format.commonFormat {
            case .pcmFormatFloat32:
                guard let src = b.floatChannelData, let dst = out.floatChannelData else { return nil }
                for c in 0..<channels { memcpy(dst[c] + offset, src[c], n * MemoryLayout<Float>.size) }
            case .pcmFormatInt16:
                guard let src = b.int16ChannelData, let dst = out.int16ChannelData else { return nil }
                for c in 0..<channels { memcpy(dst[c] + offset, src[c], n * MemoryLayout<Int16>.size) }
            default:
                return nil
            }
            offset += n
        }
        out.frameLength = AVAudioFrameCount(total)
        return out
    }
}

import AVFoundation
import UIKit

final class AtomicBool: @unchecked Sendable {
    private let lock = NSLock()
    private var v = false
    var value: Bool {
        get { lock.lock(); defer { lock.unlock() }; return v }
        set { lock.lock(); v = newValue; lock.unlock() }
    }
}

/// Convierte el micrófono de las gafas a PCM 16-bit / 16 kHz / mono para la transmisión en vivo.
final class LiveAudioEncoder: @unchecked Sendable {
    static let dst = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!
    private var conv: AVAudioConverter?
    private var src: AVAudioFormat?

    /// Devuelve un paquete binario: byte 0x02 + muestras Int16 little-endian.
    func encode(_ buf: AVAudioPCMBuffer) -> Data? {
        if src != buf.format { src = buf.format; conv = AVAudioConverter(from: buf.format, to: Self.dst) }
        guard let conv else { return nil }
        let cap = AVAudioFrameCount(Double(buf.frameLength) * Self.dst.sampleRate / buf.format.sampleRate) + 256
        guard let out = AVAudioPCMBuffer(pcmFormat: Self.dst, frameCapacity: cap) else { return nil }
        var supplied = false
        var err: NSError?
        conv.convert(to: out, error: &err) { _, status in
            if supplied { status.pointee = .noDataNow; return nil }
            supplied = true
            status.pointee = .haveData
            return buf
        }
        guard err == nil, out.frameLength > 0, let p = out.int16ChannelData?[0] else { return nil }
        var d = Data([0x02])
        d.append(UnsafeBufferPointer(start: p, count: Int(out.frameLength)))
        return d
    }
}

/// Transmisión en vivo (video de la cámara + audio del micrófono de las gafas) hacia un enlace público.
@MainActor
final class LiveService: ObservableObject {
    @Published private(set) var isLive = false
    @Published private(set) var link: String?
    @Published private(set) var viewers = 0
    @Published private(set) var expiresAt: Date?
    @Published var error: String?

    private let encoder = LiveAudioEncoder()
    private let audioOn = AtomicBool()
    private var outbox: Outbox?

    /// El servidor ya creó la sesión: empieza a mandar video y audio.
    func begin(url: String, expires: Date?, glasses: GlassesService, outbox: Outbox) async {
        self.outbox = outbox
        link = url
        expiresAt = expires
        viewers = 0
        error = nil
        do {
            try await glasses.startStream { jpeg in
                var d = Data([0x01]); d.append(jpeg)
                outbox.sendBinary(d, droppable: true)
            }
            audioOn.value = true
            isLive = true
        } catch {
            self.error = error.localizedDescription
            isLive = false
        }
    }

    func end(glasses: GlassesService) {
        audioOn.value = false
        isLive = false
        link = nil
        viewers = 0
        expiresAt = nil
        glasses.stopStream()
    }

    func setViewers(_ n: Int) { viewers = n }

    /// Hilo de audio: manda el micrófono al servidor si hay transmisión activa.
    nonisolated func feedAudio(_ buffer: AVAudioPCMBuffer) {
        guard audioOn.value, let box = outboxBox.outbox, let d = encoder.encode(buffer) else { return }
        box.sendBinary(d, droppable: true)
    }

    nonisolated let outboxBox = OutboxBox()
    func attach(_ outbox: Outbox) { outboxBox.outbox = outbox }
}

final class OutboxBox: @unchecked Sendable {
    private let lock = NSLock()
    private var o: Outbox?
    var outbox: Outbox? {
        get { lock.lock(); defer { lock.unlock() }; return o }
        set { lock.lock(); o = newValue; lock.unlock() }
    }
}

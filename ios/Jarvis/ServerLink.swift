import Foundation

/// Envío de binarios (video/audio en vivo) desde cualquier hilo, descartando cuadros si la red va lenta.
final class Outbox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionWebSocketTask?
    private var inflight = 0
    /// Cuadros de video aún sin enviar. Baja latencia: con 2 en camino, el nuevo se salta (siempre lo más reciente, sin fila).
    private var videoInflight = 0

    func set(_ t: URLSessionWebSocketTask?) {
        lock.lock(); task = t; inflight = 0; videoInflight = 0; lock.unlock()
    }

    @discardableResult
    func sendBinary(_ data: Data, droppable: Bool) -> Bool {
        let isVideo = data.first == 0x01
        lock.lock()
        guard let t = task else { lock.unlock(); return false }
        if droppable {
            if isVideo && videoInflight >= 2 { lock.unlock(); return false }
            if !isVideo && inflight > 6 { lock.unlock(); return false }
        }
        if isVideo { videoInflight += 1 } else { inflight += 1 }
        lock.unlock()
        t.send(.data(data)) { [weak self] _ in
            guard let self else { return }
            self.lock.lock()
            if isVideo { self.videoInflight = max(0, self.videoInflight - 1) } else { self.inflight = max(0, self.inflight - 1) }
            self.lock.unlock()
        }
        return true
    }
}

/// WebSocket con el servidor de Jarvis: reconexión automática, latido y mensajes JSON.
@MainActor
final class ServerLink {
    let outbox = Outbox()
    var onMessage: (([String: Any]) -> Void)?
    var onConnectionChanged: ((Bool) -> Void)?

    private var task: URLSessionWebSocketTask?
    private var loop: Task<Void, Never>?
    private var wantConnected = false
    private(set) var connected = false
    private let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.waitsForConnectivity = true
        c.timeoutIntervalForRequest = 30
        return URLSession(configuration: c)
    }()

    func connect() {
        wantConnected = true
        loop?.cancel()
        loop = Task { [weak self] in await self?.run() }
    }

    func disconnect() {
        wantConnected = false
        loop?.cancel()
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        outbox.set(nil)
        setConnected(false)
    }

    func send(_ obj: [String: Any]) {
        guard connected, let task,
              let data = try? JSONSerialization.data(withJSONObject: obj),
              let text = String(data: data, encoding: .utf8) else { return }
        task.send(.string(text)) { _ in }
    }

    private func setConnected(_ v: Bool) {
        guard connected != v else { return }
        connected = v
        onConnectionChanged?(v)
    }

    private func run() async {
        var backoff: UInt64 = 1
        while wantConnected, !Task.isCancelled {
            guard let url = Settings.websocketURL, !Settings.token.isEmpty else {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                continue
            }
            let t = session.webSocketTask(with: url)
            t.maximumMessageSize = 8 * 1024 * 1024
            task = t
            t.resume()
            // Autenticación: el token va en el primer mensaje (no en la URL).
            if let data = try? JSONSerialization.data(withJSONObject: ["type": "hello", "token": Settings.token]),
               let s = String(data: data, encoding: .utf8) {
                try? await t.send(.string(s))
            }
            let pinger = Task { [weak t] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 15_000_000_000)
                    t?.sendPing { _ in }
                }
            }
            receiving: while !Task.isCancelled {
                do {
                    let msg = try await t.receive()
                    var text: String?
                    switch msg {
                    case .string(let s): text = s
                    case .data(let d): text = String(data: d, encoding: .utf8)
                    @unknown default: break
                    }
                    guard let text, let data = text.data(using: .utf8),
                          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                    if obj["type"] as? String == "ready" { backoff = 1; outbox.set(t); setConnected(true) }
                    onMessage?(obj)
                } catch {
                    break receiving
                }
            }
            pinger.cancel()
            outbox.set(nil)
            setConnected(false)
            t.cancel(with: .goingAway, reason: nil)
            if !wantConnected { return }
            try? await Task.sleep(nanoseconds: backoff * 1_000_000_000)
            backoff = min(backoff * 2, 10)
        }
    }
}

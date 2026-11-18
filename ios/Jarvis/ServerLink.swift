import Foundation

/// Envío de binarios (video/audio en vivo) desde cualquier hilo, descartando cuadros si la red va lenta.
final class Outbox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionWebSocketTask?
    private var inflight = 0
    /// Cuadros de video aún sin enviar. Baja latencia: con 4 en camino, el nuevo se salta (siempre lo más reciente, sin fila).
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
            if isVideo && videoInflight >= 4 { lock.unlock(); return false }
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

    // MARK: Memoria guardada en el iPhone
    // El plan gratis de Render borra todo al dormirse; el servidor manda una copia ("sync") y la app
    // se la devuelve en cada conexión ("restore"), así Jarvis nunca olvida.

    private static var memoryFile: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("jarvis-memoria.json")
    }

    func saveMemory(_ msg: [String: Any]) {
        var copy = msg
        copy.removeValue(forKey: "type")
        guard let data = try? JSONSerialization.data(withJSONObject: copy) else { return }
        try? data.write(to: Self.memoryFile, options: .atomic)
    }

    private func savedMemory() -> Any? {
        guard let data = try? Data(contentsOf: Self.memoryFile) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    private var task: URLSessionWebSocketTask?
    private var loop: Task<Void, Never>?
    private var wantConnected = false
    private var generation = 0
    private(set) var connected = false
    private let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.waitsForConnectivity = true
        c.timeoutIntervalForRequest = 30
        return URLSession(configuration: c)
    }()

    func connect() {
        wantConnected = true
        if loop != nil, connected { return } // ya conectado: no abrir otra conexión (antes duplicaba respuestas)
        loop?.cancel()
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        generation &+= 1
        let gen = generation
        loop = Task { [weak self] in await self?.run(gen) }
    }

    /// Cierra la conexión actual y abre una nueva (tras cambiar servidor o contraseña).
    func reconnect() {
        disconnect()
        connect()
    }

    func disconnect() {
        wantConnected = false
        generation &+= 1
        loop?.cancel()
        loop = nil
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

    private func run(_ gen: Int) async {
        var backoff: UInt64 = 1
        while wantConnected, !Task.isCancelled, gen == generation {
            guard let url = Settings.websocketURL, !Settings.token.isEmpty else {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                continue
            }
            let t = session.webSocketTask(with: url)
            t.maximumMessageSize = 8 * 1024 * 1024
            task = t
            t.resume()
            // Autenticación: el token va en el primer mensaje (no en la URL).
            var hello: [String: Any] = ["type": "hello", "token": Settings.token]
            if let mem = savedMemory() { hello["restore"] = mem }
            // Qué voz trae esta app (para verificar desde el servidor que suena la de Jarvis).
            hello["voz"] = ["origen": LocalVoice.origin, "activa": LocalVoice.enabled]
            if let data = try? JSONSerialization.data(withJSONObject: hello),
               let s = String(data: data, encoding: .utf8) {
                try? await t.send(.string(s))
            }
            let pinger = Task { [weak t] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 15_000_000_000)
                    t?.sendPing { _ in }
                }
            }
            receiving: while !Task.isCancelled, gen == generation {
                do {
                    let msg = try await t.receive()
                    guard gen == generation, task === t else { break receiving } // conexión vieja: se descarta
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
            t.cancel(with: .goingAway, reason: nil)
            guard gen == generation else { return } // una conexión nueva ya tomó el control
            outbox.set(nil)
            setConnected(false)
            if !wantConnected { return }
            try? await Task.sleep(nanoseconds: backoff * 1_000_000_000)
            backoff = min(backoff * 2, 10)
        }
    }
}

import Foundation
import UIKit
import MWDATCore
import MWDATCamera

enum GlassesError: LocalizedError {
    case permission, noSession, noCamera, timeout, noFrame
    var errorDescription: String? {
        switch self {
        case .permission: return "Sin permiso de cámara en las gafas (concédelo en la app Meta AI)."
        case .noSession: return "No pude abrir sesión con las gafas. ¿Están puestas y conectadas?"
        case .noCamera: return "No pude activar la cámara de las gafas."
        case .timeout: return "Las gafas no enviaron imagen a tiempo."
        case .noFrame: return "No llegó ningún cuadro de video."
        }
    }
}

/// Registro con Meta AI, estado de conexión y foto desde la cámara de las gafas (Meta Wearables Device Access Toolkit).
@MainActor
final class GlassesService: ObservableObject {
    @Published private(set) var registered = false
    @Published private(set) var registrationText = "Sin registrar"
    @Published private(set) var deviceConnected = false
    @Published var lastPhoto: UIImage?
    @Published private(set) var isStreaming = false
    @Published private(set) var preview: UIImage?
    /// La vista de cámara lo activa para mostrar el video dentro de la app (ahorra batería si no se ve).
    nonisolated let previewEnabled = AtomicBool()
    nonisolated let latest = LatestJPEG()

    private var streamCamera: Camera?
    private var streamBag = ListenerTokenBag()

    private var session: DeviceSession?
    private var idleStop: Task<Void, Never>?
    private let selector: AutoDeviceSelector
    private var observers: [Task<Void, Never>] = []

    init() {
        selector = AutoDeviceSelector(wearables: Wearables.shared)
    }

    func startObserving() {
        observers.forEach { $0.cancel() }
        observers = [
            Task { [weak self] in
                guard let self else { return }
                self.apply(registration: Wearables.shared.registrationState)
                for await state in Wearables.shared.registrationStateStream() {
                    self.apply(registration: state)
                }
            },
            Task { [weak self] in
                guard let self else { return }
                for await id in self.selector.activeDeviceStream() {
                    self.deviceConnected = (id != nil)
                }
            },
        ]
    }

    private func apply(registration state: RegistrationState) {
        switch state {
        case .registered: registered = true; registrationText = "Registrada con Meta AI"
        case .registering: registered = false; registrationText = "Registrando…"
        case .available: registered = false; registrationText = "Lista para registrar"
        case .unavailable: registered = false; registrationText = "Registro no disponible"
        @unknown default: registered = false; registrationText = "Estado desconocido"
        }
    }

    // MARK: Registro y permisos (abren la app Meta AI y vuelven por el esquema jarvisglasses://)

    func register() async -> String? {
        do { try await Wearables.shared.startRegistration(); return nil }
        catch { return error.localizedDescription }
    }

    func handle(url: URL) async -> String? {
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              comps.queryItems?.contains(where: { $0.name == "metaWearablesAction" }) == true else { return nil }
        do { _ = try await Wearables.shared.handleUrl(url); return nil }
        catch { return error.localizedDescription }
    }

    func requestCameraPermission() async -> String? {
        do {
            if try await Wearables.shared.checkPermissionStatus(.camera) == .granted { return nil }
            return try await Wearables.shared.requestPermission(.camera) == .granted ? nil : "Permiso de cámara denegado"
        } catch { return error.localizedDescription }
    }

    // MARK: Foto

    /// Abre la cámara de las gafas, espera unos cuadros (autoexposición) y devuelve un JPEG reducido.
    func captureJPEG() async throws -> Data {
        if isStreaming, let d = latest.get() { return d } // ya hay video en marcha: usa el cuadro más reciente
        idleStop?.cancel()
        let session = try await ensureSession()
        if try await Wearables.shared.checkPermissionStatus(.camera) != .granted {
            guard try await Wearables.shared.requestPermission(.camera) == .granted else { throw GlassesError.permission }
        }
        let config = StreamConfiguration(videoCodec: VideoCodec.raw, resolution: StreamingResolution.medium, frameRate: 7)
        guard let camera = try session.addCamera(config: config) else { throw GlassesError.noCamera }
        let stream = camera.stream
        let bag = ListenerTokenBag()
        let gate = FrameGate(skip: 4)

        defer {
            camera.stop()
            Task { await bag.cancelAll() }
            scheduleIdleStop()
        }

        let image: UIImage = try await withCheckedThrowingContinuation { cont in
            stream.videoFramePublisher.listen { frame in
                guard gate.shouldTake(), let img = frame.makeUIImage() else { return }
                if gate.finish() { cont.resume(returning: img) }
            }.store(in: bag)
            stream.start()
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
                if gate.finish() { cont.resume(throwing: GlassesError.timeout) }
            }
        }
        lastPhoto = image
        guard let data = Self.jpeg(image, maxSide: 1024, quality: 0.72) else { throw GlassesError.noFrame }
        return data
    }

    // MARK: Video continuo (vista en la app y transmisión en vivo)

    /// Destino actual de los cuadros. Se puede cambiar con la cámara ya abierta
    /// (p. ej. "Ver cámara" y luego "Iniciar transmisión": antes el enlace se quedaba sin video).
    nonisolated let frameSink = FrameSink()

    func startStream(onJPEG: @escaping @Sendable (Data) -> Void) async throws {
        frameSink.set(onJPEG)
        guard streamCamera == nil else { return }
        idleStop?.cancel()
        let session = try await ensureSession()
        if try await Wearables.shared.checkPermissionStatus(.camera) != .granted {
            guard try await Wearables.shared.requestPermission(.camera) == .granted else { throw GlassesError.permission }
        }
        // Límites oficiales del SDK de Meta para apps externas: 360×640, 504×896 o 720×1280; 2, 7, 15, 24 o 30 cuadros/s.
        // Si el Bluetooth no da abasto, las gafas bajan solas la resolución y luego los cuadros (nunca de 15).
        let q = Settings.liveQuality
        let resolution: StreamingResolution = q == "maxima" ? .high : (q == "fluida" ? .low : .medium)
        let config = StreamConfiguration(videoCodec: VideoCodec.raw, resolution: resolution, frameRate: 30)
        guard let camera = try session.addCamera(config: config) else { throw GlassesError.noCamera }
        streamBag = ListenerTokenBag()
        // Cuadros hacia la red: 30/s en fluida, 24/s en equilibrada, 20/s en máxima (cada cuadro pesa más).
        let sendGate = FrameThrottle(minInterval: q == "maxima" ? 0.05 : (q == "fluida" ? 0.033 : 0.041))
        let previewGate = FrameThrottle(minInterval: 0.12)
        let box = latest
        let sink = frameSink
        let quality: CGFloat = q == "maxima" ? 0.7 : 0.6
        let previewFlag = previewEnabled
        camera.stream.videoFramePublisher.listen { [weak self] frame in
            guard sendGate.ok(), let img = frame.makeUIImage(), let jpg = img.jpegData(compressionQuality: quality) else { return }
            box.set(jpg)
            sink.emit(jpg)
            if previewFlag.value, previewGate.ok() {
                Task { @MainActor in self?.preview = img }
            }
        }.store(in: streamBag)
        camera.stream.start()
        streamCamera = camera
        isStreaming = true
    }

    func stopStream() {
        guard let cam = streamCamera else { return }
        cam.stop()
        streamCamera = nil
        let bag = streamBag
        Task { await bag.cancelAll() }
        isStreaming = false
        preview = nil
        scheduleIdleStop()
    }

    // MARK: Foto a resolución completa (la máxima calidad que Meta permite a apps externas)

    /// Plan A: módulo de foto del SDK (resolución .full, calidad .high; API marcada experimental por Meta).
    /// Plan B si falla: foto desde el video activo (API estable). Devuelve los datos tal cual (JPEG o HEIC).
    func captureFullPhoto() async throws -> Data {
        idleStop?.cancel()
        var temp: Camera?
        let cam: Camera
        if let c = streamCamera {
            cam = c // transmisión activa: se usa la misma cámara, sin cortar el video
        } else {
            let session = try await ensureSession()
            if try await Wearables.shared.checkPermissionStatus(.camera) != .granted {
                guard try await Wearables.shared.requestPermission(.camera) == .granted else { throw GlassesError.permission }
            }
            let config = StreamConfiguration(videoCodec: VideoCodec.raw, resolution: StreamingResolution.low, frameRate: 15)
            guard let c = try session.addCamera(config: config) else { throw GlassesError.noCamera }
            cam = c
            temp = c
        }
        let bag = ListenerTokenBag()
        defer {
            Task { await bag.cancelAll() }
            if let t = temp { t.stop(); scheduleIdleStop() }
        }
        do {
            return try await standalonePhoto(cam.photo, bag: bag)
        } catch {
            let firstError = error
            if temp != nil { try await startVideo(cam.stream, bag: bag) }
            return try await photoFromVideo(cam.stream, bag: bag, fallbackError: firstError)
        }
    }

    private func standalonePhoto(_ photo: MWDATCamera.Photo, bag: ListenerTokenBag) async throws -> Data {
        defer { photo.stop() }
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            let once = Once()
            let asked = Once()
            photo.photoDataPublisher.listen { p in
                if once.fire() { cont.resume(returning: p.imageData) }
            }.store(in: bag)
            photo.errorPublisher.listen { e in
                if once.fire() { cont.resume(throwing: e) }
            }.store(in: bag)
            photo.statePublisher.listen { st in
                if st == .started, asked.fire() { photo.capturePhoto(resolution: .full, quality: .high) }
            }.store(in: bag)
            photo.start()
            // Por si el estado "started" no se anuncia: se pide la foto igual a los 3 s.
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                if asked.fire() { photo.capturePhoto(resolution: .full, quality: .high) }
            }
            // La foto completa viaja por Bluetooth: puede tardar varios segundos.
            DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
                if once.fire() { cont.resume(throwing: GlassesError.timeout) }
            }
        }
    }

    /// Arranca el video y espera el primer cuadro (la cámara queda lista).
    private func startVideo(_ stream: MWDATCamera.Stream, bag: ListenerTokenBag) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let ready = Once()
            stream.videoFramePublisher.listen { _ in
                if ready.fire() { cont.resume() }
            }.store(in: bag)
            stream.start()
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
                if ready.fire() { cont.resume(throwing: GlassesError.timeout) }
            }
        }
    }

    private func photoFromVideo(_ stream: MWDATCamera.Stream, bag: ListenerTokenBag, fallbackError: Error) async throws -> Data {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            let once = Once()
            stream.photoDataPublisher.listen { p in
                if once.fire() { cont.resume(returning: p.data) }
            }.store(in: bag)
            if !stream.capturePhoto(format: .jpeg) {
                if once.fire() { cont.resume(throwing: fallbackError) }
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 15) {
                if once.fire() { cont.resume(throwing: GlassesError.timeout) }
            }
        }
    }

    private func ensureSession() async throws -> DeviceSession {
        if let s = session, s.state == .started { return s }
        session?.stop()
        session = nil
        let s = try Wearables.shared.createSession(deviceSelector: selector)
        try s.start()
        let ok: Bool = await withTaskGroup(of: Bool.self) { group in
            group.addTask { for await st in s.stateStream() { if st == .started { return true }; if st == .stopped { return false } }; return false }
            group.addTask { try? await Task.sleep(nanoseconds: 12_000_000_000); return false }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        guard ok else { s.stop(); throw GlassesError.noSession }
        session = s
        return s
    }

    private func scheduleIdleStop() {
        idleStop?.cancel()
        idleStop = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 45_000_000_000)
            guard !Task.isCancelled else { return }
            self?.session?.stop()
            self?.session = nil
        }
    }

    private static func jpeg(_ image: UIImage, maxSide: CGFloat, quality: CGFloat) -> Data? {
        let size = image.size
        let scale = min(1, maxSide / max(size.width, size.height))
        guard scale < 1 else { return image.jpegData(compressionQuality: quality) }
        let target = CGSize(width: size.width * scale, height: size.height * scale)
        let r = UIGraphicsImageRenderer(size: target)
        return r.image { _ in image.draw(in: CGRect(origin: .zero, size: target)) }.jpegData(compressionQuality: quality)
    }
}

final class FrameSink: @unchecked Sendable {
    private let lock = NSLock()
    private var fn: (@Sendable (Data) -> Void)?
    func set(_ f: @escaping @Sendable (Data) -> Void) { lock.lock(); fn = f; lock.unlock() }
    func emit(_ d: Data) { lock.lock(); let f = fn; lock.unlock(); f?(d) }
}

final class LatestJPEG: @unchecked Sendable {
    private let lock = NSLock()
    private var d: Data?
    func set(_ x: Data) { lock.lock(); d = x; lock.unlock() }
    func get() -> Data? { lock.lock(); defer { lock.unlock() }; return d }
}

final class FrameThrottle: @unchecked Sendable {
    private let lock = NSLock()
    private var last: CFTimeInterval = 0
    private let minInterval: CFTimeInterval
    init(minInterval: CFTimeInterval) { self.minInterval = minInterval }
    func ok() -> Bool {
        lock.lock(); defer { lock.unlock() }
        let now = CACurrentMediaTime()
        if now - last < minInterval { return false }
        last = now
        return true
    }
}

/// Descarta los primeros cuadros y garantiza una sola respuesta.
final class FrameGate: @unchecked Sendable {
    private let lock = NSLock()
    private var seen = 0
    private var finished = false
    private let skip: Int
    init(skip: Int) { self.skip = skip }
    func shouldTake() -> Bool {
        lock.lock(); defer { lock.unlock() }
        seen += 1
        return !finished && seen > skip
    }
    func finish() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if finished { return false }
        finished = true
        return true
    }
}

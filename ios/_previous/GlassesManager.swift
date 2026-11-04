import Foundation
import UIKit
import MWDATCore
import MWDATCamera

/// TODO el contacto con el SDK de Meta vive en este archivo.
/// El SDK está en "developer preview": si una versión nueva renombra algo, solo hay que arreglarlo aquí.
/// Audio (micrófono y parlantes) NO pasa por el SDK: las gafas son un auricular Bluetooth normal para iOS.
@MainActor
final class GlassesManager: ObservableObject {
    @Published private(set) var registered = false
    @Published private(set) var deviceCount = 0
    @Published private(set) var note = ""

    var connected: Bool { registered && deviceCount > 0 }

    private let wearables = Wearables.shared
    private var started = false
    private var sessionState = ""
    private var streamState = ""
    private var lastPhoto: Data?
    private var tokens: [Any] = []   // retiene los listeners mientras dura la captura

    // MARK: registro y dispositivos

    func start() {
        guard !started else { return }
        started = true
        Task { [weak self] in
            guard let self else { return }
            for await state in self.wearables.registrationStateStream() {
                // Se compara por texto para no depender de la forma exacta del enum en cada versión del SDK.
                self.registered = String(describing: state).lowercased().hasPrefix("registered")
            }
        }
        Task { [weak self] in
            guard let self else { return }
            for await devices in self.wearables.devicesStream() { self.deviceCount = devices.count }
        }
    }

    func register() {
        Task {
            do { try await wearables.startRegistration() }
            catch { note = "No pude registrar la app con Meta AI: \(error.localizedDescription)" }
        }
    }

    func handle(url: URL) async { _ = try? await wearables.handleUrl(url) }

    // MARK: cámara (foto bajo demanda)

    private func ensureCameraPermission() async -> Bool {
        func granted(_ s: PermissionStatus) -> Bool { String(describing: s).lowercased().hasPrefix("granted") }
        do {
            var status = try await wearables.checkPermissionStatus(.camera)
            if !granted(status) { status = try await wearables.requestPermission(.camera) }
            return granted(status)
        } catch {
            note = "Permiso de cámara: \(error.localizedDescription)"
            return false
        }
    }

    private func poll(timeout: Double, _ condition: @MainActor () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return condition()
    }

    /// Abre la cámara de las gafas, saca UNA foto y la cierra (ahorra batería y enciende el LED solo lo necesario).
    func capturePhoto() async -> Data? {
        guard connected else { note = "Las gafas no están conectadas"; return nil }
        guard await ensureCameraPermission() else { return nil }

        sessionState = ""; streamState = ""; lastPhoto = nil; tokens = []
        var stateTask: Task<Void, Never>?
        var deviceSession: DeviceSession?
        var camera: (any AnyObject)?   // se detiene con camera.stop() vía closure de abajo
        var stopCamera: (() async -> Void)?

        func cleanup() async {
            stateTask?.cancel()
            await stopCamera?()
            camera = nil
            tokens = []
            if let s = deviceSession { await s.stop() }
        }

        do {
            let selector = AutoDeviceSelector(wearables: wearables)
            let session = try wearables.createSession(deviceSelector: selector)
            deviceSession = session
            try await session.start()
            stateTask = Task { [weak self] in
                for await s in session.stateStream() { self?.sessionState = String(describing: s) }
            }
            guard await poll(timeout: 8, { self.sessionState.lowercased() == "started" }) else {
                note = "Las gafas no respondieron a tiempo"; await cleanup(); return nil
            }

            // Para una sola foto basta una resolución media y pocos fps (menos carga en el Bluetooth).
            let config = StreamConfiguration(videoCodec: .raw, resolution: .medium, frameRate: 15)
            guard let cam = try await session.addCamera(config: config) else { await cleanup(); return nil }
            camera = cam
            stopCamera = { await cam.stop() }
            let stream = cam.stream

            tokens.append(stream.photoDataPublisher.listen { [weak self] photo in
                let data = photo.data
                Task { @MainActor in self?.lastPhoto = data }
            })
            tokens.append(stream.statePublisher.listen { [weak self] st in
                let text = String(describing: st)
                Task { @MainActor in self?.streamState = text }
            })

            await stream.start()
            guard await poll(timeout: 8, { self.streamState.lowercased().contains("streaming") }) else {
                note = "La cámara de las gafas no arrancó"; await cleanup(); return nil
            }
            await stream.capturePhoto(format: .jpeg)
            _ = await poll(timeout: 6, { self.lastPhoto != nil })
            let photo = lastPhoto
            await cleanup()
            return photo
        } catch {
            note = "Cámara: \(error.localizedDescription)"
            await cleanup()
            return nil
        }
    }
}

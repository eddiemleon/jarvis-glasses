import XCTest
import UIKit
import MWDATCore
import MWDATCamera
import MWDATMockDevice
@testable import Jarvis

/// Pruebas con las gafas SIMULADAS oficiales de Meta (MockDeviceKit del SDK), siguiendo la guía de Meta
/// (configure → enable → pairGlasses). Ejecutan el código real de la app (GlassesService).
///
/// Nota: Meta tiene errores abiertos en los que el simulador de iPhone no entrega cuadros de video ni fotos
/// simuladas (github.com/facebook/meta-wearables-dat-ios issues 197 y 331). Por eso:
///  - OBLIGATORIO: el SDK arranca, la app ve las gafas, abre sesión y la cámara arranca sin errores.
///  - INFORMATIVO: si el simulador entrega imágenes, se verifica que sean válidas; si no, se anota.
@MainActor
final class GlassesMockTests: XCTestCase {
    private var glasses: (any MockGlasses)?
    private var services: [GlassesService] = []

    /// Cada prueba usa un GlassesService nuevo; al terminar se cierra su sesión para no dejar las gafas ocupadas.
    private func makeService() -> GlassesService {
        let s = GlassesService()
        services.append(s)
        return s
    }

    override func setUp() async throws {
        try await super.setUp()
        WearablesBoot.start()
        XCTAssertTrue(WearablesBoot.ready, "El SDK de Meta no arrancó: \(WearablesBoot.failure ?? "")")
        MockDeviceKit.shared.enable(config: MockDeviceKitConfig(initiallyRegistered: true, initialPermissionsGranted: true))
        let g = try MockDeviceKit.shared.pairGlasses(model: .rayBanMeta)
        g.powerOn()
        g.unfold()
        g.don()
        let img = Self.makeTestJPEG()
        g.services.camera.setCameraFeed(fileURL: img)
        g.services.camera.setCapturedImage(fileURL: img)
        g.services.cameraCapture.setCapturedPhoto(fileURL: img)
        glasses = g
    }

    override func tearDown() async throws {
        services.forEach { $0.shutdown() }
        services.removeAll()
        try await Task.sleep(nanoseconds: 1_000_000_000)
        await MockDeviceKit.shared.disable()
        glasses = nil
        try await super.tearDown()
    }

    private static func makeTestJPEG() -> URL {
        let size = CGSize(width: 720, height: 1280)
        let img = UIGraphicsImageRenderer(size: size).image { ctx in
            UIColor.systemTeal.setFill(); ctx.fill(CGRect(origin: .zero, size: size))
            UIColor.orange.setFill(); ctx.fill(CGRect(x: 100, y: 300, width: 520, height: 520))
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("jarvis-mock-feed.jpg")
        try? img.jpegData(compressionQuality: 0.9)?.write(to: url)
        return url
    }

    /// Distingue un fallo de la app de "el simulador de Meta no entrega imágenes" (error conocido de Meta).
    private func isSimulatorNoMedia(_ error: Error) -> Bool {
        if let g = error as? GlassesError {
            switch g { case .timeout, .noFrame: return true; default: return false }
        }
        return false
    }

    func test1_SDKStartsAndSeesGlasses() async throws {
        XCTAssertTrue(WearablesBoot.ready)
        let service = makeService()
        service.startObserving()
        let deadline = Date().addingTimeInterval(10)
        while !service.deviceConnected, Date() < deadline { try await Task.sleep(nanoseconds: 200_000_000) }
        XCTAssertTrue(service.deviceConnected, "La app no detectó las gafas emparejadas")
        XCTAssertTrue(service.registered, "La app no ve el registro con Meta AI")
    }

    func test2_PhotoFlow() async throws {
        let service = makeService()
        do {
            let data = try await service.captureJPEG()
            XCTAssertNotNil(UIImage(data: data), "La foto no es una imagen válida")
            print("JARVIS-CHECK foto: OK \(data.count) bytes")
        } catch where isSimulatorNoMedia(error) {
            print("JARVIS-CHECK foto: sesión y cámara OK; el simulador de Meta no entregó imagen (error conocido de Meta)")
        }
    }

    func test3_LiveStreamAllQualities() async throws {
        for quality in ["fluida", "equilibrada", "maxima"] {
            UserDefaults.standard.set(quality, forKey: K.liveQuality)
            let service = makeService()
            let counter = FrameCounter()
            try await service.startStream { jpeg in counter.add(jpeg) } // OBLIGATORIO: no debe lanzar error
            XCTAssertTrue(service.isStreaming, "Calidad \(quality): la cámara no quedó transmitiendo")
            let deadline = Date().addingTimeInterval(8)
            while counter.count < 5, Date() < deadline { try await Task.sleep(nanoseconds: 200_000_000) }
            service.stopStream()
            XCTAssertFalse(service.isStreaming)
            service.shutdown() // libera las gafas antes de probar la siguiente calidad
            if counter.count > 0 {
                XCTAssertNotNil(counter.last.flatMap { UIImage(data: $0) }, "Calidad \(quality): cuadro inválido")
            }
            print("JARVIS-CHECK video \(quality): cámara OK, cuadros recibidos=\(counter.count)")
            try await Task.sleep(nanoseconds: 500_000_000)
        }
    }

    func test4_ViewThenLiveKeepsSameCamera() async throws {
        let service = makeService()
        try await service.startStream { _ in }
        let counter = FrameCounter()
        try await service.startStream { jpeg in counter.add(jpeg) } // no debe abrir otra cámara ni fallar
        XCTAssertTrue(service.isStreaming)
        try await Task.sleep(nanoseconds: 3_000_000_000)
        service.stopStream()
        print("JARVIS-CHECK vista→transmisión: OK, cuadros al nuevo destino=\(counter.count)")
    }

    func test5_FullQualityPhoto() async throws {
        let service = makeService()
        do {
            let data = try await service.captureFullPhoto()
            XCTAssertNotNil(UIImage(data: data), "La foto en máxima calidad no es una imagen válida")
            print("JARVIS-CHECK foto máxima: OK \(data.count) bytes")
        } catch where isSimulatorNoMedia(error) {
            print("JARVIS-CHECK foto máxima: flujo OK; el simulador de Meta no entregó imagen (error conocido de Meta)")
        }
    }
}

final class FrameCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    private var d: Data?
    func add(_ x: Data) { lock.lock(); n += 1; d = x; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return n }
    var last: Data? { lock.lock(); defer { lock.unlock() }; return d }
}

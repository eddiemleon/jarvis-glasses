import XCTest
import UIKit
import MWDATCore
import MWDATCamera
import MWDATMockDevice
@testable import Jarvis

/// Pruebas con las gafas SIMULADAS oficiales de Meta (MockDeviceKit del SDK).
/// Ejecutan el código real de la app (GlassesService) contra unas Ray-Ban Meta virtuales:
/// conexión, foto, video en vivo en las 3 calidades y foto en máxima calidad.
@MainActor
final class GlassesMockTests: XCTestCase {
    private var glasses: (any MockGlasses)?

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
        await MockDeviceKit.shared.disable()
        glasses = nil
        try await super.tearDown()
    }

    /// Imagen de prueba (colores) guardada como JPEG temporal.
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

    func testGlassesConnectAndTakePhoto() async throws {
        let service = GlassesService()
        let data = try await service.captureJPEG()
        XCTAssertGreaterThan(data.count, 500, "La foto de las gafas llegó vacía")
        XCTAssertNotNil(UIImage(data: data), "La foto no es una imagen válida")
    }

    func testLiveStreamDeliversFramesInAllQualities() async throws {
        for quality in ["fluida", "equilibrada", "maxima"] {
            UserDefaults.standard.set(quality, forKey: K.liveQuality)
            let service = GlassesService()
            let counter = FrameCounter()
            try await service.startStream { jpeg in counter.add(jpeg) }
            let deadline = Date().addingTimeInterval(15)
            while counter.count < 5, Date() < deadline { try await Task.sleep(nanoseconds: 200_000_000) }
            service.stopStream()
            XCTAssertGreaterThanOrEqual(counter.count, 5, "Calidad \(quality): llegaron \(counter.count) cuadros de video")
            XCTAssertNotNil(counter.last.flatMap { UIImage(data: $0) }, "Calidad \(quality): el cuadro no es un JPEG válido")
            try await Task.sleep(nanoseconds: 500_000_000)
        }
    }

    func testStreamThenLiveKeepsVideo() async throws {
        // Antes: "Ver cámara" y luego "Iniciar transmisión" dejaba el enlace sin video.
        let service = GlassesService()
        try await service.startStream { _ in }
        let counter = FrameCounter()
        try await service.startStream { jpeg in counter.add(jpeg) }
        let deadline = Date().addingTimeInterval(10)
        while counter.count < 3, Date() < deadline { try await Task.sleep(nanoseconds: 200_000_000) }
        service.stopStream()
        XCTAssertGreaterThanOrEqual(counter.count, 3, "La transmisión no recibió video tras abrir la vista")
    }

    func testFullQualityPhoto() async throws {
        let service = GlassesService()
        let data = try await service.captureFullPhoto()
        XCTAssertNotNil(UIImage(data: data), "La foto en máxima calidad no es una imagen válida")
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

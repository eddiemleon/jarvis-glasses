import XCTest
import AVFoundation
@testable import Jarvis

/// La voz de Jarvis dentro del iPhone: el modelo que trae la app carga y habla en español, rápido.
final class LocalVoiceTests: XCTestCase {
    func testModelLoadsAndSpeaksFast() throws {
        let folder = try XCTUnwrap(LocalVoice.folder, "La app no trae la carpeta VozJarvis")
        print("JARVIS-CHECK voz local: origen=\(LocalVoice.origin)")
        let voice = LocalVoice()
        XCTAssertTrue(voice.load(folder: folder), "No cargó el modelo de voz")
        _ = voice.render("Listo.") // calentamiento
        for text in ["Bienvenido de vuelta, señor Leon.",
                     "Hoy la máxima llega a unos ochenta y ocho grados, con probabilidad de lluvia por la tarde."] {
            let t0 = Date()
            let buf = try XCTUnwrap(voice.render(text), "No generó audio")
            let dt = Date().timeIntervalSince(t0)
            let secs = Double(buf.frameLength) / buf.format.sampleRate
            print(String(format: "JARVIS-CHECK voz local: %.1f s de audio en %.2f s", secs, dt))
            XCTAssertGreaterThan(secs, 1.0)
            XCTAssertLessThan(dt, secs * 2, "La voz tarda demasiado") // el simulador Intel de la nube es mucho más lento que un iPhone
            XCTAssertNotNil(AudioIO.Converter().convert(buf), "No se pudo pasar al formato de las gafas")
        }
    }
}

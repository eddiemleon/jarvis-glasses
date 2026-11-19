import XCTest
@testable import Jarvis

/// Interrumpir a Jarvis con solo hablar: su voz corta la respuesta; el eco de Jarvis no.
final class BargeInTests: XCTestCase {
    let dice = SpeechListener.echoSet("El oro está en dos mil seiscientos, señor, con una ganancia de cuarenta dólares en la posición abierta.")

    func testUserInterrupts() {
        XCTAssertTrue(SpeechListener.isBargeIn(["no", "eso", "no", "te", "pregunté"], echo: dice))
        XCTAssertTrue(SpeechListener.isBargeIn(["cómo", "va", "Bitcoin"], echo: dice))
        XCTAssertTrue(SpeechListener.isBargeIn(["para"], echo: dice))
        XCTAssertTrue(SpeechListener.isBargeIn(["cállate"], echo: dice))
        print("JARVIS-CHECK interrupción: su voz corta la respuesta")
    }

    func testOwnEchoIgnored() {
        XCTAssertFalse(SpeechListener.isBargeIn(["con", "una", "ganancia", "de", "cuarenta"], echo: dice))
        XCTAssertFalse(SpeechListener.isBargeIn(["en", "la", "posición"], echo: dice))
        XCTAssertFalse(SpeechListener.isBargeIn(["oro"], echo: dice)) // una sola palabra que no es "para"
        print("JARVIS-CHECK interrupción: el eco de Jarvis se ignora")
    }

    func testGlassesMicIsDefault() {
        UserDefaults.standard.removeObject(forKey: "musicFirst")
        XCTAssertFalse(Settings.musicFirst, "Por defecto debe usarse el micrófono de las gafas")
    }
}

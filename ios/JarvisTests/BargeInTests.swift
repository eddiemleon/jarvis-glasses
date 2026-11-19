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

    func testSmartEndOfTurn() {
        XCTAssertEqual(SpeechListener.endpoint(for: "cómo va el oro hoy"), 0.5)          // frase completa: responde ya
        XCTAssertEqual(SpeechListener.endpoint(for: "dime cómo va el"), 1.3)             // a medias: espera
        XCTAssertEqual(SpeechListener.endpoint(for: "quiero saber si"), 1.3)
        XCTAssertEqual(SpeechListener.endpoint(for: "hola"), 0.8)
        print("JARVIS-CHECK fin de turno: 0.5 s si la frase está completa, espera si quedó a medias")
    }

    func testMicMigrationForcesGlasses() {
        UserDefaults.standard.set(true, forKey: "musicFirst")
        UserDefaults.standard.removeObject(forKey: "migr_mic_gafas_2")
        Settings.registerDefaults()
        XCTAssertFalse(Settings.musicFirst, "Debe volver al micrófono de las gafas")
        print("JARVIS-CHECK micrófono: modo gafas forzado")
    }
}

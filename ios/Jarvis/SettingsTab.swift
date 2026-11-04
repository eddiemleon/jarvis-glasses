import SwiftUI
import AVFoundation

struct SettingsTab: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var glasses: GlassesService

    @AppStorage(K.serverURL) private var serverURL = ""
    @AppStorage(K.token) private var token = ""
    @AppStorage(K.followUp) private var followUp = true
    @AppStorage(K.readWhatsApp) private var readWA = true
    @AppStorage(K.boostDB) private var boostDB = 9.0
    @AppStorage(K.maxSystemVolume) private var maxVolume = true
    @AppStorage(K.voiceID) private var voiceID = ""
    @AppStorage(K.speechRate) private var rate = 0.52
    @AppStorage(K.locale) private var locale = "es-US"
    @State private var note: String?

    private let voices = Speaker.spanishVoices()

    var body: some View {
        NavigationStack {
            Form {
                Section("Servidor de Jarvis") {
                    TextField("https://tu-servidor.com", text: $serverURL)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    SecureField("Contraseña (JARVIS_TOKEN)", text: $token)
                    Button("Reconectar") { model.link.reconnect() }
                    LabeledContent("Estado", value: model.serverConnected ? "Conectado · \(model.serverModel)" : "Sin conexión")
                }

                Section("Gafas Ray-Ban Meta") {
                    LabeledContent("Registro", value: glasses.registrationText)
                    LabeledContent("Micrófono", value: model.routeName)
                    Button("Registrar con Meta AI") { Task { note = await glasses.register() } }
                    Button("Permiso de cámara") { Task { note = await glasses.requestCameraPermission() ?? "Permiso concedido" } }
                    Text("Antes: app Meta AI → Tus gafas → Modo desarrollador (activarlo).").font(.footnote).foregroundStyle(.secondary)
                }

                Section("Voz y volumen") {
                    Picker("Voz", selection: $voiceID) {
                        Text("Automática (mejor disponible)").tag("")
                        ForEach(voices, id: \.identifier) { v in Text("\(v.name) · \(v.language) · \(qualityName(v.quality))").tag(v.identifier) }
                    }
                    VStack(alignment: .leading) {
                        Text("Velocidad")
                        Slider(value: $rate, in: 0.4...0.62)
                    }
                    VStack(alignment: .leading) {
                        Text("Refuerzo de volumen: +\(Int(boostDB)) dB")
                        Slider(value: $boostDB, in: 0...18, step: 1)
                    }
                    Toggle("Subir volumen del iPhone al máximo al hablar", isOn: $maxVolume)
                    Button("Probar voz") { model.testVoice() }
                    Text("El límite de volumen de fábrica de las gafas no se puede saltar. Esto sube el nivel dentro de ese límite: el volumen máximo del sistema más ganancia con limitador anti-distorsión.")
                        .font(.footnote).foregroundStyle(.secondary)
                }

                Section("Conversación") {
                    Picker("Idioma de escucha", selection: $locale) {
                        Text("Español (EE. UU./PR)").tag("es-US")
                        Text("Español (México)").tag("es-MX")
                        Text("Español (España)").tag("es-ES")
                    }
                    Toggle("Seguir escuchando tras responder", isOn: $followUp)
                    Toggle("Leer en voz alta mis WhatsApp", isOn: $readWA)
                }

                if let note { Section { Text(note).font(.footnote) } }
            }
            .navigationTitle("Ajustes")
        }
    }

    private func qualityName(_ q: AVSpeechSynthesisVoiceQuality) -> String {
        switch q {
        case .premium: return "Premium"
        case .enhanced: return "Mejorada"
        default: return "Estándar"
        }
    }
}

import SwiftUI

struct ContentView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        TabView {
            JarvisTab()
                .tabItem { Label("Jarvis", systemImage: "waveform.circle.fill") }
            CameraTab(glasses: model.glasses, live: model.live)
                .tabItem { Label("Cámara", systemImage: "eyeglasses") }
            SettingsTab(glasses: model.glasses)
                .tabItem { Label("Ajustes", systemImage: "gearshape.fill") }
        }
        .tint(Color(red: 0.2, green: 0.9, blue: 1))
        .alert("Aviso", isPresented: Binding(get: { model.errorText != nil }, set: { if !$0 { model.errorText = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(model.errorText ?? "") }
    }
}

// MARK: - Pestaña principal

struct JarvisTab: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        InnerBody(nav: model.navigator, live: model.live, glasses: model.glasses, loc: model.location)
    }
}

private struct InnerBody: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var nav: Navigator
    @ObservedObject var live: LiveService
    @ObservedObject var glasses: GlassesService
    @ObservedObject var loc: LocationService

    private var stateText: String {
        switch model.state {
        case .offline: return "Conectando…"
        case .idle: return "Di \"Jarvis\""
        case .listening: return "Te escucho"
        case .thinking: return model.statusLine.isEmpty ? "Pensando…" : model.statusLine
        case .speaking: return "Hablando"
        case .alert: return "Aviso"
        case .paused: return model.pausedUntil != nil ? "Pausado" : "Escucha apagada"
        }
    }

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.01, green: 0.03, blue: 0.07), .black], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
            VStack(spacing: 10) {
                chips
                OrbView(state: model.state, levels: model.levels)
                    .frame(maxWidth: .infinity)
                    .frame(height: 330)
                    .onTapGesture { model.pushToTalk() }
                Text(stateText)
                    .font(.system(.title3, design: .rounded).weight(.semibold))
                    .foregroundStyle(.white.opacity(0.9))
                    .animation(.easeInOut(duration: 0.2), value: stateText)
                subtitles
                if nav.active { navCard }
                Spacer(minLength: 0)
                controls
            }
            .padding(.horizontal, 16)
            .padding(.top, 6)
        }
    }

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip("eyeglasses", model.usingGlassesMic ? "Gafas (mic)" : "Sin mic de gafas", model.usingGlassesMic)
                chip("link", glasses.registered ? (glasses.deviceConnected ? "SDK Meta" : "Registrada") : "Sin registrar", glasses.deviceConnected)
                chip("server.rack", model.serverConnected ? (model.serverModel.isEmpty ? "Servidor" : model.serverModel) : "Sin servidor", model.serverConnected)
                chip("location.fill", loc.authorized ? (loc.place.isEmpty ? "GPS" : loc.place) : "GPS apagado", loc.authorized)
                if live.isLive { chip("dot.radiowaves.left.and.right", "EN VIVO · \(live.viewers)", true, tint: .red) }
                if let l = model.interpreterLocale { chip("character.bubble", "Intérprete · \(l) — di \"Jarvis\" para salir", true, tint: .orange) }
            }
        }
    }

    private func chip(_ icon: String, _ text: String, _ ok: Bool, tint: Color? = nil) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.caption2)
            Text(text).font(.caption).lineLimit(1)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background((tint ?? (ok ? Color.cyan : Color.gray)).opacity(0.16), in: Capsule())
        .foregroundStyle(tint ?? (ok ? Color.cyan : Color.gray))
    }

    private var subtitles: some View {
        VStack(spacing: 6) {
            if !model.userText.isEmpty {
                Text(model.userText)
                    .font(.callout).foregroundStyle(.white.opacity(0.55))
                    .multilineTextAlignment(.center).lineLimit(3)
            }
            if !model.assistantText.isEmpty {
                Text(model.assistantText)
                    .font(.body.weight(.medium)).foregroundStyle(Color(red: 0.6, green: 0.95, blue: 1))
                    .multilineTextAlignment(.center).lineLimit(6)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 90, alignment: .top)
        .animation(.easeInOut(duration: 0.15), value: model.assistantText)
    }

    private var navCard: some View {
        HStack(spacing: 10) {
            Image(systemName: "location.north.line.fill").foregroundStyle(.cyan)
            VStack(alignment: .leading, spacing: 2) {
                Text(nav.destinationName).font(.subheadline.weight(.semibold))
                Text(nav.nextInstruction).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            Button("Parar") { nav.stop() }.buttonStyle(.bordered).tint(.red)
        }
        .padding(12)
        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 14))
    }

    private var controls: some View {
        HStack(spacing: 14) {
            Button { model.setListening(!(model.listeningDesired)) } label: {
                Label(model.listeningDesired ? "Escuchando" : "Apagado", systemImage: model.listeningDesired ? "ear.fill" : "ear.trianglebadge.exclamationmark")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(model.listeningDesired ? .cyan : .gray)

            Button { model.pushToTalk() } label: {
                Label("Hablar", systemImage: "mic.fill").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color(red: 0.1, green: 0.7, blue: 0.9))
        }
        .controlSize(.large)
        .padding(.bottom, 8)
    }
}

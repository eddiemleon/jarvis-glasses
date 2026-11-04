import SwiftUI
import UIKit

/// Cámara de las gafas: vista en vivo dentro de la app, foto y transmisión con enlace para cualquier dispositivo.
struct CameraTab: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var glasses: GlassesService
    @ObservedObject var live: LiveService

    @State private var minutes = 60
    @State private var busy = false
    @State private var message: String?
    @State private var copied = false
    @AppStorage(K.liveQuality) private var liveQuality = "equilibrada"

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    preview
                    controls
                    if live.isLive || live.link != nil { liveCard } else { shareCard }
                    Text("El video y el audio salen de tus gafas por Bluetooth hacia el iPhone y de ahí a tu servidor. Quien tenga el enlace puede ver y escuchar hasta que lo detengas o expire.")
                        .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .padding(16)
            }
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("Cámara")
            .onAppear { glasses.previewEnabled.value = true }
            .onDisappear { glasses.previewEnabled.value = false }
        }
    }

    private var preview: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18).fill(Color.white.opacity(0.06))
            if let img = glasses.preview ?? (glasses.isStreaming ? nil : glasses.lastPhoto) {
                Image(uiImage: img).resizable().scaledToFit().clipShape(RoundedRectangle(cornerRadius: 18))
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "eyeglasses").font(.largeTitle)
                    Text(glasses.isStreaming ? "Esperando imagen…" : "Sin imagen").font(.footnote)
                }.foregroundStyle(.secondary)
            }
            if glasses.isStreaming {
                VStack { HStack { Spacer(); Label("VIVO", systemImage: "circle.fill").font(.caption2.bold()).padding(6)
                    .background(.red.opacity(0.85), in: Capsule()) }.padding(10); Spacer() }
            }
        }
        .frame(height: 380)
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Button {
                Task {
                    busy = true; defer { busy = false }
                    if glasses.isStreaming { glasses.stopStream() }
                    else {
                        do { try await glasses.startStream { _ in } } catch { message = error.localizedDescription }
                    }
                }
            } label: {
                Label(glasses.isStreaming ? "Detener vista" : "Ver cámara", systemImage: glasses.isStreaming ? "stop.fill" : "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(live.isLive) // detener la vista cortaría la transmisión

            Button {
                Task { busy = true; defer { busy = false }; message = await model.takeFullPhoto() }
            } label: {
                Label("Foto máxima", systemImage: "camera.fill").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
        .controlSize(.large)
        .disabled(busy)
        .overlay(alignment: .bottom) {
            if let m = message { Text(m).font(.caption).foregroundStyle(.orange).offset(y: 24) }
        }
        .padding(.bottom, message == nil ? 0 : 20)
    }

    private var qualityNote: String {
        switch liveQuality {
        case "fluida": return "360×640 a 30 cuadros/s: lo más rápido y estable."
        case "maxima": return "720×1280, el máximo que Meta permite. Más datos; si el Bluetooth no da abasto, las gafas bajan solas la calidad."
        default: return "504×896 a 30 cuadros/s: el punto medio recomendado por Meta."
        }
    }

    private var shareCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Transmitir en vivo", systemImage: "dot.radiowaves.left.and.right").font(.headline)
            Text("Genera un enlace privado para ver tu cámara y escuchar tu micrófono desde cualquier celular o computadora.")
                .font(.footnote).foregroundStyle(.secondary)
            Picker("Duración", selection: $minutes) {
                Text("30 min").tag(30); Text("1 h").tag(60); Text("4 h").tag(240); Text("12 h").tag(720)
            }.pickerStyle(.segmented)
            Picker("Calidad", selection: $liveQuality) {
                Text("Fluida").tag("fluida"); Text("Equilibrada").tag("equilibrada"); Text("Máxima").tag("maxima")
            }.pickerStyle(.segmented)
            Text(qualityNote).font(.caption).foregroundStyle(.secondary)
            Button {
                if glasses.isStreaming { glasses.stopStream() } // reabre la cámara con la calidad elegida
                model.startLive(minutes: minutes)
            } label: {
                Label("Iniciar transmisión", systemImage: "play.circle.fill").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).tint(.red).controlSize(.large)
        }
        .padding(16)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))
    }

    private var liveCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(live.isLive ? "En vivo" : "Preparando…", systemImage: "dot.radiowaves.left.and.right")
                    .font(.headline).foregroundStyle(.red)
                Spacer()
                Label("\(live.viewers)", systemImage: "eye.fill").font(.subheadline)
            }
            if let l = live.link {
                Text(l).font(.footnote.monospaced()).textSelection(.enabled).lineLimit(3)
                HStack {
                    ShareLink(item: URL(string: l) ?? URL(string: "https://example.com")!) {
                        Label("Compartir", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity)
                    }.buttonStyle(.bordered)
                    Button {
                        UIPasteboard.general.string = l
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                    } label: {
                        Label(copied ? "Copiado" : "Copiar", systemImage: "doc.on.doc").frame(maxWidth: .infinity)
                    }.buttonStyle(.bordered)
                }
            }
            if let e = live.expiresAt { Text("Expira \(e.formatted(date: .omitted, time: .shortened))").font(.caption).foregroundStyle(.secondary) }
            if let err = live.error { Text(err).font(.caption).foregroundStyle(.orange) }
            Button(role: .destructive) { model.stopLive() } label: {
                Label("Detener transmisión", systemImage: "stop.circle.fill").frame(maxWidth: .infinity)
            }.buttonStyle(.borderedProminent).tint(.red).controlSize(.large)
        }
        .padding(16)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))
    }
}

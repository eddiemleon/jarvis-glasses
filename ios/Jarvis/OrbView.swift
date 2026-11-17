import SwiftUI

/// Niveles de audio (micrófono y voz de Jarvis). Se escriben desde el hilo de audio y la esfera los lee
/// en cada cuadro: así la animación va a la frecuencia de la pantalla (60/120 Hz) sin redibujar la app entera.
final class AudioLevels: @unchecked Sendable {
    private let lock = NSLock()
    private var mic: Float = 0, out: Float = 0
    private var shown: Double = 0, last: Double = 0
    func setMic(_ v: Float) { lock.lock(); mic = v; lock.unlock() }
    func setOut(_ v: Float) { lock.lock(); out = v; lock.unlock() }
    /// Nivel suavizado para el instante t (sube rápido, baja suave, como un vúmetro).
    func level(at t: Double, listening: Bool) -> Double {
        lock.lock(); defer { lock.unlock() }
        let target = Double(max(mic * (listening ? 1 : 0.25), out))
        let dt = min(0.1, max(0, t - last)); last = t
        let k = target > shown ? 1 - exp(-dt / 0.05) : 1 - exp(-dt / 0.18)
        shown += (target - shown) * k
        return shown
    }
}

/// Orbe de partículas estilo Jarvis: reacciona a tu voz, a la voz de Jarvis y al estado.
struct OrbView: View {
    let state: JarvisState
    let levels: AudioLevels

    private static let points: [SIMD3<Double>] = {
        let n = 240
        let golden = Double.pi * (3 - 5.0.squareRoot())
        return (0..<n).map { i in
            let y = 1 - (Double(i) / Double(n - 1)) * 2
            let r = (1 - y * y).squareRoot()
            let th = golden * Double(i)
            return SIMD3(cos(th) * r, y, sin(th) * r)
        }
    }()

    private var color: Color {
        switch state {
        case .offline: return Color(red: 0.9, green: 0.3, blue: 0.3)
        case .idle: return Color(red: 0.1, green: 0.75, blue: 0.95)
        case .listening: return Color(red: 0.2, green: 0.95, blue: 1.0)
        case .thinking: return Color(red: 0.62, green: 0.45, blue: 1.0)
        case .speaking: return Color(red: 0.55, green: 0.98, blue: 1.0)
        case .alert: return Color(red: 1.0, green: 0.72, blue: 0.2)
        case .paused: return Color(white: 0.5)
        }
    }

    private var spin: Double {
        switch state {
        case .thinking: return 1.6
        case .listening, .speaking: return 0.7
        case .alert: return 1.0
        default: return 0.25
        }
    }

    var body: some View {
        TimelineView(.animation) { tl in // a la frecuencia de la pantalla (hasta 120 cuadros/s)
            Canvas { ctx, size in
                let t = tl.date.timeIntervalSinceReferenceDate
                let c = CGPoint(x: size.width / 2, y: size.height / 2)
                let base = min(size.width, size.height) * 0.34
                let lvl = levels.level(at: t, listening: state == .listening)
                let breathe = 1 + 0.03 * sin(t * 1.4)
                let R = base * breathe * (1 + lvl * 0.18)

                // Halo
                let halo = CGRect(x: c.x - R * 1.7, y: c.y - R * 1.7, width: R * 3.4, height: R * 3.4)
                ctx.fill(Path(ellipseIn: halo),
                         with: .radialGradient(Gradient(colors: [color.opacity(0.28 + lvl * 0.25), .clear]),
                                               center: c, startRadius: 0, endRadius: R * 1.7))

                // Anillos
                for k in 0..<3 {
                    let rr = R * (1.08 + Double(k) * 0.14) + sin(t * (1.2 + Double(k) * 0.5)) * 3 * (0.5 + lvl * 3)
                    let ring = Path(ellipseIn: CGRect(x: c.x - rr, y: c.y - rr, width: rr * 2, height: rr * 2))
                    ctx.stroke(ring, with: .color(color.opacity(0.22 - Double(k) * 0.05)), lineWidth: 1)
                }

                // Partículas
                let ay = t * spin
                let ax = 0.38
                let (sy, cy) = (sin(ay), cos(ay))
                let (sx, cx) = (sin(ax), cos(ax))
                var proj: [(CGPoint, Double, Double)] = []  // (las de atrás se dibujan primero)
                proj.reserveCapacity(Self.points.count)
                for (i, p) in Self.points.enumerated() {
                    var x = p.x * cy + p.z * sy
                    var z = -p.x * sy + p.z * cy
                    let y = p.y * cx - z * sx
                    z = p.y * sx + z * cx
                    x += 0
                    let wob = 1 + 0.07 * sin(t * 2.2 + Double(i) * 0.7) * (0.25 + lvl * 2.2)
                    let persp = 1 / (1 - z * 0.32)
                    let pt = CGPoint(x: c.x + x * R * wob * persp, y: c.y + y * R * wob * persp)
                    proj.append((pt, z, persp))
                }
                for (pt, z, persp) in proj.sorted(by: { $0.1 < $1.1 }) {
                    let depth = (z + 1) / 2
                    let s = (1.2 + 2.6 * depth) * persp * (1 + lvl * 0.6)
                    let rect = CGRect(x: pt.x - s / 2, y: pt.y - s / 2, width: s, height: s)
                    ctx.fill(Path(ellipseIn: rect), with: .color(color.opacity(0.18 + 0.82 * depth)))
                }

                // Núcleo
                let core = R * (0.16 + lvl * 0.2)
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - core, y: c.y - core, width: core * 2, height: core * 2)),
                         with: .radialGradient(Gradient(colors: [.white.opacity(0.9), color.opacity(0.0)]),
                                               center: c, startRadius: 0, endRadius: core))
            }
        }
        .drawingGroup()
        .accessibilityHidden(true)
    }
}

import SwiftUI
import AVKit

/// Abre la lista de audio del sistema (la misma de AirPlay del Centro de control) para elegir las Ray-Ban Meta
/// sin ir a Ajustes. Al elegirlas, iOS conecta su micrófono y su audio a Jarvis.
@MainActor
enum AudioRoute {
    private static let picker: AVRoutePickerView = {
        let v = AVRoutePickerView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        v.prioritizesVideoDevices = false
        v.alpha = 0.011
        return v
    }()

    static func showPicker() {
        guard let window = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
            .flatMap({ $0.windows }).first(where: { $0.isKeyWindow }) else { return }
        if picker.superview !== window { window.addSubview(picker) }
        // El selector del sistema se abre "tocando" su botón interno.
        if let b = picker.subviews.compactMap({ $0 as? UIButton }).first ?? findButton(in: picker) {
            b.sendActions(for: .touchUpInside)
        }
    }

    private static func findButton(in v: UIView) -> UIButton? {
        for s in v.subviews {
            if let b = s as? UIButton { return b }
            if let b = findButton(in: s) { return b }
        }
        return nil
    }
}

import SwiftUI
import MWDATCore

@main
struct JarvisApp: App {
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var phase

    init() {
        do { try Wearables.configure() } catch { print("Wearables.configure falló: \(error)") }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .preferredColorScheme(.dark)
                .task { await model.start() }
                .onOpenURL { url in
                    if url.host == "setup", let c = URLComponents(url: url, resolvingAgainstBaseURL: false) {
                        let q = Dictionary(uniqueKeysWithValues: (c.queryItems ?? []).compactMap { i in i.value.map { (i.name, $0) } })
                        if let s = q["server"], let t = q["token"] {
                            UserDefaults.standard.set(s, forKey: K.serverURL)
                            UserDefaults.standard.set(t, forKey: K.token)
                            Task { await model.start() }
                        }
                        return
                    }
                    Task {
                        if let err = await model.glasses.handle(url: url) { model.errorText = err }
                    }
                }
                .onChange(of: phase) { _, new in
                    if new == .active { Task { await model.start() } }
                }
        }
    }
}

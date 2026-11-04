import Foundation
import MWDATCore

/// "Hey Meta, abre Jarvis": Meta AI lanza la app y espera una respuesta. (API experimental del SDK;
/// si cambia, esta clase se puede borrar sin afectar al resto: ver README.)
@MainActor
final class GlassesVoice {
    var onLaunch: (() -> Void)?

    private var loop: Task<Void, Never>?
    private var stream: VoiceInvocationsStream?
    private var listeningOn: DeviceIdentifier?
    private var tokens = ListenerTokenBag()

    func start() {
        guard WearablesBoot.ready else { return } // sin SDK no hay "Hey Meta, abre Jarvis"
        loop?.cancel()
        loop = Task { [weak self] in
            var delay: UInt64 = 500_000_000
            while !Task.isCancelled {
                // Meta AI solo enruta invocaciones a apps ya registradas.
                if case .registered = Wearables.shared.registrationState {} else {
                    for await s in Wearables.shared.registrationStateStream() { if case .registered = s { break } }
                }
                guard let self, !Task.isCancelled else { return }
                let dropped = await self.listenOnce()
                if !dropped { return }
                try? await Task.sleep(nanoseconds: delay)
                delay = min(delay * 2, 30_000_000_000)
            }
        }
    }

    func stop() {
        loop?.cancel()
        stream?.stop()
        stream = nil
    }

    private func listenOnce() async -> Bool {
        let s: VoiceInvocationsStream
        do { s = try VoiceInvocationsStream(wearables: Wearables.shared) } catch { return true }
        stream = s
        let (drops, dropSignal) = AsyncStream<Void>.makeStream()
        tokens = ListenerTokenBag()

        s.invocationsPublisher.listen { [weak self] invocation in
            Task { @MainActor in await self?.answer(invocation) }
        }.store(in: tokens)
        s.errorPublisher.listen { _ in dropSignal.yield() }.store(in: tokens)

        let dropped = await withTaskGroup(of: Bool.self) { group in
            group.addTask { @MainActor [weak self] in
                for await ids in Wearables.shared.devicesStream() {
                    self?.ensureListening(ids)
                }
                return false
            }
            group.addTask {
                for await _ in drops { return true }
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        if listeningOn != nil { s.stop() }
        stream = nil
        listeningOn = nil
        await tokens.cancelAll()
        return dropped
    }

    private func ensureListening(_ ids: [DeviceIdentifier]) {
        guard let stream, let preferred = ids.first, preferred != listeningOn else { return }
        if listeningOn != nil { stream.stop() }
        listeningOn = nil
        do {
            try stream.start(deviceIdentifier: preferred)
            listeningOn = preferred
        } catch {}
    }

    private func answer(_ invocation: any VoiceInvocation) async {
        switch invocation {
        case let launch as LaunchApp:
            // Meta AI espera esta respuesta; si no llega, anuncia que la app "no responde".
            _ = await launch.responseHandle.sendSuccess(actionOutput: nil)
            onLaunch?()
        default:
            break
        }
    }
}

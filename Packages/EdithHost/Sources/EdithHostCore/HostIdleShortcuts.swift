import EdithExtensionCore
import Foundation

@MainActor
final class HostIdleShortcuts {
    private let entries: [HostExtension]
    private let identity: HostIdentity
    private weak var sessions: HostExtensionSessions?
    private var handingOff: Set<String> = []

    init(entries: [HostExtension], identity: HostIdentity, sessions: HostExtensionSessions) {
        self.entries = entries.filter { !$0.hotkeys.isEmpty }
        self.identity = identity
        self.sessions = sessions
    }

    func synchronize() {
        guard let sessions else { return }
        for entry in entries {
            switch sessions.states[entry.id] {
            case .idle where sessions.idleIDs.contains(entry.id):
                register(entry)
            case .starting, .active, .stopping, .idle:
                continue
            case .notInstalled, .disabled, .failed, nil:
                for hotkey in entry.hotkeys where !handingOff.contains(hotkey.id) {
                    HotKeyRegistrar.clear(hotkey.id)
                }
            }
        }
    }

    private func register(_ entry: HostExtension) {
        guard let defaults = UserDefaults(suiteName: identity.extensionDefaultsSuite(entry.id))
        else { return }
        for hotkey in entry.hotkeys where !HotKeyRegistrar.isRegistered(hotkey.id) {
            HotKeyRegistrar.configure(
                ExtensionHotKeyBinding(
                    id: hotkey.id, prefix: hotkey.prefix, defaultCode: hotkey.code,
                    defaultModifiers: hotkey.modifiers))
            HotKeyRegistrar.install(hotkey.id, defaults: defaults) { [weak self] in
                self?.handOff(entry.id, hotkey: hotkey.id)
            }
        }
    }

    private func handOff(_ id: String, hotkey: String) {
        guard let sessions, handingOff.insert(hotkey).inserted else { return }
        Task { @MainActor [weak self] in
            defer { self?.handingOff.remove(hotkey) }
            do { try await sessions.activate(id) } catch { return }
            HotKeyRegistrar.trigger(hotkey)
        }
    }
}

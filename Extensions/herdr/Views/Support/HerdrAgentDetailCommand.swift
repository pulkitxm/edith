import EdithExtensionUI
import AppKit
enum HerdrAgentDetailSurface: Equatable {
    case agentWindow
    case space(hasAgent: Bool)
    case mainSessions(agentSessionOpen: Bool)
    case detachedSessions(agentSessionOpen: Bool)
    case elsewhere
}

@MainActor
enum HerdrAgentDetailCommand {
    static func help(open: Bool, available: Bool = true) -> String {
        let title = open ? "Hide details" : "Show details"
        guard available else { return title }
        return "\(title) (⌥⌘B)"
    }

    static func matches(characters: String?, modifiers: NSEvent.ModifierFlags) -> Bool {
        modifiers.chordOnly == [.command, .option] && characters?.lowercased() == "b"
    }

    static func applies(
        to surface: HerdrAgentDetailSurface, sessionsOnScreen: Bool
    ) -> Bool {
        switch surface {
        case .agentWindow:
            return true
        case let .space(hasAgent):
            return hasAgent
        case let .mainSessions(agentSessionOpen):
            return sessionsOnScreen && agentSessionOpen
        case let .detachedSessions(agentSessionOpen):
            return agentSessionOpen
        case .elsewhere:
            return false
        }
    }

    static func surface(of window: NSWindow?, store: HerdrStore) -> HerdrAgentDetailSurface {
        guard let window else { return .elsewhere }
        if HerdrAgentWindow.agentID(of: window) != nil { return .agentWindow }
        if let model = HerdrSpaceWindow.model(of: window) {
            return .space(hasAgent: model.selectedTab?.agentTab != nil)
        }
        let agentSessionOpen = store.focusedSession != nil
        if window.identifier?.rawValue == "edith.extension.herdr" {
            return .mainSessions(agentSessionOpen: agentSessionOpen)
        }
        return .elsewhere
    }

    static func perform(
        characters: String?, modifiers: NSEvent.ModifierFlags, repeats: Bool,
        in window: NSWindow?, store: HerdrStore, sessionsOnScreen: @MainActor () -> Bool
    ) -> Bool {
        guard matches(characters: characters, modifiers: modifiers) else { return false }
        let surface = surface(of: window, store: store)
        let onScreen: Bool
        switch surface {
        case .agentWindow, .space, .detachedSessions:
            onScreen = true
        case .mainSessions:
            onScreen = sessionsOnScreen()
        case .elsewhere:
            onScreen = false
        }
        guard applies(to: surface, sessionsOnScreen: onScreen) else { return false }
        guard !repeats else { return true }
        store.toggleAgentDetails()
        return true
    }
}

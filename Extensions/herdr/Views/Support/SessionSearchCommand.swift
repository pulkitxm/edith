import AppKit
@MainActor
enum SessionSearchCommand {
    static func perform(
        in window: NSWindow?, store: HerdrStore, sessionsOnScreen: @MainActor () -> Bool
    ) -> Bool {
        guard window?.identifier?.rawValue == "edith.extension.herdr", sessionsOnScreen()
        else { return false }
        store.searchPresented = true
        return true
    }
}

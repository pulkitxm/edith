import AppKit
import EdithHostCore

struct HostSettingsNavigation: Equatable {
    let delivery: HostPresentationDelivery
    let window: NSWindow

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.delivery == rhs.delivery && lhs.window === rhs.window
    }

    @MainActor func validate(window sheet: NSWindow) throws {
        guard sheet.sheetParent === window, window.attachedSheet === sheet,
            window.isVisible, !window.isMiniaturized, sheet.isVisible
        else { throw HostWindowNavigationError.routeRejected }
    }
}

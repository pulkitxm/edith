import AppKit
import ObjectiveC
import Testing

@testable import EdithExtensionUI

@MainActor
private final class ScriptedView: NSView, DirectKeyboardInputResponder, DirectScrollHandling,
    HistoryNavigatingView
{
    var navigated: [NavigationDirection] = []

    func navigateHistory(_ direction: NavigationDirection) -> Bool {
        navigated.append(direction)
        return true
    }
}

@MainActor @Suite struct CrossImageMarkerTests {
    private func conforms(_ object: NSObject, protocolNamed name: String) -> Bool {
        guard let marker = NSProtocolFromString(name) else { return false }
        return object.conforms(to: marker)
    }

    @Test(arguments: [
        "EdithDirectKeyboardInputResponder", "EdithDirectScrollHandling",
        "EdithHistoryNavigatingView",
    ])
    func markerProtocolsAreNamedSoEveryCopyOfTheSupportCodeRecognizesThem(name: String) {
        let view = ScriptedView(frame: .zero)
        #expect(NSProtocolFromString(name) != nil)
        #expect(conforms(view, protocolNamed: name))
    }

    @Test func theMarkersStillClassifyViewsInTheSameCopy() {
        let view = ScriptedView(frame: .zero)
        #expect(InputFocus.takesKeysDirectly(view))
        #expect(ScrollForwarding.handlesScrollDirectly(from: view))
        #expect(NavigationShortcutGate.historyView(from: view) === view)
        #expect(!InputFocus.takesKeysDirectly(NSView(frame: .zero)))
        #expect(!ScrollForwarding.handlesScrollDirectly(from: NSView(frame: .zero)))
    }

    @Test func historyNavigationReachesTheViewThroughItsObjectiveCName() {
        let view = ScriptedView(frame: .zero)
        #expect(NavigationDirection.back.rawValue == 0)
        #expect(NavigationDirection.forward.rawValue == 1)
        _ = NavigationShortcutGate.historyView(from: view)?.navigateHistory(.forward)
        #expect(view.navigated == [.forward])
    }
}

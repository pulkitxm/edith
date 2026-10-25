import AppKit
@testable import GhosttyTerminal
import Testing

@Suite(.serialized) @MainActor struct GhosttySecureInputTests {
    @Test func balancesTransitionsAcrossFocusedSurfaces() {
        var transitions: [Bool] = []
        let secureInput = GhosttySecureInput(
            applicationActive: true, center: NotificationCenter()
        ) { enabled in
            transitions.append(enabled)
            return true
        }
        let firstObject = NSObject()
        let secondObject = NSObject()
        let first = ObjectIdentifier(firstObject)
        let second = ObjectIdentifier(secondObject)

        secureInput.setScoped(first, focused: true)
        secureInput.setScoped(second, focused: true)
        secureInput.setScoped(first, focused: false)
        secureInput.removeScoped(second)

        #expect(transitions == [true, false])
        #expect(!secureInput.enabled)
    }

    @Test func yieldsAndReacquiresAcrossApplicationActivation() {
        var transitions: [Bool] = []
        let center = NotificationCenter()
        let secureInput = GhosttySecureInput(applicationActive: true, center: center) { enabled in
            transitions.append(enabled)
            return true
        }
        let surfaceObject = NSObject()
        let surface = ObjectIdentifier(surfaceObject)

        secureInput.setScoped(surface, focused: true)
        center.post(name: NSApplication.didResignActiveNotification, object: nil)
        center.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        secureInput.removeScoped(surface)

        #expect(transitions == [true, false, true, false])
        #expect(!secureInput.enabled)
    }

    @Test func defersInactiveRequestsUntilActivation() {
        var transitions: [Bool] = []
        let center = NotificationCenter()
        let secureInput = GhosttySecureInput(applicationActive: false, center: center) { enabled in
            transitions.append(enabled)
            return true
        }
        let surfaceObject = NSObject()
        let surface = ObjectIdentifier(surfaceObject)

        secureInput.setScoped(surface, focused: true)
        #expect(transitions.isEmpty)

        center.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        secureInput.removeScoped(surface)

        #expect(transitions == [true, false])
        #expect(!secureInput.enabled)
    }
    @Test func hostActivityRemainsScopedAndReleasesOnDetach() {
        var transitions: [Bool] = []
        let center = NotificationCenter()
        let secureInput = GhosttySecureInput(applicationActive: false, center: center) {
            transitions.append($0); return true
        }
        let first = NSObject()
        let second = NSObject()
        secureInput.setScoped(ObjectIdentifier(first), focused: true, applicationActive: true)
        secureInput.setScoped(ObjectIdentifier(second), focused: true, applicationActive: false)
        center.post(name: NSApplication.didResignActiveNotification, object: nil)
        #expect(transitions == [true])
        secureInput.removeScoped(ObjectIdentifier(first))
        #expect(transitions == [true, false])
        secureInput.setScoped(ObjectIdentifier(second), focused: true, applicationActive: true)
        #expect(transitions == [true, false, true])
        secureInput.removeScoped(ObjectIdentifier(second))
        #expect(transitions == [true, false, true, false] && !secureInput.enabled)
    }

}

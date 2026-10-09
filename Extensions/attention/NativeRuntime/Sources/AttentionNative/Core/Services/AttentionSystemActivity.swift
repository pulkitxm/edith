@_implementationOnly import EdithExtensionSupport
@_implementationOnly import EdithExtensionUI
import CoreGraphics
import Foundation

enum AttentionSystemActivity {
    static let inputTypes: [CGEventType] = [
        .keyDown, .keyUp, .flagsChanged,
        .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
        .otherMouseDown, .otherMouseUp, .mouseMoved,
        .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
        .scrollWheel, .tabletPointer, .tabletProximity,
    ]

    static func idleSeconds(
        elapsed: (CGEventType) -> TimeInterval = {
            CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: $0)
        }
    ) -> TimeInterval? {
        inputTypes.map(elapsed).filter { $0.isFinite && $0 >= 0 }.min()
    }

    static var isLocked: Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else {
            return true
        }
        return session["CGSSessionScreenIsLocked"] as? Bool == true
            || session[kCGSessionOnConsoleKey as String] as? Bool == false
    }

    static func presence(
        idleSeconds: TimeInterval?, threshold: TimeInterval, locked: Bool
    ) -> AttentionPresence {
        if locked { return .locked }
        guard let idleSeconds, idleSeconds.isFinite, idleSeconds >= 0 else { return .idle }
        return idleSeconds >= threshold ? .idle : .active
    }
}

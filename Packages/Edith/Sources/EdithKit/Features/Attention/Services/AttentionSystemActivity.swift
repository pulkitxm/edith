import CoreGraphics
import Foundation

public enum AttentionSystemActivity {
    public static let inputTypes: [CGEventType] = [
        .keyDown, .keyUp, .flagsChanged,
        .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
        .otherMouseDown, .otherMouseUp, .mouseMoved,
        .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
        .scrollWheel, .tabletPointer, .tabletProximity,
    ]

    public static func idleSeconds(
        elapsed: (CGEventType) -> TimeInterval = {
            CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: $0)
        }
    ) -> TimeInterval? {
        inputTypes.map(elapsed).filter { $0.isFinite && $0 >= 0 }.min()
    }

    public static var isLocked: Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else {
            return true
        }
        return session["CGSSessionScreenIsLocked"] as? Bool == true
            || session[kCGSessionOnConsoleKey as String] as? Bool == false
    }

    public static func presence(
        idleSeconds: TimeInterval?, threshold: TimeInterval, locked: Bool
    ) -> AttentionPresence {
        if locked { return .locked }
        guard let idleSeconds, idleSeconds.isFinite, idleSeconds >= 0 else { return .idle }
        return idleSeconds >= threshold ? .idle : .active
    }
}

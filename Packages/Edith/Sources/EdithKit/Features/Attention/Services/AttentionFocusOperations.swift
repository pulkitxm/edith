import EdithCore
import Foundation

public enum AttentionFocusOperation: String, CaseIterable, Sendable {
    case start
    case stop

    public var descriptor: UserOperationDescriptor {
        UserOperationDescriptor(
            id: UserOperationID(rawValue: "attention.focus.\(rawValue)"), summary: summary,
            cli: ["attention", "focus", rawValue], effect: .write)
    }

    private var summary: String {
        switch self {
        case .start: "Start a focus session."
        case .stop: "Finish the active focus session."
        }
    }
}

public enum AttentionFocusOperationExecution {
    @discardableResult
    public static func start(
        name: String, duration: TimeInterval, repository: AttentionRepository
    ) throws -> AttentionFocusSession {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return try repository.startFocus(
            name: trimmed.isEmpty ? "Focus" : trimmed, duration: duration)
    }

    @discardableResult
    public static func stop(repository: AttentionRepository) throws -> AttentionFocusSession {
        try repository.endFocus()
    }
}

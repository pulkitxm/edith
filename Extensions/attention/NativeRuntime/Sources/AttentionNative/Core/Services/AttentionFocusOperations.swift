@_implementationOnly import EdithExtensionSupport
@_implementationOnly import EdithExtensionUI
import Foundation

enum AttentionFocusOperation: String, CaseIterable, Sendable {
    case start
    case stop

    var descriptor: UserOperationDescriptor {
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

enum AttentionFocusOperationExecution {
    @discardableResult
    static func start(
        name: String, duration: TimeInterval, repository: AttentionRepository
    ) throws -> AttentionFocusSession {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return try repository.startFocus(
            name: trimmed.isEmpty ? "Focus" : trimmed, duration: duration)
    }

    @discardableResult
    static func stop(repository: AttentionRepository) throws -> AttentionFocusSession {
        try repository.endFocus()
    }
}

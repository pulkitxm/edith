import Foundation

public enum StudioError: LocalizedError, Equatable, Sendable {
    case unsupportedInput(String, String)
    case unreadable(String)
    case needsPassword(String)
    case wrongPassword(String)
    case needsEngine(StudioEngine)
    case invalidOption(String, String)
    case needsMoreInputs(Int)
    case nothingToDo(String)
    case unavailable(String)
    case failed(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case let .unsupportedInput(name, tool):
            "\(name) cannot be used with \(tool)."
        case let .unreadable(name):
            "\(name) could not be opened. It may be damaged or in a format this Mac cannot read."
        case let .needsPassword(name):
            "\(name) is password protected. Enter its password and try again."
        case let .wrongPassword(name):
            "The password for \(name) is not correct."
        case let .needsEngine(engine):
            "\(engine.title) is required for this tool. Install it from Studio, then try again."
        case let .invalidOption(key, reason):
            "The \(key) setting is not valid: \(reason)."
        case let .needsMoreInputs(count):
            "Add at least \(count) files for this tool."
        case let .nothingToDo(reason):
            reason
        case let .unavailable(reason):
            reason
        case let .failed(reason):
            reason
        case .cancelled:
            "Cancelled."
        }
    }
}

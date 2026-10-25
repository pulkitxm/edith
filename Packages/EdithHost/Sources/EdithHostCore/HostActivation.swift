import Foundation

public enum HostActivationState: String, Codable, Sendable {
    case notInstalled
    case disabled
    case starting
    case active
    case stopping
    case failed
}

public struct HostActivation: Equatable, Sendable {
    public private(set) var state: HostActivationState

    public init(installed: Bool) {
        state = installed ? .disabled : .notInstalled
    }

    public mutating func installed() {
        if state == .notInstalled { state = .disabled }
    }

    public mutating func beginStart() throws {
        guard state == .disabled || state == .failed else {
            throw CocoaError(.validationMissingMandatoryProperty)
        }
        state = .starting
    }

    public mutating func started() throws {
        guard state == .starting else { throw CocoaError(.validationMissingMandatoryProperty) }
        state = .active
    }

    public mutating func beginStop() throws {
        guard state == .active || state == .starting else {
            throw CocoaError(.validationMissingMandatoryProperty)
        }
        state = .stopping
    }

    public mutating func stopped() throws {
        guard state == .stopping else { throw CocoaError(.validationMissingMandatoryProperty) }
        state = .disabled
    }

    public mutating func failed() {
        state = .failed
    }

    public mutating func removed() throws {
        guard state == .disabled || state == .failed || state == .notInstalled else {
            throw CocoaError(.validationMissingMandatoryProperty)
        }
        state = .notInstalled
    }
}

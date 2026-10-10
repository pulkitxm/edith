import Observation
import SwiftUI

@MainActor @Observable public final class ExtensionPresentationState {
    public private(set) static var current: ExtensionPresentationState?
    public var compact: Bool
    public var visible: Bool
    public var availableWidth: Double
    public let intrinsic: Bool

    public init(compact: Bool, visible: Bool, availableWidth: Double, intrinsic: Bool) {
        self.compact = compact
        self.visible = visible
        self.availableWidth = availableWidth
        self.intrinsic = intrinsic
    }

    public func withContext<T>(_ body: () throws -> T) rethrows -> T {
        let previous = Self.current
        Self.current = self
        defer { Self.current = previous }
        return try body()
    }
}

private struct ExtensionPresentationStateKey: EnvironmentKey {
    static let defaultValue: ExtensionPresentationState? = nil
}

extension EnvironmentValues {
    var extensionPresentationState: ExtensionPresentationState? {
        get { self[ExtensionPresentationStateKey.self] }
        set { self[ExtensionPresentationStateKey.self] = newValue }
    }
}

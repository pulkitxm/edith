import Observation
import AppKit
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

@MainActor
public final class ExtensionPresentationContext: NSObject {
    private var state: ExtensionPresentationState?

    @objc public func configure(_ input: NSDictionary) -> Bool {
        guard let compact = input["compact"] as? Bool, let visible = input["visible"] as? Bool,
            let width = input["width"] as? Double, width.isFinite, (0...16_384).contains(width),
            let intrinsic = input["intrinsic"] as? Bool
        else { return false }
        if let state {
            guard state.intrinsic == intrinsic else { return false }
            state.compact = compact
            state.visible = visible
            state.availableWidth = width
        } else {
            state = ExtensionPresentationState(
                compact: compact, visible: visible, availableWidth: width, intrinsic: intrinsic)
        }
        return true
    }

    @objc public func view(_ factory: @escaping @convention(block) () -> NSViewController?)
        -> NSViewController?
    {
        state?.withContext { factory() }
    }
}

@_cdecl("edith_extension_presentation_create")
public func createExtensionPresentationContext() -> UnsafeMutableRawPointer? {
    let address = MainActor.assumeIsolated {
        UInt(bitPattern: Unmanaged.passRetained(ExtensionPresentationContext()).toOpaque())
    }
    return UnsafeMutableRawPointer(bitPattern: address)
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

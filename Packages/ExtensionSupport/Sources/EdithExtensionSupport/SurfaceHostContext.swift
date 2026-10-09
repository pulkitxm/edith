import Foundation

@MainActor
public struct SurfaceHostContext {
    public let defaults: UserDefaults
    public let sharedState: ExtensionSharedState

    public init(defaults: UserDefaults, sharedState: ExtensionSharedState) {
        self.defaults = defaults
        self.sharedState = sharedState
    }

    public static var current: Self? {
        guard let suite = ProcessInfo.processInfo.environment["EDITH_SURFACE_DEFAULTS_SUITE"],
            let defaults = SharedDefaults.applicationStore(identifier: suite),
            let state = ExtensionSharedState.current
        else { return nil }
        return Self(defaults: defaults, sharedState: state)
    }

    public var activeIDs: Set<String> {
        let values = sharedState.values(for: "host")
        guard let raw = values["surface.activeIDs"], raw.utf8.count <= 16_384,
            let data = raw.data(using: .utf8),
            let ids = try? JSONDecoder().decode([String].self, from: data), ids.count <= 128,
            ids.allSatisfy({ SurfaceWidget(rawValue: "extension:" + $0) != nil })
        else { return [] }
        return Set(ids)
    }

    public func layout(_ target: SurfaceTarget) -> SurfaceLayout {
        SurfaceLayout.decode(defaults.string(forKey: target.key), target: target)
    }

    public func visibleLayout(_ target: SurfaceTarget) -> SurfaceLayout {
        var result = layout(target)
        let active = activeIDs
        result.tiles = result.visible.filter { $0.widget.available(activeIDs: active) }
        if target == .notch, !active.contains("notchShelf") { result.tiles = [] }
        return result
    }
}

public struct SurfaceContextSnapshot: Codable, Equatable, Sendable {
    public let contractVersion: Int
    public let activeIDs: Set<String>
    public let home: SurfaceLayout
    public let notch: SurfaceLayout

    @MainActor public init(_ context: SurfaceHostContext) {
        contractVersion = 1
        activeIDs = context.activeIDs
        home = context.layout(.home)
        notch = context.layout(.notch)
    }
}

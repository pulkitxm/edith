import EdithExtensionSupport
import Foundation

public enum HostSurfaceAvailabilityState: Equatable, Sendable {
    case active
    case disabled
    case needsDownload
    case needsCompatibleUpdate
    case starting
    case stopping
    case failed
    case unavailable
}

public struct HostSurfaceAvailability: Sendable {
    public let knownIDs: Set<String>
    public let installedIDs: Set<String>
    public let downloadedIDs: Set<String>
    public let states: [String: HostActivationState]

    public init(
        knownIDs: Set<String>, installedIDs: Set<String>, downloadedIDs: Set<String>,
        states: [String: HostActivationState]
    ) {
        self.knownIDs = knownIDs
        self.installedIDs = installedIDs
        self.downloadedIDs = downloadedIDs
        self.states = states
    }

    public var activeIDs: Set<String> {
        installedIDs.intersection(knownIDs).filter { states[$0] == .active }
    }

    public func status(_ widget: SurfaceWidget) -> HostSurfaceAvailabilityState {
        if widget == .clocks || !widget.providerIDs.isDisjoint(with: activeIDs) { return .active }
        let providers = widget.providerIDs.intersection(knownIDs)
        guard !providers.isEmpty else { return .unavailable }
        let installed = providers.intersection(installedIDs)
        if installed.contains(where: { states[$0] == .starting }) { return .starting }
        if installed.contains(where: { states[$0] == .stopping }) { return .stopping }
        if installed.contains(where: { states[$0] == .failed }) { return .failed }
        if !installed.isEmpty { return .disabled }
        return providers.isDisjoint(with: downloadedIDs) ? .needsDownload : .needsCompatibleUpdate
    }

    public func projected(_ layout: SurfaceLayout, target: SurfaceTarget) -> SurfaceLayout {
        var projected = layout.normalized()
        projected.tiles = projected.visible.filter { status($0.widget) == .active }
        if target == .notch, !activeIDs.contains("notchShelf") { projected.tiles = [] }
        return projected
    }

    public func queryIDs(_ layout: SurfaceLayout, target: SurfaceTarget, visible: Bool)
        -> Set<String>
    {
        guard visible else { return [] }
        return projected(layout, target: target).tiles.reduce(into: Set<String>()) {
            $0.formUnion($1.widget.providerIDs.intersection(activeIDs))
        }
    }

    public func effectiveGlance(_ source: SurfaceGlanceSource) -> SurfaceGlanceSource {
        let provider: String?
        switch source {
        case .automatic, .clock, .none: provider = nil
        case .workingAgents, .waitingAgents, .stuckAgents, .activeAgents, .quietAgents,
            .failedAgents, .permissions:
            provider = "herdr"
        case .music: provider = "music"
        case .files: provider = "notchShelf"
        case .focus: provider = "attention"
        case .limits: provider = "usage"
        case .nextMeeting: provider = "calendar"
        }
        return provider.map { activeIDs.contains($0) ? source : .none } ?? source
    }
}

extension HostMarketplace {
    public var surfaceAvailability: HostSurfaceAvailability {
        HostSurfaceAvailability(
            knownIDs: Set(entries.map(\.id)), installedIDs: Set(installed.keys),
            downloadedIDs: downloadedIDs, states: sessions.states)
    }
}

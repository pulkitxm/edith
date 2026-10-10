import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import SwiftUI

private struct UsageUIClientKey: EnvironmentKey {
    static let defaultValue: UsageUIClient? = nil
}

extension EnvironmentValues {
    var usageUIClient: UsageUIClient? {
        get { self[UsageUIClientKey.self] }
        set { self[UsageUIClientKey.self] = newValue }
    }
}

struct UsageUISceneRoute: Equatable {
    enum Location: String { case main, settings, home, notch }
    enum Interior: Equatable { case dashboard, settings, activityHeatmap, usageCard, limitsCard }
    let location: Location
    let section: String?
    let tile: SurfaceTile?

    var interior: Interior {
        switch location {
        case .main: return .dashboard
        case .settings: return .settings
        case .home where tile?.widget == .activity: return .activityHeatmap
        default: return tile?.widget == .limits ? .limitsCard : .usageCard
        }
    }

    init?(context: NSDictionary) {
        guard let raw = context["location"] as? String, let location = Location(rawValue: raw),
            context["section"] == nil || context["section"] is String
        else { return nil }
        self.location = location
        let section = context["section"] as? String
        self.section = section
        switch location {
        case .main, .settings:
            guard section.map({ ["usage", "dashboard"].contains($0) }) ?? true,
                context["target"] == nil,
                context["tile"] == nil
            else { return nil }
            tile = nil
        case .home, .notch:
            guard context["target"] as? String == raw,
                let target = SurfaceTarget(rawValue: raw),
                let data = context["tile"] as? Data, data.count <= 65_536,
                let tile = try? JSONDecoder().decode(SurfaceTile.self, from: data),
                [.usage, .activity, .limits].contains(tile.widget), section == tile.widget.id,
                (try? SurfaceSnapshotRequest(target: target, tile: tile).encoded(
                    providerID: "usage")) != nil
            else { return nil }
            self.tile = tile
        }
    }

    var surfaceRequest: SurfaceSnapshotRequest? {
        guard let tile, let target = SurfaceTarget(rawValue: location.rawValue) else { return nil }
        return SurfaceSnapshotRequest(target: target, tile: tile)
    }
}

@MainActor final class UsageUIPresentation {
    let id: UUID
    let route: UsageUISceneRoute
    let client: UsageUIClient?
    let model: DashboardModel
    let presenter: UsagePresenterState
    let readOnly: Bool
    private(set) var stopping = false
    private(set) var drained = false
    private var drain: Task<Void, Never>?

    init(id: UUID, route: UsageUISceneRoute, client: UsageUIClient?, readOnly: Bool = false) {
        self.id = id; self.route = route; self.client = client; self.readOnly = readOnly
        model = DashboardModel(uiClient: client)
        presenter = UsagePresenterState(client: client)
    }

    func matches(_ context: NSDictionary) -> Bool {
        !stopping && context["presentationID"] as? String == id.uuidString
            && UsageUISceneRoute(context: context) == route
    }

    func controller() -> NSViewController? {
        guard !stopping else { return nil }
        return NSHostingController(
            rootView: ExtensionPageHost { UsagePresentationView(scene: self) })
    }

    func start() { client?.start() }

    func shutdown() {
        guard !stopping else { return }
        stopping = true
        model.shutdown(); presenter.shutdown()
        drain = Task { [self] in
            await client?.stopAndWait()
            await model.shutdownAndWait()
            drained = true
        }
    }

    func shutdownAndWait() async { shutdown(); await drain?.value }

    func compactLimits() async throws -> UsageCompactLimitsSnapshot {
        guard !stopping, let client, let request = route.surfaceRequest,
            request.tile.widget == .limits
        else { throw ExtensionPeerError.unavailable }
        let data = try await client.invoke(
            "usage.ui.compact.limits", payload: request.encoded(providerID: "usage"))
        guard data.count <= 131_072 else { throw ExtensionPeerError.invalidRequest }
        let value = try JSONDecoder().decode(UsageCompactLimitsSnapshot.self, from: data)
        try value.validate()
        try Task.checkCancellation()
        guard !stopping else { throw ExtensionPeerError.unavailable }
        return value
    }

    func snapshot() async throws -> SurfaceSnapshot {
        guard !stopping, let client, let request = route.surfaceRequest else {
            throw ExtensionPeerError.unavailable
        }
        let data = try await client.invoke(
            "surface.snapshot", payload: request.encoded(providerID: "usage"))
        let value = try SurfaceSnapshot.decode(data, providerID: "usage")
        try Task.checkCancellation()
        guard !stopping else { throw ExtensionPeerError.unavailable }
        return value
    }

    func open() async throws {
        guard !stopping, !readOnly, let client else { throw ExtensionPeerError.unavailable }
        let payload = try JSONSerialization.data(withJSONObject: [
            "presentationID": id.uuidString, "location": route.location.rawValue,
        ])
        _ = try await client.invoke("usage.ui.open", payload: payload)
    }

    func perform(_ action: SurfaceAction) async throws -> SurfaceSnapshot {
        guard !stopping, !readOnly, let client, let request = route.surfaceRequest,
            request.tile.showActions
        else { throw ExtensionPeerError.unavailable }
        if action.id == "open" { try await open(); return try await snapshot() }
        let payload = try SurfaceActionRequest(snapshot: request, actionID: action.id).encoded(
            providerID: "usage")
        let value = try SurfaceSnapshot.decode(
            try await client.invoke("surface.perform", payload: payload), providerID: "usage")
        guard !stopping else { throw ExtensionPeerError.unavailable }
        return value
    }
}

@MainActor final class UsageUIPresentations {
    private(set) var scenes: [UUID: UsageUIPresentation] = [:]
    var isEmpty: Bool { scenes.isEmpty }

    func configure(_ scene: UsageUIPresentation) -> Bool {
        scenes = scenes.filter { !$0.value.drained }
        guard scenes[scene.id] == nil, scenes.count < 16 else { return false }
        scenes[scene.id] = scene
        scene.start()
        return true
    }

    func release(_ id: UUID) { scenes[id]?.shutdown() }
    func stop() { for scene in scenes.values { scene.shutdown() } }
    func stopAndWait() async {
        stop()
        for scene in scenes.values { await scene.shutdownAndWait() }
        scenes = [:]
    }
}

private struct UsagePresentationView: View {
    let scene: UsageUIPresentation
    var body: some View {
        Group {
            switch scene.route.interior {
            case .dashboard:
                DashboardView(model: scene.model, client: scene.client, presenter: scene.presenter)
            case .settings:
                Form { UsageSettingsRows() }.formStyle(.grouped)
                    .disabled(scene.readOnly || scene.client?.prepared != true)
            default:
                if let tile = scene.route.tile { UsageHomeScene(tile: tile, scene: scene) }
            }
        }
        .environment(\.usageUIClient, scene.client)
        .environment(
            \.automaticViewActionsEnabled,
            !scene.readOnly && !scene.stopping && scene.client?.stopped == false)
    }
}

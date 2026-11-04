import EdithExtensionSupport
import Foundation

@MainActor
public final class HostSurfaces {
    public let preferences: UserDefaults
    public let layouts: SurfaceLayoutStore
    public let context: SurfaceHostContext
    public let requests: SurfaceSnapshotClient
    public let privacy: SurfacePrivacyState
    public let navigation: HostSurfaceNavigation
    public var layoutsChanged: @MainActor () -> Void {
        get { layoutObserver.action }
        set { layoutObserver.action = newValue }
    }
    private let layoutObserver: LayoutObserver

    private final class LayoutObserver {
        var action: @MainActor () -> Void = {}
    }

    private let entries: [HostExtension]
    private weak var sessions: HostExtensionSessions?

    public var demandedProviderIDs: Set<String> {
        HostSurfaceDemand.providerIDs(
            home: layouts.home, notch: layouts.notch,
            notchEnabled: sessions?.enabledIDs.contains("notchShelf") == true, entries: entries)
    }

    public init(identity: HostIdentity, entries: [HostExtension], sessions: HostExtensionSessions)
        throws
    {
        guard let defaults = SharedDefaults.applicationStore(identifier: identity.identifier) else {
            throw CocoaError(.validationMissingMandatoryProperty)
        }
        preferences = defaults
        self.entries = entries
        self.sessions = sessions
        let channel = ExtensionSharedState(
            root: identity.root.appendingPathComponent("ExtensionState"),
            namespace: identity.identifier, owner: "host")
        let releasePresenter: @MainActor () -> Void = { [weak sessions] in
            guard let sessions, !sessions.enabledIDs.contains("presenter") else { return }
            try? channel.clear("presenter")
        }
        releasePresenter()
        context = SurfaceHostContext(defaults: defaults, sharedState: channel)
        privacy = SurfacePrivacyState(channel: channel)
        navigation = HostSurfaceNavigation(context: context)
        let known = Set(entries.map(\.id))
        let activeVersions: @MainActor () -> [String: String] = { [weak sessions] in
            guard let sessions else { return [:] }
            return sessions.versions.filter {
                known.contains($0.key) && sessions.activeIDs.contains($0.key)
            }
        }
        let requests = SurfaceSnapshotClient(activeVersions: activeVersions) {
            id, command, payload in
            let endpoint = try ExtensionPeerEndpoint(
                namespace: identity.identifier, owner: id,
                directory: identity.root.appendingPathComponent("ExtensionState/Commands"))
            return try await endpoint.invoke(command, payload: payload, timeout: 5)
        }
        self.requests = requests
        let publish: @MainActor () -> Void = { [weak sessions] in
            releasePresenter()
            let versions = activeVersions()
            let enabled =
                sessions.map { $0.enabledIDs.subtracting($0.pendingDisableIDs).intersection(known) }
                ?? []
            guard let data = try? JSONEncoder().encode(versions.keys.sorted()),
                let encodedVersions = try? JSONEncoder().encode(versions),
                let encodedEnabled = try? JSONEncoder().encode(enabled.sorted())
            else { return }
            try? channel.publish([
                "surface.activeIDs": String(decoding: data, as: UTF8.self),
                "surface.enabledIDs": String(decoding: encodedEnabled, as: UTF8.self),
                "surface.activeVersions": String(decoding: encodedVersions, as: UTF8.self),
                "surface.revision": UUID().uuidString,
            ])
        }
        let observer = LayoutObserver()
        layoutObserver = observer
        layouts = SurfaceLayoutStore(defaults: defaults) {
            publish()
            observer.action()
        }
        sessions.didChange = { [weak requests] in
            requests?.retain(activeVersions: activeVersions())
            publish()
        }
        publish()
    }
}

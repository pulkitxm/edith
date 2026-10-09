import EdithExtensionSupport
import Foundation

@MainActor
public final class HostSurfaces {
    public let preferences: UserDefaults
    public let layouts: SurfaceLayoutStore
    public let context: SurfaceHostContext
    public let requests: SurfaceSnapshotClient
    public let privacy: SurfacePrivacyState

    public init(identity: HostIdentity, entries: [HostExtension], sessions: HostExtensionSessions)
        throws
    {
        guard let defaults = SharedDefaults.applicationStore(identifier: identity.identifier) else {
            throw CocoaError(.validationMissingMandatoryProperty)
        }
        preferences = defaults
        let channel = ExtensionSharedState(
            root: identity.root.appendingPathComponent("ExtensionState"),
            namespace: identity.identifier, owner: "host")
        context = SurfaceHostContext(defaults: defaults, sharedState: channel)
        privacy = SurfacePrivacyState(channel: channel)
        let known = Set(entries.map(\.id))
        let activeVersions: @MainActor () -> [String: String] = { [weak sessions] in
            guard let sessions else { return [:] }
            return sessions.versions.filter {
                known.contains($0.key) && sessions.states[$0.key] == .active
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
        let publish: @MainActor () -> Void = {
            let versions = activeVersions()
            guard let data = try? JSONEncoder().encode(versions.keys.sorted()),
                let encodedVersions = try? JSONEncoder().encode(versions)
            else { return }
            try? channel.publish([
                "surface.activeIDs": String(decoding: data, as: UTF8.self),
                "surface.activeVersions": String(decoding: encodedVersions, as: UTF8.self),
                "surface.revision": UUID().uuidString,
            ])
        }
        layouts = SurfaceLayoutStore(defaults: defaults, changed: publish)
        sessions.didChange = { [weak requests] in
            requests?.retain(activeVersions: activeVersions())
            publish()
        }
        publish()
    }
}

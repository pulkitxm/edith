import EdithExtensionSupport
import Foundation

@MainActor
public final class HostSurfaces {
    public let preferences: UserDefaults
    public let layouts: SurfaceLayoutStore
    public let context: SurfaceHostContext

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
        let known = Set(entries.map(\.id))
        let publish: @MainActor () -> Void = { [weak sessions] in
            guard let sessions,
                let data = try? JSONEncoder().encode(
                    known.intersection(sessions.versions.keys)
                        .filter { sessions.states[$0] == .active }.sorted())
            else { return }
            try? channel.publish([
                "surface.activeIDs": String(decoding: data, as: UTF8.self),
                "surface.revision": UUID().uuidString,
            ])
        }
        layouts = SurfaceLayoutStore(defaults: defaults, changed: publish)
        sessions.didChange = publish
        publish()
    }
}

import ExtensionMarketplace
import Foundation

public struct HostRemoteConfiguration: Codable, Sendable {
    public let session: UUID
    public let worker: HostWorkerConfiguration
    public let package: ExtensionPackage
    public let uiOnly: Bool

    public init(
        session: UUID, worker: HostWorkerConfiguration, package: ExtensionPackage, uiOnly: Bool
    ) {
        self.session = session
        self.worker = worker
        self.package = package
        self.uiOnly = uiOnly
    }

    public func validate(hostIdentifier: String, extensionID: String, version: String) throws {
        guard worker.identifier == hostIdentifier, worker.extensionID == extensionID,
            worker.version == version, !worker.recoveryOnly,
            package.id == extensionID, package.version == version,
            package.hostABI == HostContract.compatibility, package.architecture == "arm64",
            package.minimumSystemVersion
                <= .init(ProcessInfo.processInfo.operatingSystemVersion),
            worker.zoom.isFinite, (0.8...1.6).contains(worker.zoom),
            worker.theme.utf8.count <= 64, worker.appearance.utf8.count <= 32
        else { throw HostWorkerError.rejected }
        _ = try worker.identity()
    }

    @MainActor func uiContext(for request: HostExtensionContentRequest, engineClient: NSObject?)
        throws
        -> NSMutableDictionary
    {
        let input = NSMutableDictionary(dictionary: [
            "remoteUI": true, "inProcess": true, "uiOnly": uiOnly,
            "location": request.location,
            "presentationID": request.presentationID.uuidString,
            "defaultsSuite": try worker.identity().extensionDefaultsSuite(package.id),
            "hostIdentifier": worker.identifier, "extensionID": package.id,
        ])
        if let engineClient { input["engineClient"] = engineClient }
        input["section"] = request.section
        if let target = request.machinesWindow {
            input["target"] = try target.context(presentationID: request.presentationID)
        }
        if let target = request.herdrWindow {
            input["target"] = target.target
            input["herdrPresentationToken"] = target.token.uuidString
        }
        if let surface = request.surface {
            input["tile"] = try JSONEncoder().encode(surface.tile)
            input["target"] = surface.target.rawValue
        }
        return input
    }
}

public struct HostRemoteSceneDescriptor: Codable, Equatable, Sendable {
    public static let maximumScenes = 16
    public let sceneIdentifier: String
    public let presentationID: UUID

    public init(slot: Int, presentationID: UUID) throws {
        guard (0..<Self.maximumScenes).contains(slot) else { throw HostWorkerError.rejected }
        sceneIdentifier = "edith-ui-\(slot)"
        self.presentationID = presentationID
    }
}

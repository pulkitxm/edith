import Foundation

@MainActor
public struct ExtensionUIConfiguration {
    public let hostIdentifier: String
    public let extensionID: String
    public let defaultsSuite: String
    public let uiOnly: Bool
    public let engineClient: ExtensionEngineClient?

    public init?(context: NSDictionary) {
        let bundle = Bundle.main
        guard bundle.bundleURL.pathExtension == "appex",
            let host = bundle.object(forInfoDictionaryKey: "EdithHostIdentifier") as? String,
            let id = bundle.object(forInfoDictionaryKey: "EdithExtensionID") as? String,
            let suite = bundle.bundleIdentifier
        else { return nil }
        self.init(context: context, hostIdentifier: host, extensionID: id, defaultsSuite: suite)
    }

    init?(context: NSDictionary, hostIdentifier: String, extensionID: String, defaultsSuite: String)
    {
        guard context["remoteUI"] as? Bool == true,
            context["hostIdentifier"] as? String == hostIdentifier,
            context["extensionID"] as? String == extensionID,
            context["defaultsSuite"] as? String == defaultsSuite,
            defaultsSuite == hostIdentifier + ".extension." + extensionID + ".worker",
            let uiOnly = context["uiOnly"] as? Bool,
            let value = context["presentationID"] as? String,
            let presentation = UUID(uuidString: value)
        else { return nil }
        self.hostIdentifier = hostIdentifier
        self.extensionID = extensionID
        self.defaultsSuite = defaultsSuite
        self.uiOnly = uiOnly
        if uiOnly {
            guard context["location"] as? String == "settings", context["tile"] == nil,
                context["target"] == nil, context["engineClient"] == nil
            else { return nil }
            engineClient = nil
        } else {
            guard let bridge = context["engineClient"] as? NSObject,
                let client = ExtensionEngineClient(bridge: bridge, presentationID: presentation)
            else { return nil }
            engineClient = client
        }
    }
}

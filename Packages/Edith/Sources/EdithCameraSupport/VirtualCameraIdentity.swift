import CryptoKit
import Foundation

public enum VirtualCameraIdentity {
    public static let productionApplication = "com.pulkit.edith"
    public static let extensionSuffix = ".camera"
    public static let productName = "Edith Camera"
    public static let manufacturer = "Edith"
    public static let model = "Edith Virtual Camera"

    public static func extensionIdentifier(forApplication application: String) -> String {
        application + extensionSuffix
    }

    public static func application(forExtension identifier: String) -> String {
        guard identifier.hasSuffix(extensionSuffix) else { return identifier }
        return String(identifier.dropLast(extensionSuffix.count))
    }

    public static func slot(ofApplication application: String) -> String? {
        let developmentPrefix = productionApplication + ".dev."
        guard application != productionApplication else { return nil }
        if application.hasPrefix(developmentPrefix) {
            return String(application.dropFirst(developmentPrefix.count))
        }
        guard application.hasPrefix(productionApplication + ".") else { return nil }
        return String(application.dropFirst(productionApplication.count + 1))
    }

    public static func deviceName(forApplication application: String) -> String {
        guard let slot = slot(ofApplication: application), !slot.isEmpty else {
            return productName
        }
        return "\(productName) (\(slot))"
    }

    public static func deviceID(forExtension identifier: String) -> UUID {
        stableUUID("edith-camera-device:" + identifier)
    }

    public static func sourceStreamID(forExtension identifier: String) -> UUID {
        stableUUID("edith-camera-source:" + identifier)
    }

    public static func sinkStreamID(forExtension identifier: String) -> UUID {
        stableUUID("edith-camera-sink:" + identifier)
    }

    public static func machServiceName(teamIdentifier: String, extensionIdentifier: String)
        -> String
    {
        teamIdentifier + "." + extensionIdentifier
    }

    static func stableUUID(_ seed: String) -> UUID {
        var bytes = Array(SHA256.hash(data: Data(seed.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(
            uuid: (
                bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14],
                bytes[15]
            ))
    }
}

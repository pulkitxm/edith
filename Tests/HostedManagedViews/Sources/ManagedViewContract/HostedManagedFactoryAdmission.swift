import CoreFoundation
import Foundation

struct HostedManagedFactoryAdmission {
    static func accepts(_ input: NSDictionary, extensionID: String, role: Bundle, worker: Bundle)
        -> Bool
    {
        accepts(
            input, extensionID: extensionID, rolePath: role.bundleURL.path,
            roleVersion: role.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            roleABI: role.object(forInfoDictionaryKey: "EdithHostABI") as? String,
            workerIdentifier: worker.bundleIdentifier)
    }

    static func accepts(
        _ input: NSDictionary, extensionID: String, rolePath: String,
        roleVersion: String?, roleABI: String?, workerIdentifier: String?
    ) -> Bool {
        guard ["plugins", "studio"].contains(extensionID),
            let remoteUI = input["remoteUI"] as? NSNumber,
            CFGetTypeID(remoteUI) == CFBooleanGetTypeID(), remoteUI.boolValue,
            let uiOnly = input["uiOnly"] as? NSNumber, CFGetTypeID(uiOnly) == CFBooleanGetTypeID(),
            !uiOnly.boolValue,
            input["extensionID"] as? String == extensionID,
            let host = input["hostIdentifier"] as? String,
            host.hasPrefix("com.pulkit.edith.tests.worker-"),
            UUID(uuidString: String(host.dropFirst("com.pulkit.edith.tests.worker-".count))) != nil,
            workerIdentifier == host + ".extension." + extensionID + ".worker",
            input["defaultsSuite"] as? String == workerIdentifier,
            let presentation = input["presentationID"] as? String,
            UUID(uuidString: presentation) != nil,
            input["location"] as? String == "main", input["section"] as? String == extensionID,
            let fixture = input["hostedManagedFixture"] as? NSDictionary,
            Set(fixture.allKeys.compactMap { $0 as? String })
                == Set([
                    "schema", "sourceCommit", "selectedVersion", "hostABI", "sourceFingerprint",
                    "roleDirectory",
                ]), fixture.count == 6,
            let schema = fixture["schema"] as? NSNumber,
            CFGetTypeID(schema) != CFBooleanGetTypeID(), schema.doubleValue == 1,
            let source = fixture["sourceCommit"] as? String, source.count == 40,
            source.allSatisfy({ $0.isASCII && ("0123456789abcdef".contains($0)) }),
            let fingerprint = fixture["sourceFingerprint"] as? String, fingerprint.count == 64,
            fingerprint.allSatisfy({ $0.isASCII && ("0123456789abcdef".contains($0)) }),
            let version = roleVersion, let abi = roleABI,
            fixture["selectedVersion"] as? String == version,
            input["version"] as? String == version,
            fixture["hostABI"] as? String == abi, input["hostABI"] as? String == abi,
            fixture["roleDirectory"] as? String == rolePath,
            rolePath.hasPrefix("/"), !rolePath.utf8.contains(0), rolePath.utf8.count <= 4096,
            !rolePath.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }),
            rolePath.hasSuffix("/Contents/Resources/Payload/" + extensionID + "/app.bundle")
        else { return false }
        return true
    }
}

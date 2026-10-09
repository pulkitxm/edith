import CryptoKit
import Darwin
import ExtensionMarketplace
import Foundation

public enum HostContainedRoleError: Error {
    case rejected, invalidMetadata, invalidPayload, invalidFactory, invalidDescription,
        invalidResult, invalidPath
}

@MainActor
public enum HostContainedRole {
    public static let roles: Set<String> = ["cameraCarrier", "cameraProvider"]

    public static func accepts(role: String, arguments: [String], fixture: Bool) -> Bool {
        guard roles.contains(role) else { return false }
        if fixture { return arguments == ["--contained-extension-probe"] }
        return role == "cameraCarrier"
            ? arguments == ["--contained-extension-role"] : arguments.isEmpty
    }

    public static func run(arguments: [String]) throws -> Bool {
        guard let role = Bundle.main.object(forInfoDictionaryKey: "EdithContainedRole") as? String
        else { return false }
        let bundle = Bundle.main
        let fixture = fixtureAdmission(bundle)
        guard accepts(role: role, arguments: arguments, fixture: fixture),
            let owner = bundle.object(forInfoDictionaryKey: "EdithContainedExtensionID") as? String,
            owner == "virtualCamera",
            let host = bundle.object(forInfoDictionaryKey: "EdithHostIdentifier") as? String,
            host == "com.pulkit.edith" || host.hasPrefix("com.pulkit.edith.dev.")
                || host.hasPrefix("com.pulkit.edith.tests."),
            let identifier = bundle.bundleIdentifier,
            identifier == host + (role == "cameraCarrier" ? ".cameraCarrier" : ".camera"),
            let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString")
                as? String,
            !version.isEmpty, version.utf8.count <= 80,
            bundle.object(forInfoDictionaryKey: "EdithHostABI") as? String
                == HostContract.compatibility,
            let provenance = bundle.object(forInfoDictionaryKey: "EdithExecutableProvenance")
                as? String,
            provenance.count == 64, provenance.allSatisfy({ $0.isHexDigit })
        else { throw HostContainedRoleError.invalidMetadata }
        try verify(bundle.bundleURL, fixture: fixture)
        if role == "cameraCarrier", !fixture { try verifyReceipt(bundle) }
        let url = bundle.bundleURL.appendingPathComponent("Contents/PlugIns/\(role).bundle")
        try verify(url, fixture: fixture)
        guard let payload = Bundle(url: url),
            payload.bundleIdentifier == "com.pulkit.edith.extensions.\(owner).\(role)",
            payload.object(forInfoDictionaryKey: "EdithHostABI") as? String
                == HostContract.compatibility,
            payload.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
                == version,
            let executable = payload.executableURL,
            let handle = dlopen(executable.path, RTLD_NOW | RTLD_LOCAL),
            let symbol = dlsym(handle, "edith_extension_create")
        else { throw HostContainedRoleError.invalidPayload }
        typealias Factory = @convention(c) () -> UnsafeMutableRawPointer?
        guard let pointer = unsafeBitCast(symbol, to: Factory.self)() else {
            throw HostContainedRoleError.invalidFactory
        }
        let object = Unmanaged<NSObject>.fromOpaque(pointer).takeRetainedValue()
        let description = try execute(object, ["operation": "describe"])
        guard description["id"] as? String == owner, description["role"] as? String == role,
            description["version"] as? String == version,
            description["hostABI"] as? String == HostContract.compatibility
        else { throw HostContainedRoleError.invalidDescription }
        let operation = arguments == ["--contained-extension-probe"] ? "probe" : "start"
        let result = try execute(
            object,
            [
                "operation": operation, "fixture": fixture,
                "hostIdentifier": host, "version": version,
            ])
        guard result["ok"] as? Bool == true else { throw HostContainedRoleError.invalidResult }
        if operation == "probe" {
            let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
            FileHandle.standardOutput.write(data + Data([10]))
            _ = try execute(object, ["operation": "stop"])
            return true
        }
        CFRunLoopRun()
        _ = try execute(object, ["operation": "stop"])
        return true
    }

    private static func fixtureAdmission(_ bundle: Bundle) -> Bool {
        guard bundle.bundleIdentifier?.hasPrefix("com.pulkit.edith.tests.") == true,
            let path = ProcessInfo.processInfo.environment["EDITH_EXTENSION_FIXTURE_HOME"]
        else { return false }
        guard let root = canonical(URL(fileURLWithPath: path)),
            let location = canonical(bundle.bundleURL)
        else { return false }
        return location.hasPrefix(root + "/")
    }

    private static func canonical(_ url: URL) -> String? {
        guard let resolved = realpath(url.path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private static func verify(_ url: URL, fixture: Bool) throws {
        guard url.path == canonical(url) else {
            throw HostContainedRoleError.invalidPath
        }
        if fixture { try ExtensionCodeSignature.verifyDevelopment(url); return }
        guard let team = ExtensionCodeSignature.teamIdentifier() else {
            throw HostContainedRoleError.rejected
        }
        try ExtensionCodeSignature.verify(url, teamIdentifier: team)
    }

    private static func verifyReceipt(_ bundle: Bundle) throws {
        let url = bundle.bundleURL.deletingLastPathComponent().appendingPathComponent(".receipts")
            .appendingPathComponent((bundle.bundleIdentifier ?? "") + ".json")
        guard bundle.bundleURL.path.hasPrefix("/Applications/Edith Extensions/"),
            url.path == canonical(url)
        else { throw HostContainedRoleError.rejected }
        for component in [
            url, url.deletingLastPathComponent(), bundle.bundleURL,
            bundle.bundleURL.deletingLastPathComponent(),
        ] {
            let attributes = try FileManager.default.attributesOfItem(atPath: component.path)
            guard (attributes[.ownerAccountID] as? NSNumber)?.intValue == 0,
                let mode = attributes[.posixPermissions] as? NSNumber,
                mode.intValue & 0o022 == 0
            else { throw HostContainedRoleError.rejected }
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attributes[.size] as? NSNumber, size.intValue <= 16_384,
            let receipt = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
                as? [String: String],
            receipt["identifier"] == bundle.bundleIdentifier,
            receipt["version"] == bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString")
                as? String,
            receipt["path"] == bundle.bundleURL.path,
            let executable = bundle.executableURL,
            receipt["executableSHA256"]
                == SHA256.hash(data: try Data(contentsOf: executable))
                .map({ String(format: "%02x", $0) }).joined()
        else { throw HostContainedRoleError.rejected }
    }

    private static func execute(_ object: NSObject, _ input: NSDictionary) throws -> NSDictionary {
        let selector = NSSelectorFromString("execute:")
        guard object.responds(to: selector),
            let result = object.perform(selector, with: input)?.takeUnretainedValue()
                as? NSDictionary
        else { throw HostContainedRoleError.rejected }
        return result
    }
}

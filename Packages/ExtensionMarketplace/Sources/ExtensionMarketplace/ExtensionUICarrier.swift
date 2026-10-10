import Foundation
import Security

public struct ExtensionUICarrier: Sendable {
    public let application: URL
    public let worker: URL
    public let workerIdentifier: String
    public let extensionPointIdentifier: String
    public let hostIdentifier: String
    public let hostExecutablePath: String
    public let hostCodeRequirement: String
    public let executableProvenance: String

    public init(payload: URL, package: ExtensionPackage, expectedHostIdentifier: String? = nil)
        throws
    {
        try self.init(
            payload: payload, manifest: ExtensionPayloadManifest(package: package),
            expectedHostIdentifier: expectedHostIdentifier)
    }

    public init(
        payload: URL, manifest: ExtensionPayloadManifest, expectedHostIdentifier: String? = nil
    ) throws {
        application = payload.appendingPathComponent("ExtensionCarrier.app")
        worker = application.appendingPathComponent("Contents/Extensions/ExtensionWorker.appex")
        try Self.requireRegularTree(application)
        let carrier = try Self.readInfo(application)
        let extensionInfo = try Self.readInfo(worker)
        guard let host = carrier["EdithHostIdentifier"] as? String,
            host == "com.pulkit.edith"
                || host.hasPrefix("com.pulkit.edith.dev.")
                || host.hasPrefix("com.pulkit.edith.tests."),
            host.count <= 192,
            host.range(of: "^[A-Za-z0-9-]+(?:\\.[A-Za-z0-9-]+)+$", options: .regularExpression)
                != nil,
            expectedHostIdentifier == nil || host == expectedHostIdentifier,
            let executablePath = carrier["EdithHostExecutablePath"] as? String,
            executablePath.count <= 4096, executablePath.hasPrefix("/"),
            !executablePath.contains("\0"), !executablePath.contains("\n"),
            !executablePath.contains("\r"),
            executablePath.split(separator: "/", omittingEmptySubsequences: false).dropFirst()
                .allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
            host != "com.pulkit.edith"
                || executablePath == "/Applications/Edith.app/Contents/MacOS/Edith",
            let requirement = carrier["EdithHostCodeRequirement"] as? String,
            !requirement.isEmpty, requirement.count <= 4096,
            !requirement.contains("\0"), !requirement.contains("\n"),
            !requirement.contains("\r"),
            let provenance = carrier["EdithExecutableProvenance"] as? String,
            provenance.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil
        else { throw MarketplaceError.invalidArchive }
        var compiled: SecRequirement?
        guard
            SecRequirementCreateWithString(requirement as CFString, [], &compiled) == errSecSuccess,
            compiled != nil
        else { throw MarketplaceError.invalidArchive }
        let identifier = "\(host).extension.\(manifest.id)"
        let shared: [String: String] = [
            "CFBundleExecutable": "Edith",
            "CFBundleShortVersionString": manifest.version,
            "CFBundleVersion": manifest.version,
            "EdithHostIdentifier": host,
            "EdithExtensionID": manifest.id,
            "EdithExtensionVersion": manifest.version,
            "EdithHostABI": manifest.hostABI,
            "EdithHostCodeRequirement": requirement,
            "EdithHostExecutablePath": executablePath,
            "EdithExecutableProvenance": provenance,
            "EdithPayloadRelativePath": "../../../..",
        ]
        guard shared.allSatisfy({ carrier[$0.key] as? String == $0.value }),
            shared.allSatisfy({ extensionInfo[$0.key] as? String == $0.value }),
            carrier["CFBundleIdentifier"] as? String == identifier,
            carrier["CFBundlePackageType"] as? String == "APPL",
            carrier["LSUIElement"] as? Bool == true,
            extensionInfo["CFBundleIdentifier"] as? String == "\(identifier).worker",
            extensionInfo["CFBundlePackageType"] as? String == "XPC!",
            let attributes = extensionInfo["EXAppExtensionAttributes"] as? [String: Any],
            attributes["EXExtensionPointIdentifier"] as? String == "\(host).ExtensionUI",
            try FileManager.default.contentsOfDirectory(
                at: application.appendingPathComponent("Contents/Extensions"),
                includingPropertiesForKeys: nil
            ).map(\.lastPathComponent) == ["ExtensionWorker.appex"]
        else { throw MarketplaceError.invalidArchive }
        try Self.requireExecutable(application.appendingPathComponent("Contents/MacOS/Edith"))
        try Self.requireExecutable(worker.appendingPathComponent("Contents/MacOS/Edith"))
        hostIdentifier = host
        hostExecutablePath = executablePath
        hostCodeRequirement = requirement
        executableProvenance = provenance
        workerIdentifier = "\(identifier).worker"
        extensionPointIdentifier = "\(host).ExtensionUI"
    }

    public func verify(teamIdentifier: String) throws {
        try ExtensionCodeSignature.verify(application, teamIdentifier: teamIdentifier)
        try ExtensionCodeSignature.verify(worker, teamIdentifier: teamIdentifier)
        try requireSandbox()
    }

    public func verifyDevelopment() throws {
        guard
            hostIdentifier.hasPrefix("com.pulkit.edith.tests.")
                || hostIdentifier.hasPrefix("com.pulkit.edith.dev.")
        else { throw MarketplaceError.invalidSignature }
        try ExtensionCodeSignature.verifyDevelopment(application)
        try ExtensionCodeSignature.verifyDevelopment(worker)
        try requireSandbox()
    }

    private func requireSandbox() throws {
        var code: SecStaticCode?
        var information: CFDictionary?
        guard SecStaticCodeCreateWithPath(worker as CFURL, [], &code) == errSecSuccess,
            let code,
            SecCodeCopySigningInformation(
                code, SecCSFlags(rawValue: kSecCSSigningInformation), &information)
                == errSecSuccess,
            let information = information as? [String: Any],
            let entitlements = information[kSecCodeInfoEntitlementsDict as String]
                as? [String: Any],
            entitlements.count == 1,
            entitlements["com.apple.security.app-sandbox"] as? Bool == true
        else { throw MarketplaceError.invalidSignature }
    }

    private static func readInfo(_ bundle: URL) throws -> [String: Any] {
        let url = bundle.appendingPathComponent("Contents/Info.plist")
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, let bytes = values.fileSize, bytes <= 65536,
            let dictionary = try PropertyListSerialization.propertyList(
                from: Data(contentsOf: url), format: nil) as? [String: Any]
        else { throw MarketplaceError.invalidArchive }
        return dictionary
    }

    private static func requireExecutable(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, (values.fileSize ?? 0) > 0,
            FileManager.default.isExecutableFile(atPath: url.path)
        else { throw MarketplaceError.invalidArchive }
    }

    private static func requireRegularTree(_ root: URL) throws {
        let rootValues = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true,
            let entries = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [
                    .isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey,
                ])
        else { throw MarketplaceError.invalidArchive }
        for case let url as URL in entries {
            let values = try url.resourceValues(
                forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey])
            guard values.isSymbolicLink != true,
                values.isRegularFile == true || values.isDirectory == true
            else { throw MarketplaceError.invalidArchive }
        }
    }
}

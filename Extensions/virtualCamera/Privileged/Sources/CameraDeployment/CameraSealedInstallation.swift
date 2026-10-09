import CryptoKit
import Darwin
import Foundation
import Security

public struct CameraInstallIdentity: Equatable {
    public let identifier: String
    public let team: String
    public let digest: Data
    public init(identifier: String, team: String, digest: Data) {
        self.identifier = identifier; self.team = team; self.digest = digest
    }
}

public final class CameraSealedInstallation {
    public struct Configuration {
        public let hostIdentifier: String
        public let version: String
        public let hostABI: String
        public let destination: URL
        public let microphoneDestination: URL
        public let owner: uid_t
        let protectedBoundary: URL
        public init(
            hostIdentifier: String, version: String, hostABI: String,
            destination: URL = URL(fileURLWithPath: "/Applications/Edith Extensions"),
            microphoneDestination: URL = URL(fileURLWithPath: "/Library/Audio/Plug-Ins/HAL"),
            owner: uid_t = 0, protectedBoundary: URL = URL(fileURLWithPath: "/")
        ) {
            self.hostIdentifier = hostIdentifier; self.version = version; self.hostABI = hostABI
            self.destination = destination; self.microphoneDestination = microphoneDestination;
            self.owner = owner; self.protectedBoundary = protectedBoundary
        }
    }

    private let configuration: Configuration
    private let verify: (URL) throws -> CameraInstallIdentity
    private let ownIdentity: CameraInstallIdentity
    private let files = FileManager.default

    public init(
        configuration: Configuration, privilegedBundle: URL,
        verify: @escaping (URL) throws -> CameraInstallIdentity = signature
    ) throws {
        self.configuration = configuration; self.verify = verify
        ownIdentity = try verify(privilegedBundle)
        guard ownIdentity.identifier == "com.pulkit.edith.extensions.virtualCamera.privileged",
            !ownIdentity.team.isEmpty, !configuration.version.isEmpty,
            configuration.version.utf8.count <= 80, configuration.hostABI == "edith-host-1",
            configuration.hostIdentifier == "com.pulkit.edith"
                || configuration.hostIdentifier.hasPrefix("com.pulkit.edith.dev.")
        else { throw failure("The camera installer identity is invalid.") }
    }

    public func installCarrier(source: URL, providerExited: Bool) throws -> URL {
        try regularTree(source)
        let sourceIdentity = try carrierIdentity(source)
        let identifier = configuration.hostIdentifier + ".cameraCarrier"
        let installed = configuration.destination.appendingPathComponent(identifier + ".app")
        try protectedDirectory(configuration.destination)
        try protectedDirectory(configuration.destination.appendingPathComponent(".receipts"))
        let receipt = configuration.destination.appendingPathComponent(
            ".receipts/" + identifier + ".json")
        if files.fileExists(atPath: installed.path) {
            try protectedTree(installed)
            let current = try carrierIdentity(installed)
            if current == sourceIdentity, try receiptMatches(receipt, installed: installed) {
                return installed
            }
            guard providerExited else {
                throw failure(
                    "Disable the camera and restart macOS before updating its installed provider.")
            }
        }
        let staging = configuration.destination.appendingPathComponent(
            ".camera-" + UUID().uuidString + ".app")
        defer { try? files.removeItem(at: staging) }
        try files.copyItem(at: source, to: staging)
        try regularTree(staging)
        guard try carrierIdentity(staging) == sourceIdentity else {
            throw failure("The camera carrier changed during installation.")
        }
        try protect(staging)
        let existed = files.fileExists(atPath: installed.path)
        let previousReceipt = try? Data(contentsOf: receipt)
        try atomicReplace(staging, installed)
        var committed = false
        defer {
            if !committed {
                if existed {
                    try? atomicReplace(staging, installed)
                } else {
                    try? files.removeItem(at: installed)
                }
                if let previousReceipt {
                    try? previousReceipt.write(to: receipt, options: .atomic)
                } else {
                    try? files.removeItem(at: receipt)
                }
            }
        }
        guard try carrierIdentity(installed) == sourceIdentity else {
            throw failure("The installed camera failed signature verification.")
        }
        let bundle = try requiredBundle(installed)
        let executable = try requiredExecutable(bundle)
        let values = [
            "identifier": identifier, "version": configuration.version,
            "hostABI": configuration.hostABI, "path": installed.path,
            "originalHostSHA256": bundle.object(forInfoDictionaryKey: "EdithExecutableProvenance")
                as! String, "executableSHA256": try digest(executable),
        ]
        let encoded = try JSONSerialization.data(withJSONObject: values, options: [.sortedKeys])
        try encoded.write(to: receipt, options: .atomic)
        try files.setAttributes(
            [.ownerAccountID: NSNumber(value: configuration.owner), .posixPermissions: 0o644],
            ofItemAtPath: receipt.path)
        try protectedTree(installed)
        guard try receiptMatches(receipt, installed: installed) else {
            throw failure("The camera installation receipt is invalid.")
        }
        committed = true
        return installed
    }

    public func installMicrophone(carrier: URL) throws -> Bool {
        try protectedTree(carrier)
        _ = try carrierIdentity(carrier)
        let identifier = configuration.hostIdentifier + ".microphone"
        let source = carrier.appendingPathComponent(
            "Contents/Library/Audio/Plug-Ins/HAL/" + identifier + ".driver")
        try regularTree(source)
        let signature = try verify(source)
        guard signature.identifier == identifier, signature.team == ownIdentity.team else {
            throw failure("The microphone signature is invalid.")
        }
        try protectedDirectory(configuration.microphoneDestination)
        let installed = configuration.microphoneDestination.appendingPathComponent(
            identifier + ".driver")
        if files.fileExists(atPath: installed.path) {
            try protectedTree(installed)
            if try verify(installed) == signature { return false }
        }
        let staging = configuration.microphoneDestination.appendingPathComponent(
            ".camera-microphone-" + UUID().uuidString)
        defer { try? files.removeItem(at: staging) }
        try files.copyItem(at: source, to: staging)
        try regularTree(staging)
        guard try verify(staging) == signature else {
            throw failure("The microphone changed during installation.")
        }
        try protect(staging)
        let existed = files.fileExists(atPath: installed.path)
        try atomicReplace(staging, installed)
        var committed = false
        defer {
            if !committed {
                if existed {
                    try? atomicReplace(staging, installed)
                } else {
                    try? files.removeItem(at: installed)
                }
            }
        }
        guard try verify(installed) == signature else {
            throw failure("The installed microphone signature is invalid.")
        }
        committed = true
        return true
    }

    public func removeMicrophone() throws -> Bool {
        let identifier = configuration.hostIdentifier + ".microphone"
        let installed = configuration.microphoneDestination.appendingPathComponent(
            identifier + ".driver")
        guard files.fileExists(atPath: installed.path) else { return false }
        try protectedTree(installed)
        let identity = try verify(installed)
        guard identity.identifier == identifier, identity.team == ownIdentity.team else {
            throw failure("The installed microphone signature is invalid.")
        }
        try files.removeItem(at: installed)
        return true
    }

    private func carrierIdentity(_ url: URL) throws -> CameraInstallIdentity {
        let identity = try verify(url)
        let bundle = try requiredBundle(url)
        let identifier = configuration.hostIdentifier + ".cameraCarrier"
        guard identity.identifier == identifier, identity.team == ownIdentity.team,
            bundle.bundleIdentifier == identifier,
            bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
                == configuration.version,
            bundle.object(forInfoDictionaryKey: "EdithContainedRole") as? String == "cameraCarrier",
            bundle.object(forInfoDictionaryKey: "EdithContainedExtensionID") as? String
                == "virtualCamera",
            bundle.object(forInfoDictionaryKey: "EdithHostIdentifier") as? String
                == configuration.hostIdentifier,
            bundle.object(forInfoDictionaryKey: "EdithHostABI") as? String == configuration.hostABI,
            let provenance = bundle.object(forInfoDictionaryKey: "EdithExecutableProvenance")
                as? String,
            provenance.count == 64, provenance.allSatisfy({ $0.isHexDigit })
        else { throw failure("The camera carrier metadata is invalid.") }
        _ = try requiredExecutable(bundle)
        let embedded = url.appendingPathComponent("Contents/PlugIns/privileged.bundle")
        guard try verify(embedded) == ownIdentity else {
            throw failure("The carrier does not contain its approved installer.")
        }
        let provider = url.appendingPathComponent(
            "Contents/Library/SystemExtensions/" + configuration.hostIdentifier
                + ".camera.systemextension")
        let providerIdentity = try verify(provider)
        guard providerIdentity.identifier == configuration.hostIdentifier + ".camera",
            providerIdentity.team == ownIdentity.team
        else { throw failure("The camera provider signature is invalid.") }
        return identity
    }

    private func receiptMatches(_ url: URL, installed: URL) throws -> Bool {
        guard files.fileExists(atPath: url.path) else { return false }
        try protectedTree(url)
        let size = try files.attributesOfItem(atPath: url.path)[.size] as? NSNumber
        guard let size, size.intValue <= 16384 else { return false }
        let values =
            try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: String]
        let executable = try requiredExecutable(requiredBundle(installed))
        let executableDigest = try digest(executable)
        return values?["identifier"] == configuration.hostIdentifier + ".cameraCarrier"
            && values?["version"] == configuration.version
            && values?["hostABI"] == configuration.hostABI && values?["path"] == installed.path
            && values?["executableSHA256"] == executableDigest
    }

    private func protectedDirectory(_ directory: URL) throws {
        guard
            canonical(directory.deletingLastPathComponent())
                == directory.deletingLastPathComponent().path
        else { throw failure("The camera installation parent path is invalid.") }
        var parent = directory.deletingLastPathComponent()
        while parent.path != "/" {
            try protectedTree(parent, recursive: false)
            if parent == configuration.protectedBoundary { break }
            parent.deleteLastPathComponent()
        }
        if !files.fileExists(atPath: directory.path) {
            try files.createDirectory(
                at: directory, withIntermediateDirectories: false,
                attributes: [
                    .ownerAccountID: NSNumber(value: configuration.owner), .posixPermissions: 0o755,
                ])
        }
        try protectedTree(directory, recursive: false)
    }

    private func protectedTree(_ url: URL, recursive: Bool = true) throws {
        try regularTree(url, recursive: recursive)
        let attributes = try files.attributesOfItem(atPath: url.path)
        guard (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == configuration.owner,
            let mode = attributes[.posixPermissions] as? NSNumber, mode.intValue & 0o022 == 0
        else { throw failure("The installed camera path is writable or has an invalid owner.") }
        if recursive, (attributes[.type] as? FileAttributeType) == .typeDirectory {
            for child in try files.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) {
                try protectedTree(child)
            }
        }
    }

    private func regularTree(_ url: URL, recursive: Bool = true) throws {
        guard canonical(url) == url.path else {
            throw failure("Camera components cannot contain symbolic links.")
        }
        let values = try url.resourceValues(forKeys: [
            .isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey,
        ])
        guard values.isSymbolicLink != true,
            values.isRegularFile == true || values.isDirectory == true
        else { throw failure("Camera components require regular files and directories.") }
        if recursive, values.isDirectory == true {
            for child in try files.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) {
                try regularTree(child)
            }
        }
    }

    private func protect(_ url: URL) throws {
        let attributes = try files.attributesOfItem(atPath: url.path)
        let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0o644
        var protection: [FileAttributeKey: Any] = [
            .ownerAccountID: NSNumber(value: configuration.owner), .posixPermissions: mode & ~0o022,
        ]
        if configuration.owner == 0 { protection[.groupOwnerAccountID] = 0 }
        try files.setAttributes(protection, ofItemAtPath: url.path)
        if (attributes[.type] as? FileAttributeType) == .typeDirectory {
            for child in try files.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) {
                try protect(child)
            }
        }
    }

    private func atomicReplace(_ staging: URL, _ installed: URL) throws {
        let replacing = files.fileExists(atPath: installed.path)
        guard
            renamex_np(
                staging.path, installed.path, replacing ? UInt32(RENAME_SWAP) : UInt32(RENAME_EXCL))
                == 0
        else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    private func requiredBundle(_ url: URL) throws -> Bundle {
        guard let bundle = Bundle(url: url) else { throw failure("The camera bundle is missing.") }
        return bundle
    }
    private func requiredExecutable(_ bundle: Bundle) throws -> URL {
        guard let executable = bundle.executableURL, files.isExecutableFile(atPath: executable.path)
        else { throw failure("The camera executable is missing.") }
        return executable
    }
    private func canonical(_ url: URL) -> String? {
        guard let result = realpath(url.path, nil) else { return nil }
        defer { free(result) }
        return String(cString: result)
    }
    private func digest(_ url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }

    public static func signature(_ url: URL) throws -> CameraInstallIdentity {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
            SecStaticCodeCheckValidity(
                code,
                SecCSFlags(
                    rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures
                        | kSecCSCheckNestedCode), nil) == errSecSuccess
        else { throw failure("The camera component failed signature verification.") }
        var information: CFDictionary?
        guard
            SecCodeCopySigningInformation(
                code, SecCSFlags(rawValue: kSecCSSigningInformation), &information)
                == errSecSuccess,
            let values = information as? [CFString: Any],
            let identifier = values[kSecCodeInfoIdentifier] as? String,
            let team = values[kSecCodeInfoTeamIdentifier] as? String,
            team.count == 10, team.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }),
            let digest = values[kSecCodeInfoUnique] as? Data
        else { throw failure("The camera component signing identity is unavailable.") }
        var requirement: SecRequirement?
        guard
            SecRequirementCreateWithString(
                "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\"" as CFString,
                [], &requirement) == errSecSuccess,
            let requirement,
            SecStaticCodeCheckValidity(
                code, SecCSFlags(rawValue: kSecCSStrictValidate), requirement) == errSecSuccess
        else { throw failure("The camera component requires a Developer ID signature.") }
        return .init(identifier: identifier, team: team, digest: digest)
    }

    private static func failure(_ message: String) -> NSError {
        NSError(
            domain: "EdithCameraDeployment", code: 1, userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
    private func failure(_ message: String) -> NSError { Self.failure(message) }
}

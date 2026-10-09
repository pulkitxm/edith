import Darwin
import ExtensionMarketplace
import Foundation
import Security

struct HostPrivilegedCaller {
    private let owner: String?
    private let version: String?
    private let source: URL?
    let container: URL?

    init(information: [String: Any], hostIdentifier: String, hostABI: String) throws {
        guard let identifier = information[kSecCodeInfoIdentifier as String] as? String,
            let info = information[kSecCodeInfoPList as String] as? [String: Any],
            info["CFBundleIdentifier"] as? String == identifier
        else { throw MarketplaceError.invalidSignature }
        if identifier == hostIdentifier {
            owner = nil; version = nil; source = nil; container = nil; return
        }
        guard let role = info["EdithContainedRole"] as? String,
            role.hasSuffix("Carrier"), Self.valid(role),
            identifier == hostIdentifier + "." + role,
            info["EdithHostIdentifier"] as? String == hostIdentifier,
            info["EdithHostABI"] as? String == hostABI,
            let owner = info["EdithContainedExtensionID"] as? String, Self.valid(owner),
            let version = info["CFBundleShortVersionString"] as? String, Self.valid(version),
            let provenance = info["EdithExecutableProvenance"] as? String,
            provenance.utf8.count == 64,
            provenance.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
            let executable = information[kSecCodeInfoMainExecutable as String] as? URL,
            executable.isFileURL,
            executable.deletingLastPathComponent().lastPathComponent == "MacOS",
            executable.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent
                == "Contents"
        else { throw MarketplaceError.invalidSignature }
        let container = executable.deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().standardizedFileURL
        guard container.pathExtension == "app" else { throw MarketplaceError.invalidSignature }
        self.owner = owner; self.version = version; self.container = container
        source = container.appendingPathComponent("Contents/PlugIns/privileged.bundle")
    }

    func authorize(source: URL, owner: String, version: String) throws {
        guard source.isFileURL else { throw MarketplaceError.invalidBundle }
        if let required = self.source {
            guard source.standardizedFileURL == required,
                source.path == source.standardizedFileURL.path,
                owner == self.owner, version == self.version
            else { throw MarketplaceError.invalidSignature }
        }
    }

    static func requirement(hostIdentifier: String, team: String) throws -> String {
        guard Self.valid(hostIdentifier), Self.valid(team) else {
            throw MarketplaceError.invalidSignature
        }
        return
            "(identifier \"\(hostIdentifier)\" or (info[EdithHostIdentifier] = \"\(hostIdentifier)\" and info[EdithHostABI] = \"\(HostContract.compatibility)\")) and anchor apple generic and certificate leaf[subject.OU] = \"\(team)\""
    }

    static func read(processIdentifier: pid_t, hostIdentifier: String, team: String) throws
        -> HostPrivilegedCaller
    {
        guard processIdentifier > 0 else { throw MarketplaceError.invalidSignature }
        var code: SecCode?
        let attributes = [kSecGuestAttributePid as String: NSNumber(value: processIdentifier)]
        guard
            SecCodeCopyGuestWithAttributes(nil, attributes as CFDictionary, [], &code)
                == errSecSuccess, let code
        else { throw MarketplaceError.invalidSignature }
        var requirement: SecRequirement?
        guard
            SecRequirementCreateWithString(
                try Self.requirement(hostIdentifier: hostIdentifier, team: team) as CFString,
                [], &requirement) == errSecSuccess,
            SecCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), requirement)
                == errSecSuccess
        else { throw MarketplaceError.invalidSignature }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else {
            throw MarketplaceError.invalidSignature
        }
        var information: CFDictionary?
        guard
            SecCodeCopySigningInformation(
                staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information)
                == errSecSuccess,
            let information = information as? [String: Any]
        else { throw MarketplaceError.invalidSignature }
        let caller = try Self(
            information: information, hostIdentifier: hostIdentifier,
            hostABI: HostContract.compatibility)
        if let container = caller.container {
            try immutableContainer(container)
            try ExtensionCodeSignature.verify(container, teamIdentifier: team)
        }
        return caller
    }

    private static func immutableContainer(_ container: URL) throws {
        var parent = container
        while parent.path != "/" {
            try immutablePath(parent); parent.deleteLastPathComponent()
        }
        guard
            let paths = FileManager.default.enumerator(
                at: container, includingPropertiesForKeys: nil)
        else { throw MarketplaceError.invalidSignature }
        var count = 0
        var bytes: Int64 = 0
        for case let path as URL in paths {
            let info = try immutablePath(path)
            count += 1; bytes += Int64(info.st_size)
            guard count <= 10_000, bytes <= 256 * 1_024 * 1_024 else {
                throw MarketplaceError.invalidSignature
            }
        }
    }

    @discardableResult private static func immutablePath(_ path: URL) throws -> stat {
        var value = stat()
        guard lstat(path.path, &value) == 0, value.st_uid == 0, value.st_mode & 0o022 == 0,
            [S_IFREG, S_IFDIR].contains(value.st_mode & S_IFMT),
            value.st_nlink == 1 || value.st_mode & S_IFMT == S_IFDIR
        else { throw MarketplaceError.invalidSignature }
        return value
    }

    private static func valid(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 200
            && value.utf8.allSatisfy {
                (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
                    || [45, 46, 95].contains($0)
            } && value != "." && value != ".."
    }
}

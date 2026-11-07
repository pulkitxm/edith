import Darwin
import ExtensionMarketplace
import Foundation
import Security

struct HostPrivilegedCallerRejection: Error, Equatable, LocalizedError, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
    var errorDescription: String? { MarketplaceError.invalidSignature.errorDescription }
}

struct HostPrivilegedCaller {
    private let owner: String?
    private let version: String?
    private let source: URL?
    let container: URL?

    init(information: [String: Any], hostIdentifier: String, hostABI: String) throws {
        guard let identifier = information[kSecCodeInfoIdentifier as String] as? String else {
            throw HostPrivilegedCallerRejection("the signature has no identifier")
        }
        guard let info = information[kSecCodeInfoPList as String] as? [String: Any] else {
            throw HostPrivilegedCallerRejection("the signature of \(identifier) seals no Info.plist")
        }
        guard info["CFBundleIdentifier"] as? String == identifier else {
            throw HostPrivilegedCallerRejection(
                "the bundle identifier \(Self.shown(info["CFBundleIdentifier"])) differs from the signed identifier \(identifier)"
            )
        }
        if identifier == hostIdentifier {
            owner = nil; version = nil; source = nil; container = nil; return
        }
        let role = info["EdithContainedRole"] as? String
        guard let role, role.hasSuffix("Carrier"), Self.valid(role),
            identifier == hostIdentifier + "." + role
        else {
            throw HostPrivilegedCallerRejection(
                "\(identifier) is not a carrier of \(hostIdentifier) (role \(Self.shown(role)))")
        }
        guard info["EdithHostIdentifier"] as? String == hostIdentifier else {
            throw HostPrivilegedCallerRejection(
                "\(identifier) belongs to host \(Self.shown(info["EdithHostIdentifier"]))")
        }
        guard info["EdithHostABI"] as? String == hostABI else {
            throw HostPrivilegedCallerRejection(
                "\(identifier) targets \(Self.shown(info["EdithHostABI"])) instead of \(hostABI)")
        }
        guard let owner = info["EdithContainedExtensionID"] as? String, Self.valid(owner) else {
            throw HostPrivilegedCallerRejection(
                "\(identifier) names an invalid extension \(Self.shown(info["EdithContainedExtensionID"]))"
            )
        }
        guard let version = info["CFBundleShortVersionString"] as? String, Self.valid(version)
        else {
            throw HostPrivilegedCallerRejection(
                "\(identifier) has an invalid version \(Self.shown(info["CFBundleShortVersionString"]))"
            )
        }
        guard let provenance = info["EdithExecutableProvenance"] as? String,
            provenance.utf8.count == 64,
            provenance.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
        else {
            throw HostPrivilegedCallerRejection(
                "\(identifier) has an invalid executable provenance \(Self.shown(info["EdithExecutableProvenance"]))"
            )
        }
        let reported = information[kSecCodeInfoMainExecutable as String]
        guard let executable = reported as? URL, executable.isFileURL,
            executable.deletingLastPathComponent().lastPathComponent == "MacOS",
            executable.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent
                == "Contents"
        else {
            throw HostPrivilegedCallerRejection(
                "\(identifier) runs from \(Self.shown(reported)) instead of an app's Contents/MacOS")
        }
        let container = executable.deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().standardizedFileURL
        guard container.pathExtension == "app" else {
            throw HostPrivilegedCallerRejection(
                "\(identifier) runs from \(container.path), which is not an app")
        }
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
        let abis = ExtensionHostABI.accepted(host: HostContract.compatibility)
            .map { "info[EdithHostABI] = \"\($0)\"" }.joined(separator: " or ")
        return
            "(identifier \"\(hostIdentifier)\" or (info[EdithHostIdentifier] = \"\(hostIdentifier)\" and (\(abis)))) and anchor apple generic and certificate leaf[subject.OU] = \"\(team)\""
    }

    static func read(processIdentifier: pid_t, hostIdentifier: String, team: String) throws
        -> HostPrivilegedCaller
    {
        guard processIdentifier > 0 else {
            throw HostPrivilegedCallerRejection("process \(processIdentifier) is not a caller")
        }
        var code: SecCode?
        let attributes = [kSecGuestAttributePid as String: NSNumber(value: processIdentifier)]
        let guest = SecCodeCopyGuestWithAttributes(nil, attributes as CFDictionary, [], &code)
        guard guest == errSecSuccess, let code else {
            throw HostPrivilegedCallerRejection(
                "macOS has no code for process \(processIdentifier) (\(guest))")
        }
        var requirement: SecRequirement?
        let expression = try Self.requirement(hostIdentifier: hostIdentifier, team: team)
        guard SecRequirementCreateWithString(expression as CFString, [], &requirement)
            == errSecSuccess, let requirement
        else { throw HostPrivilegedCallerRejection("the caller requirement does not compile") }
        var failure: Unmanaged<CFError>?
        let validity = SecCodeCheckValidityWithErrors(
            code, SecCSFlags(rawValue: kSecCSStrictValidate), requirement, &failure)
        guard validity == errSecSuccess else {
            let reason = failure?.takeRetainedValue().localizedDescription ?? "no detail"
            throw HostPrivilegedCallerRejection(
                "process \(processIdentifier) fails the caller requirement (\(validity)): \(reason)")
        }
        var staticCode: SecStaticCode?
        let copied = SecCodeCopyStaticCode(code, [], &staticCode)
        guard copied == errSecSuccess, let staticCode else {
            throw HostPrivilegedCallerRejection(
                "process \(processIdentifier) has no code on disk (\(copied))")
        }
        var information: CFDictionary?
        let signing = SecCodeCopySigningInformation(
            staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information)
        guard signing == errSecSuccess, let information = information as? [String: Any] else {
            throw HostPrivilegedCallerRejection(
                "process \(processIdentifier) has no signing information (\(signing))")
        }
        let caller = try Self(
            information: information, hostIdentifier: hostIdentifier,
            hostABI: HostContract.compatibility)
        if let container = caller.container {
            try immutableContainer(container)
            do { try ExtensionCodeSignature.verify(container, teamIdentifier: team) } catch {
                throw HostPrivilegedCallerRejection(
                    "\(container.path) fails signature verification: \(error)")
            }
        }
        return caller
    }

    private static func immutableContainer(_ container: URL) throws {
        var parent = container
        var protectedChild: stat?
        while parent.path != "/" {
            var metadata = stat()
            guard lstat(parent.path, &metadata) == 0 else {
                throw HostPrivilegedCallerRejection(
                    "\(parent.path) cannot be read (errno \(errno))")
            }
            try validateAncestor(parent, metadata: metadata, protectedChild: protectedChild)
            protectedChild = metadata; parent.deleteLastPathComponent()
        }
        guard
            let paths = FileManager.default.enumerator(
                at: container, includingPropertiesForKeys: nil)
        else {
            throw HostPrivilegedCallerRejection("\(container.path) cannot be enumerated")
        }
        var count = 0
        var bytes: Int64 = 0
        for case let path as URL in paths {
            let info = try immutablePath(path)
            count += 1; bytes += Int64(info.st_size)
            guard count <= 10_000, bytes <= 256 * 1_024 * 1_024 else {
                throw HostPrivilegedCallerRejection(
                    "\(container.path) holds more than 10000 files or 256 MB")
            }
        }
    }

    static func validateAncestor(_ path: URL, metadata: stat, protectedChild: stat?) throws {
        guard metadata.st_uid == 0, metadata.st_mode & S_IFMT == S_IFDIR else {
            throw HostPrivilegedCallerRejection(
                "\(path.path) is not a root-owned folder (\(Self.shown(metadata)))")
        }
        guard metadata.st_mode & 0o022 != 0 else { return }
        guard path.path == "/Applications", metadata.st_gid == 80,
            metadata.st_mode & 0o7777 == 0o775,
            let child = protectedChild, child.st_uid == 0,
            child.st_mode & S_IFMT == S_IFDIR, child.st_mode & 0o022 == 0
        else {
            throw HostPrivilegedCallerRejection(
                "\(path.path) is writable by others (\(Self.shown(metadata)))")
        }
    }

    @discardableResult private static func immutablePath(_ path: URL) throws -> stat {
        var value = stat()
        guard lstat(path.path, &value) == 0 else {
            throw HostPrivilegedCallerRejection("\(path.path) cannot be read (errno \(errno))")
        }
        guard value.st_uid == 0, value.st_mode & 0o022 == 0,
            [S_IFREG, S_IFDIR].contains(value.st_mode & S_IFMT),
            value.st_nlink == 1 || value.st_mode & S_IFMT == S_IFDIR
        else {
            throw HostPrivilegedCallerRejection(
                "\(path.path) is not sealed (\(Self.shown(value)))")
        }
        return value
    }

    private static func shown(_ metadata: stat) -> String {
        "uid \(metadata.st_uid) gid \(metadata.st_gid) mode \(String(metadata.st_mode, radix: 8)) links \(metadata.st_nlink)"
    }

    private static func shown(_ value: Any?) -> String {
        guard let value else { return "none" }
        let text = String(describing: value)
        return text.utf8.count <= 300 ? "\"\(text)\"" : "\"\(text.prefix(300))...\""
    }

    private static func valid(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 200
            && value.utf8.allSatisfy {
                (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
                    || [45, 46, 95].contains($0)
            } && value != "." && value != ".."
    }
}

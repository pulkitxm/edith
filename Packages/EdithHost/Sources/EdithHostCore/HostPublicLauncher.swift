import CryptoKit
import Darwin
import Foundation
import Security

public struct HostPublicLauncher: Codable, Equatable, Sendable {
    private static let adHocSignatureFlag: UInt32 = 0x0002
    public let version: Int
    public let hostIdentifier: String
    public let applicationURL: URL
    public let launcherURL: URL
    public let buildVersion: String
    public let signatureHash: Data
    public let teamIdentifier: String?
    public let bundleFileID: String
    public let launcherFileID: String
    public let launcherSHA256: String

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case version, hostIdentifier, applicationURL, launcherURL, buildVersion, signatureHash,
            teamIdentifier, bundleFileID, launcherFileID, launcherSHA256
    }

    private struct Field: CodingKey {
        let stringValue: String
        let intValue: Int? = nil
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    public init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: Field.self)
        guard
            Set(fields.allKeys.map(\.stringValue)).isSubset(
                of: Set(CodingKeys.allCases.map(\.rawValue)))
        else { throw HostWorkerError.rejected }
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        hostIdentifier = try values.decode(String.self, forKey: .hostIdentifier)
        applicationURL = try values.decode(URL.self, forKey: .applicationURL)
        launcherURL = try values.decode(URL.self, forKey: .launcherURL)
        buildVersion = try values.decode(String.self, forKey: .buildVersion)
        signatureHash = try values.decode(Data.self, forKey: .signatureHash)
        teamIdentifier = try values.decodeIfPresent(String.self, forKey: .teamIdentifier)
        bundleFileID = try values.decode(String.self, forKey: .bundleFileID)
        launcherFileID = try values.decode(String.self, forKey: .launcherFileID)
        launcherSHA256 = try values.decode(String.self, forKey: .launcherSHA256)
    }

    private init(
        hostIdentifier: String, applicationURL: URL, buildVersion: String, signatureHash: Data,
        teamIdentifier: String?, bundleFileID: String, launcherFileID: String,
        launcherSHA256: String
    ) {
        version = 1
        self.hostIdentifier = hostIdentifier
        self.applicationURL = applicationURL
        launcherURL = applicationURL.appendingPathComponent("Contents/MacOS/ed")
        self.buildVersion = buildVersion
        self.signatureHash = signatureHash
        self.teamIdentifier = teamIdentifier
        self.bundleFileID = bundleFileID
        self.launcherFileID = launcherFileID
        self.launcherSHA256 = launcherSHA256
    }

    public static func capture(
        applicationURL: URL, hostIdentifier: String, teamIdentifier: String?
    ) throws -> Self {
        guard applicationURL.isFileURL, applicationURL.host == nil || applicationURL.host == "",
            applicationURL.query == nil, applicationURL.fragment == nil,
            applicationURL.path.utf8.count <= 4_096, !applicationURL.path.utf8.contains(0),
            applicationURL.pathExtension == "app",
            !applicationURL.pathComponents.contains(where: { $0.hasSuffix(".appex") }),
            hostIdentifier.utf8.count <= 200,
            hostIdentifier.allSatisfy({
                $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-")
            })
        else { throw HostWorkerError.rejected }
        let originalID = try fileID(applicationURL, kind: S_IFDIR)
        let app = applicationURL.standardizedFileURL.resolvingSymlinksInPath()
        let bundleID = try fileID(app, kind: S_IFDIR)
        guard bundleID == originalID else { throw HostWorkerError.rejected }
        for directory in ["Contents", "Contents/MacOS", "Contents/Resources"] {
            _ = try fileID(app.appendingPathComponent(directory), kind: S_IFDIR)
        }
        let infoURL = app.appendingPathComponent("Contents/Info.plist")
        let infoData = try regularData(infoURL, maximumBytes: 65_536).data
        guard
            let info = try PropertyListSerialization.propertyList(from: infoData, format: nil)
                as? [String: Any], info["CFBundleIdentifier"] as? String == hostIdentifier,
            info["CFBundleExecutable"] as? String == "Edith",
            info["CFBundlePackageType"] as? String == "APPL",
            info["NSExtension"] == nil, info["EdithContainedRole"] == nil,
            info["EdithExtensionID"] == nil, info["EdithHostIdentifier"] == nil,
            let build = info["CFBundleVersion"] as? String, !build.isEmpty,
            build.utf8.count <= 80,
            !build.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else { throw HostWorkerError.rejected }
        _ = try fileID(
            app.appendingPathComponent("Contents/MacOS/Edith"), kind: S_IFREG,
            executable: true)
        let link = app.appendingPathComponent("Contents/MacOS/ed")
        _ = try fileID(link, kind: S_IFLNK)
        guard
            try FileManager.default.destinationOfSymbolicLink(atPath: link.path)
                == "../Resources/ed-launcher"
        else { throw HostWorkerError.rejected }
        let resource = app.appendingPathComponent("Contents/Resources/ed-launcher")
        let launcher = try regularData(resource, maximumBytes: 262_144, executable: true)
        guard link.resolvingSymlinksInPath() == resource else { throw HostWorkerError.rejected }
        let signature = try signingIdentity(
            app, hostIdentifier: hostIdentifier,
            teamIdentifier: teamIdentifier)
        guard try fileID(app, kind: S_IFDIR) == bundleID,
            try fileID(resource, kind: S_IFREG, executable: true) == launcher.id
        else { throw HostWorkerError.rejected }
        return Self(
            hostIdentifier: hostIdentifier, applicationURL: app, buildVersion: build,
            signatureHash: signature.hash, teamIdentifier: signature.team,
            bundleFileID: bundleID, launcherFileID: launcher.id,
            launcherSHA256: SHA256.hash(data: launcher.data).map { String(format: "%02x", $0) }
                .joined())
    }

    public func revalidated(hostIdentifier: String, teamIdentifier: String?) throws -> Self {
        guard version == 1, self.hostIdentifier == hostIdentifier,
            launcherURL == applicationURL.appendingPathComponent("Contents/MacOS/ed")
        else { throw HostWorkerError.rejected }
        let current = try Self.capture(
            applicationURL: applicationURL,
            hostIdentifier: hostIdentifier, teamIdentifier: teamIdentifier)
        guard current == self else { throw HostWorkerError.rejected }
        return current
    }

    public func context(hostIdentifier: String, teamIdentifier: String?) throws -> NSDictionary {
        let current = try revalidated(
            hostIdentifier: hostIdentifier, teamIdentifier: teamIdentifier)
        guard
            let value = try JSONSerialization.jsonObject(with: JSONEncoder().encode(current))
                as? NSDictionary
        else { throw HostWorkerError.rejected }
        return value
    }

    static func permitsAdHoc(_ identifier: String) -> Bool {
        let prefix = "com.pulkit.edith.tests."
        guard identifier.hasPrefix(prefix) else { return false }
        let suffix = String(identifier.dropFirst(prefix.count))
        return UUID(uuidString: suffix)?.uuidString.lowercased() == suffix.lowercased()
    }

    private static func signingIdentity(
        _ app: URL, hostIdentifier: String, teamIdentifier: String?
    ) throws -> (hash: Data, team: String?) {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else {
            throw HostWorkerError.rejected
        }
        var requirement: SecRequirement?
        if let teamIdentifier {
            guard !teamIdentifier.isEmpty, teamIdentifier.utf8.count <= 64,
                teamIdentifier.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) })
            else { throw HostWorkerError.rejected }
            let expression =
                "anchor apple generic and certificate leaf[subject.OU] = \"\(teamIdentifier)\""
            guard
                SecRequirementCreateWithString(expression as CFString, [], &requirement)
                    == errSecSuccess
            else { throw HostWorkerError.rejected }
        } else {
            guard permitsAdHoc(hostIdentifier) else { throw HostWorkerError.rejected }
        }
        guard
            SecStaticCodeCheckValidity(
                code,
                SecCSFlags(
                    rawValue: kSecCSStrictValidate | kSecCSCheckNestedCode
                        | kSecCSCheckAllArchitectures),
                requirement) == errSecSuccess
        else { throw HostWorkerError.rejected }
        var information: CFDictionary?
        guard
            SecCodeCopySigningInformation(
                code, SecCSFlags(rawValue: kSecCSSigningInformation),
                &information) == errSecSuccess, let information = information as? [String: Any],
            information[kSecCodeInfoIdentifier as String] as? String == hostIdentifier,
            let hash = information[kSecCodeInfoUnique as String] as? Data, !hash.isEmpty
        else { throw HostWorkerError.rejected }
        let team = information[kSecCodeInfoTeamIdentifier as String] as? String
        if let teamIdentifier {
            guard team == teamIdentifier else { throw HostWorkerError.rejected }
        } else {
            guard team == nil, let flags = information[kSecCodeInfoFlags as String] as? NSNumber,
                flags.uint32Value & adHocSignatureFlag != 0
            else { throw HostWorkerError.rejected }
        }
        return (hash, team)
    }

    private static func fileID(_ url: URL, kind: mode_t, executable: Bool = false) throws -> String
    {
        var value = stat()
        guard lstat(url.path, &value) == 0, value.st_mode & S_IFMT == kind,
            !executable || value.st_mode & 0o111 != 0
        else { throw HostWorkerError.rejected }
        return "\(value.st_dev):\(value.st_ino)"
    }

    private static func regularData(
        _ url: URL, maximumBytes: Int, executable: Bool = false
    ) throws -> (data: Data, id: String) {
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw HostWorkerError.rejected }
        defer { close(descriptor) }
        var value = stat()
        guard fstat(descriptor, &value) == 0, value.st_mode & S_IFMT == S_IFREG,
            value.st_size > 0, value.st_size <= maximumBytes,
            !executable || value.st_mode & 0o111 != 0
        else { throw HostWorkerError.rejected }
        let id = "\(value.st_dev):\(value.st_ino)"
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        let data = try handle.readToEnd() ?? Data()
        guard data.count == value.st_size,
            try fileID(url, kind: S_IFREG, executable: executable) == id
        else { throw HostWorkerError.rejected }
        return (data, id)
    }
}

public extension HostWorkerConfiguration {
    func publicLauncherContext(teamIdentifier: String?) throws -> NSDictionary? {
        guard !recoveryOnly, let publicLauncher else { return nil }
        return try publicLauncher.context(
            hostIdentifier: identifier, teamIdentifier: teamIdentifier)
    }
}

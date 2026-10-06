import Darwin
import Foundation
import Security

public enum MeetingMicrophoneDeployment {
    public static let errorKey = "meetingMicrophoneDeploymentError"
    public static let identifier = "com.pulkit.edith.microphone"
    public static let relativePath = "Contents/Library/Audio/Plug-Ins/HAL/" + identifier + ".driver"
    public static let destinationRoot = URL(fileURLWithPath: "/Library/Audio/Plug-Ins/HAL")

    public static func application(containing executable: URL) throws -> URL {
        var candidate = executable.standardizedFileURL.resolvingSymlinksInPath()
        while candidate.path != "/" {
            if candidate.pathExtension == "app" {
                guard Bundle(url: candidate)?.bundleIdentifier == "com.pulkit.edith" else {
                    throw failure("Only the installed Edith application can deploy its microphone.")
                }
                return candidate
            }
            candidate.deleteLastPathComponent()
        }
        throw failure("Edith’s application bundle is unavailable.")
    }

    @discardableResult
    public static func synchronize(
        application: URL, destination: URL = destinationRoot,
        verify: (URL) throws -> Data = signature
    ) throws -> Bool {
        let files = FileManager.default
        let source = application.appendingPathComponent(relativePath)
        guard source.standardizedFileURL.resolvingSymlinksInPath() == source.standardizedFileURL,
            destination.standardizedFileURL.resolvingSymlinksInPath()
                == destination.standardizedFileURL
        else { throw failure("The microphone component path is invalid.") }
        let sourceSignature = try verify(source)
        let installed = destination.appendingPathComponent(identifier + ".driver")
        guard
            installed.standardizedFileURL.resolvingSymlinksInPath() == installed.standardizedFileURL
        else {
            throw failure("The installed microphone path is invalid.")
        }
        if let current = try? verify(installed), current == sourceSignature { return false }
        try files.createDirectory(
            at: destination, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o755])
        let staging = destination.appendingPathComponent(".edith-microphone-\(UUID())")
        defer { try? files.removeItem(at: staging) }
        try files.copyItem(at: source, to: staging)
        guard try verify(staging) == sourceSignature else {
            throw failure("The microphone component changed during deployment.")
        }
        try files.setAttributes([.posixPermissions: 0o755], ofItemAtPath: staging.path)
        let replacing = files.fileExists(atPath: installed.path)
        guard
            renamex_np(
                staging.path, installed.path, replacing ? UInt32(RENAME_SWAP) : UInt32(RENAME_EXCL))
                == 0
        else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return true
    }

    public static func signature(_ url: URL) throws -> Data {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else {
            throw failure("The microphone component is missing.")
        }
        var own: SecCode?
        var ownStatic: SecStaticCode?
        var ownInfo: CFDictionary?
        guard SecCodeCopySelf([], &own) == errSecSuccess, let own,
            SecCodeCopyStaticCode(own, [], &ownStatic) == errSecSuccess, let ownStatic,
            SecCodeCopySigningInformation(ownStatic, [], &ownInfo) == errSecSuccess,
            let values = ownInfo as? [CFString: Any],
            let team = values[kSecCodeInfoTeamIdentifier] as? String,
            !team.isEmpty, team.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) })
        else { throw failure("Edith’s signing identity is unavailable.") }
        var requirement: SecRequirement?
        let expression =
            "identifier \"\(identifier)\" and anchor apple generic and certificate leaf[subject.OU] = \"\(team)\""
        guard
            SecRequirementCreateWithString(expression as CFString, [], &requirement)
                == errSecSuccess,
            let requirement,
            SecStaticCodeCheckValidity(
                code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate),
                requirement) == errSecSuccess
        else { throw failure("The microphone component failed signature verification.") }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, [], &info) == errSecSuccess,
            let values = info as? [CFString: Any], let digest = values[kSecCodeInfoUnique] as? Data
        else {
            throw failure("The microphone component has no signing fingerprint.")
        }
        return digest
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: identifier, code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

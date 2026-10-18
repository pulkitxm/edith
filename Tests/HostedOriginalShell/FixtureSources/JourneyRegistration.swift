import AppKit
import CoreServices
import CryptoKit
import Darwin
import Foundation
import Security

@main
struct JourneyRegistration {
    enum Rejection: String, Error {
        case runner = "runner-rejected"
        case paths = "paths-rejected"
        case metadata = "metadata-rejected"
        case signature = "signature-rejected"
        case status = "registration-status-rejected"
        case registered = "registered-path-rejected"
    }

    struct Receipt: Encodable {
        let schema = 1
        let hostIdentifier: String
        let sourceCommit: String
        let applicationVersion: String
        let executableSHA256: String
        let registrationStatus: Int32
        let registeredCount: Int
        let uniqueRegisteredPathMatched: Bool
    }

    static func main() {
        umask(0o077)
        do {
            try register()
        } catch {
            let category = (error as? Rejection)?.rawValue ?? "metadata-rejected"
            let data = try? JSONSerialization.data(withJSONObject: ["category": category])
            FileHandle.standardError.write(data ?? Data())
            exit(1)
        }
    }

    private static func register() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["GITHUB_ACTIONS"] == "true", environment["RUNNER_OS"] == "macOS",
            environment["RUNNER_ENVIRONMENT"] == "github-hosted",
            environment["EDITH_HOSTED_SHELL_JOURNEY"] == "1",
            environment["APP_SANDBOX_CONTAINER_ID"] == nil
        else { throw Rejection.runner }
        guard CommandLine.arguments.count == 5,
            let directory = environment["EDITH_GUI_FIXTURE_DIRECTORY"],
            directory == CommandLine.arguments[1]
        else { throw Rejection.paths }
        let version = CommandLine.arguments[2]
        let expectedSource = CommandLine.arguments[3]
        let expectedDigest = CommandLine.arguments[4]
        var user = passwd()
        var result: UnsafeMutablePointer<passwd>?
        var buffer = [CChar](repeating: 0, count: 16_384)
        guard getpwuid_r(getuid(), &user, &buffer, buffer.count, &result) == 0, result != nil,
            let home = user.pw_dir
        else { throw Rejection.paths }
        let accountHome = String(cString: home)
        guard environment["EDITH_JOURNEY_ACCOUNT_HOME"] == accountHome,
            environment["HOME"] == accountHome,
            environment["CFFIXED_USER_HOME"] == accountHome,
            NSHomeDirectory() == accountHome
        else { throw Rejection.runner }
        let root = URL(fileURLWithPath: directory)
        let rootIdentity = try owned(root, directory: true, privateMode: 0o700)
        let fixture = try JSONDecoder().decode(
            JourneyFixture.self,
            from: read(
                root.appendingPathComponent("journey.json"), limit: 16_384, privateMode: 0o600))
        try fixture.validate(accountHome: accountHome, environment: environment)
        guard fixture.directory == directory, fixture.sourceCommit == expectedSource,
            fixture.appVersions.contains(version),
            fixture.executableSHA256[version] == expectedDigest
        else { throw Rejection.metadata }
        let app = URL(fileURLWithPath: fixture.application)
        let executable = URL(fileURLWithPath: fixture.executable)
        for url in [
            app, app.appendingPathComponent("Contents"),
            app.appendingPathComponent("Contents/MacOS"),
        ] {
            _ = try owned(url, directory: true)
        }
        let info = try PropertyListSerialization.propertyList(
            from: read(app.appendingPathComponent("Contents/Info.plist"), limit: 131_072),
            format: nil)
        guard let metadata = info as? [String: Any],
            metadata["CFBundleShortVersionString"] as? String == version
        else { throw Rejection.metadata }
        let digest = try executableDigest(executable)
        try fixture.validateRegistrationMetadata(
            identifier: metadata["CFBundleIdentifier"] as? String,
            executableName: metadata["CFBundleExecutable"] as? String,
            packageType: metadata["CFBundlePackageType"] as? String,
            version: metadata["CFBundleShortVersionString"] as? String,
            executableDigest: digest)
        var code: SecStaticCode?
        var requirement: SecRequirement?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess,
            SecRequirementCreateWithString(
                "identifier \"" + fixture.identifier + "\"" as CFString, [], &requirement)
                == errSecSuccess,
            let code, let requirement,
            SecStaticCodeCheckValidity(
                code,
                SecCSFlags(
                    rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures
                        | kSecCSCheckNestedCode),
                requirement) == errSecSuccess
        else { throw Rejection.signature }
        try unchangedRoot(root, expected: rootIdentity)
        guard try executableDigest(executable) == digest else { throw Rejection.metadata }
        let status = LSRegisterURL(app as CFURL, true)
        guard status == noErr else { throw Rejection.status }
        let registered = NSWorkspace.shared.urlsForApplications(
            withBundleIdentifier: fixture.identifier)
        guard registered.count == 1, registered[0].path == fixture.application,
            registered[0].resolvingSymlinksInPath().path == fixture.application
        else { throw Rejection.registered }
        try unchangedRoot(root, expected: rootIdentity)
        guard try executableDigest(executable) == digest else { throw Rejection.metadata }
        let receipt = Receipt(
            hostIdentifier: fixture.identifier, sourceCommit: fixture.sourceCommit,
            applicationVersion: version, executableSHA256: digest, registrationStatus: status,
            registeredCount: registered.count, uniqueRegisteredPathMatched: true)
        let output = root.appendingPathComponent("registration.json")
        guard !FileManager.default.fileExists(atPath: output.path) else { throw Rejection.paths }
        let bytes = try JSONEncoder().encode(receipt)
        guard bytes.count <= 16_384 else { throw Rejection.metadata }
        try bytes.write(to: output, options: .withoutOverwriting)
        _ = try owned(output, directory: false, privateMode: 0o600)
    }

    private static func executableDigest(_ url: URL) throws -> String {
        SHA256.hash(data: try read(url, limit: 268_435_456)).map { String(format: "%02x", $0) }
            .joined()
    }

    private static func unchangedRoot(_ root: URL, expected: stat) throws {
        let current = try owned(root, directory: true, privateMode: 0o700)
        guard current.st_dev == expected.st_dev, current.st_ino == expected.st_ino else {
            throw Rejection.paths
        }
    }

    private static func owned(_ url: URL, directory: Bool, privateMode: mode_t? = nil) throws
        -> stat
    {
        var info = stat()
        guard url.path == url.standardizedFileURL.path,
            url.path == url.resolvingSymlinksInPath().path,
            lstat(url.path, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o022 == 0,
            info.st_mode & S_IFMT == (directory ? S_IFDIR : S_IFREG),
            directory || info.st_nlink == 1,
            privateMode == nil || info.st_mode & 0o777 == privateMode
        else { throw Rejection.paths }
        return info
    }

    private static func read(_ url: URL, limit: Int, privateMode: mode_t? = nil) throws -> Data {
        let before = try owned(url, directory: false, privateMode: privateMode)
        guard before.st_size > 0, before.st_size <= limit else { throw Rejection.metadata }
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw Rejection.paths }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        defer { close(descriptor) }
        var opened = stat()
        guard fstat(descriptor, &opened) == 0, opened.st_dev == before.st_dev,
            opened.st_ino == before.st_ino
        else { throw Rejection.paths }
        guard let data = try handle.read(upToCount: limit + 1), data.count == before.st_size else {
            throw Rejection.metadata
        }
        var after = stat()
        guard fstat(descriptor, &after) == 0,
            after.st_size == before.st_size,
            after.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec,
            after.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec,
            after.st_ctimespec.tv_sec == before.st_ctimespec.tv_sec,
            after.st_ctimespec.tv_nsec == before.st_ctimespec.tv_nsec
        else { throw Rejection.metadata }
        let pathAfter = try owned(url, directory: false, privateMode: privateMode)
        guard pathAfter.st_dev == before.st_dev, pathAfter.st_ino == before.st_ino else {
            throw Rejection.paths
        }
        return data
    }
}

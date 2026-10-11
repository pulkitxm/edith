import CryptoKit
import Darwin
import Foundation
import Security

@MainActor enum HostSparkleBootstrap {
    private(set) static var descriptor: SparkleBootstrapDescriptor?
    static var admitted: Bool { descriptor != nil }

    static func restore(sourceCommit: String, issuerPublicKey: Data, signingRequirement: String)
        throws
    {
        guard CommandLine.arguments.count == 1,
            getenv("EDITH_CLI") == nil, getenv("EDITH_EXTENSION_WORKER") == nil,
            let identifier = Bundle.main.bundleIdentifier,
            identifier.hasPrefix("com.pulkit.edith.tests.remote-"),
            let executable = Bundle.main.executableURL,
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
                as? String,
            !signingRequirement.isEmpty, signingRequirement.utf8.count <= 1024
        else { throw SparkleFixtureError.rejected }
        var account = passwd()
        var pointer: UnsafeMutablePointer<passwd>?
        var bytes = [CChar](repeating: 0, count: 16_384)
        guard getpwuid_r(getuid(), &account, &bytes, bytes.count, &pointer) == 0,
            pointer != nil, let home = account.pw_dir
        else { throw SparkleFixtureError.rejected }
        let accountHome = String(cString: home)
        let resources = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources")
        var pins: [OpenedPath] = []
        defer { pins.forEach { $0.close() } }
        for url in [
            Bundle.main.bundleURL, Bundle.main.bundleURL.appendingPathComponent("Contents"),
            resources,
        ] {
            pins.append(try OpenedPath(url, directory: true, mode: nil, maximum: nil))
        }
        let document = try OpenedPath(
            resources.appendingPathComponent("hosted-sparkle-fixture.json"), directory: false,
            mode: 0o600, maximum: 16_384)
        pins.append(document)
        let payload = try document.read()
        let value = try SparkleBootstrapEnvelope.verify(payload, pinnedIssuerKey: issuerPublicKey)
        let first = try observeProducer(value.producer)
        try value.validate(
            sourceCommit: sourceCommit, accountHome: accountHome, currentUID: getuid(),
            bundleIdentifier: identifier, bundlePath: Bundle.main.bundleURL.path,
            executablePath: executable.path, version: version, observedProducer: first)
        for path in [
            value.directory, value.directory + "/synthetic-data",
            value.directory + "/synthetic-data/.config",
            value.directory + "/synthetic-data/.cache",
            value.directory + "/synthetic-data/.local",
            value.directory + "/synthetic-data/.local/share", value.directory + "/tmp",
            value.directory + "/support",
        ] {
            pins.append(
                try OpenedPath(
                    URL(fileURLWithPath: path), directory: true, mode: 0o700, maximum: nil))
        }
        guard
            Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String
                == value.updatePublicKey,
            Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String
                == value.feedURL.absoluteString,
            Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
                == (version == "1.0.0" ? "1" : "2")
        else { throw SparkleFixtureError.rejected }
        var code: SecStaticCode?
        var requirement: SecRequirement?
        guard
            SecStaticCodeCreateWithPath(Bundle.main.bundleURL as CFURL, [], &code) == errSecSuccess,
            SecRequirementCreateWithString(signingRequirement as CFString, [], &requirement)
                == errSecSuccess,
            let code, let requirement,
            SecStaticCodeCheckValidity(
                code, SecCSFlags(rawValue: kSecCSStrictValidate), requirement)
                == errSecSuccess,
            try observeProducer(value.producer) == first
        else { throw SparkleFixtureError.rejected }
        try pins.forEach { try $0.validate() }
        for key in ["GITHUB_TOKEN", "GH_TOKEN", "SPARKLE_PRIVATE_KEY", "SSH_AUTH_SOCK"] {
            unsetenv(key)
        }
        for (key, value) in value.applicationEnvironment {
            guard setenv(key, value, 1) == 0 else { throw SparkleFixtureError.rejected }
        }
        descriptor = value
    }

    static func record(_ category: String) {
        guard let value = descriptor,
            ["downloaded", "extracted", "installing", "relaunching"].contains(category)
        else { exit(1) }
        do {
            let document: [String: Any] = [
                "schema": 1, "sourceCommit": value.sourceCommit, "session": value.session,
                "category": category, "pid": getpid(),
            ]
            let data =
                try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
                + Data([10])
            let path = value.directory + "/sparkle-events.jsonl"
            let descriptor = open(
                path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard descriptor >= 0 else { throw SparkleFixtureError.rejected }
            defer { close(descriptor) }
            var state = stat()
            guard fstat(descriptor, &state) == 0, state.st_uid == getuid(), state.st_nlink == 1,
                state.st_mode & S_IFMT == S_IFREG, state.st_mode & 0o777 == 0o600,
                state.st_size <= 8192
            else { throw SparkleFixtureError.rejected }
            let count = data.withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
            guard count == data.count, fsync(descriptor) == 0 else {
                throw SparkleFixtureError.rejected
            }
        } catch { exit(1) }
    }

    private static func observeProducer(_ expected: SparkleProducerIdentity) throws
        -> SparkleProducerIdentity
    {
        var first = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard expected.pid != getpid(),
            proc_pidinfo(expected.pid, PROC_PIDTBSDINFO, 0, &first, size) == size,
            first.pbi_uid == getuid(), first.pbi_status != SZOMB
        else { throw SparkleFixtureError.rejected }
        var path = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(expected.pid, &path, UInt32(path.count)) > 0 else {
            throw SparkleFixtureError.rejected
        }
        guard let terminator = path.firstIndex(of: 0) else { throw SparkleFixtureError.rejected }
        let executable = String(
            decoding: path[..<terminator].map { UInt8(bitPattern: $0) }, as: UTF8.self)
        guard executable == expected.executable else { throw SparkleFixtureError.rejected }
        let data = try read(URL(fileURLWithPath: executable), maximum: 256 * 1024 * 1024, mode: nil)
        var second = proc_bsdinfo()
        guard proc_pidinfo(expected.pid, PROC_PIDTBSDINFO, 0, &second, size) == size,
            first.pbi_uid == second.pbi_uid,
            first.pbi_start_tvsec == second.pbi_start_tvsec,
            first.pbi_start_tvusec == second.pbi_start_tvusec,
            second.pbi_status != SZOMB
        else { throw SparkleFixtureError.rejected }
        return .init(
            pid: expected.pid, birth: "\(first.pbi_start_tvsec).\(first.pbi_start_tvusec)",
            uid: first.pbi_uid, executable: executable,
            executableSHA256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
    }

    private static func read(_ url: URL, maximum: Int, mode: mode_t?) throws -> Data {
        guard url.path == url.standardizedFileURL.path,
            url.path == url.resolvingSymlinksInPath().path
        else { throw SparkleFixtureError.rejected }
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else { throw SparkleFixtureError.rejected }
        defer { close(descriptor) }
        var before = stat()
        guard fstat(descriptor, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
            before.st_nlink == 1, before.st_uid == getuid() || (mode == nil && before.st_uid == 0),
            before.st_size > 0, before.st_size <= maximum,
            before.st_mode & 0o022 == 0,
            mode == nil || before.st_mode & 0o777 == mode!
        else { throw SparkleFixtureError.rejected }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        guard let data = try handle.read(upToCount: maximum + 1), data.count == before.st_size
        else {
            throw SparkleFixtureError.rejected
        }
        var after = stat()
        guard fstat(descriptor, &after) == 0, before.st_dev == after.st_dev,
            before.st_ino == after.st_ino, before.st_uid == after.st_uid,
            before.st_mode == after.st_mode, before.st_nlink == after.st_nlink,
            before.st_size == after.st_size,
            before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
            before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
            before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
            before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec
        else { throw SparkleFixtureError.rejected }
        return data
    }

    private final class OpenedPath {
        let url: URL
        let descriptor: Int32
        let original: stat

        init(_ url: URL, directory: Bool, mode: mode_t?, maximum: Int?) throws {
            guard url.path == url.standardizedFileURL.path,
                url.path == url.resolvingSymlinksInPath().path
            else { throw SparkleFixtureError.rejected }
            let descriptor = Darwin.open(
                url.path,
                O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK | (directory ? O_DIRECTORY : 0))
            guard descriptor >= 0 else { throw SparkleFixtureError.rejected }
            var state = stat()
            guard fstat(descriptor, &state) == 0, state.st_uid == getuid(),
                state.st_mode & S_IFMT == (directory ? S_IFDIR : S_IFREG),
                state.st_mode & 0o022 == 0,
                mode.map({ state.st_mode & 0o777 == $0 }) ?? true,
                directory
                    || (state.st_nlink == 1 && state.st_size > 0 && state.st_size <= (maximum ?? 0))
            else { Darwin.close(descriptor); throw SparkleFixtureError.rejected }
            self.url = url
            self.descriptor = descriptor
            original = state
        }

        func close() { Darwin.close(descriptor) }

        func read() throws -> Data {
            var data = Data()
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
            while data.count < original.st_size {
                guard let part = try handle.read(upToCount: Int(original.st_size) - data.count),
                    !part.isEmpty
                else {
                    throw SparkleFixtureError.rejected
                }
                data.append(part)
            }
            try validate()
            return data
        }

        func validate() throws {
            var opened = stat()
            var current = stat()
            guard url.path == url.resolvingSymlinksInPath().path,
                fstat(descriptor, &opened) == 0, lstat(url.path, &current) == 0,
                Self.equal(original, opened), Self.equal(original, current)
            else { throw SparkleFixtureError.rejected }
        }

        private static func equal(_ lhs: stat, _ rhs: stat) -> Bool {
            lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino && lhs.st_uid == rhs.st_uid
                && lhs.st_mode == rhs.st_mode && lhs.st_nlink == rhs.st_nlink
                && lhs.st_size == rhs.st_size
                && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
                && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
                && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec
                && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
        }
    }
}

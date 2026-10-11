import AppKit
import CryptoKit
import Darwin
import Foundation

@main
struct SparkleProcessProbe {
    static let issuer = Data(base64Encoded: "__SPARKLE_ISSUER_KEY__")!
    static let sourceCommit = "__SPARKLE_SOURCE_COMMIT__"

    struct Observation: Codable, Equatable {
        let role: String
        let pid: Int32
        let birth: String
        let uid: UInt32
        let executable: String
        let running: Bool
    }

    struct Request: Decodable {
        let operation: String
        let directory: String
        let observations: [Observation]
    }

    static func main() throws {
        guard CommandLine.arguments.count == 2 else { throw SparkleFixtureError.rejected }
        if CommandLine.arguments[1] == "producer" {
            let value = try producer()
            FileHandle.standardOutput.write(try JSONEncoder().encode(value))
            return
        }
        guard CommandLine.arguments[1] == "request" else { throw SparkleFixtureError.rejected }
        guard let bytes = try FileHandle.standardInput.read(upToCount: 16_385),
            !bytes.isEmpty, bytes.count <= 16_384
        else { throw SparkleFixtureError.rejected }
        let request = try JSONDecoder().decode(Request.self, from: bytes)
        guard ["snapshot", "observe", "TERM", "KILL"].contains(request.operation),
            request.observations.count <= 6
        else { throw SparkleFixtureError.rejected }
        let root = URL(fileURLWithPath: request.directory)
        let envelope = try read(
            root.appendingPathComponent("Host.app/Contents/Resources/hosted-sparkle-fixture.json"),
            maximum: 16_384)
        let fixture = try SparkleBootstrapEnvelope.verify(envelope, pinnedIssuerKey: issuer)
        let actualProducer = try producer()
        guard fixture.sourceCommit == sourceCommit, fixture.producer == actualProducer,
            fixture.directory == request.directory,
            root.path == root.resolvingSymlinksInPath().path
        else { throw SparkleFixtureError.rejected }
        var rootState = stat()
        guard lstat(root.path, &rootState) == 0, rootState.st_uid == getuid(),
            rootState.st_mode & S_IFMT == S_IFDIR, rootState.st_mode & 0o777 == 0o700
        else { throw SparkleFixtureError.rejected }
        let observations: [Observation]
        if request.operation == "snapshot" {
            guard request.observations.isEmpty else { throw SparkleFixtureError.rejected }
            observations = try snapshot(fixture)
        } else {
            guard !request.observations.isEmpty else { throw SparkleFixtureError.rejected }
            observations = try request.observations.map { expected in
                try validate(expected, fixture: fixture)
                let current = try observe(expected)
                if request.operation == "TERM" || request.operation == "KILL" {
                    guard request.observations.count == 1 else {
                        throw SparkleFixtureError.rejected
                    }
                    if current.running {
                        guard try observe(expected) == current,
                            kill(expected.pid, request.operation == "TERM" ? SIGTERM : SIGKILL) == 0
                        else { throw SparkleFixtureError.rejected }
                    }
                }
                return current
            }
        }
        guard try producer() == actualProducer else { throw SparkleFixtureError.rejected }
        FileHandle.standardOutput.write(try JSONEncoder().encode(observations))
    }

    static func producer() throws -> SparkleProducerIdentity {
        let pid = getppid()
        guard pid > 1 else { throw SparkleFixtureError.rejected }
        let first = try info(pid)
        let path = try executable(pid)
        let hash = SHA256.hash(
            data: try read(URL(fileURLWithPath: path), maximum: 268_435_456, privateMode: false)
        )
        .map { String(format: "%02x", $0) }.joined()
        let second = try info(pid)
        guard equal(first, second), first.pbi_uid == getuid() else {
            throw SparkleFixtureError.rejected
        }
        return .init(
            pid: pid, birth: birth(first), uid: first.pbi_uid, executable: path,
            executableSHA256: hash)
    }

    static func snapshot(_ fixture: SparkleBootstrapDescriptor) throws -> [Observation] {
        let applications = NSRunningApplication.runningApplications(
            withBundleIdentifier: fixture.identifier
        )
        .filter { !$0.isTerminated }
        guard applications.count <= 1 else { throw SparkleFixtureError.rejected }
        var result: [Observation] = []
        if let application = applications.first {
            guard application.bundleURL?.path == fixture.directory + "/Host.app",
                application.executableURL?.path == fixture.directory
                    + "/Host.app/Contents/MacOS/Edith"
            else { throw SparkleFixtureError.rejected }
            let value = try info(application.processIdentifier)
            guard value.pbi_uid == getuid() else { throw SparkleFixtureError.rejected }
            result.append(
                .init(
                    role: "host", pid: application.processIdentifier, birth: birth(value),
                    uid: value.pbi_uid, executable: try executable(application.processIdentifier),
                    running: true))
        }
        let url = URL(fileURLWithPath: fixture.directory + "/state.json")
        if access(url.path, F_OK) == 0 {
            guard
                let state = try JSONSerialization.jsonObject(with: read(url, maximum: 131_072))
                    as? [String: Any],
                state["hostIdentifier"] as? String == fixture.identifier,
                state["sourceCommit"] as? String == fixture.sourceCommit,
                let rows = state["ownedProcesses"] as? [[String: Any]], rows.count <= 64
            else { throw SparkleFixtureError.rejected }
            for role in ["engine", "managedUI"] {
                let matches = rows.filter {
                    $0["role"] as? String == role && $0["running"] as? Bool == true
                }
                guard matches.count <= 1 else { throw SparkleFixtureError.rejected }
                if let row = matches.first {
                    guard let pid = row["pid"] as? Int32,
                        let generation = row["generation"] as? String,
                        generation.split(separator: ":").count == 2
                    else { throw SparkleFixtureError.rejected }
                    let expected = Observation(
                        role: role, pid: pid,
                        birth: generation.replacingOccurrences(of: ":", with: "."),
                        uid: getuid(), executable: rolePath(role, fixture), running: true)
                    try validate(expected, fixture: fixture)
                    let actual = try observe(expected)
                    if actual.running { result.append(actual) }
                }
            }
        }
        return result
    }

    static func rolePath(_ role: String, _ fixture: SparkleBootstrapDescriptor) -> String {
        if role == "host" || role == "engine" {
            return fixture.directory + "/Host.app/Contents/MacOS/Edith"
        }
        return fixture.directory + "/support/Edith Tests/remote-" + fixture.session
            + "/Extensions/calendar/edith-host-2/arm64/1.0.0/calendar/ExtensionCarrier.app/Contents/Extensions/ExtensionWorker.appex/Contents/MacOS/Edith"
    }

    static func validate(_ value: Observation, fixture: SparkleBootstrapDescriptor) throws {
        guard ["host", "engine", "managedUI"].contains(value.role), value.pid > 1,
            value.pid != getpid(), value.pid != getppid(), value.uid == getuid(),
            value.executable == rolePath(value.role, fixture),
            value.birth.range(of: "^[0-9]+\\.[0-9]+$", options: .regularExpression) == value.birth
                .startIndex..<value.birth.endIndex
        else { throw SparkleFixtureError.rejected }
    }

    static func observe(_ expected: Observation) throws -> Observation {
        var current = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        let present = proc_pidinfo(expected.pid, PROC_PIDTBSDINFO, 0, &current, size) == size
        if !present || birth(current) != expected.birth || current.pbi_status == SZOMB {
            return .init(
                role: expected.role, pid: expected.pid, birth: expected.birth, uid: expected.uid,
                executable: expected.executable, running: false)
        }
        guard current.pbi_uid == expected.uid, try executable(expected.pid) == expected.executable,
            equal(current, try info(expected.pid))
        else { throw SparkleFixtureError.rejected }
        return .init(
            role: expected.role, pid: expected.pid, birth: expected.birth, uid: expected.uid,
            executable: expected.executable, running: true)
    }

    static func info(_ pid: Int32) throws -> proc_bsdinfo {
        var value = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &value, size) == size,
            value.pbi_status != SZOMB
        else {
            throw SparkleFixtureError.rejected
        }
        return value
    }

    static func birth(_ value: proc_bsdinfo) -> String {
        "\(value.pbi_start_tvsec).\(value.pbi_start_tvusec)"
    }
    static func equal(_ lhs: proc_bsdinfo, _ rhs: proc_bsdinfo) -> Bool {
        lhs.pbi_pid == rhs.pbi_pid && lhs.pbi_uid == rhs.pbi_uid && birth(lhs) == birth(rhs)
    }

    static func executable(_ pid: Int32) throws -> String {
        var bytes = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &bytes, UInt32(bytes.count)) > 0, let end = bytes.firstIndex(of: 0)
        else {
            throw SparkleFixtureError.rejected
        }
        let path = String(decoding: bytes[..<end].map { UInt8(bitPattern: $0) }, as: UTF8.self)
        guard path == URL(fileURLWithPath: path).resolvingSymlinksInPath().path else {
            throw SparkleFixtureError.rejected
        }
        return path
    }

    static func read(_ url: URL, maximum: Int, privateMode: Bool = true) throws -> Data {
        guard url.path == url.resolvingSymlinksInPath().path else {
            throw SparkleFixtureError.rejected
        }
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw SparkleFixtureError.rejected }
        defer { close(descriptor) }
        var before = stat()
        guard fstat(descriptor, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
            before.st_nlink == 1, before.st_size > 0, before.st_size <= maximum,
            before.st_uid == getuid() || (!privateMode && before.st_uid == 0),
            before.st_mode & 0o022 == 0, !privateMode || before.st_mode & 0o777 == 0o600
        else { throw SparkleFixtureError.rejected }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        guard let bytes = try handle.read(upToCount: maximum + 1), bytes.count == before.st_size
        else {
            throw SparkleFixtureError.rejected
        }
        var after = stat()
        var path = stat()
        guard fstat(descriptor, &after) == 0, lstat(url.path, &path) == 0,
            before.st_dev == after.st_dev, before.st_ino == after.st_ino,
            before.st_uid == after.st_uid, before.st_mode == after.st_mode,
            before.st_nlink == after.st_nlink, before.st_size == after.st_size,
            before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
            before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
            before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
            before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec,
            after.st_dev == path.st_dev, after.st_ino == path.st_ino
        else { throw SparkleFixtureError.rejected }
        return bytes
    }
}

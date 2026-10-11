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

    struct Ledger: Codable {
        let sourceCommit: String
        let session: String
        let producer: SparkleProducerIdentity
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
        let rootPin = try PinnedInput(root, directory: true, maximum: 0)
        let document = try PinnedInput(
            root.appendingPathComponent("sparkle-bootstrap.json"),
            maximum: 16_384)
        defer { rootPin.close(); document.close() }
        let fixture = try SparkleBootstrapEnvelope.verify(document.bytes, pinnedIssuerKey: issuer)
        let actualProducer = try producer()
        guard fixture.sourceCommit == sourceCommit, fixture.producer == actualProducer,
            fixture.directory == request.directory,
            root.path == root.resolvingSymlinksInPath().path
        else { throw SparkleFixtureError.rejected }
        guard let account = getpwuid(getuid()), let home = account.pointee.pw_dir else {
            throw SparkleFixtureError.rejected
        }
        try fixture.validate(
            sourceCommit: sourceCommit, accountHome: String(cString: home), currentUID: getuid(),
            bundleIdentifier: fixture.identifier, bundlePath: fixture.directory + "/Host.app",
            executablePath: fixture.directory + "/Host.app/Contents/MacOS/Edith", version: "1.0.0",
            observedProducer: actualProducer)
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
            let ledgerDocument = try PinnedInput(
                root.appendingPathComponent("sparkle-owned-ledger.json"), maximum: 16_384)
            defer { ledgerDocument.close() }
            let ledger = try verifiedLedger(ledgerDocument.bytes, fixture: fixture)
            observations = try request.observations.map { expected in
                try validate(expected, fixture: fixture)
                guard ledger.observations.contains(where: { sameIdentity($0, expected) }) else {
                    throw SparkleFixtureError.rejected
                }
                let current = try observe(expected)
                if request.operation == "TERM" || request.operation == "KILL" {
                    guard request.observations.count == 1 else {
                        throw SparkleFixtureError.rejected
                    }
                    if current.running {
                        guard try producer() == actualProducer else {
                            throw SparkleFixtureError.rejected
                        }
                        try rootPin.validate()
                        try document.validate()
                        try ledgerDocument.validate()
                        guard try observe(expected) == current,
                            kill(expected.pid, request.operation == "TERM" ? SIGTERM : SIGKILL) == 0
                        else { throw SparkleFixtureError.rejected }
                    }
                }
                return current
            }
        }
        try rootPin.validate()
        try document.validate()
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
            let captured = Observation(
                role: "host", pid: application.processIdentifier, birth: birth(value),
                uid: value.pbi_uid, executable: try executable(application.processIdentifier),
                running: true)
            try validate(captured, fixture: fixture)
            let observed = try observe(captured)
            guard observed.running else { throw SparkleFixtureError.rejected }
            result.append(observed)
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
        try requireNoUnregisteredGenerations(result, fixture: fixture)
        return result
    }

    static func requireNoUnregisteredGenerations(
        _ observations: [Observation], fixture: SparkleBootstrapDescriptor
    ) throws {
        let count = proc_listallpids(nil, 0)
        guard count > 0, count < 65_000 else { throw SparkleFixtureError.rejected }
        var pids = [pid_t](repeating: 0, count: Int(count) + 256)
        let read = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard read > 0, read < pids.count else { throw SparkleFixtureError.rejected }
        let paths = Set([rolePath("host", fixture), rolePath("managedUI", fixture)])
        for pid in pids.prefix(Int(read)) where pid > 1 && pid != getpid() && pid != getppid() {
            guard let current = try? info(pid), current.pbi_uid == getuid(),
                let path = try? executable(pid), paths.contains(path)
            else { continue }
            guard let next = try? info(pid), equal(current, next) else {
                throw SparkleFixtureError.rejected
            }
            guard
                observations.contains(where: {
                    $0.pid == pid && $0.birth == birth(current) && $0.executable == path
                        && $0.running
                })
            else {
                throw SparkleFixtureError.rejected
            }
        }
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

    static func sameIdentity(_ lhs: Observation, _ rhs: Observation) -> Bool {
        lhs.role == rhs.role && lhs.pid == rhs.pid && lhs.birth == rhs.birth
            && lhs.uid == rhs.uid && lhs.executable == rhs.executable
    }

    static func verifiedLedger(_ bytes: Data, fixture: SparkleBootstrapDescriptor) throws -> Ledger
    {
        let envelope = try JSONDecoder().decode(SparkleBootstrapEnvelope.self, from: bytes)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard try encoder.encode(envelope) == bytes,
            let payload = Data(base64Encoded: envelope.payload), payload.count <= 8192,
            let signature = Data(base64Encoded: envelope.signature), signature.count == 64,
            try Curve25519.Signing.PublicKey(rawRepresentation: issuer).isValidSignature(
                signature, for: payload)
        else { throw SparkleFixtureError.rejected }
        let ledger = try JSONDecoder().decode(Ledger.self, from: payload)
        guard try encoder.encode(ledger) == payload, ledger.sourceCommit == sourceCommit,
            ledger.session == fixture.session, ledger.producer == fixture.producer,
            !ledger.observations.isEmpty, ledger.observations.count <= 6
        else { throw SparkleFixtureError.rejected }
        try ledger.observations.forEach { try validate($0, fixture: fixture) }
        return ledger
    }

    final class PinnedInput {
        let path: String
        let descriptor: Int32
        let original: stat
        let bytes: Data

        init(_ url: URL, directory: Bool = false, maximum: Int) throws {
            guard url.path == url.resolvingSymlinksInPath().path else {
                throw SparkleFixtureError.rejected
            }
            let fd = open(
                url.path,
                O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC | (directory ? O_DIRECTORY : 0))
            guard fd >= 0 else { throw SparkleFixtureError.rejected }
            var state = stat()
            guard fstat(fd, &state) == 0, state.st_uid == getuid(),
                state.st_mode & S_IFMT == (directory ? S_IFDIR : S_IFREG),
                state.st_mode & 0o777 == (directory ? 0o700 : 0o600),
                directory || (state.st_nlink == 1 && state.st_size > 0 && state.st_size <= maximum)
            else { Darwin.close(fd); throw SparkleFixtureError.rejected }
            let data: Data
            do {
                if directory {
                    data = Data()
                } else {
                    let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
                    guard let result = try handle.read(upToCount: maximum + 1),
                        result.count == state.st_size
                    else {
                        throw SparkleFixtureError.rejected
                    }
                    data = result
                }
            } catch { Darwin.close(fd); throw error }
            path = url.path
            descriptor = fd
            original = state
            bytes = data
            do { try validate() } catch { Darwin.close(fd); throw error }
        }

        func close() { Darwin.close(descriptor) }

        func validate() throws {
            var fd = stat()
            var current = stat()
            guard fstat(descriptor, &fd) == 0, lstat(path, &current) == 0,
                path == URL(fileURLWithPath: path).resolvingSymlinksInPath().path,
                Self.same(original, fd), Self.same(original, current)
            else { throw SparkleFixtureError.rejected }
        }

        static func same(_ lhs: stat, _ rhs: stat) -> Bool {
            guard
                lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino && lhs.st_uid == rhs.st_uid
                    && lhs.st_mode == rhs.st_mode
            else { return false }
            if lhs.st_mode & S_IFMT == S_IFDIR { return true }
            return lhs.st_nlink == rhs.st_nlink && lhs.st_size == rhs.st_size
                && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
                && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
                && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec
                && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
        }
    }
}

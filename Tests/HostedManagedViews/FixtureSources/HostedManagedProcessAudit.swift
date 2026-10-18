import AppKit
import Darwin
import Foundation

struct HostedManagedKernelProcess: Codable, Equatable {
    let pid: Int32
    let generation: String
    let uid: UInt32
    let executable: String
    let hostIdentifier: String
    let role: String
}

@main
struct HostedManagedProcessAudit {
    static func main() throws {
        let arguments = CommandLine.arguments
        guard arguments.count == 2 || arguments.count == 3,
            arguments.count == 2 || ["--owned", "--remaining", "--terminate-host", "--terminate-workers", "--kill"].contains(arguments[2])
        else { throw HostedManagedApprovalError.invalidRoute }
        let directory = URL(fileURLWithPath: arguments[1])
        let route = try HostedManagedApprovalRoute.load(
            directory: directory, environment: ProcessInfo.processInfo.environment)
        try route.validateHostedDirectory()
        let paths = try expectedPaths(route)
        let operation = arguments.count == 2 ? "host" : arguments[2]
        var rows: [HostedManagedKernelProcess]
        if ["--remaining", "--terminate-host", "--terminate-workers", "--kill"].contains(operation) {
            let pinned = try JSONDecoder().decode(
                [HostedManagedKernelProcess].self,
                from: readOwned(directory: directory, name: "cleanup-ledger.json"))
            guard pinned.count <= 16, Set(pinned.map { "\($0.pid):\($0.generation)" }).count == pinned.count
            else { throw HostedManagedApprovalError.invalidApplication }
            rows = try pinned.compactMap { expected in
                guard expected.pid > 1, expected.uid == getuid(),
                    expected.hostIdentifier == route.hostIdentifier,
                    paths[expected.role] == expected.executable,
                    expected.role != "cameraCarrier" || route.extensionID == "virtualCamera",
                    expected.generation.range(of: "^[0-9]{1,20}\\.[0-9]{1,6}$", options: .regularExpression) != nil
                else { throw HostedManagedApprovalError.invalidApplication }
                guard let current = try read(expected.pid, role: expected.role, route: route, path: expected.executable, generation: expected.generation),
                    current == expected else { return nil }
                return current
            }
            if operation != "--remaining" {
                for row in rows {
                    if operation == "--terminate-host" && row.role != "host" { continue }
                    if operation == "--terminate-workers" && row.role == "host" { continue }
                    guard try read(row.pid, role: row.role, route: route, path: row.executable) == row
                    else { continue }
                    guard kill(row.pid, operation == "--kill" ? SIGKILL : SIGTERM) == 0 || errno == ESRCH
                    else { throw HostedManagedApprovalError.invalidApplication }
                }
            }
        } else {
            rows = try discover(route, paths: paths, includeWorkers: operation == "--owned")
        }
        let data: Data
        if operation == "host" {
            data = try JSONSerialization.data(withJSONObject: rows.map {
                ["pid": $0.pid, "generation": $0.generation, "uid": $0.uid,
                 "executable": $0.executable, "hostIdentifier": $0.hostIdentifier] as [String: Any]
            }, options: .sortedKeys)
        } else {
            data = try JSONEncoder().encode(rows)
        }
        guard data.count <= 16_384 else { throw HostedManagedApprovalError.invalidApplication }
        FileHandle.standardOutput.write(data)
    }

    static func expectedPaths(_ route: HostedManagedApprovalRoute) throws -> [String: String] {
        let directory = URL(fileURLWithPath: route.directory)
        let support = route.extensionID == "calendar" ? directory.appendingPathComponent("support") : directory
        let namespace = String(route.hostIdentifier.dropFirst("com.pulkit.edith.tests.".count))
        let payload = support.appendingPathComponent("Edith Tests/\(namespace)/Extensions/\(route.extensionID)/\(route.hostABI)/arm64/\(route.version)/\(route.extensionID)")
        let host = directory.appendingPathComponent("Fixture.app/Contents/MacOS/Edith").path
        return [
            "host": host, "engine": host,
            "ui": payload.appendingPathComponent("ExtensionCarrier.app/Contents/Extensions/ExtensionWorker.appex/Contents/MacOS/Edith").path,
            "carrier": payload.appendingPathComponent("ExtensionCarrier.app/Contents/MacOS/Edith").path,
            "cameraCarrier": payload.appendingPathComponent("CameraCarrier.app/Contents/MacOS/Edith").path,
        ]
    }

    static func discover(_ route: HostedManagedApprovalRoute, paths: [String: String], includeWorkers: Bool) throws -> [HostedManagedKernelProcess] {
        let applications = NSRunningApplication.runningApplications(withBundleIdentifier: route.hostIdentifier)
        guard applications.count <= 1 else { throw HostedManagedApprovalError.ambiguousIdentity }
        var rows: [HostedManagedKernelProcess] = []
        for application in applications {
            guard let bundle = application.bundleURL, let executable = application.executableURL,
                !application.isTerminated else { throw HostedManagedApprovalError.invalidApplication }
            try route.validateApplicationPaths(bundle: bundle, executable: executable)
            if let row = try read(application.processIdentifier, role: "host", route: route, path: paths["host"]!) {
                rows.append(row)
            }
        }
        guard includeWorkers else { return rows }
        if let host = rows.first(where: { $0.role == "host" }) {
            var children = [Int32](repeating: 0, count: 16)
            let count = proc_listchildpids(host.pid, &children, Int32(children.count * MemoryLayout<Int32>.size))
            guard count >= 0, count < children.count,
                try read(host.pid, role: "host", route: route, path: host.executable) == host
            else { throw HostedManagedApprovalError.invalidApplication }
            for pid in children.prefix(Int(count)) where pid > 1 {
                var path = [CChar](repeating: 0, count: 4096)
                guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { continue }
                let executable = String(decoding: path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                guard executable == paths["engine"] else { continue }
                if let row = try read(pid, role: "engine", route: route, path: executable) { rows.append(row) }
            }
        }
        for (role, identifier) in [
            ("ui", route.workerIdentifier),
            ("carrier", route.hostIdentifier + ".extension." + route.extensionID),
            ("cameraCarrier", route.hostIdentifier + ".cameraCarrier"),
        ] {
            if role == "cameraCarrier" && route.extensionID != "virtualCamera" { continue }
            let matches = NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
            guard matches.count <= 1 else { throw HostedManagedApprovalError.ambiguousIdentity }
            for application in matches {
                if let row = try read(application.processIdentifier, role: role, route: route, path: paths[role]!) {
                    if !rows.contains(row) { rows.append(row) }
                }
            }
        }
        let candidateURL = URL(fileURLWithPath: route.directory).appendingPathComponent("managed-peers.json")
        if FileManager.default.fileExists(atPath: candidateURL.path) {
            guard let candidates = try JSONSerialization.jsonObject(
                with: readOwned(directory: URL(fileURLWithPath: route.directory), name: "managed-peers.json")) as? [[String: Any]], candidates.count <= 8
            else { throw HostedManagedApprovalError.invalidApplication }
            for candidate in candidates {
                guard Set(candidate.keys) == ["pid", "role"], let pid = candidate["pid"] as? Int32,
                    let role = candidate["role"] as? String, ["engine", "ui"].contains(role),
                    let path = paths[role] else { throw HostedManagedApprovalError.invalidApplication }
                if let row = try read(pid, role: role, route: route, path: path) {
                    if role == "engine" {
                        guard let host = rows.first(where: { $0.role == "host" }) else { continue }
                        var info = proc_bsdinfo()
                        let size = MemoryLayout<proc_bsdinfo>.size
                        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(size)) == size,
                            info.pbi_ppid == host.pid,
                            try read(host.pid, role: "host", route: route, path: host.executable) == host else { throw HostedManagedApprovalError.invalidApplication }
                    }
                    if !rows.contains(row) { rows.append(row) }
                }
            }
        }
        guard rows.count <= 16 else { throw HostedManagedApprovalError.invalidApplication }
        return rows
    }

    static func read(_ pid: Int32, role: String, route: HostedManagedApprovalRoute, path: String, generation: String? = nil) throws -> HostedManagedKernelProcess? {
        guard pid > 1, pid != getpid() else { throw HostedManagedApprovalError.invalidApplication }
        var before = proc_bsdinfo()
        var after = proc_bsdinfo()
        let size = MemoryLayout<proc_bsdinfo>.size
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &before, Int32(size)) == size else {
            guard kill(pid, 0) != 0 && errno == ESRCH else { throw HostedManagedApprovalError.invalidApplication }
            return nil
        }
        if let generation, generation != "\(before.pbi_start_tvsec).\(before.pbi_start_tvusec)" { return nil }
        guard before.pbi_uid == getuid(), before.pbi_ruid == getuid() else {
            throw HostedManagedApprovalError.invalidApplication
        }
        var actualPath = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &actualPath, UInt32(actualPath.count)) > 0,
            String(decoding: actualPath.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self) == path,
            URL(fileURLWithPath: path).resolvingSymlinksInPath().path == path,
            proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &after, Int32(size)) == size,
            after.pbi_uid == before.pbi_uid, after.pbi_ruid == before.pbi_ruid,
            after.pbi_start_tvsec == before.pbi_start_tvsec,
            after.pbi_start_tvusec == before.pbi_start_tvusec
        else { throw HostedManagedApprovalError.invalidApplication }
        return HostedManagedKernelProcess(pid: pid,
            generation: "\(before.pbi_start_tvsec).\(before.pbi_start_tvusec)", uid: before.pbi_uid,
            executable: path, hostIdentifier: route.hostIdentifier, role: role)
    }

    static func readOwned(directory: URL, name: String) throws -> Data {
        guard ["managed-peers.json", "cleanup-ledger.json"].contains(name),
            directory.path == directory.resolvingSymlinksInPath().path else { throw HostedManagedApprovalError.invalidRoute }
        let root = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard root >= 0 else { throw HostedManagedApprovalError.invalidRoute }
        defer { close(root) }
        var rootInfo = stat()
        guard fstat(root, &rootInfo) == 0, rootInfo.st_uid == getuid(), rootInfo.st_mode & 0o7777 == 0o700
        else { throw HostedManagedApprovalError.invalidRoute }
        let descriptor = openat(root, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw HostedManagedApprovalError.invalidRoute }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var before = stat()
        guard fstat(descriptor, &before) == 0, before.st_uid == getuid(), before.st_nlink == 1,
            before.st_mode & S_IFMT == S_IFREG, before.st_mode & 0o7777 == 0o600,
            before.st_size > 0, before.st_size <= 16_384,
            let bytes = try handle.read(upToCount: 16_385), bytes.count == before.st_size
        else { throw HostedManagedApprovalError.invalidRoute }
        var after = stat()
        var current = stat()
        var rootAfter = stat()
        guard lstat(directory.path, &rootAfter) == 0,
            rootAfter.st_dev == rootInfo.st_dev, rootAfter.st_ino == rootInfo.st_ino,
            rootAfter.st_uid == rootInfo.st_uid, rootAfter.st_mode == rootInfo.st_mode,
            fstatat(root, name, &current, AT_SYMLINK_NOFOLLOW) == 0,
            current.st_dev == before.st_dev, current.st_ino == before.st_ino,
            current.st_uid == before.st_uid, current.st_mode == before.st_mode,
            current.st_nlink == before.st_nlink, current.st_size == before.st_size,
            current.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec,
            current.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec,
            current.st_ctimespec.tv_sec == before.st_ctimespec.tv_sec,
            current.st_ctimespec.tv_nsec == before.st_ctimespec.tv_nsec,
            fstat(descriptor, &after) == 0, before.st_dev == after.st_dev, before.st_ino == after.st_ino,
            before.st_uid == after.st_uid, before.st_mode == after.st_mode, before.st_nlink == after.st_nlink,
            before.st_size == after.st_size, before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
            before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
            before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
            before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec
        else { throw HostedManagedApprovalError.invalidRoute }
        return bytes
    }
}

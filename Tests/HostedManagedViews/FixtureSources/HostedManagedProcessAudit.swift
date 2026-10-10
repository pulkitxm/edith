import AppKit
import Darwin
import Foundation

@main
struct HostedManagedProcessAudit {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            throw HostedManagedApprovalError.invalidRoute
        }
        let directory = URL(fileURLWithPath: CommandLine.arguments[1])
        let route = try HostedManagedApprovalRoute.load(
            directory: directory, environment: ProcessInfo.processInfo.environment)
        try route.validateHostedDirectory()
        let expected = directory.appendingPathComponent("Fixture.app")
        let executable = expected.appendingPathComponent("Contents/MacOS/Edith")
        let applications = NSRunningApplication.runningApplications(
            withBundleIdentifier: route.hostIdentifier)
        guard applications.count <= 1 else { throw HostedManagedApprovalError.ambiguousIdentity }
        var rows: [[String: Any]] = []
        for application in applications {
            guard let bundle = application.bundleURL, let path = application.executableURL,
                !application.isTerminated
            else { throw HostedManagedApprovalError.invalidApplication }
            try route.validateApplicationPaths(bundle: bundle, executable: path)
            let pid = application.processIdentifier
            var before = proc_bsdinfo()
            var after = proc_bsdinfo()
            let size = MemoryLayout<proc_bsdinfo>.size
            var actualPath = [CChar](repeating: 0, count: 4096)
            guard pid > 1, proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &before, Int32(size)) == size,
                before.pbi_uid == getuid(), before.pbi_ruid == getuid(),
                proc_pidpath(pid, &actualPath, UInt32(actualPath.count)) > 0,
                String(
                    decoding: actualPath.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) },
                    as: UTF8.self) == executable.path,
                proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &after, Int32(size)) == size,
                after.pbi_uid == before.pbi_uid, after.pbi_ruid == before.pbi_ruid,
                after.pbi_start_tvsec == before.pbi_start_tvsec,
                after.pbi_start_tvusec == before.pbi_start_tvusec, !application.isTerminated
            else { throw HostedManagedApprovalError.invalidApplication }
            rows.append([
                "pid": pid, "generation": "\(before.pbi_start_tvsec).\(before.pbi_start_tvusec)",
                "uid": before.pbi_uid, "executable": executable.path,
                "hostIdentifier": route.hostIdentifier,
            ])
        }
        let data = try JSONSerialization.data(withJSONObject: rows, options: [.sortedKeys])
        guard data.count <= 16_384 else { throw HostedManagedApprovalError.invalidApplication }
        FileHandle.standardOutput.write(data)
    }
}

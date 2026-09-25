import Darwin
import EdithKit
import Foundation

enum DevelopmentAgentJob {
    enum Load: Equatable {
        case current
        case started
        case failed
    }

    private static var domain: String { "gui/\(getuid())" }
    private static var target: String { domain + "/" + AgentService.label }

    static func ensureCurrent() async -> Load {
        let executable = AgentBuildStamp.executableURL().resolvingSymlinksInPath()
        guard let description = await launchctl("print", target) else { return await bootstrap() }
        let fields = topLevelFields(description)
        guard
            fields["program"].map({ URL(fileURLWithPath: $0).resolvingSymlinksInPath() })
                == executable
        else {
            _ = await launchctl("bootout", target)
            return await bootstrap()
        }
        guard let pid = fields["pid"].flatMap(pid_t.init), let started = processStart(pid),
            let built = modificationDate(executable), started < built
        else { return .current }
        return await launchctl("kickstart", "-k", target) == nil ? .failed : .started
    }

    static func unload() async {
        _ = await launchctl("bootout", target)
    }

    static func topLevelFields(_ description: String) -> [String: String] {
        var fields: [String: String] = [:]
        for line in description.split(separator: "\n")
        where line.hasPrefix("\t") && !line.hasPrefix("\t\t") {
            guard let separator = line.range(of: " = ") else { continue }
            let key = String(line[line.index(after: line.startIndex)..<separator.lowerBound])
            if fields[key] == nil { fields[key] = String(line[separator.upperBound...]) }
        }
        return fields
    }

    private static func bootstrap() async -> Load {
        for _ in 0..<10 {
            if await launchctl("bootstrap", domain, AgentService.bundledPlistURL.path) != nil {
                return .started
            }
            guard (try? await Task.sleep(for: .milliseconds(200))) != nil else { break }
        }
        return .failed
    }

    private static func processStart(_ pid: pid_t) -> Date? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var name = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&name, u_int(name.count), &info, &size, nil, 0) == 0, size > 0 else {
            return nil
        }
        let start = info.kp_proc.p_starttime
        return Date(
            timeIntervalSince1970: TimeInterval(start.tv_sec) + TimeInterval(start.tv_usec) / 1e6)
    }

    private static func modificationDate(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate
    }

    private static func launchctl(_ arguments: String...) async -> String? {
        let request = CLICommandRequest(
            executableURL: URL(fileURLWithPath: "/bin/launchctl"), arguments: arguments,
            environment: [:], timeout: 10, maximumOutputBytes: 1 << 20,
            discardsStandardError: true)
        guard let result = try? await CLICommandRunner.runLocal(request, onLine: { _ in }),
            result.terminationStatus == 0
        else { return nil }
        return result.standardOutput
    }
}

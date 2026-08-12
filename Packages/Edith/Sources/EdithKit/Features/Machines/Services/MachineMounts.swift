import Darwin
import Foundation

public struct MachineMount: Codable, Equatable, Sendable {
    public var machineID: UUID?
    public var target: String
    public var remotePath: String
    public var mountPoint: String
    public var isReadOnly: Bool

    public init(
        machineID: UUID? = nil, target: String, remotePath: String, mountPoint: String,
        isReadOnly: Bool = false
    ) {
        self.machineID = machineID
        self.target = target
        self.remotePath = remotePath
        self.mountPoint = mountPoint
        self.isReadOnly = isReadOnly
    }

    public var source: String { "\(target):\(remotePath)" }
}

public struct MountedVolume: Equatable, Sendable {
    public var source: String
    public var mountPoint: String
    public var kinds: [String]

    public init(source: String, mountPoint: String, kinds: [String]) {
        self.source = source
        self.mountPoint = mountPoint
        self.kinds = kinds
    }

    public var isReadOnly: Bool { kinds.contains("read-only") }
    public var looksLikeFUSE: Bool { kinds.contains { $0.contains("fuse") } }
}

public enum MountHealth: String, Equatable, Sendable {
    case mounted
    case stale
    case gone

    public var needsRepair: Bool { self != .mounted }

    public var describes: String {
        switch self {
        case .mounted: return "mounted"
        case .stale: return "not answering"
        case .gone: return "gone"
        }
    }
}

public enum MountRepair: Equatable, Sendable {
    case nothingToDo
    case healthy(MachineMount)
    case remounted(MachineMount)
    case failed(MachineMount, String)
}

public enum MachineMountError: LocalizedError, Equatable {
    case toolMissing
    case alreadyMounted(String)
    case notMounted(String)
    case mountPointBusy(String)
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .toolMissing:
            return "sshfs is not installed on this Mac."
        case let .alreadyMounted(path):
            return "That machine is already mounted at \(path)."
        case let .notMounted(name):
            return "\(name) is not mounted."
        case let .mountPointBusy(path):
            return "\(path) already has something in it."
        case let .failed(message):
            return message.isEmpty ? "The mount failed." : message
        }
    }

    public var hint: String? {
        switch self {
        case .toolMissing:
            return "install FUSE-T, which needs no kernel extension: "
                + "brew install --cask macos-fuse-t/cask/fuse-t "
                + "macos-fuse-t/cask/fuse-t-sshfs"
        case .mountPointBusy:
            return "pick another folder with --at, or empty that one"
        default:
            return nil
        }
    }
}

final class MountOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        lock.lock()
        data.append(chunk)
        lock.unlock()
    }

    func text() -> String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }
}

public enum MachineMounts {
    nonisolated(unsafe) public static var root: URL =
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Edith")

    public static let toolName = "sshfs"

    public static var recordsFile: URL { MachinePaths.dir.appendingPathComponent("mounts.json") }

    public static func folderName(for machine: Machine) -> String {
        let cleaned = machine.name
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? machine.id.uuidString : cleaned
    }

    public static func mountPoint(for machine: Machine) -> URL {
        root.appendingPathComponent(folderName(for: machine))
    }

    public static func executable() -> URL? {
        CLIToolEnvironment.executable(named: toolName)
    }

    public static var isAvailable: Bool { executable() != nil }

    public static func parse(_ output: String) -> [MountedVolume] {
        output.split(separator: "\n").compactMap { line in
            let text = String(line)
            guard let separator = text.range(of: " on ") else { return nil }
            let rest = String(text[separator.upperBound...])
            guard let optionsStart = rest.range(of: " (", options: .backwards) else { return nil }
            let options = String(rest[optionsStart.upperBound...])
                .replacingOccurrences(of: ")", with: "")
            return MountedVolume(
                source: String(text[text.startIndex..<separator.lowerBound]),
                mountPoint: String(rest[rest.startIndex..<optionsStart.lowerBound]),
                kinds: options.split(separator: ",").map {
                    $0.trimmingCharacters(in: .whitespaces)
                })
        }
    }

    public static func mount(for machine: Machine, in mounts: [MachineMount]) -> MachineMount? {
        mounts.first { $0.machineID == machine.id || $0.target == machine.sshTarget }
    }

    public static func adopted(_ volume: MountedVolume) -> MachineMount? {
        guard volume.looksLikeFUSE, let colon = volume.source.firstIndex(of: ":") else {
            return nil
        }
        return MachineMount(
            target: String(volume.source[volume.source.startIndex..<colon]),
            remotePath: String(volume.source[volume.source.index(after: colon)...]),
            mountPoint: volume.mountPoint, isReadOnly: volume.isReadOnly)
    }

    public static func reconcile(records: [MachineMount], with volumes: [MountedVolume])
        -> [MachineMount]
    {
        let byPoint = Dictionary(
            volumes.map { ($0.mountPoint, $0) }, uniquingKeysWith: { first, _ in first })
        var live = records.compactMap { record -> MachineMount? in
            guard let volume = byPoint[record.mountPoint] else { return nil }
            var updated = record
            updated.isReadOnly = volume.isReadOnly || record.isReadOnly
            return updated
        }
        let known = Set(live.map(\.mountPoint))
        live += volumes.compactMap { volume in
            guard !known.contains(volume.mountPoint) else { return nil }
            return adopted(volume)
        }
        return live
    }

    public static func volumes() async -> [MountedVolume] {
        parse(await run(URL(fileURLWithPath: "/sbin/mount"), []).output)
    }

    public static func list() async -> [MachineMount] {
        reconcile(records: records(), with: await volumes())
    }

    public static func tracked() async -> [MachineMount] {
        let live = reconcile(records: records(), with: await volumes())
        let known = Set(live.map(\.mountPoint))
        return live + records().filter { !known.contains($0.mountPoint) }
    }

    public static func current(for machine: Machine) async -> MachineMount? {
        mount(for: machine, in: await list())
    }

    public static func options(
        machine: Machine, readOnly: Bool, uid: uid_t = getuid(), gid: gid_t = getgid(),
        minimal: Bool = false,
        useFSKit: Bool = ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26
    ) -> [String] {
        var options = [
            "ControlPath=\"\(MachinePaths.socketFile(for: machine.id).path)\"",
            "ControlMaster=no",
            "reconnect",
            "ServerAliveInterval=15",
            "ServerAliveCountMax=3",
        ]
        if !machine.auth.usesAskpass { options.append("BatchMode=yes") }
        if !minimal {
            if useFSKit { options.append("backend=fskit") }
            options += [
                "volname=\(folderName(for: machine))",
                "noatime",
                "defer_permissions",
                "noappledouble",
                "noapplexattr",
                "idmap=user",
                "uid=\(uid)",
                "gid=\(gid)",
            ]
        }
        if readOnly { options.append("ro") }
        return options
    }

    public static func mountArguments(
        machine: Machine, remotePath: String, mountPoint: String, readOnly: Bool,
        uid: uid_t = getuid(), gid: gid_t = getgid(), minimal: Bool = false,
        useFSKit: Bool = ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26
    ) -> [String] {
        var options = options(
            machine: machine, readOnly: readOnly, uid: uid, gid: gid, minimal: minimal,
            useFSKit: useFSKit)
        var arguments = ["\(machine.sshTarget):\(remotePath)", mountPoint]
        if case .manual = machine.source {
            arguments += ["-p", String(machine.port)]
            if case let .keyFile(path, _) = machine.auth {
                options += [
                    "IdentityFile=\(SSHConfigFile.expandTilde(path))",
                    "IdentitiesOnly=yes",
                ]
            }
        }
        for option in options { arguments += ["-o", option] }
        return arguments
    }

    @discardableResult
    public static func mount(
        machine: Machine, remotePath: String, at mountPoint: URL? = nil, readOnly: Bool = false
    ) async throws -> MachineMount {
        guard let tool = executable() else { throw MachineMountError.toolMissing }
        if let existing = await current(for: machine) {
            throw MachineMountError.alreadyMounted(existing.mountPoint)
        }
        let destination = mountPoint ?? Self.mountPoint(for: machine)
        try prepare(destination)
        await stopOrphanedFuseTHelpers(at: destination.path)
        var complaint = ""
        for minimal in [false, true] {
            let arguments = mountArguments(
                machine: machine, remotePath: remotePath, mountPoint: destination.path,
                readOnly: readOnly, minimal: minimal)
            let attempt = await attach(
                tool, arguments, machine: machine, at: destination, remotePath: remotePath)
            if let landed = attempt.mount {
                remember(records().filter { $0.machineID != machine.id } + [landed])
                return landed
            }
            complaint = attempt.complaint
        }
        discardEmptyFolder(at: destination.path)
        throw MachineMountError.failed(
            complaint.isEmpty ? "sshfs did not mount it and said nothing about why" : complaint)
    }

    @discardableResult
    public static func unmount(machine: Machine) async throws -> MachineMount {
        guard let existing = await current(for: machine) else {
            throw MachineMountError.notMounted(machine.name)
        }
        let complaint = await release(existing.mountPoint)
        guard await current(for: machine) == nil else {
            throw MachineMountError.failed(
                complaint.isEmpty
                    ? "\(existing.mountPoint) would not unmount; something may still be in it"
                    : complaint)
        }
        remember(records().filter { $0.mountPoint != existing.mountPoint })
        await stopOrphanedFuseTHelpers(at: existing.mountPoint)
        discardEmptyFolder(at: existing.mountPoint)
        return existing
    }

    public static func health(of mount: MachineMount) async -> MountHealth {
        guard await volumes().contains(where: { $0.mountPoint == mount.mountPoint }) else {
            return .gone
        }
        let probe = await run(
            URL(fileURLWithPath: "/usr/bin/stat"), ["-f%i", mount.mountPoint], timeout: 6)
        return probe.status == 0 ? .mounted : .stale
    }

    public static func recorded(for machine: Machine, in file: URL? = nil) -> MachineMount? {
        records(in: file).first { $0.machineID == machine.id }
    }

    @discardableResult
    public static func restore(machine: Machine) async -> MountRepair {
        guard let wanted = recorded(for: machine) else { return .nothingToDo }
        let health = await health(of: wanted)
        guard health.needsRepair else { return .healthy(wanted) }
        if health == .stale { _ = await release(wanted.mountPoint) }
        remember(records().filter { $0.machineID != machine.id })
        do {
            let landed = try await mount(
                machine: machine, remotePath: wanted.remotePath,
                at: URL(fileURLWithPath: wanted.mountPoint), readOnly: wanted.isReadOnly)
            return .remounted(landed)
        } catch {
            remember(records() + [wanted])
            return .failed(wanted, error.localizedDescription)
        }
    }

    static func release(_ mountPoint: String) async -> String {
        var result = await run(URL(fileURLWithPath: "/sbin/umount"), [mountPoint], timeout: 20)
        if result.status != 0 {
            result = await run(
                URL(fileURLWithPath: "/sbin/umount"), ["-f", mountPoint], timeout: 20)
        }
        if result.status != 0 {
            result = await run(
                URL(fileURLWithPath: "/usr/sbin/diskutil"),
                ["unmount", "force", mountPoint], timeout: 30)
        }
        return explain(result.output)
    }

    static func settled(machine: Machine, at destination: URL, remotePath: String) async
        -> MachineMount?
    {
        guard let volume = await volumes().first(where: { $0.mountPoint == destination.path })
        else { return nil }
        return MachineMount(
            machineID: machine.id, target: machine.sshTarget, remotePath: remotePath,
            mountPoint: destination.path, isReadOnly: volume.isReadOnly)
    }

    private static func attach(
        _ tool: URL, _ arguments: [String], machine: Machine, at destination: URL,
        remotePath: String
    ) async -> (mount: MachineMount?, complaint: String) {
        let process = Process()
        process.executableURL = tool
        process.arguments = arguments
        process.environment = MachineSSHEnvironment.make(for: machine)
        let pipe = Pipe()
        let output = MountOutput()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        pipe.fileHandleForReading.readabilityHandler = { handle in
            PipeReading.consume(handle, receive: output.append)
        }
        guard (try? process.run()) != nil else {
            pipe.fileHandleForReading.readabilityHandler = nil
            return (nil, "\(tool.lastPathComponent) could not be started")
        }
        var landed: MachineMount?
        for _ in 0..<40 {
            try? await Task.sleep(for: .milliseconds(400))
            landed = await settled(machine: machine, at: destination, remotePath: remotePath)
            if landed != nil { break }
            if !process.isRunning {
                try? await Task.sleep(for: .milliseconds(300))
                landed = await settled(machine: machine, at: destination, remotePath: remotePath)
                break
            }
        }
        if landed == nil, process.isRunning { process.terminate() }
        pipe.fileHandleForReading.readabilityHandler = nil
        if landed == nil { await stopOrphanedFuseTHelpers(at: destination.path) }
        return (landed, landed == nil ? explain(output.text()) : "")
    }

    static func fuseTHelperPIDs(in output: String, mountedAt mountPoint: String) -> [pid_t] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(maxSplits: 1, whereSeparator: \.isWhitespace)
            guard fields.count == 2, let pid = pid_t(fields[0]) else { return nil }
            let command = String(fields[1])
            guard command.contains("go-nfsv4"), command.hasSuffix(" \(mountPoint)") else {
                return nil
            }
            return pid
        }
    }

    private static func fuseTHelperPIDs(at mountPoint: String) async -> [pid_t] {
        let result = await run(
            URL(fileURLWithPath: "/bin/ps"), ["-axo", "pid=,command="], timeout: 5)
        guard result.status == 0 else { return [] }
        return fuseTHelperPIDs(in: result.output, mountedAt: mountPoint)
    }

    private static func stopOrphanedFuseTHelpers(at mountPoint: String) async {
        guard !(await volumes()).contains(where: { $0.mountPoint == mountPoint }) else { return }
        let helpers = await fuseTHelperPIDs(at: mountPoint)
        guard !helpers.isEmpty else { return }
        for pid in helpers { _ = Darwin.kill(pid, SIGTERM) }
        try? await Task.sleep(for: .milliseconds(300))
        guard !(await volumes()).contains(where: { $0.mountPoint == mountPoint }) else { return }
        let survivors = Set(await fuseTHelperPIDs(at: mountPoint))
        for pid in helpers where survivors.contains(pid) { _ = Darwin.kill(pid, SIGKILL) }
    }

    static func prepare(_ mountPoint: URL) throws {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        if fm.fileExists(atPath: mountPoint.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue,
                (try? fm.contentsOfDirectory(atPath: mountPoint.path))?.isEmpty != false
            else { throw MachineMountError.mountPointBusy(mountPoint.path) }
            return
        }
        do {
            try fm.createDirectory(at: mountPoint, withIntermediateDirectories: true)
        } catch {
            throw MachineMountError.failed(error.localizedDescription)
        }
    }

    public static func records(in file: URL? = nil) -> [MachineMount] {
        guard let data = try? Data(contentsOf: file ?? recordsFile) else { return [] }
        return (try? JSONDecoder().decode([MachineMount].self, from: data)) ?? []
    }

    public static func remember(_ mounts: [MachineMount], in file: URL? = nil) {
        let destination = file ?? recordsFile
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(mounts.filter { $0.machineID != nil }) else { return }
        try? FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: destination, options: .atomic)
    }

    private static func discardEmptyFolder(at path: String) {
        let fm = FileManager.default
        guard path.hasPrefix(root.path + "/"),
            (try? fm.contentsOfDirectory(atPath: path))?.isEmpty == true
        else { return }
        try? fm.removeItem(atPath: path)
    }

    private static func explain(_ output: String) -> String {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        return trimmed.split(separator: "\n").last.map(String.init) ?? trimmed
    }

    private static func run(
        _ executable: URL, _ arguments: [String], timeout: TimeInterval = 30
    ) async -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = CLIToolEnvironment.sanitized()
        let pipe = Pipe()
        let output = MountOutput()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        pipe.fileHandleForReading.readabilityHandler = { handle in
            PipeReading.consume(handle, receive: output.append)
        }
        guard (try? process.run()) != nil else {
            pipe.fileHandleForReading.readabilityHandler = nil
            return (-1, "\(executable.lastPathComponent) could not be started")
        }
        let status = await SSHConnection.waitForExit(process, timeout: timeout)
        pipe.fileHandleForReading.readabilityHandler = nil
        return (status, output.text())
    }
}

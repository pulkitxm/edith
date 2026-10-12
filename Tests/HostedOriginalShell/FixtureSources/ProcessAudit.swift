import CryptoKit
import Darwin
import Foundation

@main
struct JourneyProcessAudit {
    struct State: Decodable {
        let hostIdentifier: String
        let sourceCommit: String
        let ownedProcesses: [JourneyProcessObservation]
    }

    static func main() throws {
        let environment = ProcessInfo.processInfo.environment
        guard CommandLine.arguments.count == 2,
            let directory = environment["EDITH_GUI_FIXTURE_DIRECTORY"],
            directory == CommandLine.arguments[1]
        else { throw JourneyContractError.invalidPaths }
        var user = passwd()
        var result: UnsafeMutablePointer<passwd>?
        var buffer = [CChar](repeating: 0, count: 16_384)
        guard getpwuid_r(getuid(), &user, &buffer, buffer.count, &result) == 0, result != nil,
            let home = user.pw_dir
        else { throw JourneyContractError.invalidPaths }
        let root = URL(fileURLWithPath: directory)
        let fixture = try JSONDecoder().decode(
            JourneyFixture.self,
            from: read(root.appendingPathComponent("journey.json"), limit: 16_384))
        try fixture.validate(accountHome: String(cString: home), environment: environment)
        try fixture.validateApplicationEnvironment(environment)
        let state = try JSONDecoder().decode(
            State.self, from: read(root.appendingPathComponent("state.json"), limit: 131_072))
        guard state.hostIdentifier == fixture.identifier,
            state.sourceCommit == fixture.sourceCommit,
            state.ownedProcesses.count <= 64
        else { throw JourneyContractError.invalidMetadata }
        var observations: [JourneyProcessObservation] = []
        for item in state.ownedProcesses {
            guard item.pid > 1, ["host", "engine", "managedUI"].contains(item.role) else {
                throw JourneyContractError.invalidMetadata
            }
            var info = proc_bsdinfo()
            let size = MemoryLayout<proc_bsdinfo>.size
            let exists =
                proc_pidinfo(item.pid, PROC_PIDTBSDINFO, 0, &info, Int32(size)) == size
                && info.pbi_uid == getuid()
                && "\(info.pbi_start_tvsec):\(info.pbi_start_tvusec)" == item.generation
            var path = [CChar](repeating: 0, count: 4096)
            var task = proc_taskinfo()
            let taskSize = MemoryLayout<proc_taskinfo>.size
            var running = exists
            var resident: UInt64?
            if exists {
                guard proc_pidpath(item.pid, &path, UInt32(path.count)) > 0 else {
                    throw JourneyContractError.invalidMetadata
                }
                let executable = String(cString: path)
                guard
                    item.role == "managedUI"
                        ? executable.hasPrefix(fixture.identityRoot + "/Extensions/calendar/")
                        : executable == fixture.executable
                else { throw JourneyContractError.invalidMetadata }
                if proc_pidinfo(item.pid, PROC_PIDTASKINFO, 0, &task, Int32(taskSize)) == taskSize {
                    resident = task.pti_resident_size
                }
                running =
                    proc_pidinfo(item.pid, PROC_PIDTBSDINFO, 0, &info, Int32(size)) == size
                    && "\(info.pbi_start_tvsec):\(info.pbi_start_tvusec)" == item.generation
            }
            observations.append(
                .init(
                    role: item.role, pid: item.pid, generation: item.generation,
                    running: running, residentBytes: resident))
        }
        FileHandle.standardOutput.write(try JSONEncoder().encode(observations))
    }

    private static func read(_ url: URL, limit: Int) throws -> Data {
        guard url.path == url.resolvingSymlinksInPath().path else {
            throw JourneyContractError.invalidPaths
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
            (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid()
        else { throw JourneyContractError.invalidPaths }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        guard let data = try handle.read(upToCount: limit + 1), data.count <= limit else {
            throw JourneyContractError.invalidMetadata
        }
        return data
    }
}

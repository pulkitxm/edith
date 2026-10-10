#if EDITH_CLI_FIXTURE
import Darwin
import EdithExtensionSupport
import EdithHostCore
import Foundation

@MainActor enum HostCoreFixture {
    static func run(directory: URL, orphan: Bool) throws {
        guard let identifier = Bundle.main.bundleIdentifier,
            identifier.hasPrefix("com.pulkit.edith.tests.core-"),
            let executable = Bundle.main.executableURL
        else { throw HostWorkerError.rejected }
        let identity = try HostIdentity(identifier: identifier, supportDirectory: directory)
        guard let application = SharedDefaults.applicationStore(identifier: identifier) else {
            throw HostWorkerError.rejected
        }
        Task {
            defer { application.removePersistentDomain(forName: identifier) }
            let service = HostCoreProcess(identity: identity, executable: executable)
            var stage = "start"
            do {
                application.set("synthetic-ocean", forKey: AppStorageKeys.General.theme)
                application.synchronize()
                let started = try await service.start()
                stage = "export"
                let exported = try await service.perform(.synchronize)
                stage = "export receipt"
                guard exported.settingsBackup?.exported == true,
                    exported.tasks.last?.phase == .completed,
                    FileManager.default.fileExists(
                        atPath: exported.cloudDirectory.appendingPathComponent("settings.json").path
                    )
                else { throw HostWorkerError.rejected }
                application.set("synthetic-forest", forKey: AppStorageKeys.General.theme)
                application.synchronize()
                stage = "restore"
                let imported = try await service.perform(.restore)
                application.synchronize()
                stage = "restore receipt"
                guard imported.settingsBackup?.restored == true,
                    imported.settingsBackup?.exported == false,
                    imported.tasks.last?.phase == .completed,
                    application.string(forKey: AppStorageKeys.General.theme) == "synthetic-ocean"
                else { throw HostWorkerError.rejected }
                stage = "storage"
                let data = identity.extensionDirectory("usage")
                try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
                try Data(repeating: 7, count: 71).write(
                    to: data.appendingPathComponent("synthetic"))
                let inspection = Task { try await service.perform(.inspect) }
                await Task.yield()
                let concurrent = try await service.perform(.status)
                guard concurrent.pid == started.pid else { throw HostWorkerError.rejected }
                let measured = try await inspection.value
                guard measured.storage?.footprints.first(where: { $0.id == "usage" })?.bytes == 71,
                    measured.tasks.last?.phase == .completed,
                    let pid = service.processIdentifier
                else { throw HostWorkerError.rejected }
                try HostCoreFiles.write(
                    JSONSerialization.data(withJSONObject: [
                        "ownerPID": getpid(), "corePID": pid, "measuredBytes": 71,
                        "residentBytes": started.residentBytes, "processGroup": getpgid(pid),
                        "mode": orphan ? "owner-exit" : "normal",
                    ]), to: directory.appendingPathComponent("ready.json"))
                if orphan {
                    while true { try await Task.sleep(for: .seconds(1)) }
                }
                await service.stop()
                guard !service.ready, service.processIdentifier == nil else {
                    throw HostWorkerError.rejected
                }
                let restarted = HostCoreProcess(identity: identity, executable: executable)
                let restored = try await restarted.start()
                guard restored.tasks.last?.id == measured.tasks.last?.id else {
                    throw HostWorkerError.rejected
                }
                await restarted.stop()
                try HostCoreFiles.write(
                    JSONSerialization.data(withJSONObject: [
                        "passed": true, "restartRetainedTasks": true, "stoppedProcesses": true,
                        "concurrentStatus": true,
                        "settingsExport": true, "settingsRestore": true,
                    ]), to: directory.appendingPathComponent("result.json"))
                exit(0)
            } catch {
                await service.stop()
                try? HostCoreFiles.write(
                    JSONSerialization.data(withJSONObject: [
                        "passed": false, "failure": String(describing: error), "stage": stage,
                    ]), to: directory.appendingPathComponent("result.json"))
                exit(1)
            }
        }
        dispatchMain()
    }
}
#endif

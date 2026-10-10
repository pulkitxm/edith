import Darwin
import EdithExtensionSupport
import Foundation
import Testing

@testable import EdithHostCore

@Suite @MainActor struct HostWorkerProcessGroupsTests {
    private final class Kernel {
        var identities: [Int32: ExtensionProcessIdentity] = [:]
        var groups: [Int32: Int32] = [:]
        var signals: [Int32] = []

        func tracker(maximum: Int = 128) -> HostWorkerProcessGroups {
            HostWorkerProcessGroups(
                maximumGroups: maximum,
                read: { self.identities[$0] },
                group: { self.groups[$0] ?? -1 },
                members: { group in
                    self.identities.values.filter { self.groups[$0.pid] == group }
                },
                signal: { self.signals.append($0) })
        }

        func add(_ pid: Int32, generation: String, group: Int32? = nil) throws {
            identities[pid] = try JSONDecoder().decode(
                ExtensionProcessIdentity.self,
                from: JSONSerialization.data(withJSONObject: [
                    "pid": pid, "generation": generation,
                ]))
            groups[pid] = group ?? pid
        }
    }

    @Test func forgedGenerationsNeverSignalTheLiveProcess() throws {
        let kernel = Kernel()
        try kernel.add(1234, generation: "2.0")
        var tracker = kernel.tracker()
        #expect(throws: HostWorkerError.invalidResponse) {
            try tracker.register(
                HostWorkerProcessGroup(pid: 1234, generation: "1.0", registered: true), owner: 42)
        }
        tracker.terminate(owner: 42)
        #expect(kernel.signals.isEmpty)
        #expect(tracker.count == 0)
    }

    @Test func reusedPIDsAndGroupsArePrunedWithoutSignallingTheirNewOwners() throws {
        let kernel = Kernel()
        try kernel.add(1234, generation: "1.0")
        try kernel.add(1235, generation: "1.1", group: 1234)
        var tracker = kernel.tracker()
        try tracker.register(
            HostWorkerProcessGroup(pid: 1234, generation: "1.0", registered: true), owner: 42)
        try kernel.add(1234, generation: "2.0")
        try kernel.add(1235, generation: "2.1", group: 1234)
        tracker.terminate(owner: 42)
        #expect(kernel.signals.isEmpty)
        #expect(tracker.count == 0)
    }

    @Test func deadRegistrationsArePrunedBeforeTheBoundAndForgedReleasesAreIgnored() throws {
        let kernel = Kernel()
        try kernel.add(1234, generation: "1.0")
        var tracker = kernel.tracker(maximum: 1)
        try tracker.register(
            HostWorkerProcessGroup(pid: 1234, generation: "1.0", registered: true), owner: 42)
        tracker.release(
            HostWorkerProcessGroup(pid: 1234, generation: "0.0", registered: false), owner: 42)
        #expect(tracker.count == 1)
        kernel.identities[1234] = nil
        try kernel.add(1235, generation: "2.0")
        try tracker.register(
            HostWorkerProcessGroup(pid: 1235, generation: "2.0", registered: true), owner: 42)
        #expect(tracker.count == 1)
        try kernel.add(1236, generation: "3.0")
        #expect(throws: HostWorkerError.invalidResponse) {
            try tracker.register(
                HostWorkerProcessGroup(pid: 1236, generation: "3.0", registered: true), owner: 42)
        }
        #expect(kernel.signals == [-1236])
        tracker.terminate(owner: 42)
        #expect(kernel.signals == [-1236, -1235])
    }

    @Test func liveDescendantsKeepTheirGroupOwnedAfterTheLeaderExits() throws {
        let kernel = Kernel()
        try kernel.add(1234, generation: "1.0")
        try kernel.add(1235, generation: "1.1", group: 1234)
        var tracker = kernel.tracker()
        try tracker.register(
            HostWorkerProcessGroup(pid: 1234, generation: "1.0", registered: true), owner: 42)
        kernel.identities[1234] = nil
        tracker.refresh(owner: 42)
        #expect(tracker.count == 1)
        tracker.terminate(owner: 42)
        #expect(kernel.signals == [-1234])
    }

    @Test func workerOwnershipDoesNotConsumeTheRegisteredGroupBudget() throws {
        let kernel = Kernel()
        try kernel.add(42, generation: "1.0")
        try kernel.add(1234, generation: "2.0")
        var tracker = kernel.tracker(maximum: 1)
        try tracker.register(
            HostWorkerProcessGroup(pid: 42, generation: "1.0", registered: true), owner: 42)
        try tracker.register(
            HostWorkerProcessGroup(pid: 1234, generation: "2.0", registered: true), owner: 42)
        #expect(tracker.count == 1)
        tracker.terminate(owner: 42)
        #expect(Set(kernel.signals) == [42, -42, -1234])
    }

    @Test func kernelGroupSurvivorsAreTerminatedAfterTheirLeaderExits() throws {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [
            "-c",
            "import os,subprocess,time;os.setpgrp();child=subprocess.Popen(['/bin/sleep','30']);print(child.pid,flush=True);time.sleep(30)",
        ]
        process.standardOutput = output
        try process.run()
        defer {
            kill(-process.processIdentifier, SIGKILL)
            process.waitUntilExit()
        }
        let bytes = output.fileHandleForReading.availableData
        let child = try #require(
            Int32(
                String(decoding: bytes, as: UTF8.self).trimmingCharacters(
                    in: .whitespacesAndNewlines)))
        let identity = try #require(ExtensionProcessIdentity.read(process.processIdentifier))
        var tracker = HostWorkerProcessGroups()
        try tracker.register(
            HostWorkerProcessGroup(
                pid: identity.pid, generation: identity.generation, registered: true),
            owner: getpid())
        kill(process.processIdentifier, SIGKILL)
        process.waitUntilExit()
        #expect(kill(child, 0) == 0)
        tracker.terminate(owner: getpid())
        let deadline = Date().addingTimeInterval(2)
        while kill(child, 0) == 0, Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        #expect(kill(child, 0) == -1)
    }

    @Test func kernelGenerationAdmissionPreservesAnUnrelatedProcess() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", "import os,time;os.setpgrp();time.sleep(30)"]
        try process.run()
        defer {
            kill(process.processIdentifier, SIGKILL)
            process.waitUntilExit()
        }
        let deadline = Date().addingTimeInterval(2)
        while getpgid(process.processIdentifier) != process.processIdentifier,
            Date() < deadline
        {
            Thread.sleep(forTimeInterval: 0.01)
        }
        let identity = try #require(ExtensionProcessIdentity.read(process.processIdentifier))
        var tracker = HostWorkerProcessGroups()
        #expect(throws: HostWorkerError.invalidResponse) {
            try tracker.register(
                HostWorkerProcessGroup(
                    pid: identity.pid, generation: identity.generation + "0", registered: true),
                owner: getpid())
        }
        tracker.terminate(owner: getpid())
        #expect(kill(process.processIdentifier, 0) == 0)
    }
}

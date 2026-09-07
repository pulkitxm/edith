import AppKit
import Foundation
import Testing

@testable import Edith
@testable import EdithKit

@Suite @MainActor struct MachineViewActivityTests {
    @Test func releasingOneViewKeepsSamplingForTheOther() {
        let session = localSession()
        let first = MachineActivityLease(kind: .metrics)
        let second = MachineActivityLease(kind: .metrics)
        defer { session.stop() }

        first.update([session], active: true)
        second.update([session], active: true)
        #expect(session.isCollecting)
        first.release()
        #expect(session.isCollecting)
        second.release()
        #expect(!session.isCollecting)
        #expect(session.state.isConnected)
    }

    @Test func repeatedPresentationUpdatesDoNotLeakDemand() {
        let session = localSession()
        let lease = MachineActivityLease(kind: .metrics)
        defer { session.stop() }

        for _ in 0..<20 { lease.update([session, session], active: true) }
        lease.update([session], active: false)
        #expect(!session.isCollecting)
        lease.update([session], active: true)
        #expect(session.isCollecting)
        lease.release()
        #expect(!session.isCollecting)
    }

    @Test func movingAViewReleasesTheOldMachine() {
        let first = localSession()
        let second = localSession()
        let lease = MachineActivityLease(kind: .metrics)
        defer {
            first.stop()
            second.stop()
        }

        lease.update([first], active: true)
        lease.update([second], active: true)
        #expect(!first.isCollecting)
        #expect(second.isCollecting)
        lease.release()
        #expect(!second.isCollecting)
    }

    @Test func replacingASessionWithTheSameMachineIDTransfersDemand() {
        let machine = Machine(name: "local", host: "localhost")
        let first = MachineSession(machine: machine, local: true, observesWakeRequests: false)
        let second = MachineSession(machine: machine, local: true, observesWakeRequests: false)
        let lease = MachineActivityLease(kind: .metrics)
        defer {
            first.stop()
            second.stop()
        }

        lease.update([first], active: true)
        lease.update([second], active: true)
        #expect(!first.isCollecting)
        #expect(second.isCollecting)
        lease.release()
    }

    @Test func hiddenDockerViewsReleaseTheirForegroundCadence() {
        let session = localSession()
        let first = MachineActivityLease(kind: .docker)
        let second = MachineActivityLease(kind: .docker)

        first.update([session], active: true)
        second.update([session], active: true)
        first.update([session], active: false)
        #expect(
            session.currentDockerPollInterval == MachineResourcePolicy.foregroundDockerPollInterval)
        second.release()
        #expect(
            session.currentDockerPollInterval == MachineResourcePolicy.backgroundDockerPollInterval)
    }

    @Test func suspendingViewsLeavesFiniteCommandsAvailable() async throws {
        let session = localSession()
        let lease = MachineActivityLease(kind: .metrics)
        defer { session.stop() }
        lease.update([session], active: true)
        lease.release()

        let result = try await session.runCommand("printf available", timeout: 5).get()

        #expect(result == "available")
        #expect(session.state.isConnected)
        #expect(!session.isCollecting)
    }

    @Test func hiddenViewsStopARealLogProcessAndResumeOnReturn() async throws {
        let session = localSession()
        let container = DockerContainer(
            id: "visibility", names: ["visibility"], image: "fixture", command: "",
            state: .running, status: "Up")
        var processes: [Process] = []
        let model = DockerDetailModel { _, _ in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", "printf 'ready\\n'; exec /bin/sleep 30"]
            processes.append(process)
            return process
        }
        defer {
            model.stop()
            for process in processes where process.isRunning { process.terminate() }
        }

        #expect(model.activate(session: session, container: container))
        try #require(await eventually { model.logs.contains { $0.text == "ready" } })
        let original = try #require(processes.first)
        #expect(original.isRunning)

        model.suspend()
        try #require(await eventually { !original.isRunning })
        #expect(!model.activate(session: session, container: container))
        #expect(processes.count == 2)
        try #require(await eventually { model.logs.contains { $0.text == "ready" } })
        #expect(processes.last?.isRunning == true)

        _ = model.activate(session: session, container: container, streamLogs: false)
        try #require(await eventually { processes.last?.isRunning == false })
    }

    @Test func inspectOnlyViewsNeverStartALogProcess() {
        let session = localSession()
        let container = DockerContainer(
            id: "inspect", names: ["inspect"], image: "fixture", command: "",
            state: .running, status: "Up")
        var starts = 0
        let model = DockerDetailModel { _, _ in
            starts += 1
            return nil
        }

        #expect(model.activate(session: session, container: container, streamLogs: false))
        #expect(starts == 0)
        #expect(!model.activate(session: session, container: container, streamLogs: false))
        #expect(starts == 0)
        model.stop()
    }

    private func localSession() -> MachineSession {
        MachineSession(
            machine: Machine(name: "local", host: "localhost"), local: true,
            observesWakeRequests: false)
    }

    private func eventually(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<100 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }
}

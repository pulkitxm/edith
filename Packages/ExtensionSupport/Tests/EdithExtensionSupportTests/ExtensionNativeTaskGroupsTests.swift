import Darwin
import Foundation
import Testing
@testable import EdithExtensionSupport

@Suite(.serialized) @MainActor struct ExtensionNativeTaskGroupsTests {
    @Test func trackingBoundRejectsExcessGroupsAndTerminationKillsAcceptedGroups() throws {
        let groups = ExtensionNativeTaskGroups(maximumTrackedGroups: 2)
        let children = try (0..<3).map { _ in try child() }
        defer { cleanup(children) }
        for process in children { register(process.processIdentifier) }
        children[2].waitUntilExit()
        #expect(children[2].terminationReason == .uncaughtSignal)
        #expect(children[0].isRunning && children[1].isRunning)
        groups.terminate()
        children[0].waitUntilExit()
        children[1].waitUntilExit()
        #expect(children.allSatisfy { !$0.isRunning && kill(-$0.processIdentifier, 0) == -1 })
    }

    @Test func deadGroupsArePrunedAndLateRegistrationIsTerminated() throws {
        let groups = ExtensionNativeTaskGroups(maximumTrackedGroups: 1)
        let first = try child()
        defer { cleanup([first]) }
        register(first.processIdentifier)
        kill(-first.processIdentifier, SIGKILL)
        first.waitUntilExit()
        let replacement = try child()
        defer { cleanup([replacement]) }
        register(replacement.processIdentifier)
        #expect(replacement.isRunning)
        groups.terminate()
        replacement.waitUntilExit()
        let late = try child()
        defer { cleanup([late]) }
        register(late.processIdentifier)
        late.waitUntilExit()
        #expect(late.terminationReason == .uncaughtSignal)
        register(getpid())
        register(getppid())
        #expect(kill(getpid(), 0) == 0)
    }

    private func register(_ pid: Int32) {
        NotificationCenter.default.post(
            name: ExtensionNativeTaskGroups.registered, object: nil, userInfo: ["pid": pid])
    }

    private func child() throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", "import os,time; os.setpgid(0,0); time.sleep(10)"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        let deadline = Date().addingTimeInterval(3)
        while getpgid(process.processIdentifier) != process.processIdentifier {
            guard Date() < deadline else {
                cleanup([process])
                throw ExtensionPeerError.unavailable
            }
            usleep(10_000)
        }
        return process
    }

    private func cleanup(_ processes: [Process]) {
        for process in processes {
            if process.isRunning { kill(-process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
        }
    }
}

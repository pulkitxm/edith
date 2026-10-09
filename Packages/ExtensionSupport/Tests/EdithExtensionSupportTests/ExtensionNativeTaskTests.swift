import Darwin
import Foundation
import Testing
@testable import EdithExtensionSupport

@Suite struct ExtensionNativeTaskTests {
    @Test func registrationRejectsUnrelatedInvalidAndCurrentProcesses() {
        for pid: Int32 in [0, 1, -1, getpid(), getppid(), Int32.max] {
            #expect(throws: ExtensionPeerError.self) {
                try ExtensionNativeTask.registerDescendant(pid)
            }
        }
        #expect(!ExtensionNativeTask.isDescendant(getpid(), of: getpid()))
        #expect(ExtensionNativeTask.isDescendant(getpid(), of: getppid()))
    }

    @Test func registrationAcceptsOnlyTheOwnedChildProcessGroup() throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        child.arguments = ["-c", "import os,time; os.setpgid(0,0); time.sleep(10)"]
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        try child.run()
        defer { child.terminate(); child.waitUntilExit() }
        let deadline = Date().addingTimeInterval(3)
        while getpgid(child.processIdentifier) != child.processIdentifier, Date() < deadline {
            usleep(10_000)
        }
        #expect(ExtensionNativeTask.isDescendant(child.processIdentifier, of: getpid()))
        try ExtensionNativeTask.registerDescendant(child.processIdentifier)
    }
}

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

    @Test func groupLeaderWaitCoversTheForkptySessionRace() throws {
        let argv: [UnsafeMutablePointer<CChar>?] = [strdup("/bin/sleep"), strdup("5"), nil]
        defer { argv.forEach { free($0) } }
        for _ in 0..<20 {
            var master: Int32 = -1
            let pid = forkpty(&master, nil, nil, nil)
            if pid == 0 {
                execv(argv[0]!, argv)
                _exit(127)
            }
            #expect(pid > 0)
            #expect(ExtensionNativeTask.awaitGroupLeader(pid))
            kill(pid, SIGKILL)
            waitpid(pid, nil, 0)
            close(master)
        }
    }

    @Test func groupLeaderWaitGivesUpOnAProcessThatNeverLeadsItsGroup() throws {
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/sh")
        shell.arguments = ["-c", "sleep 10 & wait"]
        try shell.run()
        defer { shell.terminate(); shell.waitUntilExit() }
        var member: Int32 = 0
        let deadline = Date().addingTimeInterval(3)
        while member == 0, Date() < deadline {
            var pids = [Int32](repeating: 0, count: 16)
            let bytes = proc_listchildpids(
                shell.processIdentifier, &pids, Int32(pids.count * MemoryLayout<Int32>.size))
            member = bytes > 0 ? pids[0] : 0
            usleep(10_000)
        }
        defer { kill(member, SIGKILL) }
        #expect(member > 1 && getpgid(member) == shell.processIdentifier)
        #expect(!ExtensionNativeTask.awaitGroupLeader(member, timeout: .milliseconds(100)))
    }
}

@Suite struct ExtensionChildEnvironmentTests {
    @Test func userProcessesNeverInheritPrivateWorkerVariables() {
        let environment = [
            "PATH": "/usr/bin", "HOME": "/Users/synthetic",
            "EDITH_EXTENSION_WORKER": "1", "EDITH_EXTENSION_NATIVE_TOKEN": "secret",
            "EDITH_SHARED_DEFAULTS_SUITE": "suite", "EDITH_APPLICATION_IDENTIFIER": "com.example",
        ]
        #expect(
            ExtensionEnvironment.childEnvironment(environment, executable: "/usr/bin/env") == [
                "PATH": "/usr/bin", "HOME": "/Users/synthetic",
                "EDITH_APPLICATION_IDENTIFIER": "com.example",
            ])
        if let host = Bundle.main.executablePath {
            #expect(ExtensionEnvironment.childEnvironment(environment, executable: host) == environment)
        }
    }
}

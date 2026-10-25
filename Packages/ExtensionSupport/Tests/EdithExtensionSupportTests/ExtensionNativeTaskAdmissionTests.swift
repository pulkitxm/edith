import Darwin
import Foundation
import Testing
@testable import EdithExtensionSupport

@MainActor @Suite(.serialized) struct ExtensionNativeTaskAdmissionTests {
    @Test func sessionTokensAreUniqueAndInvalidOrUnrelatedProcessesAreRejected() throws {
        let admission = ExtensionNativeTaskAdmission()
        #expect(admission.token != ExtensionNativeTaskAdmission().token)
        #expect(throws: ExtensionPeerError.self) {
            try admission.authorize(getpid(), token: admission.token)
        }
        #expect(throws: ExtensionPeerError.self) {
            try admission.authorize(getppid(), token: "invalid")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", "import os,time; os.setsid(); time.sleep(60)"]
        try process.run()
        defer { if process.isRunning { process.terminate() }; process.waitUntilExit() }
        let deadline = Date().addingTimeInterval(5)
        while getpgid(process.processIdentifier) != process.processIdentifier, Date() < deadline {
            usleep(10_000)
        }
        #expect(throws: ExtensionPeerError.self) {
            try admission.authorize(process.processIdentifier, token: admission.token)
        }
        try admission.registerDescendant(process.processIdentifier)
    }
}

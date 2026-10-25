@testable import MachinesExtension
import EdithExtensionSupport
import Foundation
import Testing

@Suite struct LocalMachineCommandExecutionTests {
    @Test func localCommandExecutionPreservesExecutableArguments() async throws {
        let result = await LocalMachineCommandExecution.run(
            executable: URL(fileURLWithPath: "/usr/bin/printf"),
            arguments: ["%s", "edith argument with spaces"], commandLabel: "printf")

        #expect(try result.get() == "edith argument with spaces")
    }

    @Test func localCommandExecutionKeepsEveryByteOfOutput() async throws {
        for _ in 0..<40 {
            let short = await LocalMachineCommandExecution.run(
                executable: URL(fileURLWithPath: "/usr/bin/printf"), arguments: ["%s", "done"],
                commandLabel: "printf")
            #expect(try short.get() == "done")
        }
        for _ in 0..<5 {
            let long = await LocalMachineCommandExecution.run(
                executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "head -c 300000 /dev/zero | tr '\\0' a"], commandLabel: "sh")
            #expect(try long.get().utf8.count == 300_000)
        }
    }
}

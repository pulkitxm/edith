import Darwin
import Foundation
import Testing

@testable import EdithStudio

@Suite(.serialized) struct NativeLifecycleTests {
    @Test func cancellationBeforeLaunchNeverRunsProcess() async throws {
        let space = try Workspace()
        defer { try? FileManager.default.removeItem(at: space.root) }
        let marker = space.url("launched")
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await StudioProcess.run(
                URL(fileURLWithPath: "/bin/sh"),
                ["-c", "printf started > \"$1\"", "studio-test", marker.path])
        }
        await #expect(throws: StudioError.cancelled) { try await task.value }
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test func cancellationStopsRunningProcess() async throws {
        let space = try Workspace()
        defer { try? FileManager.default.removeItem(at: space.root) }
        let marker = space.url("pid")
        let task = Task {
            try await StudioProcess.run(
                URL(fileURLWithPath: "/bin/sh"),
                [
                    "-c", "printf '%s' \"$$\" > \"$1\"; exec /bin/sleep 30", "studio-test",
                    marker.path,
                ])
        }
        for _ in 0..<200 where !FileManager.default.fileExists(atPath: marker.path) {
            try await Task.sleep(for: .milliseconds(10))
        }
        let pid = try #require(Int32(String(contentsOf: marker, encoding: .utf8)))
        task.cancel()
        await #expect(throws: StudioError.cancelled) { try await task.value }
        #expect(kill(pid, 0) == -1)
        #expect(errno == ESRCH)
    }

    @Test func zeroDeadlineCannotLeaveAProcessWaitingForever() async throws {
        let started = Date()
        await #expect(throws: StudioError.self) {
            try await StudioProcess.run(
                URL(fileURLWithPath: "/bin/sleep"), ["30"], timeout: 0)
        }
        #expect(Date().timeIntervalSince(started) < 5)
    }

    @Test func capturedOutputRespectsItsBudget() async throws {
        let result = try await StudioProcess.run(
            URL(fileURLWithPath: "/usr/bin/printf"),
            ["%s", String(repeating: "x", count: 65_536)], captureLimit: 128)
        #expect(result.status == 0)
        #expect(result.output == String(repeating: "x", count: 128))
        let negative = try await StudioProcess.run(
            URL(fileURLWithPath: "/usr/bin/printf"), ["%s", "synthetic"], captureLimit: -1)
        #expect(negative.output.isEmpty)
    }

    @Test func cancelledRunRemovesScratchAndNeverPublishesOutput() async throws {
        let space = try Workspace()
        defer { try? FileManager.default.removeItem(at: space.root) }
        let input = space.url("source.txt")
        try "synthetic source".write(to: input, atomically: true, encoding: .utf8)
        let started = space.url("started")
        let tool = StudioTool(
            id: "test.cancellable", title: "Cancellable fixture", summary: "Synthetic fixture",
            symbol: "doc", group: .edit, inputs: [.document]
        ) { run in
            let result = run.output(named: "result.txt")
            try "synthetic output".write(to: result, atomically: true, encoding: .utf8)
            try "ready".write(to: started, atomically: true, encoding: .utf8)
            try await Task.sleep(for: .seconds(30))
            return [result]
        }
        let task = Task {
            try await StudioRunner.run(
                tool: tool, inputs: [input], destination: .folder(space.output),
                environment: space.environment)
        }
        for _ in 0..<200 where !FileManager.default.fileExists(atPath: started.path) {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(FileManager.default.fileExists(atPath: started.path))
        task.cancel()
        await #expect(throws: StudioError.cancelled) { try await task.value }
        #expect(try FileManager.default.contentsOfDirectory(atPath: space.output.path).isEmpty)
        #expect(
            try FileManager.default.contentsOfDirectory(
                atPath: space.environment.temporaryRoot.path
            )
            .isEmpty)
        #expect(try String(contentsOf: input, encoding: .utf8) == "synthetic source")
    }
}

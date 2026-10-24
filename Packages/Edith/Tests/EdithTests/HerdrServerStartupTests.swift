import Foundation
import Testing

@testable import EdithKit

private actor HerdrStartupHarness {
    var requests = 0
    var sessions: [String] = []
    let responses: [HerdrCollector.CommandResult]

    init(_ responses: [HerdrCollector.CommandResult]) {
        self.responses = responses
    }

    func request() -> HerdrCollector.CommandResult {
        let result = responses[min(requests, responses.count - 1)]
        requests += 1
        return result
    }

    func start(_ session: String) {
        sessions.append(session)
    }
}

@Suite struct HerdrServerStartupTests {
    private static let stopped = HerdrCollector.CommandResult(
        status: 1, stdout: "",
        stderr: #"{"error":{"code":"server_not_running","message":"server stopped"}}"#)
    private static let ready = HerdrCollector.CommandResult(
        status: 0, stdout: #"{"result":{"workspaces":[]}}"#, stderr: "")

    @Test func startsStoppedNamedSessionAndWaitsForItsSnapshot() async {
        let harness = HerdrStartupHarness([Self.stopped, Self.stopped, Self.ready])
        let result = await HerdrCollector.recoverLocalSession(
            "example", request: { await harness.request() },
            start: { await harness.start($0) }, retryDelay: .zero)

        #expect(result.ok)
        #expect(result.stdout == Self.ready.stdout)
        #expect(await harness.sessions == ["example"])
        #expect(await harness.requests == 3)
    }

    @Test func leavesRunningServersAndUnrelatedFailuresAlone() async {
        let failures = [
            Self.ready,
            HerdrCollector.CommandResult(status: 127, stdout: "", stderr: "herdr not found"),
            HerdrCollector.CommandResult(
                status: 1, stdout: "",
                stderr: #"{"error":{"code":"permission_denied","message":"access denied"}}"#),
        ]
        for response in failures {
            let harness = HerdrStartupHarness([response])
            let result = await HerdrCollector.recoverLocalSession(
                "default", request: { await harness.request() },
                start: { await harness.start($0) }, retryDelay: .zero)

            #expect(result.status == response.status)
            #expect(result.stderr == response.stderr)
            #expect(await harness.sessions.isEmpty)
            #expect(await harness.requests == 1)
        }
    }

    @Test func boundsStartupRetriesAndPreservesTheFailure() async {
        let harness = HerdrStartupHarness([Self.stopped])
        let result = await HerdrCollector.recoverLocalSession(
            "default", request: { await harness.request() },
            start: { await harness.start($0) }, retryCount: 2, retryDelay: .zero)

        #expect(result.serverNotRunning)
        #expect(await harness.sessions == ["default"])
        #expect(await harness.requests == 3)
    }

    @Test func reportsLaunchFailures() async {
        let harness = HerdrStartupHarness([Self.stopped])
        let result = await HerdrCollector.recoverLocalSession(
            "default", request: { await harness.request() },
            start: { _ in throw HerdrCommandError.commandFailed("Could not launch Herdr") },
            retryDelay: .zero)

        #expect(!result.ok)
        #expect(result.stderr == "Could not launch Herdr")
        #expect(await harness.requests == 1)
    }

    @Test func cancellationDoesNotStartAServer() async {
        let harness = HerdrStartupHarness([Self.stopped])
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await HerdrCollector.recoverLocalSession(
                "default", request: { await harness.request() },
                start: { await harness.start($0) }, retryDelay: .zero)
        }
        _ = await task.value

        #expect(await harness.sessions.isEmpty)
    }
}

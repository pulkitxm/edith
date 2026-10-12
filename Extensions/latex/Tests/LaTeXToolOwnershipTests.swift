import Foundation
import Testing
@testable import LaTeXExtension

@Suite(.serialized) @MainActor struct LaTeXToolOwnershipTests {
    @Test func toolDiscoveryNeverInstallsAndOnlyExplicitInstallationRunsHomebrew() async throws {
        let calls = LaTeXToolCalls()
        let owner = LaTeXToolOwner { tool, arguments in
            await calls.record(tool, arguments)
            return "mock version 1.0\n"
        }
        #expect(owner.busy.isEmpty)
        #expect(await calls.values.isEmpty)
        owner.refresh()
        try await wait { owner.busy.isEmpty }
        #expect(owner.installed == ["tectonic", "latexmk", "gh", "pukbot"])
        #expect(!(await calls.values).contains { $0.tool == "brew" })
        owner.install("tectonic")
        try await wait { owner.busy.isEmpty }
        #expect(
            (await calls.values).contains {
                $0.tool == "brew" && $0.arguments == ["install", "tectonic"]
            })
        await owner.shutdown()
        let count = await calls.values.count
        owner.refresh(); owner.install("pukbot")
        #expect(await calls.values.count == count)
        #expect(owner.status.isEmpty && owner.installed.isEmpty)
    }

    @Test func stoppingCancelsInstallationAndVersionProcesses() async throws {
        let calls = LaTeXToolCalls()
        let owner = LaTeXToolOwner { tool, arguments in
            await calls.record(tool, arguments)
            do {
                try await Task.sleep(for: .seconds(30))
                return "late version"
            } catch {
                await calls.cancelled()
                throw error
            }
        }
        owner.install("tectonic")
        for _ in 0..<100 {
            if !(await calls.values).isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        await owner.shutdown()
        #expect(await calls.cancellations == 1)
        #expect(owner.busy.isEmpty && owner.installed.isEmpty && owner.status.isEmpty)
    }

    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("The owned LaTeX tool request did not finish.")
    }
}

private actor LaTeXToolCalls {
    struct Call: Sendable { let tool: String; let arguments: [String] }
    private(set) var values: [Call] = []
    private(set) var cancellations = 0
    func record(_ tool: String, _ arguments: [String]) {
        values.append(.init(tool: tool, arguments: arguments))
    }
    func cancelled() { cancellations += 1 }
}

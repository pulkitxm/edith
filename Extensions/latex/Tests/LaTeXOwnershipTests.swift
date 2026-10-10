import EdithExtensionSupport
import Foundation
import Testing
@testable import LaTeXExtension

@Suite(.serialized) @MainActor struct LaTeXOwnershipTests {
    @Test func stoppingCancelsOwnedRepositoryJobsAndRejectsLateResults() async throws {
        let probe = LaTeXOwnershipProbe()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = LaTeXService { _, _, _, _ in
            await probe.started()
            do {
                try await Task.sleep(for: .seconds(30))
                return Data(#"{"object":{"sha":"mock"}}"#.utf8)
            } catch {
                await probe.cancelled()
                throw error
            }
        }
        let model = LaTeXModel(
            service: service, store: .init(url: root.appendingPathComponent("projects.json")))
        #expect(
            model.launch {
                do {
                    try await model.add(
                        .init(
                            name: "Mock paper", location: .github, sourcePath: "paper.tex",
                            repository: "example/mock", baseBranch: "main"))
                } catch {}
            })
        try await wait { await probe.didStart }
        await model.shutdown()
        #expect(await probe.didCancel)
        #expect(model.isStopped && model.projects.isEmpty && model.original == nil)
        #expect(!model.launch { Issue.record("A stopped LaTeX owner accepted a new job.") })
        await #expect(throws: CancellationError.self) {
            try await model.add(.init(name: "Late", location: .disk, sourcePath: "/mock.tex"))
        }
    }

    @Test func stoppingCancelsCompilerWorkAndReleasesTheDocument() async throws {
        let probe = LaTeXOwnershipProbe()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("mock.tex")
        try Data("synthetic source".utf8).write(to: file)
        let service = LaTeXService { tool, _, _, _ in
            #expect(tool == "tectonic")
            await probe.started()
            do { try await Task.sleep(for: .seconds(30)); return Data() } catch {
                await probe.cancelled(); throw error
            }
        }
        let model = LaTeXModel(
            service: service, store: .init(url: root.appendingPathComponent("projects.json")))
        try await model.add(.init(name: "Mock paper", location: .disk, sourcePath: file.path))
        model.saveAndCompile()
        try await wait { await probe.didStart }
        await model.shutdown()
        #expect(await probe.didCancel)
        #expect(!model.busy && !model.buildingPDF && model.source.isEmpty)
        #expect(model.editorControls.webView == nil && !model.editorControls.ready)
        #expect(try String(contentsOf: file, encoding: .utf8) == "synthetic source")
    }

    @Test func theOwnerBoundsQueuedUIJobsAndDrainsThemOnDisable() async {
        let model = LaTeXModel()
        let accepted = (0..<40).filter { _ in
            model.launch { try? await Task.sleep(for: .seconds(30)) }
        }
        #expect(accepted.count == 16)
        await model.shutdown()
        #expect(!model.launch {})
    }

    private func wait(_ condition: () async -> Bool) async throws {
        for _ in 0..<100 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("The owned LaTeX operation did not start.")
    }
}

private actor LaTeXOwnershipProbe {
    private(set) var didStart = false
    private(set) var didCancel = false
    func started() { didStart = true }
    func cancelled() { didCancel = true }
}

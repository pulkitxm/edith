import EdithExtensionSupport
import Foundation
import Testing
@testable import LaTeXExtension

@Suite(.serialized) @MainActor struct LaTeXSurfaceTests {
    @Test func rowsComeFromTheStoredLibraryWithASingleOpenAction() async throws {
        let fixture = try LaTeXSurfaceFixture()
        defer { fixture.cleanup() }
        let calls = LaTeXSurfaceCalls()
        let model = fixture.model(
            service: .init { tool, _, _, _ in
                await calls.record(tool); return Data()
            })
        let surface = LaTeXSurface(model: model, privacyValues: { [:] })
        var tile = SurfaceTile(.ability("latex"))
        tile.sourceIDs = [fixture.projects[1].id.uuidString]
        let request = SurfaceSnapshotRequest(target: .notch, tile: tile)
        let snapshot = try SurfaceSnapshot.decode(
            try await surface.execute(
                "surface.snapshot", payload: request.encoded(providerID: "latex")),
            providerID: "latex")
        #expect(snapshot.rows.map(\.id) == [fixture.projects[1].id.uuidString])
        #expect(snapshot.sources.count == 2)
        #expect(snapshot.rows[0].detail == "example/mock" && snapshot.rows[0].value == "PR #10")
        #expect(snapshot.rows[0].icon == "doc.richtext")
        #expect(snapshot.rows[0].actions.map(\.title) == ["Open document"])
        #expect(snapshot.message == nil)
        #expect(model.selectedID == nil)
        for invalid in ["build/" + fixture.projects[0].id.uuidString, "invalid-synthetic-action"] {
            await #expect(throws: ExtensionPeerError.self) {
                try await surface.execute(
                    "surface.perform",
                    payload: SurfaceActionRequest(snapshot: request, actionID: invalid).encoded(
                        providerID: "latex"))
            }
        }
        _ = try await surface.execute(
            "surface.perform",
            payload: SurfaceActionRequest(
                snapshot: request, actionID: "open/" + fixture.projects[1].id.uuidString
            ).encoded(providerID: "latex"))
        #expect(model.selectedID == nil && !model.busy)
        #expect(await calls.tools.isEmpty)
        await model.shutdown()
    }

    @Test func presenterMasksTheLibraryBeforeAnyStorageOrToolWork() async throws {
        let fixture = try LaTeXSurfaceFixture()
        defer { fixture.cleanup() }
        try Data("invalid synthetic library".utf8).write(to: fixture.store.url)
        let calls = LaTeXSurfaceCalls()
        let model = fixture.model(
            service: .init { tool, _, _, _ in
                await calls.record(tool); return Data()
            })
        let surface = LaTeXSurface(model: model, privacyValues: { ["active": "1"] })
        let request = SurfaceSnapshotRequest(target: .home, tile: SurfaceTile(.ability("latex")))
        let snapshot = try SurfaceSnapshot.decode(
            try await surface.execute(
                "surface.snapshot", payload: request.encoded(providerID: "latex")),
            providerID: "latex")
        #expect(snapshot.rows.isEmpty && snapshot.metrics.isEmpty && snapshot.sources.isEmpty)
        #expect(!model.load.hasContent && model.load.errorMessage == nil)
        #expect(await calls.tools.isEmpty)
        await model.shutdown()
    }
}

private struct LaTeXSurfaceFixture {
    let root: URL
    let store: LaTeXProjectStore
    let projects: [LaTeXProject]
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("mock.tex")
        try Data("synthetic source".utf8).write(to: source)
        store = .init(url: root.appendingPathComponent("projects.json"))
        projects = [
            .init(name: "Mock local paper", location: .disk, sourcePath: source.path),
            .init(
                name: "Mock repository paper", location: .github, sourcePath: "papers/mock.tex",
                repository: "example/mock", baseBranch: "main", pullRequest: 10),
        ]
        try store.save(projects)
    }
    @MainActor func model(service: LaTeXService) -> LaTeXModel {
        .init(service: service, store: store)
    }
    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

private actor LaTeXSurfaceCalls {
    private(set) var tools: [String] = []
    func record(_ tool: String) { tools.append(tool) }
}

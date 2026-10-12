import EdithExtensionSupport
import Foundation
import Testing
@testable import LaTeXExtension

@Suite(.serialized) @MainActor struct LaTeXSurfaceTests {
    @Test func projectSourcesFieldsLimitsAndActionsUseCurrentLibraryData() async throws {
        let fixture = try LaTeXSurfaceFixture()
        defer { fixture.cleanup() }
        let calls = LaTeXSurfaceCalls()
        let model = fixture.model(
            service: .init { tool, _, _, _ in
                await calls.record(tool); return Data()
            })
        let surface = LaTeXSurface(model: model, privacyValues: { [:] })
        var tile = SurfaceTile(.ability("latex"));
        tile.sourceIDs = [fixture.projects[0].id.uuidString]
        tile.itemLimit = 1; tile.hiddenFields = ["compiler", "reviews"]
        let request = SurfaceSnapshotRequest(target: .notch, tile: tile)
        let snapshot = try SurfaceSnapshot.decode(
            try await surface.execute(
                "surface.snapshot", payload: request.encoded(providerID: "latex")),
            providerID: "latex")
        #expect(snapshot.rows.map(\.id) == [fixture.projects[0].id.uuidString])
        #expect(snapshot.sources.count == 2 && snapshot.metrics.map(\.id) == ["projects"])
        #expect(snapshot.rows[0].detail == "mock.tex")
        #expect(snapshot.rows[0].actions.count == 2)
        #expect(await calls.tools.isEmpty)
        for invalid in ["build/" + fixture.projects[1].id.uuidString, "invalid-synthetic-action"] {
            await #expect(throws: ExtensionPeerError.self) {
                try await surface.execute(
                    "surface.perform",
                    payload: SurfaceActionRequest(snapshot: request, actionID: invalid).encoded(
                        providerID: "latex"))
            }
        }
        tile.hiddenFields = ["build"]
        await #expect(throws: ExtensionPeerError.self) {
            try await surface.execute(
                "surface.perform",
                payload: SurfaceActionRequest(
                    snapshot: .init(target: .home, tile: tile),
                    actionID: "build/" + fixture.projects[0].id.uuidString
                ).encoded(providerID: "latex"))
        }
        #expect(await calls.tools.isEmpty)
        await model.shutdown()
    }

    @Test func compilationUsesTheSelectedProjectAndTheOwnedCompiler() async throws {
        let fixture = try LaTeXSurfaceFixture()
        defer { fixture.cleanup() }
        try Data("%PDF-1.7\nsynthetic\n%%EOF".utf8).write(to: fixture.projects[0].pdfURL)
        let calls = LaTeXSurfaceCalls()
        let model = fixture.model(
            service: .init { tool, _, _, _ in
                await calls.record(tool); return Data("synthetic compiler output".utf8)
            })
        let surface = LaTeXSurface(model: model, privacyValues: { [:] })
        let request = SurfaceSnapshotRequest(target: .home, tile: SurfaceTile(.ability("latex")))
        _ = try await surface.execute(
            "surface.perform",
            payload: SurfaceActionRequest(
                snapshot: request,
                actionID: "build/" + fixture.projects[0].id.uuidString
            ).encoded(providerID: "latex"))
        for _ in 0..<100 {
            let tools = await calls.tools
            if !model.busy && !tools.isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await calls.tools == ["tectonic"])
        #expect(
            model.selectedID == fixture.projects[0].id && model.message == "PDF compiled on disk.")
        await model.shutdown()
        await #expect(throws: ExtensionPeerError.self) {
            try await surface.execute(
                "surface.snapshot", payload: request.encoded(providerID: "latex"))
        }
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

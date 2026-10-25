import EdithExtensionSupport
import EdithStudio
import Foundation
import Testing
@testable import StudioExtension

@MainActor
@Suite(.serialized)
struct StudioSurfaceTests {
    @Test func filtersSourcesAndFieldsAndKeepsPathsOpaque() throws {
        let model = StudioModel(defaults: StudioTestFiles.defaults(), loadsState: false)
        let files = [
            StudioMediaItem(url: URL(fileURLWithPath: "/synthetic/private/portrait.png")),
            StudioMediaItem(url: URL(fileURLWithPath: "/synthetic/private/report.pdf")),
        ]
        var tile = SurfaceTile(.ability("studio"))
        tile.sourceIDs = ["image"]
        tile.contentKinds = ["files"]
        tile.hiddenFields = ["metadata", "updated"]
        let snapshot = SurfaceCommandService.project(
            StudioSurface.snapshot(model, files: files, projects: [], tile: tile), tile: tile)
        #expect(snapshot.metrics.first?.value == "1")
        #expect(snapshot.rows.count == 1)
        #expect(snapshot.rows.first?.title == "portrait.png")
        #expect(snapshot.rows.first?.detail == "")
        #expect(snapshot.updatedAt == nil)
        let encoded = try snapshot.encoded()
        #expect(!String(decoding: encoded, as: UTF8.self).contains("/synthetic/private"))
        #expect(snapshot.rows.first?.actions.first?.id.hasPrefix("open:") == true)
        #expect(snapshot.rows.first?.actions.first?.id.count == 69)
        #expect(StudioSurface.identifier(files[0].url) != StudioSurface.identifier(files[1].url))
    }

    @Test func sharedAdmissionEnforcesPrivacyAndStaleActions() async throws {
        let model = StudioModel(defaults: StudioTestFiles.defaults(), loadsState: false)
        let tile = SurfaceTile(.ability("studio"))
        let snapshot = SurfaceSnapshotRequest(target: .home, tile: tile)
        var privacy = ["active": "1", "blurStudio": "1"]
        var executed = false
        var inspected = false
        let hidden = try await SurfaceCommandService.execute(
            providerID: "studio", command: "surface.snapshot",
            payload: snapshot.encoded(providerID: "studio"),
            snapshot: { tile in
                inspected = true
                return StudioSurface.snapshot(model, files: [], projects: [], tile: tile)
            },
            perform: { _ in executed = true }, privacyValues: { privacy })
        #expect(!inspected)
        #expect(
            try SurfaceSnapshot.decode(hidden, providerID: "studio").message
                == "Hidden while presenting.")
        let action = SurfaceActionRequest(snapshot: snapshot, actionID: "open:stale")
        await #expect(throws: ExtensionPeerError.self) {
            _ = try await SurfaceCommandService.execute(
                providerID: "studio", command: "surface.perform",
                payload: action.encoded(providerID: "studio"),
                snapshot: { StudioSurface.snapshot(model, files: [], projects: [], tile: $0) },
                perform: { _ in executed = true }, privacyValues: { privacy })
        }
        privacy = [:]
        await #expect(throws: ExtensionPeerError.self) {
            _ = try await SurfaceCommandService.execute(
                providerID: "studio", command: "surface.perform",
                payload: action.encoded(providerID: "studio"),
                snapshot: { StudioSurface.snapshot(model, files: [], projects: [], tile: $0) },
                perform: { _ in executed = true }, privacyValues: { privacy })
        }
        #expect(!executed)
    }

    @Test func canceledSnapshotDoesNotPublishAndShutdownCancelsJobs() async throws {
        let model = StudioModel(defaults: StudioTestFiles.defaults(), loadsState: false)
        let request = SurfaceSnapshotRequest(target: .home, tile: SurfaceTile(.ability("studio")))
        let task = Task {
            try await SurfaceCommandService.execute(
                providerID: "studio", command: "surface.snapshot",
                payload: request.encoded(providerID: "studio"),
                snapshot: { _ in
                    try await Task.sleep(for: .seconds(30))
                    return .init(providerID: "studio")
                }, perform: { _ in })
        }
        await Task.yield()
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        let tool = try #require(StudioCatalog.tool("image.edit"))
        let job = StudioJob(tool: tool, inputs: [])
        job.phase = .running
        model.jobs = [job]
        StudioRunRegistry.track(job)
        model.shutdown()
        #expect(!job.isRunning)
        #expect(!StudioRunRegistry.contains(job))
    }

    @Test func largeLibrariesStayWithinSurfaceBounds() throws {
        let model = StudioModel(defaults: StudioTestFiles.defaults(), loadsState: false)
        let files = (0..<500).map {
            StudioMediaItem(url: URL(fileURLWithPath: "/synthetic/file-\($0).png"))
        }
        var tile = SurfaceTile(.ability("studio"))
        tile.contentKinds = ["files"]
        tile.itemLimit = 3
        let snapshot = SurfaceCommandService.project(
            StudioSurface.snapshot(model, files: files, projects: [], tile: tile), tile: tile)
        #expect(snapshot.rows.count == 3)
        #expect(snapshot.metrics.first?.value == "500")
        #expect(try snapshot.encoded().count < 8 * 1_024)
    }
    @Test func filenamesWithLargeGraphemesStayInsideTheWireTextLimit() throws {
        let model = StudioModel(defaults: StudioTestFiles.defaults(), loadsState: false)
        let name = "e" + String(repeating: "\u{301}", count: 900) + ".png"
        let item = StudioMediaItem(url: URL(fileURLWithPath: "/synthetic/" + name))
        var tile = SurfaceTile(.ability("studio"))
        tile.contentKinds = ["files"]
        let snapshot = StudioSurface.snapshot(model, files: [item], projects: [], tile: tile)
        #expect(snapshot.rows.first?.title.utf8.count ?? 0 <= 1_024)
        #expect(try snapshot.encoded().count < 8 * 1_024)
    }

    @Test func stoppedModelRejectsRestartAndLateMutations() async throws {
        let defaults = StudioTestFiles.defaults()
        let model = StudioModel(defaults: defaults, loadsState: false)
        let tool = try #require(StudioCatalog.tool("image.edit"))
        let job = StudioJob(tool: tool, inputs: [])
        model.shutdown()
        model.shutdown()
        model.start()
        model.observeLibrary()
        model.watchLibrary(paths: [FileManager.default.temporaryDirectory])
        model.loadRecent()
        model.loadWorkflows()
        model.refreshProjects()
        model.refreshEngines()
        model.add([URL(fileURLWithPath: "/synthetic/after-stop.png")])
        model.openRunner(tool, with: [])
        model.run(job)
        model.install(.ffmpeg)
        model.recordSaved(
            toolID: tool.id, title: "Stopped",
            outputs: [URL(fileURLWithPath: "/synthetic/output.png")])
        try await Task.sleep(for: .milliseconds(200))
        #expect(model.isStopped)
        #expect(model.files.isEmpty)
        #expect(model.jobs.isEmpty)
        #expect(model.recent.isEmpty)
        #expect(model.workflows.isEmpty)
        #expect(model.videoProjects.isEmpty)
        #expect(model.installing == nil)
        #expect(!job.isRunning)
        #expect(!StudioRunRegistry.contains(job))
    }

}

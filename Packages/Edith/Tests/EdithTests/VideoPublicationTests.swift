import CryptoKit
import Foundation
import Testing
@testable import Edith

@Suite struct VideoPublicationTests {
    struct Fixture {
        let directory: URL
        let projects: [URL]
        let input: URL
        let manifest: URL

        init() throws {
            let directory = try VideoEditorServiceTests.folder()
            self.directory = directory
            projects = ["approved", "new"].map {
                directory.appendingPathComponent("\($0).openscreen")
            }
            input = directory.appendingPathComponent("plan.json")
            manifest = directory.appendingPathComponent("publications.json")
            for (index, project) in projects.enumerated() {
                _ = try VideoEditorService.create(at: project, title: "Synthetic cut \(index)")
            }
            try JSONEncoder().encode(
                VideoPublicationPlan(
                    projects: projects.map {
                        .init(
                            path: $0.lastPathComponent,
                            title: "Upload \($0.deletingPathExtension().lastPathComponent)")
                    })
            ).write(to: input)
        }

        func order(_ ids: [String]) throws -> URL {
            let url = directory.appendingPathComponent("order.json")
            try JSONEncoder().encode(VideoPublicationOrder(projectIDs: ids)).write(to: url)
            return url
        }

        func cleanup() { try? FileManager.default.removeItem(at: directory) }
    }

    @Test func movesApprovedCutSecondWithoutChangingAnyProjectBytes() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let source = try await VideoEditorServiceTests.movie(in: fixture.directory)
        _ = try await VideoEditorService.apply(
            VideoEditPlan(operations: [
                .addMedia(path: source.path, name: "approved"),
                .trim(clipID: "approved", start: 0.1, end: 0.8),
                .speed(clipID: "approved", rate: 2),
            ]),
            to: fixture.projects[0], overwrite: true)
        let hashes = try fixture.projects.map { SHA256.hash(data: try Data(contentsOf: $0)) }
        let preview = try await VideoPublicationService.create(
            at: fixture.manifest, input: fixture.input, dryRun: true)
        #expect(!preview.written)
        #expect(!FileManager.default.fileExists(atPath: fixture.manifest.path))
        let created = try await VideoPublicationService.create(
            at: fixture.manifest, input: fixture.input)
        let before = try Data(contentsOf: fixture.manifest)
        let ids = created.manifest.items.map(\.projectID).reversed().map { $0 }
        let order = try fixture.order(ids)
        let dryRun = try await VideoPublicationService.reorder(
            fixture.manifest, input: order, dryRun: true, overwrite: true)
        #expect(!dryRun.written)
        #expect(try Data(contentsOf: fixture.manifest) == before)
        let reordered = try await VideoPublicationService.reorder(
            fixture.manifest, input: order, overwrite: true)
        #expect(reordered.manifest.items.map(\.projectID) == ids)
        #expect(reordered.manifest.items[1].title == "Upload approved")
        #expect(try VideoPublicationService.show(fixture.manifest).items.map(\.projectID) == ids)
        #expect(try fixture.projects.map { SHA256.hash(data: try Data(contentsOf: $0)) } == hashes)
    }

    @Test func rejectsDuplicateProjectsIDsStaleIdentityAndMissingFiles() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        for paths in [
            [fixture.projects[0], fixture.projects[0]],
            [fixture.projects[0], fixture.directory.appendingPathComponent("missing")],
        ] {
            try JSONEncoder().encode(
                VideoPublicationPlan(projects: paths.map { .init(path: $0.path) })
            ).write(to: fixture.input)
            await #expect(throws: (any Error).self) {
                try await VideoPublicationService.create(at: fixture.manifest, input: fixture.input)
            }
        }
        try FileManager.default.removeItem(at: fixture.projects[1])
        try FileManager.default.copyItem(at: fixture.projects[0], to: fixture.projects[1])
        try JSONEncoder().encode(
            VideoPublicationPlan(projects: fixture.projects.map { .init(path: $0.path) })
        ).write(to: fixture.input)
        do {
            _ = try await VideoPublicationService.create(at: fixture.manifest, input: fixture.input)
            Issue.record("Duplicate project IDs were accepted")
        } catch let error as VideoEditorService.Failure {
            #expect(error.code == "invalid_publication_duplicate")
        }
        _ = try VideoEditorService.create(
            at: fixture.projects[1], title: "Different", overwrite: true)
        let created = try await VideoPublicationService.create(
            at: fixture.manifest, input: fixture.input)
        let before = try Data(contentsOf: fixture.manifest)
        let duplicate = try fixture.order([
            created.manifest.items[0].projectID, created.manifest.items[0].projectID,
        ])
        await #expect(throws: (any Error).self) {
            try await VideoPublicationService.reorder(
                fixture.manifest, input: duplicate, overwrite: true)
        }
        _ = try VideoEditorService.create(
            at: fixture.projects[0], title: "Replacement", overwrite: true)
        do {
            _ = try VideoPublicationService.show(fixture.manifest)
            Issue.record("A stale project ID was accepted")
        } catch let error as VideoEditorService.Failure {
            #expect(error.code == "invalid_publication_identity")
        }
        #expect(try Data(contentsOf: fixture.manifest) == before)
    }

    @Test func rejectsDependencyProjectAndPlanAliases() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let source = try await VideoEditorServiceTests.movie(in: fixture.directory)
        _ = try await VideoEditorService.apply(
            VideoEditPlan(operations: [.addMedia(path: source.path, name: "cut")]),
            to: fixture.projects[0], overwrite: true)
        let sidecar = URL(fileURLWithPath: source.path + ".cursor.json")
        try Data("[]".utf8).write(to: sidecar)
        let session = URL(fileURLWithPath: source.path + ".session.json")
        try Data(#"{"microphone":true,"webcam":false}"#.utf8).write(to: session)
        for (index, protected) in [fixture.projects[0], source, sidecar, session, fixture.input]
            .enumerated()
        {
            let before = try Data(contentsOf: protected)
            await #expect(throws: (any Error).self) {
                try await VideoPublicationService.create(
                    at: protected, input: fixture.input, overwrite: true)
            }
            #expect(try Data(contentsOf: protected) == before)
            for symbolic in [false, true] {
                let alias = fixture.directory.appendingPathComponent(
                    "alias-\(index)-\(symbolic).json")
                if symbolic {
                    try FileManager.default.createSymbolicLink(
                        at: alias, withDestinationURL: protected)
                } else {
                    try FileManager.default.linkItem(at: protected, to: alias)
                }
                await #expect(throws: (any Error).self) {
                    try await VideoPublicationService.create(
                        at: alias, input: fixture.input, overwrite: true)
                }
                #expect(try Data(contentsOf: protected) == before)
                #expect(try Data(contentsOf: alias) == before)
            }
        }
        try FileManager.default.removeItem(at: source)
        await #expect(throws: (any Error).self) {
            try await VideoPublicationService.create(at: fixture.manifest, input: fixture.input)
        }
    }

    @Test func rejectsUnknownFieldsBoundsAndCancellationAndRequiresOverwrite() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let valid = try Data(contentsOf: fixture.input)
        for invalid in [
            #"{"version":true,"projects":[{"path":"approved.openscreen"}]}"#,
            #"{"version":1.5,"projects":[{"path":"approved.openscreen"}]}"#,
            #"{"version":9999999999999999999999999,"projects":[]}"#,
            #"{"version":1,"projects":[{"path":"approved.openscreen","extra":1}]}"#,
            #"{"version":1,"projects":[],"extra":1}"#,
            String(repeating: " ", count: 1024 * 1024 + 1),
        ] {
            try Data(invalid.utf8).write(to: fixture.input)
            await #expect(throws: (any Error).self) {
                try await VideoPublicationService.create(at: fixture.manifest, input: fixture.input)
            }
        }
        try valid.write(to: fixture.input)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await VideoPublicationService.create(
                at: fixture.manifest, input: fixture.input)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(!FileManager.default.fileExists(atPath: fixture.manifest.path))
        let created = try await VideoPublicationService.create(
            at: fixture.manifest, input: fixture.input)
        let before = try Data(contentsOf: fixture.manifest)
        let order = try fixture.order(created.manifest.items.map(\.projectID))
        await #expect(throws: (any Error).self) {
            try await VideoPublicationService.reorder(fixture.manifest, input: order)
        }
        #expect(try Data(contentsOf: fixture.manifest) == before)
    }
}

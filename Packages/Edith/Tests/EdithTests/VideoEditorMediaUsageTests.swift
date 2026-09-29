import Foundation
import Testing
@testable import Edith

@Suite struct VideoEditorMediaUsageTests {
    static func source(_ name: String, bytes: String, in folder: URL) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try Data(bytes.utf8).write(to: url)
        return url
    }

    static func report(_ urls: [URL], scope: String = "visual", offset: Int = 0, limit: Int = 100)
        async throws -> VideoEditorService.MediaUsage
    {
        try VideoEditorMediaServiceTests.decode(
            VideoEditorService.MediaUsage.self,
            await VideoEditorService.mediaUsage(
                projects: urls, scope: scope, offset: offset, limit: limit)
        ).result
    }

    @Test func repeatedClipsAndRenamedCopiesAreConflictsWithoutMutation() async throws {
        let folder = try VideoEditorServiceTests.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let original = try Self.source("one.mov", bytes: "one", in: folder)
        let copy = try Self.source("renamed.mov", bytes: "one", in: folder)
        var first = VideoProject.create(title: "First")
        first.addAsset(original, duration: 10, width: 64, height: 64)
        first.split(clipID: first.clips[0].id, at: 5)
        let a = folder.appendingPathComponent("a.openscreen")
        try first.save(to: a)
        var second = VideoProject.create(title: "Second")
        second.addAsset(copy, duration: 10, width: 64, height: 64)
        let b = folder.appendingPathComponent("b.openscreen")
        try second.save(to: b)
        let before = try [a, b, original, copy].map { try Data(contentsOf: $0) }
        let local = try await Self.report([a])
        #expect(
            local.occurrenceCount == 2 && local.uniqueClipCount == 2
                && local.uniqueOriginalCount == 1)
        #expect(local.conflicts[0].withinProject && !local.conflicts[0].crossProject)
        #expect(
            local.conflicts[0].wholeOriginalReuse
                && local.conflicts[0].rangeRelationship == "disjoint")
        #expect(!local.conflicts[0].overlappingExactSourceRanges)
        let report = try await Self.report([b, a])
        #expect(report.occurrenceCount == 3 && report.uniqueOriginalCount == 1)
        #expect(report.conflicts[0].crossProject && report.conflicts[0].withinProject)
        #expect(report.conflicts[0].overlappingExactSourceRanges)
        #expect(report.occurrences.map(\.sourceIn) == [0, 5, 0])
        #expect(report.occurrences.map(\.sourceOut) == [5, 10, 10])
        #expect(report.assessment == "knownReuseDetected")
        #expect(report.familyRelationshipStatus == "undeclaredReencodesNotRuledOut")
        let page = try await Self.report([a, b], offset: 1, limit: 1)
        #expect(page.occurrences[0].clipID == report.occurrences[1].clipID && page.nextOffset == 2)
        #expect(page.occurrenceCount == report.occurrenceCount && page.conflicts.isEmpty)
        #expect(try [a, b, original, copy].map { try Data(contentsOf: $0) } == before)
    }

    @Test func sharedFamiliesDetectReencodesAndDistinctOriginalsHaveNoKnownReuse() async throws {
        let folder = try VideoEditorServiceTests.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = try Self.source("same-name.mov", bytes: "first encoding", in: folder)
        let second = try Self.source("other.mov", bytes: "alternate encoding", in: folder)
        let paths = [
            folder.appendingPathComponent("a.openscreen"),
            folder.appendingPathComponent("b.openscreen"),
        ]
        for (index, source) in [first, second].enumerated() {
            var project = VideoProject.create()
            project.addAsset(source, duration: 10, width: 64, height: 64)
            try project.save(to: paths[index])
        }
        let distinct = try await Self.report(paths)
        #expect(distinct.uniqueOriginalCount == 2 && distinct.conflicts.isEmpty)
        #expect(
            distinct.assessment == "noKnownReuse"
                && distinct.familyRelationshipStatus == "undeclaredReencodesNotRuledOut")
        for path in paths {
            var project = try VideoProject.open(path)
            try project.indexMedia(provenanceByAssetID: [
                project.assets[0].id: .init(
                    sourceFamilyID: "shoot-1", declaration: "explicit alternate")
            ])
            try project.save(to: path)
        }
        let originals = try paths.map { try Data(contentsOf: $0) }
        let related = try await Self.report(paths)
        #expect(related.uniqueOriginalCount == 1 && related.uniqueByteIdentityCount == 2)
        #expect(
            related.conflicts[0].declaredFamilyRepeated && !related.conflicts[0].exactBytesRepeated)
        #expect(related.conflicts[0].rangeRelationship == "unknownAcrossExportsOrLoops")
        #expect(
            related.occurrences.allSatisfy { $0.source.provenance?.sourceFamilyID == "shoot-1" })
        #expect(try paths.map { try Data(contentsOf: $0) } == originals)
        try Data("changed bytes".utf8).write(to: first)
        await #expect(throws: (any Error).self) { try await Self.report(paths) }
    }

    @Test func visualScopeAllowsReusedMusicAndAllScopeReportsIt() async throws {
        let folder = try VideoEditorServiceTests.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let music = try Self.source("music.wav", bytes: "music", in: folder)
        var paths: [URL] = []
        for index in 0..<2 {
            let source = try Self.source("\(index).mov", bytes: "unique \(index)", in: folder)
            var project = VideoProject.create()
            project.addAsset(source, duration: 10, width: 64, height: 64)
            project.addAudio(music, duration: 10, at: 0)
            let path = folder.appendingPathComponent("\(index).openscreen")
            try project.save(to: path)
            paths.append(path)
        }
        let visual = try await Self.report(paths)
        #expect(visual.conflicts.isEmpty && visual.uniqueOriginalCount == 2)
        #expect(visual.excludedIndependentAudioCount == 2)
        let all = try await Self.report(paths, scope: "all")
        #expect(
            all.uniqueOriginalCount == 3 && all.occurrenceCount == 4 && all.uniqueClipCount == 2)
        #expect(all.occurrences.filter { $0.role == "independentAudio" }.count == 2)
        #expect(all.conflicts.count == 1 && all.conflicts[0].crossProject)
        await #expect(throws: (any Error).self) { try await Self.report(paths, scope: "invalid") }
        await #expect(throws: (any Error).self) { try await Self.report(paths, limit: 101) }
        await #expect(throws: (any Error).self) { try await Self.report([paths[0], paths[0]]) }
    }
}

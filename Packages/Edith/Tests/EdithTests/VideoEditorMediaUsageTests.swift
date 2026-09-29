import Foundation
import Testing
@testable import Edith

@Suite struct VideoEditorMediaUsageTests {
    @Test func stillCarriersReusePhotographicOriginalWithinAndAcrossProjects() async throws {
        let folder = try VideoEditorServiceTests.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let photo = try Self.source("original.jpg", bytes: "photographic original", in: folder)
        let carriers = try ["first encoding", "second encoding"].enumerated().map {
            try Self.source("carrier-\($0.offset).mov", bytes: $0.element, in: folder)
        }
        let identity = try VideoMediaLibrary.identity(of: photo)
        var paths: [URL] = []
        for selection in [[0, 1], [0], [1]] {
            var project = VideoProject.create()
            for index in selection {
                project.addAsset(
                    carriers[index], duration: 10, width: 64, height: 64, sourceImage: photo)
                project.trim(
                    clipID: project.clips.last!.id, start: Double(index * 5),
                    end: Double(index * 5 + 5))
            }
            try project.indexMedia(
                provenanceByAssetID: Dictionary(
                    uniqueKeysWithValues: project.assets.map {
                        (
                            $0.id,
                            VideoMediaLibrary.Provenance(
                                sourceFamilyID: "photo-take", declaration: "Explicit original photo"
                            )
                        )
                    }))
            let path = folder.appendingPathComponent("project-\(paths.count).openscreen")
            try project.save(to: path)
            paths.append(path)
        }
        let files = paths + carriers + [photo]
        let before = try files.map { try Data(contentsOf: $0) }
        for selection in [[paths[0]], [paths[1], paths[2]]] {
            let report = try await Self.report(selection)
            #expect(report.occurrenceCount == 2 && report.uniqueOriginalCount == 1)
            #expect(report.uniqueByteIdentityCount == 1 && report.conflictCount == 1)
            #expect(report.assessment == "knownReuseDetected")
            #expect(
                report.occurrences.allSatisfy {
                    $0.source.identity == identity && $0.sourceRole == .sourceImage
                        && !$0.sourceRangeComparable
                })
            #expect(
                report.occurrences.allSatisfy {
                    $0.source.provenance?.sourceFamilyID == "photo-take"
                })
            let conflict = report.conflicts[0]
            #expect(conflict.withinProject == (selection.count == 1))
            #expect(conflict.crossProject == (selection.count == 2))
            #expect(
                conflict.wholeOriginalReuse && conflict.exactBytesRepeated
                    && !conflict.overlappingExactSourceRanges)
            #expect(conflict.rangeRelationship == "notComparableForStillOriginals")
        }
        #expect(try files.map { try Data(contentsOf: $0) } == before)
        var specific = try VideoProject.open(paths[1])
        var manifest = try specific.mediaManifest()
        manifest.entries = manifest.entries.map { entry in
            guard entry.reference.role == .sourceImage else { return entry }
            return .init(
                reference: entry.reference,
                source: .init(
                    identity: entry.source.identity,
                    provenance: .init(
                        sourceFamilyID: "photo-specific", declaration: "Explicit photo family")))
        }
        specific.root["edithMediaLibrary"] = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(manifest))
        try specific.save(to: paths[1])
        let declared = try await Self.report([paths[1]])
        #expect(declared.occurrences[0].source.provenance?.sourceFamilyID == "photo-specific")
        try Data("changed photo".utf8).write(to: photo)
        do {
            _ = try await Self.report([paths[0]])
            Issue.record("Changed indexed photograph was accepted")
        } catch let error as VideoEditorService.Failure {
            #expect(error.code == "identity_mismatch")
        }
    }

    @Test func directImageAssetsHaveNoComparableSourceTimeRanges() async throws {
        let folder = try VideoEditorServiceTests.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let photo = try Self.source("original.jpg", bytes: "original photo", in: folder)
        var project = VideoProject.create()
        project.addAsset(photo, duration: 10, width: 64, height: 64)
        var assets = project.assets.map(\.raw)
        assets[0]["kind"] = "image"
        project.root["assets"] = assets
        project.split(clipID: project.clips[0].id, at: 5)
        try project.indexMedia()
        let path = folder.appendingPathComponent("project.openscreen")
        try project.save(to: path)
        let report = try await Self.report([path])
        #expect(report.uniqueOriginalCount == 1)
        #expect(
            report.occurrences.allSatisfy {
                $0.sourceRole == .original && !$0.sourceRangeComparable
            })
        #expect(report.conflicts[0].rangeRelationship == "notComparableForStillOriginals")
    }

    @Test func fortyFiveDifferentSourcesStayDistinctAcrossPages() async throws {
        let folder = try VideoEditorServiceTests.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        var project = VideoProject.create(title: "45 synthetic shots")
        for index in 0..<45 {
            let source = try Self.source(
                "shot-\(index).mov", bytes: "unique original \(index)", in: folder)
            project.addAsset(source, duration: 1, width: 64, height: 64)
        }
        let path = folder.appendingPathComponent("shots.openscreen")
        try project.save(to: path)
        let before = try Data(contentsOf: path)
        var offset = 0
        var clipIDs = Set<String>()
        repeat {
            let result = try await Self.report([path], offset: offset, limit: 10)
            #expect(result.uniqueClipCount == 45 && result.uniqueOriginalCount == 45)
            #expect(result.conflicts.isEmpty && result.assessment == "noKnownReuse")
            clipIDs.formUnion(result.occurrences.map(\.clipID))
            guard let next = result.nextOffset else { break }
            offset = next
        } while true
        #expect(clipIDs.count == 45)
        #expect(try Data(contentsOf: path) == before)
    }

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

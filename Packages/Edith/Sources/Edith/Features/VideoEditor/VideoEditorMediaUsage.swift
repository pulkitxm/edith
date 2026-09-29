import Foundation

extension VideoEditorService {
    struct MediaUsage: Codable, Sendable {
        struct Occurrence: Codable, Sendable {
            let index: Int
            let project: String
            let projectID: String
            let clipID: String
            let assetID: String
            let role: String
            let sourceRole: VideoMediaLibrary.Role
            let sourceRangeComparable: Bool
            let sourceIn: Double
            let sourceOut: Double?
            let source: VideoMediaLibrary.Source
            let originalGroup: Int
        }

        struct Conflict: Codable, Sendable {
            let originalGroup: Int
            let occurrenceCount: Int
            let withinProject: Bool
            let crossProject: Bool
            let exactBytesRepeated: Bool
            let declaredFamilyRepeated: Bool
            let wholeOriginalReuse: Bool
            let overlappingExactSourceRanges: Bool
            let rangeRelationship: String
            let conflictingFamilyDeclarations: Bool
        }

        let scope: String
        let projectCount: Int
        let occurrenceCount: Int
        let uniqueClipCount: Int
        let uniqueByteIdentityCount: Int
        let uniqueOriginalCount: Int
        let conflictCount: Int
        let assessment: String
        let familyRelationshipStatus: String
        let excludedIndependentAudioCount: Int
        let offset: Int
        let limit: Int
        let nextOffset: Int?
        let occurrences: [Occurrence]
        let conflicts: [Conflict]
    }

    public static func mediaUsage(
        projects urls: [URL], scope: String = "visual", offset: Int = 0, limit: Int = 100
    ) async throws -> Data {
        try await mediaErrors {
            try require((1...100).contains(urls.count), "Supply 1 to 100 projects.")
            try require(["visual", "all"].contains(scope), "Scope must be visual or all.")
            try require(
                offset >= 0 && offset <= 10000 && (1...100).contains(limit),
                "Offset must be 0 to 10000; limit must be 1 to 100.")
            let paths = urls.map { $0.standardizedFileURL.resolvingSymlinksInPath() }.sorted {
                $0.path < $1.path
            }
            try require(Set(paths).count == paths.count, "Project paths must be distinct.")
            var rows: [MediaUsage.Occurrence] = []
            var revisions: [Revision] = []
            var excludedAudio = 0
            for path in paths {
                try Task.checkCancellation()
                let snapshot = try readProject(path)
                revisions.append(snapshot.revision)
                let project = snapshot.project
                let manifest = try project.mediaManifest()
                var sources: [String: VideoMediaLibrary.Source] = [:]
                func append(
                    _ id: String, assetID: String, role: String, start: Double, end: Double?
                ) throws {
                    try require(rows.count < 10000, "Usage audit exceeds 10000 occurrences.")
                    guard let asset = project.assets.first(where: { $0.id == assetID }) else {
                        throw Failure("invalid_project", "Missing occurrence asset.")
                    }
                    let sourceRole: VideoMediaLibrary.Role =
                        asset.raw["edithSourceImagePath"] == nil ? .original : .sourceImage
                    let comparable =
                        sourceRole != .sourceImage && asset.raw["kind"] as? String != "image"
                    if sources[assetID] == nil {
                        let sourceURL = try project.mediaURL(
                            for: .init(assetID: assetID, role: sourceRole))
                        let identity = try VideoMediaLibrary.identity(of: sourceURL)
                        let indexed = manifest.entries.first {
                            $0.reference.assetID == assetID && $0.reference.role == sourceRole
                        }
                        if let indexed, indexed.source.identity != identity {
                            throw VideoMediaLibrary.Failure.identityMismatch(sourceURL.path)
                        }
                        let assetDeclaration = manifest.entries.first {
                            $0.reference.assetID == assetID && $0.reference.role == .original
                        }?.source.provenance
                        sources[assetID] = .init(
                            identity: identity,
                            provenance: indexed?.source.provenance ?? assetDeclaration)
                    }
                    rows.append(
                        .init(
                            index: rows.count, project: path.path, projectID: project.id,
                            clipID: id, assetID: assetID, role: role, sourceRole: sourceRole,
                            sourceRangeComparable: comparable, sourceIn: start,
                            sourceOut: end,
                            source: sources[assetID]!, originalGroup: 0))
                }
                for clip in project.clips.sorted(by: {
                    ($0.timelineStart, $0.id) < ($1.timelineStart, $1.id)
                }) {
                    let asset = project.assets.first { $0.id == clip.assetID }!
                    let audio = ["audio", "music"].contains(asset.raw["kind"] as? String ?? "")
                    if scope == "visual" && audio { excludedAudio += 1; continue }
                    try append(
                        clip.id, assetID: clip.assetID, role: audio ? "timelineAudio" : "visual",
                        start: clip.start, end: clip.end)
                }
                excludedAudio += scope == "visual" ? project.audioTracks.count : 0
                if scope == "all" {
                    try require(
                        Set(project.audioTracks.map(\.id)).count == project.audioTracks.count
                            && project.audioTracks.allSatisfy { !$0.id.isEmpty },
                        "Audio track IDs must be unique and nonempty.")
                    for track in project.audioTracks.sorted(by: {
                        ($0.startMs, $0.id) < ($1.startMs, $1.id)
                    }) {
                        let asset = project.assets.first { $0.id == track.assetID }!
                        let start = track.offsetMs / 1000
                        try append(
                            track.id, assetID: track.assetID, role: "independentAudio",
                            start: start,
                            end: track.loop
                                ? nil
                                : min(asset.duration, start + (track.endMs - track.startMs) / 1000))
                    }
                }
            }
            var parent = Array(rows.indices)
            func root(_ value: Int) -> Int {
                var current = value
                while parent[current] != current { current = parent[current] }
                return current
            }
            var identities: [VideoMediaLibrary.Identity: Int] = [:]
            var families: [String: Int] = [:]
            for row in rows {
                if let previous = identities[row.source.identity] {
                    parent[root(row.index)] = root(previous)
                } else {
                    identities[row.source.identity] = row.index
                }
                if let family = row.source.provenance?.sourceFamilyID {
                    if let previous = families[family] {
                        parent[root(row.index)] = root(previous)
                    } else {
                        families[family] = row.index
                    }
                }
            }
            var groupIDs: [Int: Int] = [:]
            rows = rows.map { row in
                let key = root(row.index)
                if groupIDs[key] == nil { groupIDs[key] = groupIDs.count }
                return .init(
                    index: row.index, project: row.project, projectID: row.projectID,
                    clipID: row.clipID, assetID: row.assetID, role: row.role,
                    sourceRole: row.sourceRole, sourceRangeComparable: row.sourceRangeComparable,
                    sourceIn: row.sourceIn,
                    sourceOut: row.sourceOut, source: row.source, originalGroup: groupIDs[key]!)
            }
            let groups = Dictionary(grouping: rows, by: \.originalGroup)
            let conflicts: [MediaUsage.Conflict] = groups.keys.sorted().compactMap { key in
                let group = groups[key]!
                guard group.count > 1 else { return nil }
                let bytes = Dictionary(grouping: group, by: { $0.source.identity })
                let declared = group.compactMap { $0.source.provenance?.sourceFamilyID }
                var overlap = false
                for matches in bytes.values {
                    var furthest = -Double.infinity
                    for row in matches.sorted(by: { $0.sourceIn < $1.sourceIn }) {
                        if row.sourceRangeComparable, let end = row.sourceOut {
                            if row.sourceIn < furthest { overlap = true }
                            furthest = max(furthest, end)
                        }
                    }
                }
                let unknownRanges = bytes.count > 1 || group.contains { $0.sourceOut == nil }
                let stillOriginal = group.contains { !$0.sourceRangeComparable }
                let projectCounts = Dictionary(grouping: group, by: \.project)
                return .init(
                    originalGroup: key, occurrenceCount: group.count,
                    withinProject: projectCounts.values.contains { $0.count > 1 },
                    crossProject: projectCounts.count > 1,
                    exactBytesRepeated: bytes.values.contains { $0.count > 1 },
                    declaredFamilyRepeated: Set(declared).count < declared.count,
                    wholeOriginalReuse: true,
                    overlappingExactSourceRanges: overlap,
                    rangeRelationship: stillOriginal
                        ? "notComparableForStillOriginals"
                        : (unknownRanges
                            ? "unknownAcrossExportsOrLoops"
                            : (overlap ? "overlapping" : "disjoint")),
                    conflictingFamilyDeclarations: bytes.values.contains {
                        Set($0.compactMap { $0.source.provenance?.sourceFamilyID }).count > 1
                    })
            }
            for revision in revisions {
                guard try revision.fingerprint.matches(revision.url) else {
                    throw Failure("project_changed", "A project changed during the usage audit.")
                }
            }
            let next = offset + limit < max(rows.count, conflicts.count) ? offset + limit : nil
            return try mediaEnvelope(
                MediaUsage(
                    scope: scope, projectCount: paths.count,
                    occurrenceCount: rows.count,
                    uniqueClipCount: rows.filter { $0.role != "independentAudio" }.count,
                    uniqueByteIdentityCount: identities.count, uniqueOriginalCount: groups.count,
                    conflictCount: conflicts.count,
                    assessment: conflicts.isEmpty ? "noKnownReuse" : "knownReuseDetected",
                    familyRelationshipStatus: "undeclaredReencodesNotRuledOut",
                    excludedIndependentAudioCount: excludedAudio,
                    offset: offset, limit: limit, nextOffset: next,
                    occurrences: Array(rows.dropFirst(offset).prefix(limit)),
                    conflicts: Array(conflicts.dropFirst(offset).prefix(limit))), operation: "usage"
            )
        }
    }
}

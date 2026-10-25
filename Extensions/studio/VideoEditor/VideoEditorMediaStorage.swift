import Foundation

extension VideoEditorService {
    public static func mediaPackage(_ source: URL, to destination: URL) async throws -> Data {
        try await mediaErrors {
            try require(destination.isFileURL, "Package destination must be a local directory.")
            let lock = try await VideoProjectFileAccess.transaction(source)
            defer { withExtendedLifetime(lock) {} }
            let snapshot = try readProject(source)
            try protectMediaSources(snapshot.project, destination: destination)
            try VideoProjectExportDestination.validate(destination, project: snapshot.project)
            return try VideoProjectFileAccess.publication(source) {
                try verifyMediaRevision(snapshot.revision)
                var report: Data?
                _ = try snapshot.project.packageOriginalMedia(
                    to: destination,
                    validatePackage: { project, result in
                        try validateStructure(project)
                        _ = try encodedProject(project)
                        try verifyMediaRevision(snapshot.revision)
                        report = try mediaEnvelope(
                            result, operation: "package", project: result.projectURL, written: true)
                    })
                return report!
            }
        }
    }

    public static func mediaOpen(
        _ directory: URL, output: URL? = nil, dryRun: Bool = false, overwrite: Bool = false
    ) async throws -> Data {
        try await mediaMutation(
            directory.appendingPathComponent("project.openscreen"),
            output: output, dryRun: dryRun, overwrite: overwrite, operation: "open"
        ) { project in
            project = try VideoProject.openMediaPackage(directory)
            return try project.mediaManifest()
        }
    }

    public static func mediaRelink(
        _ source: URL, referenceID: String, role: String = "original", to media: URL,
        policy: String = "requireIdentity", expectedSHA256: String? = nil,
        expectedByteCount: Int64? = nil, output: URL? = nil,
        dryRun: Bool = false, overwrite: Bool = false
    ) async throws -> Data {
        try require(
            !referenceID.isEmpty && referenceID.count <= 1000,
            "Reference ID must be 1 to 1000 characters.")
        guard let role = VideoMediaLibrary.Role(rawValue: role),
            let policy = VideoMediaLibrary.RelinkPolicy(rawValue: policy)
        else { throw Failure("invalid_media", "Unknown media role or relink policy.") }
        try require(
            (expectedSHA256 == nil) == (expectedByteCount == nil),
            "Expected SHA-256 and byte count must be supplied together.")
        let expected = expectedSHA256.map {
            VideoMediaLibrary.Identity(sha256: $0, byteCount: expectedByteCount!)
        }
        return try await mediaMutation(
            source, output: output, dryRun: dryRun, overwrite: overwrite, operation: "relink"
        ) { project in
            try requireLocalFile(media)
            return try project.relinkOriginalMedia(
                .init(assetID: referenceID, role: role), to: media,
                policy: policy, expectedIdentity: expected)
        }
    }

    static func verifyMediaRevision(_ revision: Revision) throws {
        guard try revision.fingerprint.matches(revision.url) else {
            throw Failure(
                "project_changed", "The source project changed during the media operation.")
        }
    }
}

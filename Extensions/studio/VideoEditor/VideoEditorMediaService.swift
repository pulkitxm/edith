import Foundation

extension VideoEditorService {
    struct MediaEnvelope<Value: Codable & Sendable>: Codable, Sendable {
        let version: Int
        let operation: String
        let project: String?
        let written: Bool
        let result: Value
    }

    struct MediaIdentityResult: Codable, Sendable {
        let url: URL
        let identity: VideoMediaLibrary.Identity
    }

    static func mediaEnvelope<T: Codable & Sendable>(
        _ value: T, operation: String, project: URL? = nil, written: Bool = false
    ) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(
            MediaEnvelope(
                version: 1, operation: operation, project: project?.path, written: written,
                result: value))
        try require(data.count < 4 * 1024 * 1024, "Media result exceeds 4 MiB; use fewer inputs.")
        return data
    }

    static func mediaErrors<T>(_ body: () async throws -> T) async throws -> T {
        do { return try await body() } catch let error as VideoMediaLibrary.Failure {
            let code: String
            switch error {
            case .invalidIdentity, .invalidProvenance, .invalidReference, .notRegularFile:
                code = "invalid_media"
            case .changedDuringRead: code = "media_changed"
            case .identityMismatch: code = "identity_mismatch"
            case .unsupportedMedia: code = "unsupported_media"
            case .reservationConflict: code = "source_reserved"
            case .provenanceConflict: code = "provenance_conflict"
            case .invalidReceipt: code = "invalid_receipt"
            case .invalidLedger: code = "invalid_ledger"
            case .destinationExists: code = "output_exists"
            }
            throw Failure(code, error.localizedDescription)
        } catch is CancellationError { throw Failure("cancelled", "Media operation cancelled.") }
    }

    static func requireMediaPaths(_ urls: [URL], minimum: Int = 1) throws {
        try require((minimum...1000).contains(urls.count), "Supply \(minimum) to 1000 media files.")
        for url in urls { try requireLocalFile(url) }
    }

    static func protectMediaSources(_ project: VideoProject, destination: URL) throws {
        try protectSources(project, destination: destination)
        let target = VideoProjectFileAccess.identity(destination)
        let token =
            try? destination.resourceValues(forKeys: [.fileResourceIdentifierKey])
            .fileResourceIdentifier as? NSObject
        for reference in try project.mediaReferences() {
            let url = try project.mediaURL(for: reference)
            let sourceToken =
                try? url.resourceValues(forKeys: [.fileResourceIdentifierKey])
                .fileResourceIdentifier as? NSObject
            try require(
                VideoProjectFileAccess.identity(url) != target
                    && !(token != nil && token?.isEqual(sourceToken) == true),
                "Output must not replace any media dependency.")
        }
    }

    public static func mediaIdentity(_ url: URL) async throws -> Data {
        try await mediaErrors {
            try requireMediaPaths([url])
            return try mediaEnvelope(
                MediaIdentityResult(url: url, identity: VideoMediaLibrary.identity(of: url)),
                operation: "identity")
        }
    }

    public static func mediaProbe(_ url: URL) async throws -> Data {
        try await mediaErrors {
            try requireMediaPaths([url])
            return try await mediaEnvelope(VideoMediaLibrary.inspect(url), operation: "probe")
        }
    }

    public static func mediaDuplicates(_ urls: [URL]) async throws -> Data {
        try await mediaErrors {
            try requireMediaPaths(urls, minimum: 2)
            return try mediaEnvelope(
                VideoMediaLibrary.duplicates(in: urls), operation: "duplicates")
        }
    }

    public static func mediaChronology(_ urls: [URL]) async throws -> Data {
        try await mediaErrors {
            try requireMediaPaths(urls)
            var inspected: [VideoMediaLibrary.InspectedMedia] = []
            for url in urls { inspected.append(try await VideoMediaLibrary.inspect(url)) }
            return try mediaEnvelope(
                VideoMediaLibrary.chronologicalOrder(inspected), operation: "chronology")
        }
    }

    public static func mediaIndex(
        _ source: URL, probe: Bool = false, output: URL? = nil,
        dryRun: Bool = false, overwrite: Bool = false
    ) async throws -> Data {
        try await mediaMutation(
            source, output: output, dryRun: dryRun, overwrite: overwrite, operation: "index"
        ) { project in
            if probe { return try await project.inspectMedia() }
            return try project.indexMedia()
        }
    }

    public static func mediaProvenance(
        _ source: URL, assetID: String, familyID: String, declaration: String,
        output: URL? = nil, dryRun: Bool = false, overwrite: Bool = false
    ) async throws -> Data {
        try require(
            !assetID.isEmpty && assetID.count <= 1000 && !familyID.isEmpty && familyID.count <= 1000
                && !declaration.isEmpty && declaration.count <= 4000,
            "Asset, family and declaration must be nonempty and within their limits.")
        return try await mediaMutation(
            source, output: output, dryRun: dryRun, overwrite: overwrite, operation: "provenance"
        ) { project in
            try project.indexMedia(provenanceByAssetID: [
                assetID: .init(sourceFamilyID: familyID, declaration: declaration)
            ])
        }
    }

    static func mediaMutation<T: Codable & Sendable>(
        _ source: URL, output: URL?, dryRun: Bool, overwrite: Bool, operation: String,
        change: (inout VideoProject) async throws -> T
    ) async throws -> Data {
        try await mediaErrors {
            let lock = dryRun ? nil : try await VideoProjectFileAccess.transaction(source)
            defer { withExtendedLifetime(lock) {} }
            let snapshot = try readProject(source)
            var project = snapshot.project
            let value = try await change(&project)
            try validateStructure(project)
            let data = try encodedProject(project)
            let destination = output ?? source
            try require(
                destination.isFileURL && destination.pathExtension == "openscreen",
                "Expected a local .openscreen output.")
            try protectMediaSources(snapshot.project, destination: destination)
            try protectMediaSources(project, destination: destination)
            if VideoProjectFileAccess.identity(destination)
                != VideoProjectFileAccess.identity(source)
            {
                try VideoProjectExportDestination.validate(destination, project: snapshot.project)
                try VideoProjectExportDestination.validate(destination, project: project)
            }
            try Task.checkCancellation()
            let report = try mediaEnvelope(
                value, operation: operation, project: destination, written: !dryRun)
            if !dryRun {
                try saveEncoded(
                    data, to: destination, overwrite: overwrite, expectedSource: snapshot.revision)
            }
            return report
        }
    }
}

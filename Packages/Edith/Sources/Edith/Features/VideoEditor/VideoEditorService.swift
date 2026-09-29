@preconcurrency import AVFoundation
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum VideoEditorService {
    public struct Failure: LocalizedError, Sendable {
        public let code: String
        public let message: String
        public var errorDescription: String? { message }

        public init(_ code: String, _ message: String) {
            self.code = code
            self.message = message
        }
    }

    public struct Result: Codable, Sendable {
        public let version: Int
        public let path: String
        public let written: Bool
        public let clipIDs: [String]
        public let aliases: [String: String]
    }

    public static func create(at url: URL, title: String, overwrite: Bool = false) throws -> Result
    {
        try requireTitle(title)
        let project = VideoProject.create(title: title)
        try save(project, to: url, overwrite: overwrite)
        return result(project, url: url, written: true)
    }

    public static func show(_ url: URL) throws -> Data {
        let project = try open(url)
        return try JSONSerialization.data(
            withJSONObject: project.root, options: [.prettyPrinted, .sortedKeys])
    }

    public static func validate(_ url: URL) async throws -> Result {
        let project = try open(url)
        try await validateMedia(project)
        if !project.clips.isEmpty { _ = try await VideoRenderPipeline.make(project: project) }
        return result(project, url: url, written: false)
    }

    public static func apply(
        _ plan: VideoEditPlan, to url: URL, output: URL? = nil,
        dryRun: Bool = false, overwrite: Bool = false, mediaDirectory: URL? = nil
    ) async throws -> Result {
        guard plan.version == 1, plan.operations.count <= 1000 else {
            throw Failure(
                "invalid_plan", "Expected edit plan version 1 with up to 1000 operations.")
        }
        var project = try open(url)
        var aliases: [String: String] = [:]
        let directory = mediaDirectory ?? url.deletingLastPathComponent()
        for (index, operation) in plan.operations.enumerated() {
            try Task.checkCancellation()
            do {
                try await apply(
                    operation, project: &project, aliases: &aliases, directory: directory)
            } catch {
                throw Failure(
                    "invalid_operation", "Operation \(index): \(error.localizedDescription)")
            }
        }
        try validateStructure(project)
        try await validateMedia(project)
        let destination = output ?? url
        try require(
            destination.isFileURL && destination.pathExtension == "openscreen",
            "Project output must be a local .openscreen file.")
        try protectSources(project, destination: destination)
        try Task.checkCancellation()
        if !dryRun {
            try save(project, to: destination, overwrite: overwrite)
        }
        return result(project, url: destination, written: !dryRun, aliases: aliases)
    }

    public static func render(
        _ url: URL, to output: URL, overwrite: Bool = false
    ) async throws -> Result {
        let project = try open(url)
        try await validateMedia(project)
        try requireOutput(output, extension: "mp4", project: project, source: url)
        try checkDestination(output, overwrite: overwrite)
        let pipeline = try await VideoRenderPipeline.make(project: project)
        let temporary = temporaryOutput(output)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try await pipeline.exportMP4(to: temporary)
        try Task.checkCancellation()
        try publish(temporary, to: output, overwrite: overwrite)
        return result(project, url: output, written: true)
    }

    public static func frame(
        _ url: URL, at seconds: Double, to output: URL, overwrite: Bool = false
    ) async throws -> Result {
        try require(seconds.isFinite && seconds >= 0, "Frame time must be finite and nonnegative.")
        let project = try open(url)
        try await validateMedia(project)
        try requireOutput(output, extension: "png", project: project, source: url)
        try checkDestination(output, overwrite: overwrite)
        let pipeline = try await VideoRenderPipeline.make(project: project)
        try require(
            seconds.isFinite && seconds >= 0 && seconds < pipeline.duration,
            "Frame time is outside the rendered timeline.")
        let generator = AVAssetImageGenerator(asset: pipeline.composition)
        generator.videoComposition = pipeline.videoComposition
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let image = try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600))
            .image
        let temporary = temporaryOutput(output)
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard
            let destination = CGImageDestinationCreateWithURL(
                temporary as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw Failure("render_failed", "Could not create PNG output.") }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw Failure("render_failed", "Could not finish PNG output.")
        }
        try Task.checkCancellation()
        try publish(temporary, to: output, overwrite: overwrite)
        return result(project, url: output, written: true)
    }

    static func require(_ condition: Bool, _ message: String) throws {
        guard condition else { throw Failure("invalid_value", message) }
    }

    static func requireTitle(_ title: String) throws {
        try require(
            !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && title.count <= 1000,
            "Title must contain 1 to 1000 characters.")
    }

    static func result(
        _ project: VideoProject, url: URL, written: Bool, aliases: [String: String] = [:]
    ) -> Result {
        Result(
            version: 1, path: url.path, written: written, clipIDs: project.clips.map(\.id),
            aliases: aliases)
    }

    static func open(_ url: URL) throws -> VideoProject {
        try requireLocalFile(url)
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        try require(size <= 32 * 1024 * 1024, "Project exceeds 32 MiB.")
        try validateValues(JSONSerialization.jsonObject(with: Data(contentsOf: url)))
        let project = try VideoProject.open(url)
        try validateStructure(project)
        return project
    }

    static func requireLocalFile(_ url: URL) throws {
        try require(url.isFileURL, "Only local files are supported.")
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isReadableKey])
        try require(
            values.isRegularFile == true && values.isReadable == true,
            "Expected a readable regular file: \(url.path)")
    }

    static func validateStructure(_ project: VideoProject) throws {
        try validateValues(project.root)
        try require(
            project.root["assets"] is [[String: Any]]
                && (project.root["timeline"] as? [String: Any])?["clips"] is [[String: Any]],
            "Project assets and timeline clips must be arrays of objects.")
        try require(!project.id.isEmpty, "Project ID must not be empty.")
        for key in ["annotations", "audioTracks", "zoomRanges", "edithTransitions"] {
            if let entries = project.root[key] {
                try require(
                    entries is [[String: Any]], "Project \(key) must be an array of objects.")
            }
        }
        let ratio = project.aspectRatio.split(separator: ":").compactMap { Double($0) }
        try require(
            project.aspectRatio == "native"
                || (ratio.count == 2
                    && ratio.allSatisfy { $0.isFinite && (0.1...100).contains($0) }),
            "Invalid canvas aspect ratio.")
        try require(
            project.padding.isFinite && (0...25).contains(project.padding),
            "Invalid canvas padding.")
        try require(
            project.assets.count <= 10000 && project.clips.count <= 10000,
            "Project exceeds 10000 assets or clips.")
        try require(
            Set(project.assets.map(\.id)).count == project.assets.count
                && !project.assets.contains { $0.id.isEmpty },
            "Asset IDs must be unique and nonempty.")
        try require(
            Set(project.clips.map(\.id)).count == project.clips.count
                && !project.clips.contains { $0.id.isEmpty },
            "Clip IDs must be unique and nonempty.")
        for asset in project.assets {
            try require(
                asset.duration.isFinite && asset.duration > 0 && asset.duration <= 604800,
                "Invalid asset duration: \(asset.id)")
            try require(
                (asset.raw["originalPath"] as? String)?.hasPrefix("/") == true,
                "Asset paths must be absolute local paths.")
        }
        for clip in project.clips {
            guard let asset = project.assets.first(where: { $0.id == clip.assetID }) else {
                throw Failure("invalid_project", "Missing asset for clip \(clip.id).")
            }
            try require(
                clip.start.isFinite && clip.end.isFinite && clip.start >= 0 && clip.end > clip.start
                    && clip.end <= asset.duration + 0.001,
                "Invalid source range for clip \(clip.id).")
            try require(
                clip.timelineStart.isFinite && clip.timelineStart >= 0 && clip.rate.isFinite
                    && (0.25...5).contains(clip.rate),
                "Invalid timeline or speed for clip \(clip.id).")
            let gain = (clip.raw["audioGainDb"] as? NSNumber)?.doubleValue ?? 0
            try require((-60...12).contains(gain), "Invalid clip audio gain.")
            if let crop = clip.crop {
                guard let x = crop["x"], let y = crop["y"], let width = crop["width"],
                    let height = crop["height"]
                else {
                    throw Failure("invalid_project", "Incomplete crop region.")
                }
                try require(
                    x >= 0 && y >= 0 && width > 0 && height > 0 && x + width <= 1.000001
                        && y + height <= 1.000001, "Invalid crop bounds.")
            }
        }
        let timelineEnd = project.clips.last.map { $0.timelineStart + $0.duration } ?? 0
        try require(timelineEnd <= 604800, "Timeline exceeds seven days.")
        for track in project.audioTracks {
            try require(
                project.assets.contains { $0.id == track.assetID },
                "Audio track references a missing asset.")
            try require(
                track.startMs >= 0 && track.endMs > track.startMs && track.offsetMs >= 0
                    && (-60...12).contains(track.gainDb), "Invalid audio timing or gain.")
        }
        for region in project.speedRegions {
            guard let rate = region["speed"] as? NSNumber else {
                throw Failure("invalid_project", "Speed region is missing its rate.")
            }
            try require((0.25...5).contains(rate.doubleValue), "Invalid speed region rate.")
        }
    }

    static func validateValues(_ value: Any, depth: Int = 0) throws {
        try require(depth <= 32, "Project nesting exceeds 32 levels.")
        if let number = value as? NSNumber {
            try require(
                number.doubleValue.isFinite && abs(number.doubleValue) <= 1_000_000_000_000,
                "Project contains an invalid numeric value.")
        } else if let entries = value as? [String: Any] {
            try require(entries.count <= 10000, "Project object is too large.")
            for entry in entries.values { try validateValues(entry, depth: depth + 1) }
        } else if let entries = value as? [Any] {
            try require(entries.count <= 10000, "Project array is too large.")
            for entry in entries { try validateValues(entry, depth: depth + 1) }
        }
    }

    static func validateMedia(_ project: VideoProject) async throws {
        for asset in project.assets {
            try Task.checkCancellation()
            try requireLocalFile(asset.url)
            let media = AVURLAsset(url: asset.url)
            let duration = try await media.load(.duration).seconds
            try require(duration.isFinite && duration > 0, "Media duration is invalid: \(asset.id)")
            if project.clips.contains(where: { $0.assetID == asset.id }) {
                guard let track = try await media.loadTracks(withMediaType: .video).first else {
                    throw Failure("unsupported_media", "Clip media has no video track: \(asset.id)")
                }
                let size = try await track.load(.naturalSize)
                try require(
                    size.width.isFinite && size.height.isFinite && size.width > 0 && size.height > 0
                        && size.width <= 16384 && size.height <= 16384,
                    "Invalid source video dimensions.")
            }
            for clip in project.clips where clip.assetID == asset.id {
                try require(
                    clip.end <= duration + 0.05, "Clip extends beyond the media: \(clip.id)")
            }
            for key in ["edithAudioPath", "edithSourceImagePath"] {
                if let path = asset.raw[key] as? String {
                    try requireLocalFile(URL(fileURLWithPath: path))
                }
            }
            if let path = asset.cameraTrack?["sourcePath"] as? String {
                try requireLocalFile(URL(fileURLWithPath: path))
            }
        }
    }

    static func protectSources(_ project: VideoProject, destination: URL) throws {
        let target = destination.resolvingSymlinksInPath().standardizedFileURL
        var sources = project.assets.flatMap { asset -> [URL] in
            [asset.url]
                + [
                    asset.raw["edithAudioPath"], asset.raw["edithSourceImagePath"],
                    asset.cameraTrack?["sourcePath"],
                ]
                .compactMap { ($0 as? String).map { URL(fileURLWithPath: $0) } }
        }
        sources += sources.map { URL(fileURLWithPath: $0.path + ".cursor.json") }
        try require(
            !sources.contains { $0.resolvingSymlinksInPath().standardizedFileURL == target },
            "Output must not replace source media or sidecars.")
    }

    static func requireOutput(
        _ output: URL, extension suffix: String, project: VideoProject, source: URL
    ) throws {
        try require(
            output.pathExtension.lowercased() == suffix, "Output must have a .\(suffix) extension.")
        try require(
            output.resolvingSymlinksInPath().standardizedFileURL
                != source.resolvingSymlinksInPath().standardizedFileURL,
            "Output must not replace the project.")
        try protectSources(project, destination: output)
    }

    static func checkDestination(_ url: URL, overwrite: Bool) throws {
        try require(url.isFileURL, "Output must be a local file.")
        var info = stat()
        if lstat(url.path, &info) == 0 {
            try require(
                info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
                "Output must not be a symlink or directory.")
            guard overwrite else {
                throw Failure("output_exists", "Output exists. Pass --overwrite to replace it.")
            }
        } else if errno != ENOENT {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }

    static func temporaryOutput(_ url: URL) -> URL {
        url.deletingLastPathComponent().appendingPathComponent(
            ".edith-\(UUID().uuidString).\(url.pathExtension)")
    }

    static func save(_ project: VideoProject, to url: URL, overwrite: Bool) throws {
        try require(
            url.pathExtension == "openscreen", "Project output must have an .openscreen extension.")
        try checkDestination(url, overwrite: overwrite)
        let temporary = temporaryOutput(url)
        defer { try? FileManager.default.removeItem(at: temporary) }
        var copy = project
        try copy.save(to: temporary)
        try publish(temporary, to: url, overwrite: overwrite)
    }

    static func publish(_ temporary: URL, to url: URL, overwrite: Bool) throws {
        try checkDestination(url, overwrite: overwrite)
        if overwrite {
            guard rename(temporary.path, url.path) == 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
        } else {
            guard link(temporary.path, url.path) == 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
        }
    }
}

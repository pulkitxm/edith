@preconcurrency import AVFoundation
import CoreText
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

extension VideoEditorService {
    public struct ProjectSummary: Codable, Sendable {
        public let path: String
        public let id: String?
        public let title: String?
        public let clips: Int?
        public let error: String?
    }

    public struct ReviewFrame: Codable, Sendable {
        public let frame: Int64
        public let time: Double
    }

    public struct ContactSheetReport: Codable, Sendable {
        public let version: Int
        public let path: String
        public let width: Int
        public let height: Int
        public let frames: [ReviewFrame]
        public let sha256: String
    }

    public static func list(in directory: URL) throws -> [ProjectSummary] {
        try require(directory.isFileURL, "Project directory must be local.")
        return try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ).filter { $0.pathExtension == "openscreen" }.sorted { $0.path < $1.path }.map { url in
            do {
                let project = try open(url)
                return ProjectSummary(
                    path: url.path, id: project.id, title: project.title,
                    clips: project.clips.count, error: nil)
            } catch {
                return ProjectSummary(
                    path: url.path, id: nil, title: nil, clips: nil,
                    error: error.localizedDescription)
            }
        }
    }

    public static func clone(
        _ source: URL, to output: URL, title: String, overwrite: Bool = false
    ) throws -> Result {
        try requireTitle(title)
        var project = try open(source)
        try requireOutput(output, extension: "openscreen", project: project, source: source)
        var metadata = project.root["project"] as? [String: Any] ?? [:]
        let identity = VideoProject.create(title: title).root["project"] as? [String: Any] ?? [:]
        metadata.merge(identity) { _, new in new }
        project.root["project"] = metadata
        try save(project, to: output, overwrite: overwrite)
        return result(project, url: output, written: true)
    }

    public static func contactSheet(
        _ source: URL, times: [Double], columns: Int = 4, cellWidth: Int = 320,
        to output: URL, overwrite: Bool = false
    ) async throws -> ContactSheetReport {
        try require((1...64).contains(times.count), "Choose between 1 and 64 review frames.")
        try require((1...8).contains(columns), "Contact sheets support 1 to 8 columns.")
        try require((64...1920).contains(cellWidth), "Cell width must be between 64 and 1920.")
        let project = try open(source)
        try requireOutput(output, extension: "png", project: project, source: source)
        try checkDestination(output, overwrite: overwrite)
        try await validateMedia(project)
        let pipeline = try await VideoRenderPipeline.make(project: project)
        try require(
            times.allSatisfy { $0.isFinite && $0 >= 0 && $0 < pipeline.duration },
            "Review frame times must fall inside the rendered output timeline.")
        let scale = min(1, Double(cellWidth) / max(pipeline.canvas.width, pipeline.canvas.height))
        let width = max(1, Int((pipeline.canvas.width * scale).rounded()))
        let height = max(1, Int((pipeline.canvas.height * scale).rounded()))
        let selections = try times.map { seconds -> (CMTime, CTLine, ReviewFrame) in
            let selection = try frameSelection(in: pipeline, seconds: seconds)
            let frame = selection.frame
            let selected = selection.time
            let label = String(format: "#%lld  %.3f s", frame, selected.seconds)
            let line = CTLineCreateWithAttributedString(
                NSAttributedString(
                    string: label,
                    attributes: [
                        NSAttributedString.Key(kCTFontAttributeName as String):
                            CTFontCreateWithName("Menlo" as CFString, 11, nil),
                        NSAttributedString.Key(kCTForegroundColorAttributeName as String):
                            CGColor(gray: 0.9, alpha: 1),
                    ]))
            return (selected, line, ReviewFrame(frame: frame, time: selected.seconds))
        }
        try require(
            selections.allSatisfy { CMTimeCompare($0.0, pipeline.composition.duration) < 0 },
            "Review frame is outside the composition.")
        let labelWidth = Int(
            ceil(selections.map { CTLineGetTypographicBounds($0.1, nil, nil, nil) }.max()!))
        let tileWidth = max(width, labelWidth)
        let columnCount = min(columns, times.count)
        let rows = (times.count + columnCount - 1) / columnCount
        let gap = 12
        let labelHeight = 28
        let sheetWidth = columnCount * (tileWidth + gap) + gap
        let sheetHeight = rows * (height + labelHeight + gap) + gap
        try require(
            sheetWidth > 0 && sheetHeight > 0 && sheetWidth * sheetHeight <= 64_000_000,
            "Contact sheet exceeds 64 million pixels. Reduce cell width or frame count.")
        guard
            let context = CGContext(
                data: nil, width: sheetWidth, height: sheetHeight, bitsPerComponent: 8,
                bytesPerRow: sheetWidth * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw Failure("render_failed", "Could not allocate the contact sheet.") }
        context.setFillColor(CGColor(gray: 0.07, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: sheetWidth, height: sheetHeight))
        context.interpolationQuality = .high
        let generator = AVAssetImageGenerator(asset: pipeline.composition)
        generator.videoComposition = pipeline.videoComposition
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        for (index, selection) in selections.enumerated() {
            try Task.checkCancellation()
            let rendered = try await generator.image(at: selection.0)
            let x = gap + (index % columnCount) * (tileWidth + gap)
            let y = sheetHeight - (index / columnCount + 1) * (height + labelHeight + gap)
            context.draw(
                rendered.image,
                in: CGRect(
                    x: x + (tileWidth - width) / 2, y: y + labelHeight,
                    width: width, height: height))
            context.textPosition = CGPoint(x: x, y: y + 8)
            CTLineDraw(selection.1, context)
        }
        let temporary = temporaryOutput(output)
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard let image = context.makeImage(),
            let destination = CGImageDestinationCreateWithURL(
                temporary as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw Failure("render_failed", "Could not create the contact sheet PNG.") }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw Failure("render_failed", "Could not finish the contact sheet PNG.")
        }
        let hash = SHA256.hash(data: try Data(contentsOf: temporary))
            .map { String(format: "%02x", $0) }.joined()
        try Task.checkCancellation()
        try publish(temporary, to: output, overwrite: overwrite)
        return ContactSheetReport(
            version: 1, path: output.path, width: sheetWidth, height: sheetHeight,
            frames: selections.map(\.2), sha256: hash)
    }

}

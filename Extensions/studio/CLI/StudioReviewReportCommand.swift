import ArgumentParser
import EdithExtensionSupport
import EdithExtensionCommands
import Foundation

struct StudioEditReviewReport: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "review-report",
        abstract: "Report native composition timing, expectations and optional border geometry.",
        discussion:
            """
            Results are always JSON. Completed failed, sampled or unavailable
            assessments exit 1 with diagnostics on stdout. Source frame coordinates use
            nominal FPS, not decoded VFR sample indices. Border samples never claim full
            coverage.

            Reads the current state. Does not change it.

            ed studio edit review-report web
            """
    )
    @Argument(help: "Local .openscreen project.") var project: String
    @Option(help: "Expected native composition duration in seconds.") var expectDuration: Double?
    @Option(help: "Allowed duration difference in seconds.") var durationTolerance: Double = 0.001
    @Option(help: "Expected output frame count.") var expectFrameCount: Int64?
    @Option(help: "Expected surviving clip count, excluding speed-slice boundaries.")
    var expectShotCount: Int?
    @Flag(help: "Assess geometric source coverage, including cursor-driven zoom.")
    var checkBorders = false
    @Option(
        help:
            "Maximum checked output frames, from 2 to 100000. Longer output is explicitly sampled.")
    var maxBorderFrames = 10000
    @Option(
        help: "Save a complete .json report; stdout then contains its path, status and checksum.")
    var output: String?
    @OptionGroup var options: StudioEditOutput

    func run() async throws {
        var passed = false
        try await StudioEditBridge.run(json: options.json) {
            var review = VideoEditorService.ReviewOptions()
            review.expectedDuration = expectDuration
            review.durationTolerance = durationTolerance
            review.expectedFrameCount = expectFrameCount
            review.expectedShotCount = expectShotCount
            review.checkBorders = checkBorders
            review.maximumBorderFrames = maxBorderFrames
            let source = StudioEditBridge.url(project)
            let report = try await VideoEditorService.reviewReport(source, options: review)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data: Data
            if let output {
                let artifact = try VideoEditorService.writeReviewReport(
                    report, project: source, to: StudioEditBridge.url(output),
                    overwrite: options.overwrite)
                data = try encoder.encode(artifact)
            } else {
                data = try encoder.encode(report)
            }
            guard data.count <= 4 << 20 else {
                throw VideoEditorService.Failure(
                    "result_too_large",
                    "Review JSON exceeds 4 MiB. Use --output to save the full report.")
            }
            CLIOut.out(String(decoding: data, as: UTF8.self))
            passed = report.status == .passed
        }
        if !passed { throw ExitCode.failure }
    }
}

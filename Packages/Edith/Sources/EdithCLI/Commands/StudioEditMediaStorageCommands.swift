import ArgumentParser
import Edith
import Foundation

struct StudioMediaPackage: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "package",
        abstract: "Copy every original dependency into a new portable directory atomically.",
        discussion: """
            Copy every original dependency into a new portable directory atomically.

            Changes the state this command names.

            ed studio edit media package web --output /tmp/out.png
            """, )
    @Argument(help: "Source .openscreen project.") var project: String
    @Option(help: "New package directory; existing destinations are never replaced.") var output:
        String
    @OptionGroup var options: StudioMediaReadOptions
    func run() async throws {
        try await StudioMediaBridge.run(json: options.json) {
            try await VideoEditorService.mediaPackage(
                StudioEditBridge.url(project), to: StudioEditBridge.url(output))
        }
    }
}

struct StudioMediaOpen: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "open",
        abstract: "Verify and rebase a moved package without opening an editor window.",
        discussion: """
            Verify and rebase a moved package without opening an editor window.

            Changes this Mac by opening the target in an app or a browser.

            ed studio edit media open /tmp/companion-export
            """, )
    @Argument(help: "Package directory containing project.openscreen and originals.") var directory:
        String
    @OptionGroup var options: StudioMediaWriteOptions
    func run() async throws {
        try await StudioMediaBridge.run(json: options.json) {
            try await VideoEditorService.mediaOpen(
                StudioEditBridge.url(directory), output: options.output.map(StudioEditBridge.url),
                dryRun: options.dryRun, overwrite: options.overwrite)
        }
    }
}

struct StudioMediaRelink: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "relink",
        abstract: "Relink a media reference with strict identity verification by default.",
        discussion: """
            Relink a media reference with strict identity verification by default.

            Changes the state this command names.

            ed studio edit media relink web --reference reference --path /etc/os-release
            """, )
    @Argument(help: "Source .openscreen project.") var project: String
    @Option(
        help:
            "Reference assetID from the media index; project ID for wallpaper or annotation ID for annotation images."
    ) var reference: String
    @Option(
        help:
            "original, camera, sourceImage, processedAudio, cursor, wallpaper, annotationImage or annotationContent."
    ) var role = "original"
    @Option(help: "Replacement local file.") var path: String
    @Option(
        help:
            "requireIdentity or allowReplacement. Replacement clears stale metadata and provenance."
    ) var policy = "requireIdentity"
    @Option(
        help: "Expected original SHA-256 for missing unindexed media; requires --expected-bytes.")
    var expectedSha256: String?
    @Option(help: "Expected original byte count; requires --expected-sha256.") var expectedBytes:
        Int64?
    @OptionGroup var options: StudioMediaWriteOptions
    func run() async throws {
        try await StudioMediaBridge.run(json: options.json) {
            try await VideoEditorService.mediaRelink(
                StudioEditBridge.url(project), referenceID: reference, role: role,
                to: StudioEditBridge.url(path), policy: policy, expectedSHA256: expectedSha256,
                expectedByteCount: expectedBytes,
                output: options.output.map(StudioEditBridge.url), dryRun: options.dryRun,
                overwrite: options.overwrite)
        }
    }
}

import ArgumentParser
import EdithKit
import Foundation

struct MediaCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "media",
        abstract: "Convert images and compress videos locally.",
        subcommands: [MediaConvertImagesCommand.self, MediaCompressVideoCommand.self])
}

enum MediaCLI {
    static func url(_ path: String) -> URL {
        let expanded = (path as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") {
            return URL(fileURLWithPath: expanded).standardizedFileURL
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(expanded).standardizedFileURL
    }

    static func input(_ path: String) throws -> URL {
        let url = url(path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw CLIFailure.notFound("no file at \(url.path)")
        }
        return url
    }

    static func format(_ value: String) throws -> MediaImageFormat {
        guard let format = MediaImageFormat(rawValue: value.lowercased()) else {
            throw CLIFailure.usage(
                "--format must be "
                    + MediaImageFormat.allCases.map(\.rawValue)
                    .joined(separator: ", "))
        }
        return format
    }

    static func failure(_ error: Error) -> CLIFailure {
        if error is CancellationError { return .unavailable("media processing was cancelled") }
        if let error = error as? MediaToolkitError {
            return .unavailable(error.localizedDescription)
        }
        return CLIFailure(error.localizedDescription)
    }

    static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }
}

struct MediaConvertImagesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "convert-images",
        abstract: "Convert and resize one or more images.")

    @Argument(help: "Input image paths.")
    var inputs: [String] = []

    @Option(name: .customLong("to"), help: "Output directory.")
    var outputDirectory: String

    @Option(help: "Output format: jpeg, png or heic.")
    var format = MediaImageFormat.jpeg.rawValue

    @Option(help: "Lossy quality from 0.1 to 1.")
    var quality = 0.82

    @Option(help: "Largest output edge in pixels; 0 keeps the original size.")
    var maxDimension = 1600

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    func run() async throws {
        try await execute {
            guard !inputs.isEmpty else {
                throw CLIFailure.usage("name at least one input image")
            }
            guard (0.1...1).contains(quality) else {
                throw CLIFailure.usage("--quality must be between 0.1 and 1")
            }
            let maxDimension = try ArgumentChecks.nonNegative(
                self.maxDimension, "--max-dimension")
            guard maxDimension <= 20_000 else {
                throw CLIFailure.usage("--max-dimension must be 20000 or less")
            }
            let format = try MediaCLI.format(format)
            let inputURLs = try inputs.map(MediaCLI.input)
            let outputURL = MediaCLI.url(outputDirectory)
            let options = MediaImageOptions(
                format: format, quality: quality,
                maxDimension: maxDimension == 0 ? nil : maxDimension)
            let results: [MediaImageResult]
            do {
                results = try await Task.detached(priority: .userInitiated) {
                    try MediaToolkit.convertImages(
                        inputURLs, to: outputURL, options: options,
                        cancelled: { Task.isCancelled })
                }.value
            } catch {
                throw MediaCLI.failure(error)
            }
            let succeeded = results.filter { $0.outputURL != nil }.count
            guard !json else {
                CLIOut.json(
                    .object([
                        "operation": .string(
                            MediaToolkitOperation.convertImages.descriptor.id.rawValue),
                        "outputDirectory": .string(outputURL.path),
                        "succeeded": .int(succeeded),
                        "failed": .int(results.count - succeeded),
                        "results": .array(results.map(Self.json)),
                    ]))
                return
            }
            for result in results {
                if let outputURL = result.outputURL {
                    CLIOut.out(outputURL.path)
                } else {
                    CLIOut.note(
                        "\(result.inputURL.lastPathComponent): \(result.error ?? "failed")")
                }
            }
            CLIOut.note("converted \(succeeded) of \(results.count) images")
        }
    }

    static func json(_ result: MediaImageResult) -> JSONValue {
        .object([
            "input": .string(result.inputURL.path),
            "output": result.outputURL.map { .string($0.path) } ?? .null,
            "inputBytes": .number(result.inputBytes),
            "outputBytes": .number(result.outputBytes),
            "error": result.error.map(JSONValue.string) ?? .null,
        ])
    }
}

struct MediaCompressVideoCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "compress-video",
        abstract: "Compress a complete video under a size limit.")

    @Argument(help: "Input video path.")
    var input: String

    @Option(name: .customLong("to"), help: "Output directory.")
    var outputDirectory: String

    @Option(help: "Maximum output size in decimal megabytes.")
    var targetMB = 20

    @Flag(help: "Remove audio from the compressed copy.")
    var noAudio = false

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    func run() async throws {
        try await execute {
            guard (1...512).contains(targetMB) else {
                throw CLIFailure.usage("--target-mb must be between 1 and 512")
            }
            let inputURL = try MediaCLI.input(input)
            let outputURL = MediaCLI.url(outputDirectory)
            let options = MediaVideoOptions(
                targetMegabytes: targetMB, keepAudio: !noAudio)
            let result: MediaVideoResult
            do {
                result = try await Task.detached(priority: .userInitiated) {
                    try await MediaToolkit.compressVideo(
                        inputURL, to: outputURL, options: options,
                        cancelled: { Task.isCancelled })
                }.value
            } catch {
                throw MediaCLI.failure(error)
            }
            guard !json else {
                CLIOut.json(
                    .object([
                        "operation": .string(
                            MediaToolkitOperation.compressVideo.descriptor.id.rawValue),
                        "input": .string(result.inputURL.path),
                        "output": .string(result.outputURL.path),
                        "inputBytes": .number(result.inputBytes),
                        "outputBytes": .number(result.outputBytes),
                        "targetBytes": .number(result.targetBytes),
                        "audio": .bool(options.keepAudio),
                    ]))
                return
            }
            CLIOut.out(result.outputURL.path)
            CLIOut.note(
                "compressed \(MediaCLI.bytes(result.inputBytes)) to \(MediaCLI.bytes(result.outputBytes))"
            )
        }
    }
}

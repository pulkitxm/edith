import AVFoundation
import Testing

@testable import Edith

@Suite(.serialized) struct VideoFrameSamplingReferenceTests {
    static var ffmpeg: URL? {
        ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"]
            .map { URL(fileURLWithPath: $0) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    @Test(.enabled(if: ffmpeg != nil), arguments: VideoFrameSamplingTests.cases + ["vfrSix"])
    func publicDeliveryMatchesIndependentFFmpegFrameIdentities(_ name: String) async throws {
        let directory = try VideoEditorServiceTests.folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("original.mov")
        try await VideoFrameSamplingTests.fixture(
            source, times: VideoFrameSamplingTests.timestamps(name, seconds: 24), seconds: 24)
        let original = try Data(contentsOf: source)
        let seek = Double(VideoFrameSamplingTests.seek(name)) / 90000
        let file = directory.appendingPathComponent("edit.openscreen")
        _ = try VideoEditorService.create(at: file, title: "Synthetic sampling acceptance")
        _ = try await VideoEditorService.apply(
            .init(operations: [
                .addMedia(path: source.path, name: "shot"),
                .videoSettings(settings: .init(width: 32, height: 32)),
                .trim(clipID: "shot", start: seek, end: seek + 15),
                .sourceAudio(clipID: "shot", gainDb: 0, muted: true),
                .frameSampling(clipID: "shot", mode: .nearest),
            ]), to: file, overwrite: true)
        let destination = directory.appendingPathComponent("delivery.mp4")
        let result = try await VideoEditorService.render(file, to: destination)
        #expect(result.videoReport?.frameCount == 900)
        let actual = try VideoFrameSamplingTests.read(AVURLAsset(url: destination))
        let expected = try reference(source, seek: seek, in: directory)
        #expect(actual.count == 900 && expected.count == 900)
        #expect(actual == expected)
        let restored = try VideoEditorService.open(file)
        #expect(restored.clips[0].start == seek && restored.clips[0].end == seek + 15)
        #expect(try Data(contentsOf: source) == original)
        print(
            "sampling \(name): frames=\(actual.count), mismatches=\(zip(actual, expected).filter { $0 != $1 }.count), storedTrim=\(restored.clips[0].start)...\(restored.clips[0].end), sourceUnchanged=\(try Data(contentsOf: source) == original)"
        )
    }

    private func reference(_ source: URL, seek: Double, in directory: URL) throws -> [Int] {
        let output = directory.appendingPathComponent("reference.rgb")
        let process = Process()
        process.executableURL = try #require(Self.ffmpeg)
        process.arguments = [
            "-nostdin", "-v", "error", "-ss", String(seek), "-i", source.path,
            "-vf", "fps=60", "-frames:v", "900", "-pix_fmt", "rgb24", "-f", "rawvideo", output.path,
        ]
        process.standardInput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0)
        let data = try Data(contentsOf: output)
        try #require(data.count == 900 * 32 * 32 * 3)
        return stride(from: 0, to: data.count, by: 32 * 32 * 3).map { offset in
            (0..<8).reduce(0) { value, bit in
                value | (data[offset + (bit * 4 + 2) * 3] > 128 ? 1 << bit : 0)
            }
        }
    }
}

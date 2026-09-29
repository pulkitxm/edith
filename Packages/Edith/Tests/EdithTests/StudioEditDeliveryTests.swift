import Darwin
import Foundation
import MCP
import Testing
@testable import Edith
@testable import EdithCLI

@Suite(.serialized) struct StudioEditDeliveryTests {
    @Test func exactFrameFlagReturnsFrameAndTimeAndRejectsAmbiguousSelection() async throws {
        let directory = try VideoEditorServiceTests.folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let project = try await VideoDeliveryServiceTests.project(in: directory)
        let output = directory.appendingPathComponent("frame.png")
        let arguments = [
            "studio", "edit", "frame", project.path, "--output", output.path, "--json",
        ]
        let selected = try CLIProcessProbe.run(arguments + ["--frame", "3"])
        #expect(selected.code == 0, "\(selected.stderr)")
        let result = try StudioCLITests.json(selected.stdout)
        #expect(result["frame"] as? Int == 3)
        #expect(result["time"] as? Double == 0.05)
        #expect(result["written"] as? Bool == true)
        let original = try Data(contentsOf: output)
        for options in [["--time", "0", "--frame", "3"], ["--frame", "60"], [String]()] {
            let invalid = try CLIProcessProbe.run(arguments + ["--overwrite"] + options)
            #expect(invalid.code == 2)
            #expect(invalid.stdout.isEmpty)
            #expect(try Data(contentsOf: output) == original)
        }
    }

    @Test func flagsReachNativeWriterAndProgressStaysOffStdout() async throws {
        let directory = try VideoEditorServiceTests.folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let project = try await VideoDeliveryServiceTests.project(in: directory)
        let output = directory.appendingPathComponent("master.mov")
        let run = try CLIProcessProbe.run(
            [
                "studio", "edit", "render", project.path, "--output", output.path,
                "--codec", "proRes422HQ", "--color-space", "displayP3", "--audio-codec", "pcm",
                "--audio-sample-rate", "96000", "--audio-channels", "1", "--progress", "--json",
            ], timeout: 60)
        #expect(run.code == 0, "\(run.stderr)")
        let result = try StudioCLITests.json(run.stdout)
        #expect(result["written"] as? Bool == true)
        #expect(result["path"] as? String == output.path)
        let report = try #require(result["videoReport"] as? [String: Any])
        #expect(report["videoCodec"] as? String == "apch")
        #expect(report["bitsPerComponent"] as? Int == 10)
        #expect(report["colorPrimaries"] as? String == "P3_D65")
        #expect(report["audioSampleRate"] as? Int == 96000)
        #expect(report["audioChannels"] as? Int == 1)
        let events = try run.stderr.split(separator: "\n").map {
            try StudioCLITests.json(String($0))
        }
        #expect(!events.isEmpty && events.count <= 101)
        #expect(events.allSatisfy { $0["event"] as? String == "progress" })
        let percentages = events.compactMap { $0["percent"] as? Int }
        #expect(percentages.last == 100)
        #expect(zip(percentages, percentages.dropFirst()).allSatisfy { $0 < $1 })
    }

    @Test func audioDeliveryIsAvailableThroughMCPAndRejectsInvalidSettings() async throws {
        let directory = try VideoEditorServiceTests.folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let project = try await VideoDeliveryServiceTests.project(in: directory)
        let output = directory.appendingPathComponent("mix.m4a")
        let response = await OperationMCPServer.call(
            CallTool.Parameters(
                name: "edith_studio_edit_render_audio",
                arguments: [
                    "arguments": .array(
                        [
                            project.path, "--output", output.path, "--container", "m4a",
                            "--sample-rate", "44100", "--channels", "1", "--bit-rate", "192000",
                        ].map { .string($0) })
                ]), executable: CLIProcessProbe.binary)
        #expect(response.isError != true)
        guard case let .text(text, _, _) = try #require(response.content.first) else {
            Issue.record("Missing audio delivery result")
            return
        }
        let result = try StudioCLITests.json(text)
        #expect(result["written"] as? Bool == true)
        let report = try #require(result["audioReport"] as? [String: Any])
        #expect(report["codec"] as? String == "aac ")
        #expect(report["sampleRate"] as? Int == 44100)
        #expect(report["channels"] as? Int == 1)
        #expect(report["frames"] as? Int == 44100)
        let original = try Data(contentsOf: output)
        let invalid = try CLIProcessProbe.run([
            "studio", "edit", "render-audio", project.path, "--output", output.path,
            "--container", "m4a", "--sample-rate", "96000", "--overwrite", "--json",
        ])
        #expect(invalid.code == 2)
        #expect(invalid.stdout.isEmpty)
        #expect(
            (try StudioCLITests.json(invalid.stderr)["error"] as? [String: Any])?["code"] as? String
                == "invalid_settings")
        #expect(try Data(contentsOf: output) == original)
    }

    @Test(arguments: [SIGINT, SIGTERM])
    func signalsCancelNativeExportAndCleanPartials(_ signal: Int32) async throws {
        let directory = try VideoEditorServiceTests.folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let project = try await VideoDeliveryServiceTests.project(in: directory)
        var document = try VideoProject.open(project)
        let clip = document.clips[0]
        document.setClips(
            (0..<600).map { index in
                var copy = clip
                copy.raw["id"] = "clip_\(index)"
                return copy
            })
        try document.save(to: project)
        let output = directory.appendingPathComponent("delivery.mp4")
        let sentinel = Data("previous delivery".utf8)
        try sentinel.write(to: output)
        let outURL = directory.appendingPathComponent("stdout.txt")
        let errURL = directory.appendingPathComponent("stderr.txt")
        try Data().write(to: outURL)
        try Data().write(to: errURL)
        let stdout = try FileHandle(forWritingTo: outURL)
        let stderr = try FileHandle(forWritingTo: errURL)
        defer { try? stdout.close(); try? stderr.close() }
        let process = Process()
        process.executableURL = CLIProcessProbe.binary
        process.arguments = [
            "studio", "edit", "render", project.path, "--output", output.path,
            "--overwrite", "--json", "--progress",
        ]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        defer { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
        let deadline = Date().addingTimeInterval(60)
        var interrupted = false
        while process.isRunning, Date() < deadline {
            let text = try String(contentsOf: errURL, encoding: .utf8)
            if !interrupted, text.contains("\"event\":\"progress\"") {
                #expect(kill(process.processIdentifier, signal) == 0)
                interrupted = true
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(!process.isRunning, "Native export did not stop after cancellation")
        #expect(interrupted)
        #expect(process.terminationReason == .exit)
        #expect(process.terminationStatus == 128 + signal)
        #expect(try Data(contentsOf: outURL).isEmpty)
        let lines = try String(contentsOf: errURL, encoding: .utf8).split(separator: "\n")
        let error = try StudioCLITests.json(String(try #require(lines.last)))
        #expect((error["error"] as? [String: Any])?["code"] as? String == "cancelled")
        #expect(try Data(contentsOf: output) == sentinel)
        #expect(
            try !FileManager.default.contentsOfDirectory(atPath: directory.path).contains {
                $0.hasPrefix(".edith-") || $0.contains(".partial.")
            })
    }
}

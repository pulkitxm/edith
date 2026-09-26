import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import EdithStudio

@Suite struct ImageAuditFailureTests {
    static let singleInputTools: [(String, [String: StudioValue])] = [
        ("image.compress", [:]), ("image.resize", [:]), ("image.crop", [:]),
        ("image.crop", ["mode": .text("trim")]), ("image.convert", [:]), ("image.rotate", [:]),
        ("image.watermark", [:]), ("image.remove-background", [:]), ("image.blur-faces", [:]),
        ("image.upscale", [:]), ("image.adjust", ["filter": .text("mono")]),
        ("image.meme", ["top": .text("hi")]), ("image.border", [:]), ("image.metadata", [:]),
        ("image.metadata", ["mode": .text("location")]), ("image.to-text", [:]),
        ("image.icon", [:]),
    ]

    static func damagedFiles(_ space: Workspace) throws -> [URL] {
        var urls: [URL] = []
        for name in ["empty.jpg", "empty.png", "empty.heic", "empty.gif"] {
            let url = space.url(name)
            try Data().write(to: url)
            urls.append(url)
        }
        let random = space.url("noise.png")
        try Data((0..<4096).map { UInt8(truncatingIfNeeded: $0 &* 7919 &+ 13) }).write(to: random)
        urls.append(random)
        let fakeJPEG = space.url("fake.jpg")
        try Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10] + Array(repeating: 0x41, count: 64))
            .write(to: fakeJPEG)
        urls.append(fakeJPEG)
        for (name, type) in [("cut.jpg", UTType.jpeg), ("cut.png", UTType.png)] {
            let full = space.url("full-" + name)
            try AuditImages.write(
                Fixtures.photo(width: 200, height: 150), to: full, type: type,
                properties: AuditImages.cameraProperties(orientation: 6))
            let data = try Data(contentsOf: full)
            let url = space.url(name)
            try data.prefix(data.count * 6 / 10).write(to: url)
            urls.append(url)
        }
        return urls
    }

    @Test func damagedFilesFailWithAClearStudioError() async throws {
        let space = try Workspace()
        let damaged = try Self.damagedFiles(space)
        for (id, values) in Self.singleInputTools {
            for input in damaged {
                do {
                    let result = try await space.run(id, [input], values)
                    Issue.record("\(id) accepted \(input.lastPathComponent): \(result.outputs)")
                } catch let error as StudioError {
                    let message = error.errorDescription ?? ""
                    #expect(
                        message.contains(input.lastPathComponent),
                        "\(id) \(input.lastPathComponent): \(message)")
                } catch {
                    Issue.record("\(id) \(input.lastPathComponent) threw \(error)")
                }
            }
        }
        for id in ["image.collage", "image.make-gif"] {
            let good = space.url("good.png")
            try AuditImages.write(AuditImages.quadrants(), to: good, type: .png)
            await #expect(throws: StudioError.self) {
                try await space.run(id, [good, damaged[0]])
            }
        }
    }

    @Test func wrongKindsAndMissingSettingsAreRejected() async throws {
        let space = try Workspace()
        let photo = space.url("photo.png")
        try AuditImages.write(AuditImages.quadrants(), to: photo, type: .png)
        let pdf = space.url("doc.pdf")
        try Fixtures.pdf(at: pdf, pages: ["A"])
        let text = space.url("notes.txt")
        try "hello".write(to: text, atomically: true, encoding: .utf8)
        for tool in ImageTools.all where tool.isRunnable {
            for input in [pdf, text] {
                let inputs = tool.arity == .each ? [input] : [input, photo]
                await #expect(
                    throws: StudioError.unsupportedInput(input.lastPathComponent, tool.title)
                ) {
                    try await space.run(tool.id, inputs)
                }
            }
        }
        let invalid: [(String, [URL], [String: StudioValue], String)] = [
            ("image.watermark", [photo], ["text": .text("  ")], "text"),
            ("image.watermark", [photo], ["kind": .text("image")], "image"),
            (
                "image.watermark", [photo],
                ["kind": .text("image"), "image": .text(space.url("missing.png").path)],
                "missing.png"
            ),
            ("image.meme", [photo], [:], "top text"),
            ("image.rotate", [photo], ["angle": .text("0")], "rotate"),
            ("image.adjust", [photo], [:], "filter"),
            ("image.collage", [photo], [:], "2"),
            ("image.make-gif", [photo], [:], "2"),
            (
                "image.crop", [photo],
                [
                    "mode": .text("area"),
                    "area": .rect(StudioRect(x: 1.2, y: 0, width: 0.2, height: 1)),
                ],
                "crop"
            ),
        ]
        for (id, inputs, values, fragment) in invalid {
            do {
                _ = try await space.run(id, inputs, values)
                Issue.record("\(id) \(values) should fail")
            } catch let error as StudioError {
                let message = error.errorDescription ?? ""
                #expect(message.lowercased().contains(fragment.lowercased()), "\(id): \(message)")
            }
        }
    }

    @Test func visionToolsExplainImagesTooSmallToAnalyze() async throws {
        let space = try Workspace()
        let dot = space.url("dot.png")
        try AuditImages.write(AuditImages.pixelGrid([[.red, .green]]), to: dot, type: .png)
        for (id, values) in [
            ("image.to-text", [String: StudioValue]()), ("image.remove-background", [:]),
            ("image.blur-faces", ["text": .bool(true)]),
        ] {
            do {
                let result = try await space.run(id, [dot], values)
                #expect(!result.outputs.isEmpty, "\(id)")
            } catch let error as StudioError {
                #expect(error.errorDescription?.contains("dot.png") == true, "\(id) \(error)")
            } catch {
                Issue.record("\(id) threw a raw error: \(error)")
            }
        }
    }

    @Test func toolsNeverTouchTheirInputsEvenWhenSavingNextToThem() async throws {
        let space = try Workspace()
        let photo = space.url("IMG_0001.JPG")
        try AuditImages.photo(at: photo, orientation: 6, camera: true)
        let second = space.url("IMG_0002.heic")
        try AuditImages.photo(at: second, orientation: 8, type: .heic, camera: true)
        let alpha = space.url("logo.png")
        try AuditImages.write(AuditImages.transparentCorner(), to: alpha, type: .png)
        let inputs = [photo, second, alpha]
        let before = try AuditFiles.snapshot(inputs)
        let settings: [String: [String: StudioValue]] = [
            "image.meme": ["top": .text("hi")], "image.adjust": ["filter": .text("mono")],
            "image.convert": ["format": .text("jpg")],
        ]
        for tool in ImageTools.all where tool.isRunnable && tool.id != "image.remove-background" {
            let values = settings[tool.id] ?? [:]
            do {
                let result = try await StudioRunner.run(
                    tool: tool, inputs: inputs, settings: StudioSettings(values),
                    destination: .nextToOriginal, environment: space.environment)
                for output in result.outputs {
                    #expect(!inputs.contains(output.url), "\(tool.id) overwrote \(output.url)")
                }
            } catch let error as StudioError {
                #expect(tool.id == "image.to-text", "\(tool.id) failed: \(error)")
            }
            #expect(try AuditFiles.snapshot(inputs) == before, "\(tool.id) changed an input")
        }
    }
}

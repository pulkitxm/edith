import Foundation
import Testing

@testable import EdithStudio

@Suite struct CatalogTests {
    @Test func toolIdentifiersAreUniqueAndNamespaced() {
        let ids = StudioCatalog.tools.map(\.id)
        #expect(Set(ids).count == ids.count)
        for id in ids {
            #expect(id.split(separator: ".").count == 2, "\(id) should be family.name")
        }
        #expect(StudioCatalog.tools.count >= 100)
        let titles = StudioCatalog.tools.map(\.title)
        let repeated = Dictionary(grouping: titles, by: { $0 }).filter { $0.value.count > 1 }.keys
        #expect(repeated.isEmpty, "tool titles repeat: \(repeated.sorted())")
    }

    @Test func everyToolIsCompleteAndRunnableOrAnEditor() {
        for tool in StudioCatalog.tools {
            #expect(!tool.title.isEmpty && tool.summary.count > 20, "\(tool.id) needs copy")
            #expect(
                !tool.inputs.isEmpty || !tool.extraExtensions.isEmpty || tool.arity == .none,
                "\(tool.id) accepts nothing")
            switch tool.style {
            case .run: #expect(tool.isRunnable, "\(tool.id) has no implementation")
            case .editor: #expect(!tool.isRunnable, "\(tool.id) is an editor with a runner")
            case .compare: #expect(tool.arity == .combine(minimum: 2, maximum: 2))
            }
        }
    }

    @Test func optionDefaultsAreValidForTheirKinds() {
        for tool in StudioCatalog.tools {
            let keys = tool.options.map(\.key)
            #expect(Set(keys).count == keys.count, "\(tool.id) repeats an option key")
            for option in tool.options {
                switch option.kind {
                case let .choice(choices):
                    let value = option.defaultValue.text ?? ""
                    #expect(
                        choices.contains { $0.value == value },
                        "\(tool.id).\(option.key) defaults to \(value) which is not a choice")
                case .toggle:
                    #expect(option.defaultValue.bool != nil, "\(tool.id).\(option.key)")
                case let .integer(range, _):
                    let value = Int(option.defaultValue.number ?? .nan)
                    #expect(range.contains(value), "\(tool.id).\(option.key) default out of range")
                case let .number(range, _, _), let .percent(range):
                    #expect(
                        range.contains(option.defaultValue.number ?? .nan),
                        "\(tool.id).\(option.key) default out of range")
                case .anchor:
                    #expect(StudioAnchor(rawValue: option.defaultValue.text ?? "") != nil)
                case .color:
                    #expect(StudioColor(hex: option.defaultValue.text ?? "") != nil)
                default:
                    break
                }
                if let condition = option.condition {
                    #expect(
                        keys.contains(condition.key),
                        "\(tool.id).\(option.key) depends on a missing key")
                }
            }
        }
    }

    @Test func quickActionsResolveForEveryKind() {
        for (kind, actions) in StudioCatalog.quickActions {
            for (action, id) in actions {
                let tool = StudioCatalog.tool(id)
                #expect(tool != nil, "\(kind) \(action) points at missing \(id)")
                if let tool { #expect(tool.accepts(kind: kind) || !tool.extraExtensions.isEmpty) }
            }
        }
    }

    @Test func optionParsingAcceptsTheCommandLineShapes() throws {
        let compress = try #require(StudioCatalog.tool("pdf.compress"))
        let level = try #require(compress.options.first { $0.key == "level" })
        #expect(try level.parse("EXTREME") == .text("extreme"))
        #expect(throws: StudioError.self) { try level.parse("maximum") }
        let toggle = StudioOption.toggle("x", "X", default: false)
        #expect(try toggle.parse("yes") == .bool(true))
        let percent = StudioOption.percent("q", "Q", default: 0.5)
        #expect(try percent.parse("40%") == .number(0.4))
        #expect(try StudioOption.span().parse("0:05-0:12") == .span(StudioSpan(start: 5, end: 12)))
        #expect(try StudioOption.span().parse("1:00-") == .span(StudioSpan(start: 60, end: nil)))
        #expect(throws: StudioError.self) { try StudioOption.span().parse("0:12-0:05") }
        #expect(
            try StudioOption.rect("r", "R").parse("0.1,0.2,0.5,0.5")
                == .rect(StudioRect(x: 0.1, y: 0.2, width: 0.5, height: 0.5)))
        #expect(StudioTime.parse("1:02:03.5") == 3723.5)
        #expect(StudioTime.format(75) == "01:15")
    }

    @Test func kindsAndToolsMatchFiles() {
        #expect(StudioKind.of(URL(fileURLWithPath: "/a/b.PDF")) == .pdf)
        #expect(StudioKind.of(URL(fileURLWithPath: "/a/b.heic")) == .image)
        #expect(StudioKind.of(URL(fileURLWithPath: "/a/b.mkv")) == .video)
        #expect(StudioKind.of(URL(fileURLWithPath: "/a/b.flac")) == .audio)
        #expect(StudioKind.of(URL(fileURLWithPath: "/a/b.docx")) == .document)
        #expect(StudioKind.of(URL(fileURLWithPath: "/a/b.pptx")) == .presentation)
        #expect(StudioKind.of(URL(fileURLWithPath: "/a/b.xlsx")) == .spreadsheet)
        #expect(StudioKind.of(URL(fileURLWithPath: "/a/b.tgz")) == .archive)
        let pdfs = [URL(fileURLWithPath: "/a.pdf"), URL(fileURLWithPath: "/b.pdf")]
        let ids = StudioCatalog.tools(accepting: pdfs).map(\.id)
        #expect(ids.contains("pdf.merge"))
        #expect(ids.contains("pdf.compare"))
        #expect(!ids.contains("image.compress"))
        let single = StudioCatalog.tools(accepting: [pdfs[0]]).map(\.id)
        #expect(!single.contains("pdf.merge"))
    }

    @Test func runnerRejectsWrongInputsBeforeWorking() async throws {
        let space = try Workspace()
        let image = space.url("photo.png")
        try Fixtures.image(at: image)
        await #expect(throws: StudioError.unsupportedInput("photo.png", "Compress PDF")) {
            try await space.run("pdf.compress", [image])
        }
        var missing = space.environment
        missing.ffmpeg = nil
        await #expect(throws: StudioError.needsEngine(.ffmpeg)) {
            try await space.run("video.compress", [space.url("clip.mp4")], environment: missing)
        }
    }

    @Test func runnerKeepsGoingWhenOneFileInABatchFails() async throws {
        let space = try Workspace()
        let good = space.url("good.pdf")
        let bad = space.url("bad.pdf")
        try Fixtures.pdf(at: good, pages: ["Fine"])
        try Data("not a pdf".utf8).write(to: bad)
        let result = try await space.run("pdf.rotate", [good, bad])
        #expect(result.outputs.count == 1)
        #expect(result.failures.map(\.file) == ["bad.pdf"])
    }

    @Test func outputsNeverOverwriteExistingFiles() async throws {
        let space = try Workspace()
        let source = space.url("keep.pdf")
        try Fixtures.pdf(at: source, pages: ["Keep"])
        let first = try await space.run("pdf.rotate", [source])
        let second = try await space.run("pdf.rotate", [source])
        #expect(try first.url().lastPathComponent == "keep-rotated.pdf")
        #expect(try second.url().lastPathComponent == "keep-rotated 2.pdf")
        let beside = try await StudioRunner.run(
            tool: try #require(StudioCatalog.tool("pdf.rotate")), inputs: [source],
            destination: .nextToOriginal, environment: space.environment)
        #expect(try beside.url().deletingLastPathComponent() == space.root)
    }

    @Test func cancellationStopsARunQuickly() async throws {
        let space = try Workspace()
        let source = space.url("big.pdf")
        try Fixtures.pdf(at: source, pages: Array(repeating: "Page", count: 60))
        let task = Task { try await space.run("pdf.ocr", [source], ["skipText": .bool(false)]) }
        try await Task.sleep(for: .milliseconds(150))
        task.cancel()
        let started = Date()
        let outcome = await task.result
        #expect(Date().timeIntervalSince(started) < 10)
        if case let .failure(error) = outcome {
            #expect((error as? StudioError) == .cancelled || error is CancellationError)
        }
    }
}

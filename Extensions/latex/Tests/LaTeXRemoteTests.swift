import AppKit
import PDFKit
import EdithExtensionCommands
import EdithExtensionSupport
import Foundation
import Testing
@testable import LaTeXExtension

@Suite(.serialized) @MainActor struct LaTeXRemoteTests {
    @Test func ownedSourceAndCheckedDraftStayInEngine() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("synthetic.tex")
        try Data("original document".utf8).write(to: source)
        let store = LaTeXProjectStore(url: root.appendingPathComponent("projects.json"))
        let engine = LaTeXModel(store: store)
        try await engine.add(.init(name: "Synthetic", location: .disk, sourcePath: source.path))
        let id = try #require(engine.selectedID)
        let bridge = LaTeXUIBridge(invoke: { command, payload in
            try await LaTeXUIBridge.execute(command, payload: payload, model: engine)
        })
        let ui = LaTeXModel(remote: bridge)
        await ui.start()
        #expect(ui.projects.count == 1 && ui.source == "original document")
        let revision = try #require(ui.original?.revision)
        _ = try await bridge.perform(
            .init(action: "draft", projectID: id, revision: revision, text: "edited document"))
        #expect(engine.dirty && engine.source == "edited document")
        #expect(try String(contentsOf: source, encoding: .utf8) == "original document")
        await #expect(throws: (any Error).self) {
            _ = try await bridge.perform(
                .init(action: "draft", projectID: id, revision: "stale", text: "lost document"))
        }
        #expect(engine.source == "edited document")
        await ui.shutdown()
        #expect(!engine.isStopped && engine.dirty)
        await engine.shutdown()
    }

    @Test func selectingClearsStaleSourceAndFailuresKeepTheirMessage() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("first.tex")
        let second = root.appendingPathComponent("second.tex")
        try Data("first document".utf8).write(to: first)
        try Data("second document".utf8).write(to: second)
        let store = LaTeXProjectStore(url: root.appendingPathComponent("projects.json"))
        let engine = LaTeXModel(store: store)
        try await engine.add(.init(name: "First", location: .disk, sourcePath: first.path))
        try await engine.add(.init(name: "Second", location: .disk, sourcePath: second.path))
        let firstID = try #require(engine.projects.first?.id)
        let bridge = LaTeXUIBridge(invoke: { command, payload in
            try await LaTeXUIBridge.execute(command, payload: payload, model: engine)
        })
        let ui = LaTeXModel(remote: bridge)
        await ui.start()
        #expect(ui.load.hasContent && !ui.load.isRunning && ui.localMessage == nil)
        let secondID = try #require(ui.projects.last?.id)
        await ui.select(secondID)
        #expect(ui.source == "second document" && !ui.busy && !ui.load.isRunning)
        #expect(ui.editorRequest == 0)
        try FileManager.default.removeItem(at: first)
        await ui.select(firstID)
        #expect(ui.selectedID == firstID && ui.original == nil && ui.source.isEmpty)
        #expect(ui.load.errorMessage != nil && !ui.busy)
        await ui.shutdown(); await engine.shutdown()
    }

    @Test func largeValidPDFIsTransferredInCheckedChunksAndRemainsRenderable() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("synthetic.tex")
        try Data("synthetic document".utf8).write(to: source)
        let project = LaTeXProject(name: "Synthetic", location: .disk, sourcePath: source.path)
        let image = NSImage(size: NSSize(width: 64, height: 64), flipped: false) { rect in
            NSColor.white.setFill(); rect.fill(); return true
        }
        let document = PDFDocument()
        document.insert(try #require(PDFPage(image: image)), at: 0)
        document.documentAttributes = [
            PDFDocumentAttribute.titleAttribute: String(repeating: "synthetic", count: 300_000)
        ]
        let bytes = try #require(document.dataRepresentation())
        #expect(bytes.count > 2_097_152)
        try bytes.write(to: project.pdfURL)
        let engine = LaTeXModel(
            store: LaTeXProjectStore(url: root.appendingPathComponent("projects.json")))
        try await engine.add(project)
        let bridge = LaTeXUIBridge(invoke: {
            try await LaTeXUIBridge.execute($0, payload: $1, model: engine)
        })
        let snapshot = try await bridge.snapshot()
        let transferred = try #require(snapshot.pdfPreview)
        #expect(transferred == bytes && PDFDocument(data: transferred)?.pageCount == 1)
        let stale = LaTeXPDFChunkRequest(projectID: project.id, generation: UUID(), offset: 0)
        await #expect(throws: ExtensionPeerError.self) {
            _ = try await LaTeXUIBridge.execute(
                "latex.ui.pdfChunk", payload: JSONEncoder().encode(stale), model: engine)
        }
        await engine.shutdown()
    }

    @Test func snapshotsFollowProjectsChangedFromTheTerminal() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("synthetic.tex")
        try Data("original document".utf8).write(to: source)
        let store = LaTeXProjectStore(url: root.appendingPathComponent("projects.json"))
        let engine = LaTeXModel(store: store)
        let bridge = LaTeXUIBridge(invoke: { command, payload in
            try await LaTeXUIBridge.execute(command, payload: payload, model: engine)
        })
        #expect(try await bridge.snapshot().projects.isEmpty)
        let project = LaTeXProject(name: "Terminal", location: .disk, sourcePath: source.path)
        try store.save([project])
        #expect(try await bridge.snapshot().projects.map(\.id) == [project.id])
        _ = try await bridge.perform(.init(action: "select", projectID: project.id))
        #expect(try await bridge.snapshot().selectedID == project.id)
        try store.save([])
        let emptied = try await bridge.snapshot()
        #expect(emptied.projects.isEmpty && emptied.selectedID == nil)
        await engine.shutdown()
    }

    @Test func catalogDeclaresThatTerminalInputIsAccepted() throws {
        let catalog = try #require(
            JSONSerialization.jsonObject(
                with: LaTeXCLIExecution.catalog(Data("{}".utf8))) as? [String: Any])
        #expect(catalog["acceptsInput"] as? Bool == true)
        let routes = try #require(catalog["commands"] as? [[String: Any]])
        #expect(routes.contains { $0["route"] as? [String] == ["latex", "write"] })
    }

    @Test func terminalStreamsUseCallerDirectoryAndStandardInput() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("synthetic.tex")
        try Data("original document".utf8).write(to: source)
        let store = LaTeXProjectStore(url: root.appendingPathComponent("projects.json"))
        let add = try await LaTeXCLIExecution.run(
            .init(
                arguments: ["add", "--name", "Synthetic", "--file", "synthetic.tex", "--json"],
                workingDirectory: root.path), store: store)
        #expect(add.exitCode == 0)
        let project = try #require(store.load().first)
        #expect(project.sourcePath == source.path)
        let original = try await LaTeXService.live.load(project)
        let streams = try ExtensionCLIStreams(owner: "latex")
        let start = ExtensionCLIStreamStart(
            owner: "latex", session: UUID(),
            request: try .init(
                arguments: [
                    "write", project.id.uuidString, "--revision", LaTeXCLI.revision(original),
                    "--json",
                ], standardInput: Data("updated document".utf8), workingDirectory: root.path))
        let payload = try LaTeXCLIExecution.stream(
            streams, operation: "latex.cli.start", payload: JSONEncoder().encode(start),
            store: store)
        let handle = try JSONDecoder().decode(ExtensionCLIStreamHandle.self, from: payload)
        var sequence: UInt64 = 0; var output = Data()
        for _ in 0..<200 {
            let frame = try streams.read(.init(handle: handle, sequence: sequence))
            for chunk in frame.chunks {
                #expect(chunk.channel == .stdout); output.append(chunk.data)
            }
            sequence = frame.nextSequence
            if frame.state != .running {
                #expect(frame.state == .completed && frame.exitCode == 0); break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        let result = try #require(JSONSerialization.jsonObject(with: output) as? [String: Any])
        #expect(
            result["source"] as? String == "updated document" && result["applied"] as? Bool == false
        )
        #expect(try String(contentsOf: source, encoding: .utf8) == "original document")
        await streams.stopAndWait()
    }

    @Test func originalCLIReadsAndPreviewsCheckedEditsWithoutChangingFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("synthetic.tex")
        try Data("original document".utf8).write(to: source)
        let project = LaTeXProject(name: "Synthetic", location: .disk, sourcePath: source.path)
        let store = LaTeXProjectStore(url: root.appendingPathComponent("projects.json"))
        try store.save([project])
        let read = try await LaTeXCLIExecution.run(
            .init(arguments: ["read", project.id.uuidString, "--json"]), store: store)
        let value = try #require(
            JSONSerialization.jsonObject(with: Data(read.stdout.utf8)) as? [String: Any])
        let revision = try #require(value["revision"] as? String)
        #expect(read.exitCode == 0 && value["source"] as? String == "original document")
        let edit = try await LaTeXCLIExecution.run(
            .init(
                arguments: ["edit", project.id.uuidString, "--revision", revision, "--json"],
                standardInput: Data(
                    #"[{"find":"original","replace":"updated","expectedMatches":1}]"#.utf8)),
            store: store)
        let plan = try #require(
            JSONSerialization.jsonObject(with: Data(edit.stdout.utf8)) as? [String: Any])
        #expect(edit.exitCode == 0 && plan["source"] as? String == "updated document")
        #expect(plan["applied"] as? Bool == false)
        #expect(try String(contentsOf: source, encoding: .utf8) == "original document")
        let stale = try await LaTeXCLIExecution.run(
            .init(
                arguments: ["write", project.id.uuidString, "--revision", "stale", "--yes"],
                standardInput: Data("replacement".utf8)), store: store)
        #expect(stale.exitCode != 0 && stale.stderr.contains("revision changed"))
        #expect(try String(contentsOf: source, encoding: .utf8) == "original document")
        let help = try await LaTeXCLIExecution.run(.init(arguments: ["--help"]), store: store)
        #expect(
            help.exitCode == 0 && help.stdout.contains("merge") && help.stdout.contains("compile"))
    }
}

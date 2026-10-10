import AppKit
import PDFKit
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
        #expect(try store.loadDraft()?.text == "edited document")
    }

    @Test func buildDeliveryStaysEngineOwnedAndFixtureCannotOpenURLs() async throws {
        let store = LaTeXProjectStore(
            url: FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString))
        let engine = LaTeXModel(store: store)
        engine.buildURL = URL(string: "https://fixture.invalid/build")
        #expect(throws: ExtensionPeerError.self) { try engine.deliverBuildURL() }
        var actions: [LaTeXUIAction] = []
        let bridge = LaTeXUIBridge(invoke: { command, payload in
            #expect(command == "latex.ui.action")
            actions.append(try JSONDecoder().decode(LaTeXUIAction.self, from: payload))
            return try JSONEncoder().encode(LaTeXUISnapshot(model: engine))
        })
        let ui = LaTeXModel(remote: bridge)
        ui.selectedID = UUID()
        ui.openBuildURL()
        while actions.isEmpty { await Task.yield() }
        #expect(actions.count == 1 && actions[0].action == "buildURL")
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
            .init(arguments: ["edit", project.id.uuidString, "--revision", revision, "--json"]),
            input: Data(#"[{"find":"original","replace":"updated","expectedMatches":1}]"#.utf8),
            store: store)
        let plan = try #require(
            JSONSerialization.jsonObject(with: Data(edit.stdout.utf8)) as? [String: Any])
        #expect(edit.exitCode == 0 && plan["source"] as? String == "updated document")
        #expect(plan["applied"] as? Bool == false)
        #expect(try String(contentsOf: source, encoding: .utf8) == "original document")
        let stale = try await LaTeXCLIExecution.run(
            .init(arguments: ["write", project.id.uuidString, "--revision", "stale", "--yes"]),
            input: Data("replacement".utf8), store: store)
        #expect(stale.exitCode != 0 && stale.stderr.contains("revision changed"))
        #expect(try String(contentsOf: source, encoding: .utf8) == "original document")
        let help = try await LaTeXCLIExecution.run(.init(arguments: ["--help"]), store: store)
        #expect(
            help.exitCode == 0 && help.stdout.contains("merge") && help.stdout.contains("compile"))
    }
}

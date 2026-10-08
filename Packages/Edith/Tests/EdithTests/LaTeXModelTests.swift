import AppKit
import Foundation
import SwiftUI
import Testing
import WebKit

@testable import Edith
@testable import EdithKit

@MainActor @Suite(.serialized) struct LaTeXModelTests {
    @Test func selectionKeepsUnsavedEditsAndRemovalKeepsSource() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("paper.tex")
        try Data("original".utf8).write(to: file)
        let store = LaTeXProjectStore(url: root.appendingPathComponent("projects.json"))
        let model = LaTeXModel(store: store)
        await model.start()
        try await model.add(LaTeXProject(name: "Paper", location: .disk, sourcePath: file.path))
        let id = try #require(model.selectedID)
        model.source = "edited"
        await model.select(UUID())
        model.remove()
        #expect(model.selectedID == id)
        #expect(model.source == "edited")
        #expect(model.projects.count == 1)
        model.discard()
        model.remove()
        #expect(model.projects.isEmpty)
        #expect(try String(contentsOf: file, encoding: .utf8) == "original")
    }

    @Test func addRejectsMissingAndDuplicateFiles() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = LaTeXModel(
            store: LaTeXProjectStore(url: root.appendingPathComponent("projects.json")))
        let file = root.appendingPathComponent("paper.tex")
        let project = LaTeXProject(name: "Paper", location: .disk, sourcePath: file.path)
        await #expect(throws: (any Error).self) { try await model.add(project) }
        #expect(model.projects.isEmpty)
        try Data("document".utf8).write(to: file)
        try await model.add(project)
        await #expect(throws: LaTeXError.self) { try await model.add(project) }
        #expect(model.projects.count == 1)
    }

    @Test func localAndRepositoryWorkspacesRenderAtDifferentSizes() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("paper.tex")
        try Data(Self.sample.utf8).write(to: file)
        let model = LaTeXModel(
            store: LaTeXProjectStore(url: root.appendingPathComponent("projects.json")))
        try await model.add(
            LaTeXProject(name: "Research paper", location: .disk, sourcePath: file.path))
        let scale = UIScale.current
        defer { UIScale.apply(scale) }
        for compact in [false, true] {
            UIScale.apply(compact ? 1.3 : 1)
            for scheme in [ColorScheme.light, .dark] {
                let size = CGSize(width: compact ? 600 : 1100, height: 800)
                let host = try auditHost(
                    LaTeXPage(model: model, opensEditor: true).environment(\.compactLayout, compact)
                        .environment(
                            \.colorScheme, scheme), size: size)
                let text = try auditText(host)
                #expect(text.contains("Save"))
                #expect(text.contains("paper.tex"))
                try capture(host, name: "latex-local-\(compact)-\(scheme)")
            }
        }
        let library = try auditHost(LaTeXPage(model: model), size: CGSize(width: 1100, height: 800))
        let libraryText = try auditText(library)
        #expect(libraryText.contains("Open editor"))
        #expect(!libraryText.contains("Save & compile"))
        try capture(library, name: "latex-library")
        let service = LaTeXService { _, args, _, _ in
            if args.contains(where: { $0.contains("git/ref") }) {
                return Data(#"{"object":{"sha":"commit-1"}}"#.utf8)
            }
            let data: [String: String] = [
                "type": "file", "encoding": "base64",
                "content": Data(Self.sample.utf8).base64EncodedString(), "sha": "blob-1",
            ]
            return try JSONEncoder().encode(data)
        }
        let repoModel = LaTeXModel(
            service: service,
            store: LaTeXProjectStore(url: root.appendingPathComponent("repo-projects.json")))
        try await repoModel.add(
            LaTeXProject(
                name: "Research paper", location: .github, sourcePath: "papers/main.tex",
                repository: "northstar/research", baseBranch: "main"))
        let host = try auditHost(
            LaTeXPage(model: repoModel, opensEditor: true), size: CGSize(width: 1100, height: 800))
        let text = try auditText(host)
        #expect(text.contains("Create pull request"))
        #expect(text.contains("GitHub build"))
        #expect(!text.contains("Save & compile"))
        try capture(host, name: "latex-repository")
    }

    @Test func bundledEditorPreservesHistorySelectionSearchAndSave() async throws {
        var text = Self.sample
        var saves = 0
        let controls = LaTeXEditorControls()
        let host = try auditHost(
            LaTeXSourceEditor(
                text: Binding(get: { text }, set: { text = $0 }), controls: controls, dark: true,
                editable: true, onSave: { saves += 1 }), size: CGSize(width: 700, height: 500))
        let window = TestWindowHost.window(contentRect: host.bounds)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        let view = try #require(controls.webView)
        try await waitForEditor(controls)
        #expect(!controls.canUndo)
        let colored =
            try await view.callAsyncJavaScript(
                "return document.querySelectorAll('.cm-line span').length > 0",
                arguments: [:], in: nil, contentWorld: .page) as? Bool
        #expect(colored == true)
        _ = try await view.callAsyncJavaScript(
            "window.edithEditor.command('focus'); document.execCommand('insertText', false, inserted)",
            arguments: ["inserted": "Added "], in: nil, contentWorld: .page)
        try await Task.sleep(for: .milliseconds(300))
        #expect(text.hasPrefix("Added "))
        #expect(controls.canUndo)
        #expect(controls.column == 7)
        _ = try await view.callAsyncJavaScript(
            "for (const character of input) { document.execCommand('insertText', false, character); await new Promise(resolve => setTimeout(resolve, 5)); }",
            arguments: ["input": "rapid typing "], in: nil, contentWorld: .page)
        try await Task.sleep(for: .milliseconds(200))
        #expect(text.hasPrefix("Added rapid typing "))
        let edited = text
        controls.fontSize = 16
        controls.wrapsLines = false
        try await Task.sleep(for: .milliseconds(200))
        controls.undo()
        try await Task.sleep(for: .milliseconds(200))
        #expect(text != edited)
        #expect(text.hasSuffix(Self.sample))
        #expect(controls.canRedo)
        controls.redo()
        try await Task.sleep(for: .milliseconds(200))
        #expect(text == edited)
        controls.find()
        try await Task.sleep(for: .milliseconds(200))
        let finding =
            try await view.callAsyncJavaScript(
                "return document.querySelector('.cm-search input[name=search]') !== null",
                arguments: [:], in: nil, contentWorld: .page) as? Bool
        #expect(finding == true)
        _ = try await view.callAsyncJavaScript(
            "window.edithEditor.command('closeFind'); window.edithEditor.command('focus'); document.querySelector('.cm-content').dispatchEvent(new KeyboardEvent('keydown', {key:'s', code:'KeyS', metaKey:true, bubbles:true, cancelable:true}))",
            arguments: [:], in: nil, contentWorld: .page)
        try await Task.sleep(for: .milliseconds(200))
        #expect(saves == 1)
    }

    @Test func nativeSaveRecompilesAnUnchangedRepositoryAndLoadsPDF() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = LaTeXProject(
            name: "Paper", location: .github, sourcePath: "main.tex",
            repository: "northstar/paper", baseBranch: "main", reviewBranch: "latex/paper",
            pullRequest: 42)
        let calls = LaTeXBuildCalls()
        let service = LaTeXService { tool, args, _, directory in
            #expect(directory == nil)
            if tool == "pukbot" {
                #expect(
                    args == ["workflow", "rerun", "--repo", project.repository, "72", "--json"])
                await calls.record()
                return Data()
            }
            if args.contains(where: { $0.contains("git/ref") }) {
                return Data(#"{"object":{"sha":"current"}}"#.utf8)
            }
            if args.contains("view") {
                return Data(
                    #"{"number":42,"title":"Paper","state":"OPEN","url":"https://github.com/northstar/paper/pull/42","headRefOid":"current","mergeable":"MERGEABLE","statusCheckRollup":[]}"#
                        .utf8)
            }
            if args.contains("diff") { return Data() }
            if args.contains(where: { $0.contains("/contents/") }) {
                return Data(
                    #"{"type":"file","encoding":"base64","content":"SGVsbG8=","sha":"blob"}"#.utf8)
            }
            if args.contains(where: { $0.hasSuffix("/runs") }) {
                return Data(
                    "{\"workflow_runs\":[{\"id\":72,\"path\":\"\(project.workflowPath)\",\"html_url\":\"https://github.com/northstar/paper/actions/runs/72\",\"status\":\"completed\",\"conclusion\":\"success\"}]}"
                        .utf8)
            }
            if args.contains(where: { $0.hasSuffix("/zip") }) {
                return Data(
                    base64Encoded:
                        "UEsDBBQAAAAIAK0bSF1BbHXDIgAAACAAAAAIAAAAbWFpbi5wZGZTDXBx0zXUM+cqrswryUgtyUzWLShKLctMLedSVXX1dwMAUEsBAhQDFAAAAAgArRtIXUFsdcMiAAAAIAAAAAgAAAAAAAAAAAAAAIABAAAAAG1haW4ucGRmUEsFBgAAAAABAAEANgAAAEgAAAAAAA=="
                )!
            }
            return Data(
                #"{"artifacts":[{"id":2,"expired":false,"size_in_bytes":100,"workflow_run":{"id":72,"head_sha":"current"}}]}"#
                    .utf8)
        }
        let store = LaTeXProjectStore(url: root.appendingPathComponent("projects.json"))
        try store.save([project])
        let model = LaTeXModel(service: service, store: store)
        await model.start()
        await model.select(project.id)
        #expect(!model.dirty && model.canSubmit)
        #expect(model.pdfPreview != nil)
        let host = try auditHost(
            LaTeXPage(model: model, opensEditor: true), size: CGSize(width: 1100, height: 800))
        let window = TestWindowHost.window(contentRect: host.bounds)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        try await waitForEditor(model.editorControls)
        let view = try #require(model.editorControls.webView)
        let event = try #require(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero,
                modifierFlags: .command, timestamp: 0, windowNumber: window.windowNumber,
                context: nil, characters: "s", charactersIgnoringModifiers: "s", isARepeat: false,
                keyCode: 1))
        view.keyDown(with: event)
        for _ in 0..<50 {
            if model.message == "PDF compiled on GitHub." { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(await calls.count == 1)
        #expect(model.message == "PDF compiled on GitHub.")
        #expect(!model.busy && !model.buildingPDF && !model.dirty)
        #expect(model.pdfPreview == Data("%PDF-1.7\nsynthetic-preview\n%%EOF".utf8))
        #expect(try store.load() == [project])
    }

    @Test func typingKeepsWorkspaceAndWrappedViewportStable() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("paper.tex")
        try Data(Self.sample.utf8).write(to: file)
        let model = LaTeXModel(
            store: LaTeXProjectStore(url: root.appendingPathComponent("projects.json")))
        try await model.add(
            LaTeXProject(name: "Research paper", location: .disk, sourcePath: file.path))
        let host = try auditHost(
            LaTeXPage(model: model, opensEditor: true), size: CGSize(width: 1100, height: 800))
        func editor(in view: NSView) -> WKWebView? {
            if let text = view as? WKWebView { return text }
            return view.subviews.lazy.compactMap { editor(in: $0) }.first
        }
        let view = try #require(editor(in: host))
        let window = TestWindowHost.window(contentRect: host.bounds)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        for _ in 0..<50 {
            if (try? await view.callAsyncJavaScript(
                "return document.querySelector('.cm-content') !== null", arguments: [:], in: nil,
                contentWorld: .page) as? Bool) == true
            {
                break
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        host.layoutSubtreeIfNeeded()
        let before = view.convert(view.bounds, to: host)
        let wrapWidth =
            try await view.callAsyncJavaScript(
                "return document.querySelector('.cm-content').clientWidth", arguments: [:], in: nil,
                contentWorld: .page) as? Double
        _ = try await view.callAsyncJavaScript(
            "window.edithEditor.command('focus'); document.execCommand('insertText', false, 'Updated ')",
            arguments: [:], in: nil, contentWorld: .page)
        try await Task.sleep(for: .milliseconds(300))
        host.layoutSubtreeIfNeeded()
        #expect(before == view.convert(view.bounds, to: host))
        let afterWidth =
            try await view.callAsyncJavaScript(
                "return document.querySelector('.cm-content').clientWidth", arguments: [:], in: nil,
                contentWorld: .page) as? Double
        #expect(wrapWidth == afterWidth)
        #expect(model.source.hasPrefix("Updated "))
        #expect(model.dirty)
    }

    @Test func editorReattachmentKeepsDraftSelectionAndHistory() async throws {
        var text = Self.sample
        let controls = LaTeXEditorControls()
        func content() -> LaTeXSourceEditor {
            LaTeXSourceEditor(
                text: Binding(get: { text }, set: { text = $0 }), controls: controls,
                dark: false, editable: true, documentID: "paper")
        }
        var first: NSHostingView<AnyView>? = try auditHost(
            content(), size: CGSize(width: 700, height: 500))
        let window = TestWindowHost.window(contentRect: first!.bounds)
        window.isReleasedWhenClosed = false
        window.contentView = first
        defer { window.close() }
        try await waitForEditor(controls)
        let view = try #require(controls.webView)
        _ = try await view.callAsyncJavaScript(
            "window.edithEditor.command('focus'); document.execCommand('insertText', false, 'Draft ')",
            arguments: [:], in: nil, contentWorld: .page)
        try await Task.sleep(for: .milliseconds(200))
        #expect(text.hasPrefix("Draft "))
        let column = controls.column
        window.contentView = nil
        first = nil
        try await Task.sleep(for: .milliseconds(100))
        let second = try auditHost(content(), size: CGSize(width: 900, height: 500))
        window.contentView = second
        try await Task.sleep(for: .milliseconds(200))
        #expect(controls.webView === view)
        #expect(controls.column == column)
        #expect(controls.canUndo)
        controls.undo()
        try await Task.sleep(for: .milliseconds(200))
        #expect(text == Self.sample)
    }

    @Test func longSourceScrollsInsideItsWorkspace() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = (1...250).map {
            "\\section{Section \($0)} " + String(repeating: "paper ", count: 100)
        }.joined(separator: "\n")
        let file = root.appendingPathComponent("paper.tex")
        try Data(source.utf8).write(to: file)
        let model = LaTeXModel(
            store: LaTeXProjectStore(url: root.appendingPathComponent("projects.json")))
        try await model.add(LaTeXProject(name: "Paper", location: .disk, sourcePath: file.path))
        let controls = model.editorControls
        controls.wrapsLines = false
        let host = try auditHost(
            LaTeXPage(model: model, opensEditor: true), size: CGSize(width: 1100, height: 800))
        let window = TestWindowHost.window(contentRect: host.bounds)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.close() }
        try await waitForEditor(controls)
        try await Task.sleep(for: .milliseconds(200))
        let view = try #require(controls.webView)
        let point = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        let cgEvent = try #require(
            CGEvent(
                scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: -700,
                wheel2: -120, wheel3: 0))
        let wheel = try #require(NSEvent(cgEvent: cgEvent))
        let encoded = try NSKeyedArchiver.archivedData(
            withRootObject: wheel, requiringSecureCoding: false)
        let decoder = try NSKeyedUnarchiver(forReadingFrom: encoded)
        decoder.requiresSecureCoding = false
        decoder.setClass(EditorWheelEvent.self, forClassName: NSStringFromClass(type(of: wheel)))
        let event = try #require(
            decoder.decodeObject(forKey: NSKeyedArchiveRootObjectKey) as? EditorWheelEvent)
        event.target = window
        event.point = point
        event.number = window.windowNumber
        NSApp.sendEvent(event)
        try await Task.sleep(for: .milliseconds(300))
        let result =
            try await view.callAsyncJavaScript(
                "const s = document.querySelector('.cm-scroller'); return {height:s.clientHeight, content:s.scrollHeight, top:s.scrollTop, left:s.scrollLeft, page:document.documentElement.scrollTop};",
                arguments: [:], in: nil, contentWorld: .page) as? [String: Double]
        let metrics = try #require(result)
        #expect(metrics["height"]! <= 800)
        #expect(metrics["content"]! > metrics["height"]!)
        #expect(metrics["top"]! > 0)
        #expect(metrics["page"] == 0)
        #expect(model.source == source)
        #expect(!model.dirty)
        #expect(controls.line == 1)
        #expect(metrics["left"]! > 0)
        if let path = ProcessInfo.processInfo.environment["EDITH_EXTENSION_EVIDENCE_DIR"] {
            let configuration = WKSnapshotConfiguration()
            configuration.afterScreenUpdates = false
            let image = try await view.takeSnapshot(configuration: configuration)
            let tiff = try #require(image.tiffRepresentation)
            let bitmap = try #require(NSBitmapImageRep(data: tiff))
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
            try png.write(
                to: URL(fileURLWithPath: path).appendingPathComponent("latex-scrolled-source.png"))
        }
    }

    @objc(EdithEditorWheelEvent) private final class EditorWheelEvent: NSEvent {
        var target: NSWindow?
        var point = NSPoint.zero
        var number = 0
        required init?(coder: NSCoder) { super.init(coder: coder) }
        override var window: NSWindow? { target }
        override var windowNumber: Int { number }
        override var locationInWindow: NSPoint { point }
    }

    private func waitForEditor(_ controls: LaTeXEditorControls) async throws {
        for _ in 0..<50 {
            if controls.ready { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(controls.ready)
    }

    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func capture(_ host: NSHostingView<AnyView>, name: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["EDITH_EXTENSION_EVIDENCE_DIR"]
        else { return }
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        let root = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try png.write(to: root.appendingPathComponent("\(name).png"))
    }

    nonisolated private static let sample = #"""
        \documentclass{article}
        \title{A Small Guide to Big Ideas}
        \author{Northstar Research}
        \begin{document}
        \maketitle
        \section{A clear starting point}
        Every useful document begins with a simple idea.
        \end{document}
        """#
}

private actor LaTeXBuildCalls {
    var count = 0
    func record() { count += 1 }
}

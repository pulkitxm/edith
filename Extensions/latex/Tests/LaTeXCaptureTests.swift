import AppKit
import EdithExtensionUI
import SwiftUI
import Testing
@testable import LaTeXExtension

@MainActor @Suite(.serialized) struct LaTeXCaptureTests {
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "latex-capture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func store(_ root: URL) -> LaTeXProjectStore {
        LaTeXProjectStore(url: root.appendingPathComponent("projects.json"))
    }

    @Test func libraryStatesRenderEveryVariant() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let paper = root.appendingPathComponent("paper.tex")
        let notes = root.appendingPathComponent("lecture-notes.tex")
        try Data("\\documentclass{article}".utf8).write(to: paper)
        try Data("\\documentclass{book}".utf8).write(to: notes)
        let populated = LaTeXModel(store: store(root))
        try await populated.add(
            LaTeXProject(name: "Research paper", location: .disk, sourcePath: paper.path))
        try await populated.add(
            LaTeXProject(name: "Lecture notes", location: .disk, sourcePath: notes.path))
        for variant in LaTeXRenderCapture.variants {
            let empty = LaTeXModel(
                store: store(root.appendingPathComponent(UUID().uuidString)))
            await empty.start()
            try await LaTeXRenderCapture.render("latex-first-run", variant: variant) {
                LaTeXPage(model: empty)
            }
            let loading = LaTeXModel(
                store: store(root.appendingPathComponent(UUID().uuidString)))
            _ = loading.load.begin()
            try await LaTeXRenderCapture.render("latex-loading", variant: variant) {
                LaTeXPage(model: loading)
            }
            let failing = LaTeXModel(
                store: store(root.appendingPathComponent(UUID().uuidString)))
            let request = failing.load.begin()
            failing.load.fail(request, message: "Your LaTeX library could not be read.")
            try await LaTeXRenderCapture.render("latex-error", variant: variant) {
                LaTeXPage(model: failing)
            }
            let bitmap = try await LaTeXRenderCapture.render(
                "latex-library", variant: variant
            ) {
                LaTeXPage(model: populated)
            }
            #expect(LaTeXRenderCapture.distinctColors(bitmap) > 3)
        }
    }

    @Test func workspaceAndAddSheetRender() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let paper = root.appendingPathComponent("paper.tex")
        try Data("\\documentclass{article}".utf8).write(to: paper)
        let model = LaTeXModel(store: store(root))
        try await model.add(
            LaTeXProject(name: "Research paper", location: .disk, sourcePath: paper.path))
        for variant in LaTeXRenderCapture.variants {
            try await LaTeXRenderCapture.render(
                "latex-workspace", variant: variant, settle: .milliseconds(800)
            ) {
                LaTeXPage(model: model, opensEditor: true)
            }
        }
        for variant in [LaTeXRenderCapture.variants[0], LaTeXRenderCapture.variants[3]] {
            let sheet = LaTeXRenderCapture.Variant(
                name: variant.name, width: 520, height: 580, zoom: 1, scheme: variant.scheme)
            try await LaTeXRenderCapture.render("latex-add", variant: sheet) {
                LaTeXAddProject(model: model, onAdded: {})
            }
        }
    }
}

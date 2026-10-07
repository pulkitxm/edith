import AppKit
import Foundation
import SwiftUI
import Testing

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
                #expect(text.contains("Source"))
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

    private static let sample = #"""
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

import Foundation
@testable import EdithDocsWorker

enum DocsJevFixture {
    static let library = DocsLibrary(sources: [
        DocsSource(
            path: "extensions/enable.md",
            markdown: "# `ed extensions enable`\n\nEnable an extension."),
        DocsSource(
            path: "extensions/disable.md",
            markdown: "# `ed extensions disable`\n\nDisable an extension."),
        DocsSource(
            path: "invoke/inspect.md",
            markdown: "# `ed invoke synthetic inspect`\n\nInspect a synthetic worker fixture."),
        DocsSource(
            path: "invoke/reset.md",
            markdown: "# `ed invoke synthetic reset`\n\nReset a synthetic worker fixture."),
    ])

    static func decision(_ name: String, _ probabilities: [String: Double]) -> JevDecision {
        let best = probabilities.max { $0.value < $1.value }!.key
        return JevDecision(
            response: JevResponse(
                model: "jev-latest",
                answers: [
                    name: JevAnswer(type: "choice", choice: best, probabilities: probabilities)
                ]), milliseconds: 50)
    }
}

enum CLIDocs {
    static let directory: URL = {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        return root.appendingPathComponent("docs/cli")
    }()

    static func pages() throws -> [String: String] {
        let names =
            FileManager.default.enumerator(atPath: directory.path)?
            .compactMap { $0 as? String }.filter { $0.hasSuffix(".md") } ?? []
        var loaded: [String: String] = [:]
        for name in names {
            loaded[name] = try String(
                contentsOf: directory.appendingPathComponent(name), encoding: .utf8
            )
            .replacingOccurrences(of: "\u{2014}", with: ",")
        }
        return loaded
    }
}

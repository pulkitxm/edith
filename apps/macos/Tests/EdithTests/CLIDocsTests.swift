import Foundation
import Testing

@testable import EdithCLI

enum CLIDocs {
    static let hidden: Set<String> = ["ed __complete"]

    static let directory: URL = {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("docs/cli")
    }()

    static func pages() throws -> [String: String] {
        let names =
            FileManager.default.enumerator(atPath: directory.path)?
            .compactMap { $0 as? String }.filter { $0.hasSuffix(".md") } ?? []
        var loaded: [String: String] = [:]
        for name in names {
            loaded[name] = try String(
                contentsOf: directory.appendingPathComponent(name), encoding: .utf8)
        }
        return loaded
    }

    static func groups(_ pages: [String: String]) -> [String] {
        Set(pages.keys.compactMap { $0.contains("/") ? String($0.split(separator: "/")[0]) : nil })
            .sorted()
    }

    static func resolve(_ link: String, from page: String) -> String {
        var parts = page.split(separator: "/").dropLast().map(String.init)
        for piece in link.split(separator: "/").map(String.init) {
            if piece == "." { continue }
            if piece == ".." {
                if !parts.isEmpty { parts.removeLast() }
                continue
            }
            parts.append(piece)
        }
        return parts.joined(separator: "/")
    }

    static func paths(_ node: CommandNode, prefix: [String] = []) -> [String] {
        let here = prefix + [node.name]
        let label = here.joined(separator: " ")
        guard !node.children.isEmpty else { return [label] }
        return [label] + node.children.flatMap { paths($0, prefix: here) }
    }

    static func mentions(_ text: String, _ command: String) -> Bool {
        var searched = text[...]
        while let found = searched.range(of: command) {
            let after = found.upperBound
            if after == searched.endIndex { return true }
            let next = searched[after]
            if !next.isLetter && !next.isNumber && next != "-" { return true }
            searched = searched[after...]
        }
        return false
    }
}

struct CLIDocsTests {
    @Test func everyCommandInTheTreeIsDocumented() throws {
        let pages = try CLIDocs.pages()
        #expect(!pages.isEmpty, "docs/cli has no pages, so this test proves nothing")
        let text = pages.values.joined(separator: "\n")
        let commands = CLIDocs.paths(CommandTree.root).filter { !CLIDocs.hidden.contains($0) }
        #expect(commands.count > 100, "the command tree looks truncated: \(commands.count)")
        let undocumented = commands.filter { !CLIDocs.mentions(text, $0) }
        #expect(
            undocumented.isEmpty,
            "these commands have no page in docs/cli: \(undocumented.sorted())")
    }

    @Test func everyGroupIsListedInTheIndex() throws {
        let pages = try CLIDocs.pages()
        let index = try #require(pages["README.md"], "docs/cli/README.md is missing")
        let flat = pages.keys.filter { !$0.contains("/") && $0 != "README.md" }
        let unlisted =
            CLIDocs.groups(pages).filter { !index.contains("(./\($0)/README.md)") }
            + flat.filter { !index.contains("(./\($0))") }
        #expect(
            unlisted.isEmpty,
            "these are not linked from docs/cli/README.md: \(unlisted.sorted())")
    }

    @Test func everyCommandPageIsListedByItsGroup() throws {
        let pages = try CLIDocs.pages()
        var unlisted: [String] = []
        for (name, _) in pages where name.contains("/") {
            let parts = name.split(separator: "/")
            guard parts.count == 2, parts[1] != "README.md" else { continue }
            let readme = pages["\(parts[0])/README.md"]
            if readme?.contains("(./\(parts[1]))") != true { unlisted.append(name) }
        }
        #expect(
            unlisted.isEmpty,
            "these pages are not linked from their group README: \(unlisted.sorted())")
    }

    @Test func everyPageLinksBackToItsIndex() throws {
        let pages = try CLIDocs.pages()
        let orphans =
            pages
            .filter { name, text in
                guard name != "README.md" else { return false }
                let back = name.contains("/") ? "(../README.md)" : "(./README.md)"
                return !text.contains(back)
            }
            .keys
        #expect(
            orphans.isEmpty,
            "these pages never link back up to an index: \(orphans.sorted())")
    }

    @Test func everyRelativeLinkResolves() throws {
        let pages = try CLIDocs.pages()
        var broken: [String] = []
        let pattern = try NSRegularExpression(pattern: #"\]\((\.{1,2}/[^)#\s]+\.md)"#)
        for (name, text) in pages {
            let range = NSRange(text.startIndex..., in: text)
            for match in pattern.matches(in: text, range: range) {
                guard let found = Range(match.range(at: 1), in: text) else { continue }
                let link = String(text[found])
                if pages[CLIDocs.resolve(link, from: name)] == nil {
                    broken.append("\(name) -> \(link)")
                }
            }
        }
        #expect(broken.isEmpty, "these relative links point at nothing: \(broken.sorted())")
    }

    @Test func everyPageOpensWithATitle() throws {
        for (name, text) in try CLIDocs.pages() {
            let first = text.split(separator: "\n", omittingEmptySubsequences: true).first ?? ""
            #expect(first.hasPrefix("# "), "\(name) does not open with an H1")
        }
    }
}

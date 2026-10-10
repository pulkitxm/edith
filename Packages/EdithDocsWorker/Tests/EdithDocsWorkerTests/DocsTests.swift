import Foundation
import Testing

@testable import EdithDocsWorker

enum DocsFixture {
    static let library: DocsLibrary = DocsLibrary.bundled()!

}

@Suite struct DocsLibraryTests {
    @Test func bundleCoversEveryFileInDocsCLI() throws {
        let files = try CLIDocs.pages()
        let library = try #require(DocsLibrary.bundled())
        #expect(Set(library.pages.map(\.path)) == Set(files.keys))
        for page in library.pages {
            #expect(page.markdown == files[page.path], "\(page.path) is stale in the bundle")
        }
        #expect(library.groups.first?.id == "")
        #expect(library.groups.flatMap(\.pages).count == library.pages.count)
    }

    @Test func parsesHeadingsAnchorsTablesCodeListsAndLinks() {
        let page = DocsParser.page(
            path: "extensions/ls.md",
            markdown: """
                # `ed extensions ls`

                Lists **live** panes with *care* and `--json`, see [the group](./README.md#notes) \
                or [TypeSafe](https://typesafe.ai).

                ## Options

                | Name | Default |
                | :--- | ---: |
                | `--machine <name>` | all hosts |

                ```json
                {"hosts": []}
                ```

                1. First
                   - nested one
                   - nested two
                2. Second

                ## Options

                ---
                """)
        #expect(page.title == "ed extensions ls")
        #expect(page.command == "ed extensions ls")
        #expect(page.headings.map(\.anchor) == ["ed-extensions-ls", "options", "options-1"])
        #expect(page.outline.count == 2)
        guard case .paragraph(let spans) = page.blocks[1] else {
            Issue.record("the abstract is not a paragraph")
            return
        }
        #expect(spans.contains { $0.text == "live" && $0.style == .strong })
        #expect(spans.contains { $0.text == "care" && $0.style == .emphasis })
        #expect(spans.contains { $0.text == "--json" && $0.style == .code })
        #expect(spans.contains { $0.link == .page(path: "extensions/README.md", anchor: "notes") })
        #expect(spans.contains { $0.link == .external(URL(string: "https://typesafe.ai")!) })
        guard case .table(let table) = page.blocks[3] else {
            Issue.record("the options table did not parse")
            return
        }
        #expect(table.alignments == [.leading, .trailing])
        #expect(table.header.map(DocsSpan.plain) == ["Name", "Default"])
        #expect(
            table.rows.first.map { $0.map(DocsSpan.plain) } == ["--machine <name>", "all hosts"])
        #expect(page.blocks[4] == .code(language: "json", text: #"{"hosts": []}"#))
        guard case .list(let list) = page.blocks[5] else {
            Issue.record("the ordered list did not parse")
            return
        }
        #expect(list.ordered && list.items.count == 2)
        guard case .list(let nested) = list.items[0].last else {
            Issue.record("the nested list did not parse")
            return
        }
        #expect(nested.items.count == 2 && !nested.ordered)
        #expect(page.blocks.last == .rule)
    }

    @Test func dashesStayLiteralOutsideCode() {
        let page = DocsParser.page(path: "a.md", markdown: "# A\n\nPass --yes -- then 'quote'.")
        #expect(page.abstract == "Pass --yes -- then 'quote'.")
    }

    @Test func everyBundledCommandResolvesToADocumentedSection() throws {
        let library = DocsFixture.library
        let leaves = library.commands.map(\.path)
        #expect(
            Set(leaves)
                == Set([
                    "ed extensions", "ed extensions ls", "ed extensions info",
                    "ed extensions install",
                    "ed extensions update", "ed extensions enable", "ed extensions disable",
                    "ed extensions remove", "ed invoke",
                ]))
        for leaf in leaves {
            let location = try #require(library.location(forCommand: leaf), "\(leaf) has no page")
            let page = try #require(library.page(location.path), "\(leaf) points at no page")
            if let anchor = location.anchor {
                #expect(page.headings.contains { $0.anchor == anchor }, "\(leaf) has a dead anchor")
            }
            #expect(
                page.command == leaf || DocsCommandText.mentions(page.markdown, leaf),
                "\(leaf) lands on \(page.path), which never mentions it")
        }
    }

    @Test func commandsResolveToTheirOwnSections() {
        let library = DocsFixture.library
        #expect(
            library.location(forCommand: "ed extensions ls")
                == DocsLocation(path: "extensions/ls.md"))
        #expect(
            library.location(forCommand: "extensions ls") == DocsLocation(path: "extensions/ls.md"))
        #expect(
            library.location(forCommand: "ed extensions enable")
                == DocsLocation(path: "extensions/enable.md"))
        #expect(library.location(forCommand: "ed invoke") == DocsLocation(path: "invoke/README.md"))
        #expect(library.lookup("extensions/ls") == DocsLocation(path: "extensions/ls.md"))
        #expect(library.lookup("extensions") == DocsLocation(path: "extensions/README.md"))
        #expect(library.lookup("nothing at all") == nil)
    }

    @Test func relativeLinksResolveToBundledPages() {
        let library = DocsFixture.library
        var broken: [String] = []
        for page in library.pages {
            for span in page.blocks.flatMap(Self.spans) {
                guard case .page(let path, let anchor) = span.link else { continue }
                guard let target = library.page(path) else {
                    broken.append("\(page.path) -> \(path)")
                    continue
                }
                if let anchor, !target.headings.contains(where: { $0.anchor == anchor }) {
                    broken.append("\(page.path) -> \(path)#\(anchor)")
                }
            }
        }
        #expect(broken.isEmpty, "\(broken)")
    }

    static func spans(_ block: DocsBlock) -> [DocsSpan] {
        switch block {
        case .heading(let heading): heading.spans
        case .paragraph(let spans): spans
        case .list(let list): list.items.flatMap { $0.flatMap(spans) }
        case .table(let table): (table.header + table.rows.flatMap { $0 }).flatMap { $0 }
        case .quote(let blocks): blocks.flatMap(spans)
        case .code, .rule: []
        }
    }
}

@Suite struct DocsAskTests {
    static let cases: [(String, String)] = [
        ("list extensions", "ed extensions ls"),
        ("inspect extension info", "ed extensions info"),
        ("install an extension", "ed extensions install"),
        ("update an extension", "ed extensions update"),
        ("enable an extension", "ed extensions enable"),
        ("disable an extension", "ed extensions disable"),
        ("remove an extension", "ed extensions remove"),
        ("invoke a worker operation", "ed invoke"),
    ]

    @Test(arguments: cases) func lexicalRankerFindsTheCommand(_ request: String, _ expected: String)
        async
    {
        let answer = await DocsAsk.answer(
            request, in: DocsFixture.library, decider: nil,
            defaults: UserDefaults(suiteName: "test.docs.\(UUID().uuidString)")!)
        #expect(answer.engine == .search)
        #expect(
            answer.picks.first?.command.path == expected,
            "\(request) -> \(answer.picks.prefix(3).map { "\($0.command.path) \($0.probability)" })"
        )
    }
}

@Suite struct DocsJevTests {
    final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var value: Int { lock.withLock { count } }
        func add() { lock.withLock { count += 1 } }
    }

    struct Decider: JevDeciding {
        let calls: Calls
        let answer: @Sendable (JevRequest) throws -> JevDecision

        func decide(_ request: JevRequest, purpose: String) async throws -> JevDecision {
            calls.add()
            #expect(purpose == DocsAsk.purpose)
            return try answer(request)
        }
    }

    static func defaults(configured: Bool) -> UserDefaults {
        let defaults = UserDefaults(suiteName: "test.docs.\(UUID().uuidString)")!
        JevAvailability.record(configured: configured, in: defaults)
        return defaults
    }

    static func gatewayDecider(_ calls: Calls, area: Double = 0.9) -> Decider {
        Decider(calls: calls) { request in
            if request.questions["area"] != nil {
                return DocsJevFixture.decision(
                    "area", ["extensions": area, "invoke": min(area, 1 - area)])
            }
            guard case .fields(let state) = request.state, state["area"] == "extensions" else {
                return DocsJevFixture.decision(
                    "command", ["invoke synthetic inspect": 0.6, "invoke synthetic reset": 0.4])
            }
            return DocsJevFixture.decision(
                "command", ["extensions enable": 0.8, "extensions disable": 0.2])
        }
    }

    @Test func jevCombinesAreaAndCommandProbabilities() async {
        let calls = Calls()
        let answer = await DocsAsk.answer(
            "activate an extension", in: DocsJevFixture.library,
            decider: Self.gatewayDecider(calls),
            defaults: Self.defaults(configured: true))
        #expect(answer.engine == .jev)
        #expect(answer.picks.first?.command.path == "ed extensions enable")
        #expect(abs((answer.picks.first?.probability ?? 0) - 0.72) < 0.0001)
        #expect(answer.picks.first?.command.location == DocsLocation(path: "extensions/enable.md"))
        #expect(calls.value == 3)
    }

    @Test func jevErrorsFallBackToSearch() async {
        let calls = Calls()
        let failing = Decider(calls: calls) { _ in throw JevError.noCredits("no credits") }
        let answer = await DocsAsk.answer(
            "enable an extension", in: DocsJevFixture.library, decider: failing,
            defaults: Self.defaults(configured: true))
        #expect(calls.value == 1)
        #expect(answer.engine == .search)
        #expect(answer.picks.first?.command.path == "ed extensions enable")
    }

    @Test func unsureJevFallsBackToSearch() async {
        let answer = await DocsAsk.answer(
            "enable an extension", in: DocsJevFixture.library,
            decider: Self.gatewayDecider(Calls(), area: 0.1),
            defaults: Self.defaults(configured: true))
        #expect(answer.engine == .search)
        #expect(answer.picks.first?.command.path == "ed extensions enable")
    }

    @Test func noKeyMakesNoJevCall() async {
        let calls = Calls()
        let answer = await DocsAsk.answer(
            "enable an extension", in: DocsJevFixture.library, decider: Self.gatewayDecider(calls),
            defaults: Self.defaults(configured: false))
        #expect(calls.value == 0)
        #expect(answer.engine == .search)
        #expect(!JevAvailability.isConfigured(Self.defaults(configured: false)))
    }

    @Test func routeGroupsFitJevChoiceLimits() {
        let groups = DocsAsk.routeGroups(DocsFixture.library)
        #expect(groups.count >= 2 && groups.count <= JevQuestion.maximumOptions)
        #expect(groups.allSatisfy { $0.members.count <= JevQuestion.maximumOptions })
        #expect(
            groups.contains {
                $0.id == "extensions" && $0.members.contains { $0.id == "extensions enable" }
            })
    }

    @Test func routeGroupsOfferTheCommandsRatherThanTheGroupPage() {
        let groups = DocsAsk.routeGroups(DocsFixture.library)
        for group in groups where group.members.count > 1 {
            #expect(
                !group.members.contains { $0.id == group.id }, "\(group.id) offers its overview")
        }
        let routes = Set(groups.flatMap(\.members).map(\.id))
        let leaves = DocsFixture.library.commands.filter { command in
            command.route != command.area
                || !DocsFixture.library.commands.contains {
                    $0.area == command.area && $0.route != command.area
                }
        }
        #expect(routes == Set(leaves.map(\.route)))
    }
}

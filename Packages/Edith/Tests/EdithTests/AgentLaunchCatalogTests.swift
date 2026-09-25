import Foundation
import Testing

@testable import EdithKit

private final class FetchLog: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [(AgentLaunchKind, Bool)] = []
    private var now = Date(timeIntervalSince1970: 1_000)

    func record(_ kind: AgentLaunchKind, _ refresh: Bool) {
        lock.withLock { calls.append((kind, refresh)) }
    }

    var count: Int { lock.withLock { calls.count } }
    var lastRefresh: Bool? { lock.withLock { calls.last?.1 } }

    func advance(_ seconds: TimeInterval) { lock.withLock { now += seconds } }
    func date() -> Date { lock.withLock { now } }
}

@Suite struct AgentLaunchCatalogTests {
    static let codexJSON = """
        warning: ignored preamble
        {"fetched_at":"2026-09-01T00:00:00Z","models":[
          {"slug":"alpha-mini","display_name":"Alpha Mini","description":"Small model.",
           "visibility":"list","priority":2,"default_reasoning_level":"medium",
           "supported_reasoning_levels":[{"effort":"low","description":"Light"},
             {"effort":"medium","description":"Balanced"}],
           "service_tiers":[],"additional_speed_tiers":[]},
          {"slug":"alpha-hidden","display_name":"Hidden","visibility":"hide","priority":0},
          {"slug":"alpha-pro","display_name":"Alpha Pro","description":"Big model.",
           "visibility":"list","priority":1,"default_reasoning_level":"high",
           "supported_reasoning_levels":[{"effort":"low","description":"Light"},
             {"effort":"medium","description":"Balanced"},{"effort":"high","description":"Deep"}],
           "service_tiers":[{"id":"priority","name":"Fast","description":"2x speed, increased usage"}],
           "additional_speed_tiers":["fast"]},
          {"slug":"alpha-speedy","visibility":"list","additional_speed_tiers":["fast"]},
          {"display_name":"No slug","visibility":"list"}
        ]}
        """

    @Test func codexJSONKeepsListedModelsInPriorityOrder() throws {
        let models = AgentLaunchCatalogParser.codexModels(from: Self.codexJSON)
        #expect(models.map(\.id) == ["alpha-pro", "alpha-mini", "alpha-speedy"])
        let pro = try #require(models.first)
        #expect(pro.name == "Alpha Pro")
        #expect(pro.summary == "Big model.")
        #expect(pro.efforts.map(\.id) == ["low", "medium", "high"])
        #expect(pro.effort("high")?.summary == "Deep")
        #expect(pro.defaultEffort == "high")
        #expect(pro.fastSummary == "2x speed, increased usage")
        #expect(models[1].fastSummary == nil)
        #expect(models[2].name == "alpha-speedy")
        #expect(models[2].fastSummary == "Faster responses, uses more of your limit")
    }

    @Test func codexCatalogDerivesTheDefaultFromEveryListedModel() throws {
        let catalog = try #require(AgentLaunchCatalogParser.catalog(.codex, from: Self.codexJSON))
        #expect(catalog.source == .cli("codex"))
        #expect(catalog.source.label == "from codex")
        #expect(catalog.standard.efforts.isEmpty)
        #expect(catalog.standard.fastSummary == nil)
        #expect(catalog.model("alpha-pro").supportsFast)
        #expect(catalog.model("not-listed") == catalog.standard)
    }

    @Test func malformedCodexOutputFallsBack() {
        #expect(AgentLaunchCatalogParser.codexModels(from: "codex: command not found").isEmpty)
        #expect(AgentLaunchCatalogParser.codexModels(from: #"{"models": "nope"}"#).isEmpty)
        #expect(AgentLaunchCatalogParser.catalog(.codex, from: "{truncated") == nil)
    }

    @Test func opencodeLinesSurviveTerminalNoise() {
        let output =
            "\u{4}\u{8}\u{8}acme/model-one\r\nacme/model-one-fast\r\n\u{1B}[32mzeta/model-two\u{1B}[0m\r\n"
            + "Loading models...\r\nnot a model line\r\nacme/model-one\r\n"
        let models = AgentLaunchCatalogParser.opencodeModels(from: output)
        #expect(models.map(\.id) == ["acme/model-one", "acme/model-one-fast", "zeta/model-two"])
        #expect(models[0].name == "model-one")
        #expect(models[0].summary == "acme")
        #expect(models[1].summary == "Fast variant, acme")
        #expect(models.allSatisfy { $0.efforts.isEmpty && !$0.supportsFast })
    }

    @Test func opencodeCatalogListsModelsButCannotSelectAtLaunch() throws {
        let catalog = try #require(
            AgentLaunchCatalogParser.catalog(.opencode, from: "acme/model-one\n"))
        #expect(catalog.models.count == 1)
        #expect(!catalog.kind.selectsAtLaunch)
        #expect(catalog.kind.note != nil)
    }

    @Test func piTableRowsBecomeProviderQualifiedModels() {
        let output = """
            provider   model          context  max-out  thinking  images
            acme       reasoner-1     200K     64K      yes       yes
            acme       plain-1        128K     8K       no        no
            zeta       reasoner-2     1M       128K     yes       no
            No models matched
            """
        let models = AgentLaunchCatalogParser.piModels(from: output)
        #expect(models.map(\.id) == ["acme/reasoner-1", "acme/plain-1", "zeta/reasoner-2"])
        #expect(models[0].summary == "acme, 200K context")
        #expect(models[0].efforts.map(\.id) == AgentLaunchKind.piThinking.map(\.id))
        #expect(models[1].efforts.isEmpty)
    }

    @Test func cursorListDropsHeadersAndMarkers() {
        let output = """
            Available models

            auto - Auto  (current)
            model-alpha - Model Alpha
            model-beta-thinking - Model Beta - Thinking (default)
            bare-id

            Tip: use --model <id> (or /model <id> in interactive mode) to switch.
            """
        let models = AgentLaunchCatalogParser.cursorModels(from: output)
        #expect(models.map(\.id) == ["auto", "model-alpha", "model-beta-thinking", "bare-id"])
        #expect(models[0].name == "Auto")
        #expect(models[2].name == "Model Beta - Thinking")
        #expect(models[3].name == "bare-id")
    }

    @Test func builtInCatalogsCoverEveryKind() {
        for kind in AgentLaunchKind.allCases {
            #expect(kind.builtIn.source == .builtIn)
            #expect(kind.builtIn.source.label == "built in")
        }
        let claude = AgentLaunchKind.claude.builtIn
        #expect(
            Set(claude.models.map(\.id)).isSuperset(of: [
                "default", "best", "fable", "opus", "sonnet", "haiku", "sonnet[1m]", "opus[1m]",
                "fable[1m]", "opusplan", "claude-opus-5-5", "claude-haiku-4-5-20251001",
            ]))
        #expect(claude.model("opus").supportsFast)
        #expect(!claude.model("sonnet").supportsFast)
        #expect(claude.model("haiku").efforts.isEmpty)
        #expect(claude.standard.supportsFast)
        #expect(AgentLaunchKind.codex.builtIn.models.first?.id == "gpt-6-astra")
        #expect(AgentLaunchKind.codex.builtIn.standard.efforts.map(\.id).contains("xhigh"))
        #expect(AgentLaunchKind.pi.builtIn.standard.efforts.map(\.id).first == "off")
        #expect(
            AgentLaunchKind.gemini.builtIn.models.map(\.id) == [
                "auto", "pro", "flash", "flash-lite",
            ])
        #expect(AgentLaunchKind.amp.builtIn.models.map(\.id) == ["low", "medium", "high", "ultra"])
        #expect(AgentLaunchKind.opencode.builtIn.models.isEmpty)
    }

    @Test func kindsResolveFromDisplayNamesAndSlugs() {
        #expect(AgentLaunchKind(kind: "claude") == .claude)
        #expect(AgentLaunchKind(kind: "Claude Code") == .claude)
        #expect(AgentLaunchKind(kind: "cursor-agent") == .cursor)
        #expect(AgentLaunchKind(kind: "amp") == .amp)
        #expect(AgentLaunchKind(kind: "Copilot CLI") == nil)
    }

    @Test func pickerKeepsAStoredModelThatIsNoLongerListed() {
        let catalog = AgentLaunchKind.gemini.builtIn
        #expect(catalog.pickerModels(including: "pro").count == 4)
        #expect(catalog.pickerModels(including: "gemini-custom").last?.id == "gemini-custom")
        #expect(catalog.pickerModels(including: nil).count == 4)
    }

    @Test func explanationsDescribeEachChoiceInOneLine() {
        let claude = AgentLaunchKind.claude.builtIn
        #expect(
            claude.explanations(for: AgentLaunchOptions(model: "opus", effort: "high", fast: true))
                == [
                    "opus: Latest Opus", "Effort high: Deeper thinking for complex work",
                    "Fast mode on: About 2x speed, uses more of your limit.",
                ])
        #expect(claude.explanations(for: AgentLaunchOptions(model: "sonnet")).count == 2)
        #expect(
            AgentLaunchKind.pi.builtIn.explanations(for: .none)
                == ["Pi picks its own model.", "Thinking: the model's default."])
        #expect(
            AgentLaunchKind.gemini.builtIn.explanations(for: AgentLaunchOptions(model: "gemini-x"))
                == ["gemini-x: not in the current list"])
    }

    @Test func discoveryScriptsAreBoundedAndPlatformAware() throws {
        let codex = try #require(
            AgentLaunchDiscovery.script(for: .codex, refresh: false, platform: .darwin))
        #expect(codex.contains("models_cache.json"))
        #expect(codex.contains("codex debug models --bundled"))
        #expect(!codex.contains("codex debug models ||"))
        #expect(codex.contains("| head -c "))
        let refreshed = try #require(
            AgentLaunchDiscovery.script(for: .codex, refresh: true, platform: .darwin))
        #expect(refreshed.contains("codex debug models ||"))
        let mac = try #require(
            AgentLaunchDiscovery.script(for: .opencode, refresh: false, platform: .darwin))
        #expect(mac.contains("script -q /dev/null opencode models"))
        let linux = try #require(
            AgentLaunchDiscovery.script(for: .opencode, refresh: false, platform: .linux))
        #expect(linux.contains("script -qec 'opencode models' /dev/null"))
        #expect(
            AgentLaunchDiscovery.script(for: .pi, refresh: false, platform: .linux)?
                .contains("pi --list-models") == true)
        #expect(
            AgentLaunchDiscovery.script(for: .cursor, refresh: false, platform: .linux)?
                .contains("agent models") == true)
        #expect(AgentLaunchDiscovery.script(for: .claude, refresh: false, platform: .linux) == nil)
    }

    @Test func catalogsAreCachedPerKindUntilTheyExpire() async {
        let log = FetchLog()
        let catalogs = AgentLaunchCatalogs(
            lifetime: 60, clock: { log.date() },
            fetch: { kind, refresh, _ in
                log.record(kind, refresh)
                return kind == .codex ? Self.codexJSON : nil
            })
        #expect(await catalogs.cached(for: .codex) == AgentLaunchKind.codex.builtIn)

        let first = await catalogs.catalog(for: .codex)
        #expect(first.source == .cli("codex"))
        #expect(await catalogs.catalog(for: .codex) == first)
        #expect(log.count == 1)
        #expect(await catalogs.cached(for: .codex) == first)

        log.advance(61)
        _ = await catalogs.catalog(for: .codex)
        #expect(log.count == 2)

        _ = await catalogs.catalog(for: .codex, refresh: true)
        #expect(log.count == 3)
        #expect(log.lastRefresh == true)

        #expect(await catalogs.catalog(for: .pi) == AgentLaunchKind.pi.builtIn)
        #expect(log.count == 4)
        #expect(await catalogs.catalog(for: .claude) == AgentLaunchKind.claude.builtIn)
        #expect(log.count == 4)
    }

    @Test func overlappingLoadsShareOneFetchAndACancelledLoadStillCachesTheResult() async {
        let log = FetchLog()
        let gate = AsyncStream<Void>.makeStream()
        let catalogs = AgentLaunchCatalogs(
            lifetime: 60, clock: { log.date() },
            fetch: { kind, refresh, _ in
                log.record(kind, refresh)
                for await _ in gate.stream { break }
                return Self.codexJSON
            })
        let cancelled = Task { await catalogs.catalog(for: .codex) }
        let waiting = Task { await catalogs.catalog(for: .codex) }
        while log.count == 0 { await Task.yield() }
        cancelled.cancel()
        gate.continuation.yield()
        #expect(await waiting.value.source == .cli("codex"))
        _ = await cancelled.value
        #expect(log.count == 1)
        #expect(await catalogs.cached(for: .codex).source == .cli("codex"))
    }
}

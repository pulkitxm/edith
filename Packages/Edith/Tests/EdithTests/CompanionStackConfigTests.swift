import Foundation
import Testing

@testable import EdithKit

@Suite struct CompanionStackConfigTests {
    @Test func theEnvFileCarriesEveryKnobTheComposeStackReads() {
        let env = CompanionStackConfig().envFile()
        for key in [
            "COMPANION_PG_PASSWORD", "COMPANION_API_PORT", "COMPANION_PG_PORT",
            "COMPANION_REDIS_PORT", "COMPANION_EMBED_MODEL", "COMPANION_VLM_MODEL",
            "COMPANION_STT_MODEL", "COMPANION_REASON_PROVIDER", "COMPANION_REASON_URL",
            "COMPANION_REASON_MODEL", "COMPANION_REFLECT_AT",
        ] {
            #expect(env.contains("\(key)="), "missing \(key)")
        }
    }

    @Test func secretsAreBlankUnlessHandedIn() {
        #expect(CompanionStackConfig().envFile().contains("ANTHROPIC_API_KEY=\n"))
        let filled = CompanionStackConfig().envFile(
            secrets: CompanionSecretValues(anthropicKey: "sk-live", githubToken: "gho_x"))
        #expect(filled.contains("ANTHROPIC_API_KEY=sk-live"))
        #expect(filled.contains("GITHUB_TOKEN=gho_x"))
        #expect(filled.contains("NOTION_TOKEN=\n"))
    }

    @Test func theSttModelNameIsDerivedFromItsFile() {
        #expect(CompanionStackConfig().envFile().contains("COMPANION_STT_MODEL_NAME=base"))
    }

    @Test func clashingPortsAreRejectedBeforeAnythingStarts() {
        var config = CompanionStackConfig()
        config.pgPort = 4820
        #expect(config.validated().contains("the api, postgres and redis ports must differ"))
    }

    @Test func anOutOfRangePortIsRejected() {
        var config = CompanionStackConfig()
        config.apiPort = 70000
        #expect(config.validated().contains("port 70000 is out of range"))
    }

    @Test func aGoodConfigHasNothingToComplainAbout() {
        #expect(CompanionStackConfig().validated().isEmpty)
    }

    @Test func aLocalReasonerNeedsAnEndpoint() {
        var config = CompanionStackConfig()
        config.reasonURL = ""
        #expect(config.validated().contains("a local reasoner needs an endpoint URL"))
    }

    @Test func aConfigBundleRoundTripsAndCarriesNoSecrets() throws {
        var config = CompanionStackConfig()
        config.reasonModel = "qwen3:4b"
        let bundle = CompanionConfigBundle(
            config: config,
            deployment: CompanionDeployment(
                machineID: UUID(), machineName: "Studio Mac", tier: "cpu"))
        let data = try CompanionConfigBundle.encode(bundle)
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.lowercased().contains("anthropic_api_key"))
        #expect(!text.lowercased().contains("sk-"))
        let decoded = try CompanionConfigBundle.decode(data)
        #expect(decoded.config.reasonModel == "qwen3:4b")
        #expect(decoded.deployment?.machineName == "Studio Mac")
    }

    @Test func aBundleFromANewerEdithIsRefusedRatherThanMisread() throws {
        let json = #"{"version":99,"exportedAt":"2026-08-16T00:00:00Z","config":{}}"#
        #expect(throws: CompanionConfigError.self) {
            try CompanionConfigBundle.decode(Data(json.utf8))
        }
    }

    @Test func aSecretHintNeverReturnsTheSecret() {
        #expect(CompanionSecrets.hint("sk-ant-secret-x4Fq") == "set, ending x4Fq")
        #expect(CompanionSecrets.hint("") == nil)
    }

    @Test func configRoundTripsThroughItsStore() {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("companion-config-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        var config = CompanionStackConfig()
        config.apiPort = 5820
        CompanionConfigStore.save(config, to: url)
        #expect(CompanionConfigStore.load(url).apiPort == 5820)
    }

    @Test func aMissingConfigFallsBackToTheDefaults() {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("absent-\(UUID().uuidString).json")
        #expect(CompanionConfigStore.load(url) == CompanionStackConfig())
    }
}

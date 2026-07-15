import EdithKit
import Testing
@testable import EdithHelper

@Suite struct LimitsRefreshTests {
    @Test func refreshesEveryEnabledProviderRegardlessOfSelection() {
        #expect(UsageStore.enabledLimitProviders(claude: true, codex: true) == [.claude, .codex])
        #expect(UsageStore.enabledLimitProviders(claude: true, codex: false) == [.claude])
        #expect(UsageStore.enabledLimitProviders(claude: false, codex: true) == [.codex])
        #expect(UsageStore.enabledLimitProviders(claude: false, codex: false).isEmpty)
    }
}

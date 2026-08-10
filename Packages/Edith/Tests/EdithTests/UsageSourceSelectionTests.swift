import EdithKit
import Testing

@Suite struct UsageSourceSelectionTests {
    private func restore(
        selected: Set<String>? = nil, known: Set<String>? = nil, storedVersion: Int? = nil,
        available: Set<String> = ["cli", "codex"], defaults: Set<String> = ["cli", "codex"]
    ) -> Set<String> {
        UsageSourceSelection.restore(
            selected: selected, known: known, storedVersion: storedVersion, available: available,
            defaults: defaults)
    }

    private func reconcile(
        selected: Set<String>? = nil, known: Set<String>? = nil,
        available: Set<String> = ["cli", "codex"], defaults: Set<String> = ["cli", "codex"]
    ) -> Set<String> {
        UsageSourceSelection.reconcile(
            selected: selected, known: known, available: available, defaults: defaults)
    }

    @Test func firstLoadSelectsEveryDefaultSource() {
        #expect(reconcile() == ["cli", "codex"])
    }

    @Test func unversionedPoisonedStateMigratesToEveryDefaultSource() {
        #expect(
            restore(selected: ["cli"], known: ["cli", "codex"]) == ["cli", "codex"])
    }

    @Test func oldVersionMigratesToEveryDefaultSource() {
        #expect(
            restore(selected: ["cli"], known: ["cli", "codex"], storedVersion: 0)
                == ["cli", "codex"])
    }

    @Test func currentVersionPreservesIntentionalDeselection() {
        #expect(
            restore(
                selected: ["cli"], known: ["cli", "codex"],
                storedVersion: UsageSourceSelection.currentVersion
            ) == ["cli"])
    }

    @Test func futureVersionPreservesIntentionalDeselection() {
        #expect(
            restore(
                selected: ["cli"], known: ["cli", "codex"],
                storedVersion: UsageSourceSelection.currentVersion + 1
            ) == ["cli"])
    }

    @Test func migrationWithoutDefaultsSelectsEveryAvailableSource() {
        #expect(restore(selected: ["cli"], known: ["cli"], defaults: []) == ["cli", "codex"])
    }

    @Test func legacySavedSelectionMigratesToEveryDefaultSource() {
        #expect(reconcile(selected: ["cli"]) == ["cli", "codex"])
    }

    @Test func newlyDiscoveredSourceIsAutomaticallySelected() {
        #expect(reconcile(selected: ["cli"], known: ["cli"]) == ["cli", "codex"])
    }

    @Test func explicitlyDeselectedKnownSourceStaysDeselected() {
        #expect(reconcile(selected: ["cli"], known: ["cli", "codex"]) == ["cli"])
    }

    @Test func removedSourcesAreDiscarded() {
        #expect(
            reconcile(
                selected: ["cli", "codex"], known: ["cli", "codex"], available: ["codex"],
                defaults: ["codex"]
            ) == ["codex"])
    }

    @Test func fullyStaleSelectionFallsBackToDefaults() {
        #expect(
            reconcile(
                selected: ["removed"], known: ["removed"], available: ["codex"],
                defaults: ["codex"]
            ) == ["codex"])
    }

    @Test func fullyStaleSelectionWithoutDefaultsFallsBackToAvailableSources() {
        #expect(
            reconcile(
                selected: ["removed"], known: ["removed"], available: ["codex"], defaults: []
            ) == ["codex"])
    }

    @Test func emptySelectionFallsBackToDefaults() {
        #expect(reconcile(selected: [], known: ["cli", "codex"]) == ["cli", "codex"])
    }

    @Test func missingDefaultsFallsBackToEveryAvailableSource() {
        #expect(reconcile(available: ["codex"], defaults: ["missing"]) == ["codex"])
    }

    @Test func noAvailableSourcesReturnsEmptySelection() {
        #expect(reconcile(available: [], defaults: []) == [])
    }
}

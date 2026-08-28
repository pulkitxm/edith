import CoreGraphics
import Foundation
import Testing

@testable import EdithHelper
@testable import EdithKit

@Suite struct KeyboardToolsTests {
    private let settings = KeyboardToolsSettings(
        debounceEnabled: true, debounceWindow: 50, superEnabled: true,
        superTapAction: .escape, superHoldAction: .hyper)

    @Test func debounceRejectsFastDuplicatePresses() {
        var state = KeyboardDebounceState()
        let firstDown = state.shouldSuppress(
            keyCode: 0, repeatEvent: false, kind: .down, timestamp: 1_000_000_000,
            settings: settings)
        let firstUp = state.shouldSuppress(
            keyCode: 0, repeatEvent: false, kind: .up, timestamp: 1_010_000_000,
            settings: settings)
        let duplicate = state.shouldSuppress(
            keyCode: 0, repeatEvent: false, kind: .down, timestamp: 1_020_000_000,
            settings: settings)
        let later = state.shouldSuppress(
            keyCode: 0, repeatEvent: false, kind: .down, timestamp: 1_070_000_000,
            settings: settings)

        #expect(!firstDown)
        #expect(!firstUp)
        #expect(duplicate)
        #expect(!later)
    }

    @Test func debouncePreservesRepeatAndAlternatingKeys() {
        var state = KeyboardDebounceState()
        let first = state.shouldSuppress(
            keyCode: 0, repeatEvent: false, kind: .down, timestamp: 1_000_000_000,
            settings: settings)
        let repeated = state.shouldSuppress(
            keyCode: 0, repeatEvent: true, kind: .down, timestamp: 1_010_000_000,
            settings: settings)
        let alternating = state.shouldSuppress(
            keyCode: 11, repeatEvent: false, kind: .down, timestamp: 1_020_000_000,
            settings: settings)

        #expect(!first)
        #expect(!repeated)
        #expect(!alternating)
    }

    @Test func debounceSuppressesHeldKeyBouncePair() {
        var state = KeyboardDebounceState()
        let firstDown = state.shouldSuppress(
            keyCode: 0, repeatEvent: false, kind: .down, timestamp: 1_000_000_000,
            settings: settings)
        let bounceDown = state.shouldSuppress(
            keyCode: 0, repeatEvent: false, kind: .down, timestamp: 1_010_000_000,
            settings: settings)
        let bounceUp = state.shouldSuppress(
            keyCode: 0, repeatEvent: false, kind: .up, timestamp: 1_020_000_000,
            settings: settings)
        let physicalUp = state.shouldSuppress(
            keyCode: 0, repeatEvent: false, kind: .up, timestamp: 1_100_000_000,
            settings: settings)

        #expect(!firstDown)
        #expect(bounceDown)
        #expect(bounceUp)
        #expect(!physicalUp)
    }

    @Test func debounceSuppressesReleasedKeyBouncePair() {
        var state = KeyboardDebounceState()
        _ = state.shouldSuppress(
            keyCode: 0, repeatEvent: false, kind: .down, timestamp: 1_000_000_000,
            settings: settings)
        _ = state.shouldSuppress(
            keyCode: 0, repeatEvent: false, kind: .up, timestamp: 1_010_000_000,
            settings: settings)
        let bounceDown = state.shouldSuppress(
            keyCode: 0, repeatEvent: false, kind: .down, timestamp: 1_020_000_000,
            settings: settings)
        let bounceUp = state.shouldSuppress(
            keyCode: 0, repeatEvent: false, kind: .up, timestamp: 1_030_000_000,
            settings: settings)
        let laterDown = state.shouldSuppress(
            keyCode: 0, repeatEvent: false, kind: .down, timestamp: 1_100_000_000,
            settings: settings)

        #expect(bounceDown)
        #expect(bounceUp)
        #expect(!laterDown)
    }

    @Test func superKeySeparatesTapFromChord() {
        var state = KeyboardSuperState()
        let tapDown = state.decide(
            type: .keyDown, keyCode: KeyboardSuperState.triggerKeyCode,
            repeatEvent: false, timestamp: 1_000_000_000)
        let tapUp = state.decide(
            type: .keyUp, keyCode: KeyboardSuperState.triggerKeyCode,
            repeatEvent: false, timestamp: 1_100_000_000)
        let chordDown = state.decide(
            type: .keyDown, keyCode: KeyboardSuperState.triggerKeyCode,
            repeatEvent: false, timestamp: 2_000_000_000)
        let chordKey = state.decide(
            type: .keyDown, keyCode: 0, repeatEvent: false,
            timestamp: 2_100_000_000)
        let chordUp = state.decide(
            type: .keyUp, keyCode: KeyboardSuperState.triggerKeyCode,
            repeatEvent: false, timestamp: 2_200_000_000)

        #expect(tapDown == .swallow)
        #expect(tapUp == .tap)
        #expect(chordDown == .swallow)
        #expect(chordKey == .addModifiers)
        #expect(chordUp == .swallow)
    }

    @Test func longSoloSuperHoldDoesNotRunTapAction() {
        var state = KeyboardSuperState()
        _ = state.decide(
            type: .keyDown, keyCode: KeyboardSuperState.triggerKeyCode,
            repeatEvent: false, timestamp: 1_000_000_000)
        let release = state.decide(
            type: .keyUp, keyCode: KeyboardSuperState.triggerKeyCode,
            repeatEvent: false, timestamp: 1_600_000_000)
        #expect(release == .swallow)
    }

    @Test func superKeyAppliesModifiersToPointerChords() {
        var state = KeyboardSuperState()
        _ = state.decide(
            type: .keyDown, keyCode: KeyboardSuperState.triggerKeyCode,
            repeatEvent: false, timestamp: 1_000_000_000)

        let pointer = state.decide(
            type: .leftMouseDown, keyCode: 0, repeatEvent: false,
            timestamp: 1_100_000_000)
        let release = state.decide(
            type: .keyUp, keyCode: KeyboardSuperState.triggerKeyCode,
            repeatEvent: false, timestamp: 1_200_000_000)
        #expect(pointer == .addModifiers)
        #expect(release == .swallow)
    }

    @Test func mappingPreservesExternalEntriesAndRejectsConflicts() {
        let external = KeyboardSuperMapping(source: 1, destination: 2)
        #expect(
            KeyboardSuperMappingSupport.desiredMappings(
                enabling: true, existing: [external], ownsMapping: false)
                == [KeyboardSuperMappingSupport.ownedMapping, external])
        #expect(
            KeyboardSuperMappingSupport.desiredMappings(
                enabling: false,
                existing: [KeyboardSuperMappingSupport.ownedMapping, external],
                ownsMapping: true) == [external])

        let conflict = KeyboardSuperMapping(
            source: KeyboardSuperState.capsLockUsage, destination: 3)
        #expect(
            KeyboardSuperMappingSupport.desiredMappings(
                enabling: true, existing: [conflict], ownsMapping: false) == nil)
    }

    @Test func mappingReportsRequireConsistentReadback() {
        let owned = KeyboardSuperMappingSupport.ownedMapping
        let report = mappingReport([[owned], [owned]])
        #expect(KeyboardSuperMappingSupport.mappingTables(report) == [[owned], [owned]])
        #expect(KeyboardSuperMappingSupport.reportConfirms(report, expected: [owned]))

        let inconsistent = mappingReport([
            [owned], [KeyboardSuperMapping(source: 1, destination: 2)],
        ])
        #expect(
            KeyboardSuperMappingSupport.consistentMappings(
                inconsistent, ownsMapping: false) == nil)
    }

    @Test func settingsSanitizeStoredValues() {
        let suite = "KeyboardToolsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(1, forKey: AppStorageKeys.KeyboardTools.debounceWindow)
        defaults.set("invalid", forKey: AppStorageKeys.KeyboardTools.superTapAction)
        defaults.set("invalid", forKey: AppStorageKeys.KeyboardTools.superHoldAction)

        let loaded = KeyboardToolsSettings.load(defaults)
        #expect(loaded.debounceWindow == KeyboardToolsSettings.debounceRange.lowerBound)
        #expect(loaded.debounceEnabled)
        #expect(loaded.superEnabled)
        #expect(loaded.superTapAction == .escape)
        #expect(loaded.superHoldAction == .hyper)
    }

    @Test func liveReadinessRequiresAtLeastOneTool() async {
        let suite = "KeyboardToolsReadinessTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let ready = await ExtensionLiveAdapters.readiness(
            for: "keyboardTools", defaults: defaults)
        defaults.set(false, forKey: AppStorageKeys.KeyboardTools.debounceEnabled)
        defaults.set(false, forKey: AppStorageKeys.KeyboardTools.superEnabled)
        let missing = await ExtensionLiveAdapters.readiness(
            for: "keyboardTools", defaults: defaults)

        #expect(missing == .needsSetup("Turn on Debounce, Super key, or both."))
        #expect(ready == .ready("The keyboard event filter is configured and ready."))
    }

    @Test func settingsBackupIncludesPreferencesButNotRuntimeState() {
        let preferences = [
            AppStorageKeys.KeyboardTools.enabled,
            AppStorageKeys.KeyboardTools.debounceEnabled,
            AppStorageKeys.KeyboardTools.debounceWindow,
            AppStorageKeys.KeyboardTools.superEnabled,
            AppStorageKeys.KeyboardTools.superTapAction,
            AppStorageKeys.KeyboardTools.superHoldAction,
        ]
        let runtime = [
            AppStorageKeys.KeyboardTools.mappingApplied,
            AppStorageKeys.KeyboardTools.runtimeActive,
            AppStorageKeys.KeyboardTools.runtimeError,
        ]

        #expect(preferences.allSatisfy(SettingsBackup.backedKeys.contains))
        #expect(preferences.allSatisfy(SettingsBackup.sharedKeys.contains))
        #expect(runtime.allSatisfy { !SettingsBackup.backedKeys.contains($0) })
        #expect(runtime.allSatisfy { !SettingsBackup.sharedKeys.contains($0) })
    }

    private func mappingReport(_ tables: [[KeyboardSuperMapping]]) -> String {
        tables.enumerated().map { index, mappings in
            let values = mappings.map {
                "{ HIDKeyboardModifierMappingSrc = \($0.source); HIDKeyboardModifierMappingDst = \($0.destination); }"
            }.joined(separator: "\n")
            return "\(index) \(KeyboardSuperMappingSupport.property) (\n\(values)\n)"
        }.joined(separator: "\n")
    }
}

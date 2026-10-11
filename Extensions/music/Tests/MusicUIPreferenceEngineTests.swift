import EdithExtensionSupport
import Foundation
import Testing

@testable import MusicExtension

extension MusicExtensionTests {
    @MainActor @Suite struct MusicUIPreferenceEngineTests {
        @Test func initialReadDoesNotMutatePreferences() {
            let state = MemoryPreferences()
            let value = state.engine.preferences()
            #expect(value.crossfade)
            #expect(value.fadeLength == 2)
            #expect(!value.barCollapsed && !value.barAutoHide && !value.gridView)
            #expect(state.writes == 0)
        }

        @Test func invalidValuesAndUnrelatedActionsCannotMutatePreferences() throws {
            let state = MemoryPreferences()
            for kind: MusicUIActionKind in [.crossfade, .barCollapsed, .barAutoHide, .gridView] {
                for value: Double? in [nil, -1, 0.5, 2, .nan, .infinity] {
                    #expect(throws: (any Error).self) { try state.perform(kind, value) }
                }
            }
            for value: Double? in [nil, 0.49, 8.01, .nan, .infinity] {
                #expect(throws: (any Error).self) { try state.perform(.fadeLength, value) }
            }
            for kind in MusicUIActionKind.allCases where !MusicUIPreferenceEngine.accepts(kind) {
                #expect(throws: (any Error).self) { try state.perform(kind, 1) }
            }
            #expect(state.writes == 0)
            #expect(state.invalidations == 0)
        }

        @Test func originalControlsRoundTripAndOnlyChangedHostSlotsInvalidate() throws {
            let state = MemoryPreferences()
            state.values["syntheticUnrelated"] = "retained"
            try state.perform(.barCollapsed, 1)
            #expect(state.engine.preferences().barCollapsed && state.invalidations == 1)
            try state.perform(.barCollapsed, 1)
            #expect(state.invalidations == 1)
            try state.perform(.barCollapsed, 0)
            #expect(!state.engine.preferences().barCollapsed && state.invalidations == 2)
            try state.perform(.barAutoHide, 1)
            #expect(state.engine.preferences().barAutoHide && state.invalidations == 3)
            try state.perform(.crossfade, 0)
            #expect(!state.engine.preferences().crossfade && state.invalidations == 3)
            try state.perform(.gridView, 1)
            #expect(state.engine.preferences().gridView && state.invalidations == 3)
            for value in [0.5, 2, 8] {
                try state.perform(.fadeLength, value)
                #expect(state.engine.preferences().fadeLength == value)
            }
            #expect(state.values["syntheticUnrelated"] as? String == "retained")
        }

        @Test func storedDurationsKeepOriginalReadbackBounds() {
            let state = MemoryPreferences()
            for (stored, expected) in [(-2.0, 0.5), (20.0, 8.0), (Double.nan, 2.0)] {
                state.values[MusicFade.secondsKey] = stored
                #expect(state.engine.preferences().fadeLength == expected)
            }
            #expect(state.writes == 0)
        }

        @MainActor private final class MemoryPreferences {
            var values: [String: Any] = [:]
            var writes = 0
            var invalidations = 0
            var engine: MusicUIPreferenceEngine {
                MusicUIPreferenceEngine(
                    object: { self.values[$0] },
                    boolean: { self.values[$0] as? Bool ?? false },
                    set: { self.values[$1] = $0; self.writes += 1 })
            }
            func perform(_ kind: MusicUIActionKind, _ value: Double?) throws {
                try engine.perform(
                    MusicUIAction(kind: kind, value: value),
                    invalidateHostSlots: { self.invalidations += 1 })
            }
        }
    }
}

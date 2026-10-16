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

        @Test func fixtureSettingsAndOriginalControlsUseOnlyAdmittedPreferences() throws {
            let state = MemoryPreferences()
            var checks = 0
            let read = try state.engine.executeFixture(
                "music.ui.settings", payload: Data("{}".utf8), version: "1.0.0",
                requireCurrent: { checks += 1 }, invalidateHostSlots: {})
            let initial = try JSONDecoder().decode(MusicUISettings.self, from: read)
            #expect(initial.version == "1.0.0" && initial.preferences.crossfade)
            #expect(state.writes == 0 && checks == 1)
            let controls: [(MusicUIActionKind, Double)] = [
                (.crossfade, 0), (.fadeLength, 8), (.barCollapsed, 1), (.barAutoHide, 1),
            ]
            for (kind, value) in controls {
                let payload = try JSONEncoder().encode(MusicUIAction(kind: kind, value: value))
                let result = try state.engine.executeFixture(
                    "music.ui.action", payload: payload, version: "1.0.0",
                    requireCurrent: { checks += 1 },
                    invalidateHostSlots: { state.invalidations += 1 })
                #expect(result == Data("{}".utf8))
            }
            let saved = state.engine.preferences()
            #expect(!saved.crossfade && saved.fadeLength == 8)
            #expect(saved.barCollapsed && saved.barAutoHide && !saved.gridView)
            #expect(state.writes == 4 && state.invalidations == 2 && checks == 5)
        }

        @Test func fixtureRejectsUnrelatedEffectsAndMalformedRequestsBeforeWrites() throws {
            let state = MemoryPreferences()
            let requests: [(String, Data, String)] = [
                ("music.ui.settings", Data("{\"extra\":true}".utf8), "1.0.0"),
                ("music.ui.settings", Data("{}".utf8), ""),
                ("music.ui.settings", Data("{}".utf8), "1\0.0"),
                ("surface.perform", Data("{}".utf8), "1.0.0"),
                ("music.ui.action", Data("{}".utf8), "1.0.0"),
                ("music.ui.action", Data(repeating: 32, count: 16_385), "1.0.0"),
            ]
            for (operation, payload, version) in requests {
                #expect(throws: (any Error).self) {
                    try state.engine.executeFixture(
                        operation, payload: payload, version: version,
                        requireCurrent: {}, invalidateHostSlots: {})
                }
            }
            for kind in MusicUIActionKind.allCases
            where ![.crossfade, .fadeLength, .barCollapsed, .barAutoHide].contains(kind) {
                let payload = try JSONEncoder().encode(MusicUIAction(kind: kind, value: 1))
                #expect(throws: (any Error).self) {
                    try state.engine.executeFixture(
                        "music.ui.action", payload: payload, version: "1.0.0",
                        requireCurrent: {}, invalidateHostSlots: {})
                }
            }
            for action in [
                MusicUIAction(kind: .crossfade, path: "synthetic", value: 1),
                MusicUIAction(kind: .crossfade, target: "synthetic", value: 1),
            ] {
                let payload = try JSONEncoder().encode(action)
                #expect(throws: (any Error).self) {
                    try state.engine.executeFixture(
                        "music.ui.action", payload: payload, version: "1.0.0",
                        requireCurrent: {}, invalidateHostSlots: {})
                }
            }
            #expect(state.writes == 0 && state.invalidations == 0)
        }

        @Test func revokedAuthorityCannotReadOrMutatePreferences() throws {
            let state = MemoryPreferences()
            for operation in ["music.ui.settings", "music.ui.action"] {
                let payload =
                    operation == "music.ui.settings"
                    ? Data("{}".utf8)
                    : try JSONEncoder().encode(MusicUIAction(kind: .barCollapsed, value: 1))
                #expect(throws: RevokedAuthority.self) {
                    try state.engine.executeFixture(
                        operation, payload: payload, version: "1.0.0",
                        requireCurrent: { throw RevokedAuthority.revoked },
                        invalidateHostSlots: { state.invalidations += 1 })
                }
            }
            #expect(state.writes == 0 && state.invalidations == 0 && state.reads == 0)
        }

        @Test func cancelledFixtureRequestCannotReadOrMutatePreferences() async throws {
            let state = MemoryPreferences()
            var checks = 0
            let payload = try JSONEncoder().encode(MusicUIAction(kind: .barAutoHide, value: 1))
            let request = Task {
                try state.engine.executeFixture(
                    "music.ui.action", payload: payload, version: "1.0.0",
                    requireCurrent: { checks += 1 },
                    invalidateHostSlots: { state.invalidations += 1 })
            }
            request.cancel()
            await #expect(throws: CancellationError.self) { try await request.value }
            #expect(checks == 0 && state.reads == 0)
            #expect(state.writes == 0 && state.invalidations == 0)
        }

        private enum RevokedAuthority: Error { case revoked }

        @MainActor private final class MemoryPreferences {
            var values: [String: Any] = [:]
            var reads = 0
            var writes = 0
            var invalidations = 0
            var engine: MusicUIPreferenceEngine {
                MusicUIPreferenceEngine(
                    object: {
                        self.reads += 1; return self.values[$0]
                    },
                    boolean: {
                        self.reads += 1; return self.values[$0] as? Bool ?? false
                    },
                    set: {
                        self.values[$1] = $0; self.writes += 1
                    })
            }
            func perform(_ kind: MusicUIActionKind, _ value: Double?) throws {
                try engine.perform(
                    MusicUIAction(kind: kind, value: value),
                    invalidateHostSlots: { self.invalidations += 1 })
            }
        }
    }
}

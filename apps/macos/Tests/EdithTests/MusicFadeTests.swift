import EdithKit
import Foundation
import Testing

@Suite struct MusicFadeTests {
    private func defaults(_ values: [String: Any]) -> UserDefaults {
        let store = UserDefaults(suiteName: "edith-fade-\(UUID().uuidString)")!
        for (key, value) in values { store.set(value, forKey: key) }
        return store
    }

    @Test func disabledMeansNoFade() {
        #expect(MusicFade.duration(from: defaults([MusicFade.enabledKey: false])) == 0)
    }

    @Test func enabledWithoutLengthUsesDefault() {
        let store = defaults([MusicFade.enabledKey: true])
        #expect(MusicFade.duration(from: store) == MusicFade.defaultSeconds)
    }

    @Test func lengthIsClampedToRange() {
        let low = defaults([MusicFade.enabledKey: true, MusicFade.secondsKey: 0.1])
        let high = defaults([MusicFade.enabledKey: true, MusicFade.secondsKey: 99.0])
        #expect(MusicFade.duration(from: low) == MusicFade.secondsRange.lowerBound)
        #expect(MusicFade.duration(from: high) == MusicFade.secondsRange.upperBound)
    }

    @Test func lengthInRangeIsKept() {
        let store = defaults([MusicFade.enabledKey: true, MusicFade.secondsKey: 3.5])
        #expect(MusicFade.duration(from: store) == 3.5)
    }

    @Test func crossfadeIsOnByDefaultInSharedStore() {
        #expect(SharedDefaults.registeredDefaults[MusicFade.enabledKey] as? Bool == true)
    }
}

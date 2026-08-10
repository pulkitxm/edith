import Foundation
import Testing

@testable import EdithKit

@Suite struct ColorHistoryStoreTests {
    private func swatch(_ seed: Double) -> ColorSwatch {
        ColorSwatch(red: seed, green: seed, blue: seed, profile: .sRGB)
    }

    @Test func insertsNewestFirst() {
        let history = [swatch(0.2), swatch(0.3)]
        let updated = ColorHistoryStore.inserting(swatch(0.1), into: history, limit: 10)
        #expect(updated.map(\.red) == [0.1, 0.2, 0.3])
    }

    @Test func capsAtTheConfiguredLimit() {
        let history = (0..<5).map { swatch(Double($0) / 10) }
        let updated = ColorHistoryStore.inserting(swatch(0.9), into: history, limit: 3)
        #expect(updated.count == 3)
        #expect(updated.first?.red == 0.9)
    }

    @Test func codableRoundTripsExactly() throws {
        let original = ColorSwatch(red: 0.25, green: 0.5, blue: 0.75, profile: .displayP3)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ColorSwatch.self, from: data)
        #expect(decoded == original)
    }
}

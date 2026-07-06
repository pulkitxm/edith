import SwiftUI
import Testing

@testable import Edith

@Suite struct DonutSelectionTests {
    let slices = [
        DonutSlice(id: "a", label: "a", value: 10, color: .red),
        DonutSlice(id: "b", label: "b", value: 30, color: .blue),
        DonutSlice(id: "c", label: "c", value: 60, color: .green),
    ]

    @Test func valueInsideFirstSliceSelectsIt() {
        #expect(donutSlice(at: 0, in: slices)?.id == "a")
        #expect(donutSlice(at: 9.9, in: slices)?.id == "a")
    }

    @Test func boundaryValueBelongsToNextSlice() {
        #expect(donutSlice(at: 10, in: slices)?.id == "b")
        #expect(donutSlice(at: 40, in: slices)?.id == "c")
    }

    @Test func valueAtOrPastTotalClampsToLastSlice() {
        #expect(donutSlice(at: 100, in: slices)?.id == "c")
        #expect(donutSlice(at: 250, in: slices)?.id == "c")
    }

    @Test func emptySlicesSelectNothing() {
        #expect(donutSlice(at: 5, in: []) == nil)
    }
}

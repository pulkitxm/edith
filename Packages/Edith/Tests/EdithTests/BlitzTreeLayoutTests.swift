import Foundation
import Testing

@testable import Edith

@Suite struct BlitzTreeLayoutTests {
    @Test func preservesAreaAndWeightsWithoutOverlaps() {
        let weights = [60.0, 25, 10, 4, 1]
        let bounds = CGRect(x: 0, y: 0, width: 800, height: 300)
        let rectangles = BlitzTreeLayout.rectangles(weights: weights, in: bounds)
        for index in weights.indices {
            let rect = rectangles[index]
            #expect(bounds.contains(rect))
            #expect(abs(rect.width * rect.height - 2400 * weights[index]) < 0.001)
            for other in rectangles.indices where other > index {
                let intersection = rect.intersection(rectangles[other])
                #expect(intersection.isNull || intersection.width * intersection.height < 0.001)
            }
        }
    }

    @Test func emptyAndZeroSizedEntriesDoNotCorruptLayout() {
        let bounds = CGRect(x: 0, y: 0, width: 300, height: 800)
        #expect(BlitzTreeLayout.rectangles(weights: [], in: bounds).isEmpty)
        let rectangles = BlitzTreeLayout.rectangles(weights: [0, -1, .nan, 5], in: bounds)
        #expect(rectangles == [.zero, .zero, .zero, bounds])
        #expect(BlitzTreeLayout.rectangles(weights: [5], in: .zero) == [.zero])
    }
}

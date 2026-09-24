import CoreGraphics
import Foundation
import Testing

@testable import EdithKit

@Suite struct HerdrLayoutTests {
    private let unit = CGRect(x: 0, y: 0, width: 100, height: 100)

    @Test func splittingAPaneGivesTheNewPaneHalfOfIt() {
        let layout = HerdrLayout.stack(.horizontal, ["a", "b"])
            .inserting(.pane("c"), near: "b", side: .right)
        let frames = layout.frames(in: unit)
        #expect(layout.panes == ["a", "b", "c"])
        #expect(frames["a"] == CGRect(x: 0, y: 0, width: 50, height: 100))
        #expect(frames["b"] == CGRect(x: 50, y: 0, width: 25, height: 100))
        #expect(frames["c"] == CGRect(x: 75, y: 0, width: 25, height: 100))
    }

    @Test func splittingAcrossTheAxisNestsASplit() {
        let layout = HerdrLayout.stack(.horizontal, ["a", "b"])
            .inserting(.pane("c"), near: "a", side: .top)
        let frames = layout.frames(in: unit)
        #expect(layout.panes == ["c", "a", "b"])
        #expect(frames["c"] == CGRect(x: 0, y: 0, width: 50, height: 50))
        #expect(frames["a"] == CGRect(x: 0, y: 50, width: 50, height: 50))
        #expect(frames["b"] == CGRect(x: 50, y: 0, width: 50, height: 100))
    }

    @Test func edgeInsertionSpansTheWholeSide() {
        let layout = HerdrLayout.stack(.horizontal, ["a", "b"])
            .inserting(.pane("c"), atEdge: .bottom)
        let frames = layout.frames(in: unit)
        #expect(frames["c"] == CGRect(x: 0, y: 50, width: 100, height: 50))
        let widened = HerdrLayout.stack(.horizontal, ["a", "b"])
            .inserting(.pane("c"), atEdge: .left)
        #expect(widened.panes == ["c", "a", "b"])
        #expect(abs((widened.frames(in: unit)["c"]?.width ?? 0) - 100.0 / 3) < 0.001)
    }

    @Test func removingCollapsesSingleChildSplits() throws {
        let layout = HerdrLayout.stack(.horizontal, ["a", "b"])
            .inserting(.pane("c"), near: "b", side: .bottom)
        let removed = try #require(layout.removing("c"))
        #expect(removed.panes == ["a", "b"])
        guard case let .split(split) = removed else {
            Issue.record("expected a split")
            return
        }
        #expect(split.axis == .horizontal)
        #expect(split.ratios == [0.5, 0.5])
        #expect(HerdrLayout.pane("a").removing("a") == nil)
    }

    @Test func swappingAndReplacingKeepTheShape() {
        let layout = HerdrLayout.stack(.vertical, ["a", "b", "c"])
        #expect(layout.swapping("a", "c").panes == ["c", "b", "a"])
        #expect(layout.replacing("b", with: "z").panes == ["a", "z", "c"])
    }

    @Test func rotatingAndMirroringFlipTheShape() {
        let layout = HerdrLayout.group(.horizontal, [.pane("a"), .stack(.vertical, ["b", "c"])])
        let rotated = layout.rotated().frames(in: unit)
        #expect(rotated["a"] == CGRect(x: 0, y: 0, width: 100, height: 50))
        #expect(rotated["b"] == CGRect(x: 0, y: 50, width: 50, height: 50))
        let mirrored = layout.mirrored(.horizontal)
        #expect(mirrored.panes == ["b", "c", "a"])
        #expect(layout.mirrored(.vertical).panes == ["a", "c", "b"])
    }

    @Test func resizingRespectsTheMinimumShare() {
        let layout = HerdrLayout.stack(.horizontal, ["a", "b"])
        guard case let .split(split) = layout else {
            Issue.record("expected a split")
            return
        }
        let resized = layout.resizing(split: split.id, index: 0, by: 0.2)
        #expect(abs((resized.frames(in: unit)["a"]?.width ?? 0) - 70) < 0.001)
        #expect(layout.resizing(split: split.id, index: 0, by: 0.49) == layout)
        #expect(abs((resized.equalized().frames(in: unit)["a"]?.width ?? 0) - 50) < 0.001)
    }

    @Test func splitLayoutsKeepAGapFromTheCanvasEdges() {
        let canvas = CGRect(x: 0, y: 0, width: 112, height: 100)
        let split = HerdrLayout.stack(.horizontal, ["a", "b"])
        let frames = split.paneFrames(in: canvas, gap: 6)
        #expect(frames["a"] == CGRect(x: 6, y: 6, width: 47, height: 88))
        #expect(frames["b"] == CGRect(x: 59, y: 6, width: 47, height: 88))
        #expect(split.paneDividers(in: canvas, gap: 6).first?.rect.minX == 53)
        #expect(HerdrLayout.pane("a").paneFrames(in: canvas, gap: 6)["a"] == canvas)
    }

    @Test func dividersSitInTheGaps() {
        let layout = HerdrLayout.group(.horizontal, [.pane("a"), .stack(.vertical, ["b", "c"])])
        let rect = CGRect(x: 0, y: 0, width: 106, height: 106)
        let dividers = layout.dividers(in: rect, gap: 6)
        #expect(dividers.count == 2)
        #expect(dividers[0].rect == CGRect(x: 50, y: 0, width: 6, height: 106))
        #expect(dividers[0].span == 100)
        #expect(dividers[1].rect == CGRect(x: 56, y: 50, width: 50, height: 6))
    }

    @Test func neighboursFollowTheGeometry() {
        let layout = HerdrLayout.group(.horizontal, [.pane("a"), .stack(.vertical, ["b", "c"])])
        #expect(layout.neighbor(of: "a", toward: .right) == "b")
        #expect(layout.neighbor(of: "c", toward: .left) == "a")
        #expect(layout.neighbor(of: "b", toward: .bottom) == "c")
        #expect(layout.neighbor(of: "c", toward: .bottom) == nil)
    }

    @Test func layoutsRoundTripThroughJSON() throws {
        let layout = HerdrLayout.group(.horizontal, [.pane("a"), .stack(.vertical, ["b", "c"])])
        let data = try JSONEncoder().encode(layout)
        #expect(try JSONDecoder().decode(HerdrLayout.self, from: data) == layout)
    }

    @Test func arrangementOptionsGrowWithThePaneCount() {
        #expect(HerdrArrangement.options(for: 1).isEmpty)
        let two = HerdrArrangement.options(for: 2)
        let three = HerdrArrangement.options(for: 3)
        let four = HerdrArrangement.options(for: 4)
        let six = HerdrArrangement.options(for: 6)
        #expect(two.first == .columns)
        #expect(two.count >= 4)
        #expect(three.count > two.count)
        #expect(four.contains(.grid))
        #expect(six.count >= four.count)
    }

    @Test func arrangementOptionsNeverRepeatAShape() {
        for count in 2...9 {
            let layouts = HerdrArrangement.options(for: count).compactMap {
                $0.layout(HerdrArrangement.placeholders(count))
            }
            for (index, layout) in layouts.enumerated() {
                #expect(layout.paneCount == count)
                for other in layouts.dropFirst(index + 1) {
                    #expect(!layout.geometryMatches(other, tolerance: 0.001))
                }
            }
        }
    }

    @Test func slotOrderReadsTheArrangementBack() throws {
        let layout = try #require(HerdrArrangement.focusRight.layout(["main", "b", "c"]))
        #expect(HerdrArrangement.focusRight.slotOrder(of: layout) == ["main", "b", "c"])
        #expect(HerdrArrangement.columns.slotOrder(of: layout) == nil)
    }

    @Test func gridOfFourIsTwoByTwo() throws {
        let layout = try #require(HerdrArrangement.grid.layout(["a", "b", "c", "d"]))
        let frames = layout.frames(in: unit)
        #expect(frames["a"] == CGRect(x: 0, y: 0, width: 50, height: 50))
        #expect(frames["d"] == CGRect(x: 50, y: 50, width: 50, height: 50))
    }

    @Test func focusArrangementsGiveTheFirstPaneTheLargestShare() throws {
        for arrangement in [HerdrArrangement.focusLeft, .focusRight, .focusTop, .focusBottom] {
            let layout = try #require(arrangement.layout(["main", "b", "c"]))
            let frames = layout.frames(in: unit)
            let main = try #require(frames["main"])
            #expect(frames.values.allSatisfy { main.width * main.height >= $0.width * $0.height })
        }
        let center = try #require(HerdrArrangement.focusCenter.layout(["main", "b", "c"]))
        #expect(center.frames(in: unit)["main"] == CGRect(x: 25, y: 0, width: 50, height: 100))
    }

    @Test func matchingRecognisesTheCurrentArrangement() throws {
        let grid = try #require(HerdrArrangement.grid.layout(["w", "x", "y", "z"]))
        #expect(HerdrArrangement.matching(grid) == .grid)
        let columns = HerdrLayout.stack(.horizontal, ["a", "b", "c"])
        #expect(HerdrArrangement.matching(columns) == .columns)
        guard case let .split(split) = columns else { return }
        let resized = columns.resizing(split: split.id, index: 0, by: 0.2)
        #expect(HerdrArrangement.matching(resized) == nil)
    }
}

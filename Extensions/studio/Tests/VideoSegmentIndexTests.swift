import CoreMedia
import Testing
@testable import StudioExtension

struct VideoSegmentIndexTests {
    private func range(_ start: Int64, _ duration: Int64, scale: Int32 = 600) -> CMTimeRange {
        CMTimeRange(
            start: CMTime(value: start, timescale: scale),
            duration: CMTime(value: duration, timescale: scale))
    }

    private func equivalent(_ ranges: [CMTimeRange], at times: [CMTime]) {
        let index = VideoSegmentIndex(ranges: ranges)
        for time in times {
            let expected = ranges.indices.reversed().first { ranges[$0].containsTime(time) }
            #expect(index.index(at: time) == expected)
        }
    }

    @Test func all3600FramesAndClipEdgesKeepOriginalSelection() {
        let ranges = (0..<120).map { range(Int64($0 * 600), 600) }
        var times = (-1...3600).map { CMTime(value: Int64($0), timescale: 30) }
        for edge in 0...120 {
            times += [-1, 0, 1].map { CMTime(value: Int64(edge * 60000 + $0), timescale: 60000) }
        }
        equivalent(ranges, at: times)
        let index = VideoSegmentIndex(ranges: ranges)
        #expect(index.index(at: .zero) == 0)
        #expect(index.index(at: CMTime(value: 1, timescale: 1)) == 1)
        #expect(index.index(at: CMTime(value: 120, timescale: 1)) == nil)
    }

    @Test func gapsZeroLengthsAndFractionalClocksKeepHalfOpenBoundaries() {
        let ranges = [
            range(0, 0), range(0, 1001, scale: 30000), range(1001, 0, scale: 30000),
            range(3003, 2002, scale: 30000), range(5005, 0, scale: 30000),
            range(5005, 1001, scale: 30000),
        ]
        let times = (0...6010).map { CMTime(value: Int64($0), timescale: 30000) }
        equivalent(ranges, at: times)
        equivalent([], at: [.zero, .invalid, .indefinite, .positiveInfinity])
    }

    @Test func overlappingAndUnsortedRangesStillChooseLastContainingRange() {
        for ranges in [
            [range(0, 600), range(300, 600), range(300, 0), range(400, 100)],
            [range(600, 600), range(0, 900), range(300, 200)],
            [range(0, 1200), range(0, 600), range(0, 0)],
        ] {
            equivalent(ranges, at: (-1...1201).map { CMTime(value: Int64($0), timescale: 600) })
        }
        #expect(
            VideoSegmentIndex(ranges: [range(600, 600), range(0, 900), range(300, 200)])
                .index(at: CMTime(value: 400, timescale: 600)) == 2)
    }

    @Test func invalidRangesAndNonNumericTimesPreserveOriginalContainment() {
        equivalent(
            [
                range(0, 600), .invalid,
                CMTimeRange(start: .indefinite, duration: CMTime(value: 1, timescale: 1)),
                range(600, -300), range(600, 600),
            ],
            at: [.invalid, .indefinite, .positiveInfinity, .negativeInfinity, .zero]
                + (-1...1201).map { CMTime(value: Int64($0), timescale: 600) })
    }
}

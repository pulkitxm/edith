import CoreMedia

struct VideoSegmentIndex: Sendable {
    private let ranges: [CMTimeRange]
    private let ordered: Bool

    init(ranges: [CMTimeRange]) {
        self.ranges = ranges
        ordered =
            ranges.allSatisfy {
                $0.isValid && $0.start.isNumeric && $0.duration.isNumeric
                    && $0.duration >= .zero && $0.end.isNumeric
            }
            && zip(ranges, ranges.dropFirst()).allSatisfy {
                $0.end <= $1.start
            }
    }

    func index(at time: CMTime) -> Int? {
        guard ordered, time.isNumeric else {
            return ranges.indices.reversed().first { ranges[$0].containsTime(time) }
        }
        var low = 0
        var high = ranges.count
        while low < high {
            let middle = low + (high - low) / 2
            if ranges[middle].start <= time {
                low = middle + 1
            } else {
                high = middle
            }
        }
        guard low > 0, ranges[low - 1].containsTime(time) else { return nil }
        return low - 1
    }
}

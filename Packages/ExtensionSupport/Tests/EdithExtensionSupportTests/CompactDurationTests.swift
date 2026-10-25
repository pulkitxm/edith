import Testing

@testable import EdithExtensionSupport

@Suite struct CompactDurationTests {
    @Test(arguments: [
        (0.0, "0s"),
        (59.9, "59s"),
        (60.0, "1m"),
        (3_599.0, "59m"),
        (3_600.0, "1h"),
        (86_399.0, "23h"),
        (86_400.0, "1d"),
        (172_800.0, "2d"),
    ])
    func textBucketsSeconds(seconds: Double, label: String) {
        #expect(CompactDuration.text(seconds) == label)
    }

    @Test func textTruncatesTowardZero() {
        #expect(CompactDuration.text(90.9) == "1m")
        #expect(CompactDuration.text(-5) == "-5s")
    }

    @Test(arguments: [
        (0.0, "0s"),
        (45.0, "45s"),
        (60.0, "1m"),
        (250.0, "4m 10s"),
        (3_600.0, "1h"),
        (3_900.0, "1h 5m"),
        (86_399.0, "23h 59m"),
        (86_400.0, "1d"),
        (93_600.0, "1d 2h"),
        (1_209_600.0, "14d"),
    ])
    func detailedShowsTheTwoLargestUnits(seconds: Double, label: String) {
        #expect(CompactDuration.detailed(seconds) == label)
    }

    @Test func detailedClampsInvalidInput() {
        #expect(CompactDuration.detailed(-5) == "0s")
        #expect(CompactDuration.detailed(.nan) == "0s")
        #expect(CompactDuration.detailed(.infinity) == "0s")
        #expect(CompactDuration.detailed(90.9) == "1m 30s")
    }

    @Test func detailedCanStopAtMinutes() {
        #expect(CompactDuration.detailed(45, showsSeconds: false) == "45s")
        #expect(CompactDuration.detailed(250, showsSeconds: false) == "4m")
        #expect(CompactDuration.detailed(93_659, showsSeconds: false) == "1d 2h")
    }
}

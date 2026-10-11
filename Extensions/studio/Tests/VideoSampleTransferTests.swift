import Testing
@testable import StudioExtension

struct VideoSampleTransferTests {
    private enum Failure: Error { case reader, writer, append }

    @Test func prefetchesOneSampleWhileEncodingAndPreservesEveryTimestamp() async throws {
        let timestamps = (0..<3600).map { Int64($0) * 1001 }
        var next = 0
        var appended: [Int64] = []
        var ready = true
        var maximumPending = 0
        var waits = 0
        var finished = 0
        try await VideoSampleTransfer.run(
            validate: {},
            readNext: { () -> Int64? in
                guard next < timestamps.count else { return nil }
                defer { next += 1 }
                maximumPending = max(maximumPending, next + 1 - appended.count)
                return timestamps[next]
            },
            isReady: { ready },
            waitForReadiness: {
                #expect(next == appended.count + 1)
                waits += 1
                ready = true
            },
            append: {
                appended.append($0)
                ready = false
            }, finish: { finished += 1 })
        #expect(appended == timestamps)
        #expect(maximumPending == 1)
        #expect(waits == timestamps.count - 1)
        #expect(finished == 1)
    }

    @Test func emptySourceFinishesWithoutWaitingForEncoder() async throws {
        var finished = 0
        try await VideoSampleTransfer.run(
            validate: {}, readNext: { Optional<Int>.none }, isReady: { false },
            waitForReadiness: { Issue.record("EOF waited for encoder readiness") },
            append: { _ in Issue.record("EOF appended a sample") },
            finish: { finished += 1 })
        #expect(finished == 1)
    }

    @Test func readerFailureAfterPrefetchNeverAppendsOrFinishes() async {
        var failed = false
        await #expect(throws: Failure.reader) {
            try await VideoSampleTransfer.run(
                validate: { if failed { throw Failure.reader } },
                readNext: {
                    failed = true; return 1
                }, isReady: { true },
                waitForReadiness: {},
                append: { _ in Issue.record("Failed reader appended a sample") },
                finish: { Issue.record("Failed reader marked finished") })
        }
    }

    @Test func writerFailureDuringBackpressureNeverAppendsOrFinishes() async {
        var failed = false
        var reads = 0
        await #expect(throws: Failure.writer) {
            try await VideoSampleTransfer.run(
                validate: { if failed { throw Failure.writer } },
                readNext: {
                    reads += 1; return reads
                }, isReady: { false },
                waitForReadiness: { failed = true },
                append: { _ in Issue.record("Failed writer appended a sample") },
                finish: { Issue.record("Failed writer marked finished") })
        }
        #expect(reads == 1)
    }

    @Test func cancellationDuringPrefetchPreventsAppend() async {
        let worker = Task {
            try await VideoSampleTransfer.run(
                validate: {},
                readNext: {
                    withUnsafeCurrentTask { $0?.cancel() }
                    return 1
                }, isReady: { true }, waitForReadiness: {},
                append: { _ in Issue.record("Cancelled sample appended") },
                finish: { Issue.record("Cancelled transfer marked finished") })
        }
        await #expect(throws: CancellationError.self) {
            try await worker.value
        }
    }

    @Test func cancellationDuringBackpressurePreventsAppendAndReadAhead() async {
        let worker = Task {
            var reads = 0
            do {
                try await VideoSampleTransfer.run(
                    validate: {},
                    readNext: {
                        reads += 1; return reads
                    }, isReady: { false },
                    waitForReadiness: { withUnsafeCurrentTask { $0?.cancel() } },
                    append: { _ in Issue.record("Cancelled sample appended") },
                    finish: { Issue.record("Cancelled transfer marked finished") })
            } catch {
                #expect(reads == 1)
                throw error
            }
        }
        await #expect(throws: CancellationError.self) { try await worker.value }
    }

    @Test func appendFailureStopsReadingAndDoesNotFinish() async {
        var reads = 0
        await #expect(throws: Failure.append) {
            try await VideoSampleTransfer.run(
                validate: {},
                readNext: {
                    reads += 1; return reads
                }, isReady: { true },
                waitForReadiness: {}, append: { _ in throw Failure.append },
                finish: { Issue.record("Failed append marked finished") })
        }
        #expect(reads == 1)
    }
}

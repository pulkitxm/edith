import EdithKit
import Testing

@Suite struct PerformanceTraceTests {
    @Test func areasCoverTheAuditSurface() {
        #expect(
            Set(PerformanceArea.allCases.map(\.rawValue)) == [
                "startup", "input", "repository", "git", "github", "extensionDiscovery",
                "uiRendering", "cache", "backgroundWorker", "generation", "memory",
                "mainThread", "largeRepository", "slowNetwork",
            ])
    }

    @Test @MainActor func spansCarryStableIdentityAndThreadContext() {
        let span = PerformanceTrace.begin(.input, "test.dispatch")
        defer { PerformanceTrace.end(span) }

        #expect(span.area == .input)
        #expect(span.name == "test.dispatch")
        #expect(span.beganOnMainThread)
    }

    @Test func measuredOperationsPreserveResults() throws {
        let value = try PerformanceTrace.measure(.cache, "test.cache") {
            if Bool(false) { throw CancellationError() }
            return 42
        }

        #expect(value == 42)
    }
}

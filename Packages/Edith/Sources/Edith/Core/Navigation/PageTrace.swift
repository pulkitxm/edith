import EdithKit

@MainActor
enum PageTrace {
    private static var pending: [MainDestination: PerformanceSpan] = [:]

    static func begin(_ destination: MainDestination) {
        if let stale = pending.removeValue(forKey: destination) {
            PerformanceTrace.end(stale)
        }
        pending[destination] = PerformanceTrace.begin(
            .uiRendering, "page.\(destination.rawValue)")
    }

    static func end(_ destination: MainDestination) {
        guard let span = pending.removeValue(forKey: destination) else { return }
        PerformanceTrace.end(span)
    }
}

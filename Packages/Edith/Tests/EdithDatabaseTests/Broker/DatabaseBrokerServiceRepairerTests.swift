import Foundation
import Testing

@testable import EdithDatabase

@Suite
struct DatabaseBrokerServiceRepairerTests {
    @Test func anAbsentServiceNeedsNoManualCleanup() async throws {
        let root = URL(fileURLWithPath: "/tmp", isDirectory: true).appendingPathComponent(
            "eddb-\(UUID().uuidString.prefix(8))",
            isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = DatabaseBrokerPaths(
            dataDirectory: root.appendingPathComponent("data", isDirectory: true),
            runtimeDirectory: root.appendingPathComponent("runtime", isDirectory: true))
        try FileManager.default.createDirectory(
            at: paths.runtimeDirectory,
            withIntermediateDirectories: true)

        try await DatabaseBrokerServiceRepairer(paths: paths).repair()
    }
}

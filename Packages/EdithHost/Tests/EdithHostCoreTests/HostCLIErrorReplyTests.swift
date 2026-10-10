import EdithExtensionSupport
import Foundation
import Testing

@testable import EdithHostCore

@MainActor @Suite struct HostCLIErrorReplyTests {
    @Test func coreErrorsPreserveOriginalExitCodesAcrossActualAuthenticatedSocket() async throws {
        let identifier = "com.pulkit.edith.tests.core-errors-\(UUID().uuidString)"
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(identifier)
        let identity = try HostIdentity(identifier: identifier, supportDirectory: root)
        let defaults = try #require(UserDefaults(suiteName: identifier))
        defer {
            defaults.removePersistentDomain(forName: identifier)
            try? FileManager.default.removeItem(at: root)
        }
        let service = HostCoreCLIService(
            configuration: try HostConfigurationCLI(shared: defaults, standard: defaults),
            action: { _ in throw HostCLIError.unavailable })
        let server = HostCLIServer(identity: identity) { try await service.execute($0) }
        try server.start()
        defer { service.shutdown(); server.shutdown() }
        let cli = HostCommandCLI(
            version: "synthetic",
            tooling: HostToolingCLI(
                home: root, executable: root.appendingPathComponent("ed"), path: []),
            invoke: { request in
                if request.action == .ls { return Data("[]".utf8) }
                return try await HostCommandCLITransport.invoke(request, identity: identity)
            })
        let invalid = await cli.run(["config", "set", "appearance", "invalid"])
        #expect(invalid.exitCode == 2 && invalid.stdout.isEmpty)
        #expect(invalid.stderr == "error: appearance allows: system, light, dark\n")
        #expect(defaults.object(forKey: "appearance") == nil)
        let unavailable = await cli.run(["permissions", "ls"])
        #expect(unavailable.exitCode == 4 && unavailable.stdout.isEmpty)
        #expect(unavailable.stderr == "error: \(HostCLIError.unavailable.localizedDescription)\n")
    }
}

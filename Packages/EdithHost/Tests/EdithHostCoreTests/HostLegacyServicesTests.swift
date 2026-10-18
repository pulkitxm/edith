import Foundation
import Testing

@testable import EdithHostCore

@Suite struct HostLegacyServicesTests {
    private let support = FileManager.default.temporaryDirectory.appendingPathComponent(
        UUID().uuidString)

    @Test func productionRetiresOnlyTheLegacyUserJobs() throws {
        let identity = try HostIdentity(identifier: "com.pulkit.edith", supportDirectory: support)
        var requested: [String] = []
        HostLegacyServices.retire(identity: identity, user: 501) { requested.append($0) }
        #expect(
            requested == [
                "gui/501/com.pulkit.edith.agent", "gui/501/com.pulkit.edith.helper.v2",
            ])
        #expect(!requested.contains { $0.hasPrefix("system/") || $0.contains("lidawake") })
    }

    @Test func developmentAndTestIdentitiesNeverTouchProductionLabels() throws {
        for identifier in [
            "com.pulkit.edith.dev.upgrade-restore", "com.pulkit.edith.tests.legacy-services",
        ] {
            let identity = try HostIdentity(identifier: identifier, supportDirectory: support)
            var requested: [String] = []
            HostLegacyServices.retire(identity: identity, user: 501) { requested.append($0) }
            #expect(requested.isEmpty)
            #expect(HostLegacyServices.targets(identity: identity).isEmpty)
        }
    }
}

import EdithHostCore
import EdithExtensionSupport
import Foundation
import Testing

@testable import EdithHost

@MainActor @Suite struct HostPermissionCLITests {
    @Test func originalPermissionCommandsUseInjectedOSStateAndOnlyExplicitRequests() async throws {
        var requests: [HostPermission] = []
        var opened: [URL] = []
        var granted = false
        let suite = "com.pulkit.edith.tests.permission-cli-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let state = HostPermissions(
            environment: .init(
                read: { [.calendar: granted] },
                request: {
                    requests.append($0); granted = true
                },
                openSettings: {
                    opened.append($0); return true
                }))
        let cli = HostPermissionCLIAdapter(
            permissions: state,
            entries: {
                [
                    .init(
                        id: "calendar", title: "Calendar", symbolName: "calendar", category: "Tools"
                    )
                ]
            }, activeIDs: { ["calendar"] }, defaults: defaults)
        let pending = try await cli.execute(["ls", "--attention", "--json"])
        let rows = try JSONDecoder().decode(HostCLIJSON.self, from: Data(pending.stdout.utf8))
            .object?["permissions"]?.array
        #expect(rows?.count == 1 && rows?.first?.object?["id"] == .string("calendar"))
        #expect(requests.isEmpty && opened.isEmpty)
        let request = try await cli.execute(["request", "CALENDAR", "--json"])
        let result = try JSONDecoder().decode(HostCLIJSON.self, from: Data(request.stdout.utf8))
        #expect(result.object?["granted"] == .bool(true) && requests == [.calendar])
        #expect(defaults.bool(forKey: AppStorageKeys.Permissions.calendarGranted))
        let config = try HostConfigurationCLI(shared: defaults, standard: defaults)
        #expect(
            try config.execute(["get", AppStorageKeys.Permissions.calendarGranted]).stdout
                == "true\n")
        #expect(throws: HostCLIError.self) {
            try config.execute(["set", AppStorageKeys.Permissions.calendarGranted, "false"])
        }
        #expect(defaults.bool(forKey: AppStorageKeys.Permissions.calendarGranted))
        _ = try await cli.execute(["settings", "calendar"])
        #expect(opened == [HostPermission.calendar.settingsURL!])
        await #expect(throws: HostCLIError.self) {
            try await cli.execute(["request", "bluetooth"])
        }
        await #expect(throws: HostCLIError.self) { try await cli.execute(["ls", "--yes"]) }
        #expect(requests == [.calendar])
    }
}

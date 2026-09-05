import Darwin
import Foundation
import Testing

@testable import EdithCLI
@testable import EdithKit

@Suite struct TestIsolationTests {
    private enum FixtureFailure: Error { case expected }

    @Test func cliWorldRestoresItsIncomingDataRootAfterSuccessAndFailure() async throws {
        let previous = try #require(
            ProcessInfo.processInfo.environment[DataRoot.devOverrideVariable])
        let support = DataRoot.support
        await CLIProbe.inWorld { world in
            setenv(DataRoot.devOverrideVariable, world.sandbox.path, 1)
            #expect(DataRoot.support.path == world.sandbox.standardizedFileURL.path)
        }
        #expect(ProcessInfo.processInfo.environment[DataRoot.devOverrideVariable] == previous)
        #expect(DataRoot.support == support)
        do {
            try await CLIProbe.inWorld { world in
                setenv(DataRoot.devOverrideVariable, world.sandbox.path, 1)
                throw FixtureFailure.expected
            }
            Issue.record("The fixture failure should propagate.")
        } catch FixtureFailure.expected {
            #expect(ProcessInfo.processInfo.environment[DataRoot.devOverrideVariable] == previous)
            #expect(DataRoot.support == support)
        }
    }

    @Test func missingPrimaryOverrideStillUsesTheIsolatedHome() async throws {
        try await CLIProbe.exclusive {
            let previous = try #require(
                ProcessInfo.processInfo.environment[DataRoot.devOverrideVariable])
            let isolatedHome = try #require(
                ProcessInfo.processInfo.environment["EDITH_DATABASE_HOME"])
            unsetenv(DataRoot.devOverrideVariable)
            defer { setenv(DataRoot.devOverrideVariable, previous, 1) }
            let expected = URL(fileURLWithPath: isolatedHome).appendingPathComponent(
                "Library/Application Support/Edith")
            #expect(DataRoot.support.path == expected.path)
            #expect(Repo.usageJSON.path == expected.appendingPathComponent("data/usage.json").path)
            #expect(DataRoot.caches.path.hasPrefix(isolatedHome + "/"))
            #expect(
                DataRoot.logs.path
                    == URL(fileURLWithPath: isolatedHome).appendingPathComponent(
                        "Library/Logs/Edith"
                    ).path)
        }
    }

    @Test func defaultTransportAndCloudPathsCannotAddressProduction() throws {
        let environment = ProcessInfo.processInfo.environment
        _ = try #require(environment["EDITH_TEST_RUNTIME_ROOT"])
        let service = try #require(environment["EDITH_AGENT_MACH_SERVICE"])
        let cloud = try #require(environment[AppData.cloudOverrideVariable])
        #expect(service != "com.pulkit.edith.agent")
        #expect(AgentService.machServiceName == service)
        #expect(AgentService.usesCustomService)
        #expect(
            environment["EDITH_DATABASE_KEYCHAIN_SERVICE"]?.hasPrefix("com.pulkit.edith.tests.")
                == true)
        #expect(
            AppData.resolveCloudDirectory().path
                == URL(fileURLWithPath: cloud).standardizedFileURL.path)
        #expect(environment["EDITH_SHARED_DEFAULTS_SUITE"] != SharedDefaults.suiteName)
        #expect(environment["EDITH_HELPER_DEFAULTS_SUITE"] != "com.pulkit.edith.helper")
        #expect(IPC.Name.settingsChanged.rawValue.hasSuffix(service))
    }
}

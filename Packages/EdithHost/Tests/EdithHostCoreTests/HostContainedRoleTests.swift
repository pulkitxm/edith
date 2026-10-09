import Testing
@testable import EdithHostCore

@MainActor @Suite struct HostContainedRoleTests {
    @Test func productionArgumentsAreExactAndNeverAcceptProbes() {
        #expect(
            HostContainedRole.accepts(
                role: "cameraCarrier", arguments: ["--contained-extension-role"], fixture: false))
        #expect(HostContainedRole.accepts(role: "cameraProvider", arguments: [], fixture: false))
        for role in HostContainedRole.roles {
            #expect(
                !HostContainedRole.accepts(
                    role: role, arguments: ["--contained-extension-probe"], fixture: false))
            #expect(
                !HostContainedRole.accepts(
                    role: role, arguments: ["--contained-extension-role", "/tmp/payload"],
                    fixture: false))
        }
        #expect(!HostContainedRole.accepts(role: "arbitrary", arguments: [], fixture: true))
    }
    @Test func isolatedFixturesCanProbeBothContainedRoles() {
        for role in HostContainedRole.roles {
            #expect(
                HostContainedRole.accepts(
                    role: role, arguments: ["--contained-extension-probe"], fixture: true))
        }
    }
}

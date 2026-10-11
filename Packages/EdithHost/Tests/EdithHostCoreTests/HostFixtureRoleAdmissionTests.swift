import Foundation
import Testing

@testable import EdithHostCore

#if EDITH_FUNCTIONAL_FIXTURE
@MainActor @Suite struct HostFixtureRoleAdmissionTests {
    private let app = URL(fileURLWithPath: "/synthetic/app.bundle")
    private let helper = URL(fileURLWithPath: "/synthetic/helper.bundle")
    private let marker = ["sourceCommit": "synthetic"]

    @Test func oneVerifiedRoleDoesNotAuthorizeOtherPresentRoles() throws {
        let admission = HostFixtureRoleAdmission(
            roleDirectory: app, contextMarker: marker, revalidate: {})
        try HostFixtureRoleAdmission.validate(
            [admission], available: [app, helper], markerKeys: ["sourceCommit"])
        #expect([admission].map(\.roleDirectory) == [app])
        let unexpected = HostFixtureRoleAdmission(
            roleDirectory: URL(fileURLWithPath: "/elsewhere/app.bundle"), contextMarker: marker,
            revalidate: {})
        #expect(throws: HostFixtureRoleAdmission.Failure.self) {
            try HostFixtureRoleAdmission.validate(
                [unexpected], available: [app, helper], markerKeys: ["sourceCommit"])
        }
        #expect(throws: HostFixtureRoleAdmission.Failure.self) {
            try HostFixtureRoleAdmission.validate(
                [admission, admission], available: [app, helper], markerKeys: ["sourceCommit"])
        }
    }

    @Test func staleAdmissionBlocksConstructionAndRejectsChangedConstruction() throws {
        var current = false
        var constructed = 0
        let admission = HostFixtureRoleAdmission(roleDirectory: app, contextMarker: marker) {
            guard current else { throw HostFixtureRoleAdmission.Failure.rejected }
        }
        #expect(throws: HostFixtureRoleAdmission.Failure.self) {
            try admission.withCurrent { constructed += 1 }
        }
        #expect(constructed == 0)
        current = true
        #expect(throws: HostFixtureRoleAdmission.Failure.self) {
            try admission.withCurrent {
                constructed += 1; current = false
            }
        }
        #expect(constructed == 1)
    }

    @Test func extraContextMarkerKeysDoNotOverrideOriginalContext() throws {
        let admission = HostFixtureRoleAdmission(
            roleDirectory: app,
            contextMarker: ["sourceCommit": "synthetic", "dataDirectory": "/synthetic/override"],
            revalidate: {})
        #expect(throws: HostFixtureRoleAdmission.Failure.self) {
            try HostFixtureRoleAdmission.validate(
                [admission], available: [app], markerKeys: ["sourceCommit"])
        }
    }
}
#endif

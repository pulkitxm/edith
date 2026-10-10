import Darwin
import Foundation
import ProbeContract
import Testing

private let identifier = "com.pulkit.edith.tests.remote-00000000-0000-4000-8000-000000000001"
private let environment = [
    "GITHUB_ACTIONS": "true", "RUNNER_OS": "macOS", "RUNNER_ENVIRONMENT": "github-hosted",
    "EDITH_HOSTED_MANAGED_PROBE": "1",
]

private func fixture(_ changes: [String: Any] = [:]) throws -> ProbeFixture {
    let directory = "/synthetic/home/Applications/Edith Remote Fixture Probe"
    let carrier =
        directory + "/support/Edith Tests/remote-00000000-0000-4000-8000-000000000001"
        + "/Extensions/calendar/edith-host-2/arm64/1.0.0/calendar/ExtensionCarrier.app"
    var value: [String: Any] = [
        "directory": directory, "app": directory + "/Host.app",
        "executable": directory + "/Host.app/Contents/MacOS/Edith", "carrier": carrier,
        "worker": carrier + "/Contents/Extensions/ExtensionWorker.appex", "identifier": identifier,
        "extensionID": "calendar", "version": "1.0.0", "hostABI": "edith-host-2",
        "hostExecutableSHA256": String(repeating: "a", count: 64), "backgroundOnly": true,
    ]
    value.merge(changes) { _, new in new }
    return try JSONDecoder().decode(
        ProbeFixture.self, from: JSONSerialization.data(withJSONObject: value))
}

@Test func exactOwnedUUIDFixtureIsAdmitted() throws {
    try fixture().validate(home: URL(fileURLWithPath: "/synthetic/home"), environment: environment)
}

@Test func sandboxContainerCannotReplaceAccountHome() throws {
    let selected = try fixture()
    let account = URL(fileURLWithPath: "/synthetic/home")
    let container = account.appendingPathComponent(
        "Library/Containers/com.pulkit.edith.tests.hosted-managed-ui.xctrunner/Data")
    #expect(throws: ProbeContractError.invalidFixtureField("directoryOutsideAccountHome")) {
        try selected.validate(home: container, environment: environment)
    }
    try selected.validate(home: account, environment: environment)
    #expect(throws: ProbeContractError.invalidFixtureField("directoryOutsideAccountHome")) {
        try selected.validate(
            home: URL(fileURLWithPath: "/synthetic/other"), environment: environment)
    }
}

@Test func accountHomeResolvesCurrentAccountWithoutEnvironmentMutation() throws {
    let home = try ProbeRunner.accountHome()
    let account = try #require(getpwuid(getuid()))
    #expect(home.path == String(cString: account.pointee.pw_dir))
    #expect(home.path.hasPrefix("/"))
    #expect(home.standardizedFileURL.path == home.path)
}

@Test func hostedProducerNestedCalendarShapeIsAdmitted() throws {
    let uuid = "01873b63-4a37-46d7-95fc-5de23a79afca"
    let directory = "/synthetic/runner/Applications/Edith Remote Fixture Hosted " + uuid
    let carrier =
        directory + "/support/Edith Tests/remote-" + uuid
        + "/Extensions/calendar/edith-host-2/arm64/1.0.0/calendar/ExtensionCarrier.app"
    let selected = try fixture([
        "identifier": "com.pulkit.edith.tests.remote-" + uuid, "directory": directory,
        "app": directory + "/Host.app", "executable": directory + "/Host.app/Contents/MacOS/Edith",
        "carrier": carrier, "worker": carrier + "/Contents/Extensions/ExtensionWorker.appex",
    ])
    try selected.validate(home: URL(fileURLWithPath: "/synthetic/runner"), environment: environment)
    #expect(
        selected.workerIdentifier == "com.pulkit.edith.tests.remote-" + uuid
            + ".extension.calendar.worker")
    #expect(throws: ProbeContractError.invalidFixtureField("nestedRolePaths")) {
        try fixture(["carrier": directory + "/ExtensionCarrier.app"]).validate(
            home: URL(fileURLWithPath: "/synthetic/home"), environment: environment)
    }
}

@Test(arguments: [
    "GITHUB_ACTIONS", "RUNNER_OS", "RUNNER_ENVIRONMENT", "EDITH_HOSTED_MANAGED_PROBE",
])
func localOrIncompleteRunnerIsRejected(key: String) throws {
    var rejected = environment
    rejected.removeValue(forKey: key)
    #expect(throws: ProbeContractError.untrustedRunner) {
        try fixture().validate(home: URL(fileURLWithPath: "/synthetic/home"), environment: rejected)
    }
}

@Test func alteredFixtureIsRejected() throws {
    for changes in [
        ["identifier": "com.pulkit.edith.tests.remote-owned-20261010"],
        ["identifier": "com.pulkit.edith"],
        ["extensionID": "usage"], ["version": "1.0"], ["backgroundOnly": false],
        ["app": "/Applications/Edith.app"], ["executable": "/synthetic/other"],
        ["worker": "/synthetic/flat/ExtensionWorker.appex"],
        ["directory": "/synthetic/home/Applications/Edith Remote Fixture Probe/../foreign"],
        ["hostExecutableSHA256": "bad"],
    ] as [[String: Any]] {
        #expect(throws: (any Error).self) {
            try fixture(changes).validate(
                home: URL(fileURLWithPath: "/synthetic/home"), environment: environment)
        }
    }
}

private func control(_ label: String, value: String? = "0", hittable: Bool = true)
    -> ProbeApprovalControl
{
    .init(kind: "checkbox", labels: [label], value: value, enabled: true, hittable: hittable)
}

@Test func approvalOnlySelectsExactLabel() throws {
    #expect(
        try ProbeApproval.select(
            [control("other"), control("Edith calendar")], expectedLabel: "Edith calendar") == 1)
    for controls in [
        [], [control("other")], [control("Edith calendar"), control("Edith calendar")],
    ] {
        #expect(throws: ProbeContractError.ambiguousControl) {
            try ProbeApproval.select(controls, expectedLabel: "Edith calendar")
        }
    }
}

@Test func unknownToggleStateAndUnhittableControlAreRejected() {
    for candidate in [
        control("Edith calendar", value: nil), control("Edith calendar", value: "mixed"),
        control("Edith calendar", hittable: false),
    ] {
        #expect(throws: ProbeContractError.unsupportedControl) {
            try ProbeApproval.select([candidate], expectedLabel: "Edith calendar")
        }
    }
}

@Test func engineOrApprovalResultCannotPassManagedProof() throws {
    let selected = try fixture()
    for value in [
        ["outcome": "passed", "engineLifecycleValidated": true],
        ["outcome": "passed", "approvalRequired": true],
        ["outcome": "passed", "managedNativeViewValidated": true],
    ] as [[String: Any]] {
        #expect(throws: ProbeContractError.incompleteProof) {
            try ProbeApproval.validateManagedProof(
                JSONSerialization.data(withJSONObject: value), fixture: selected)
        }
    }
}

@Test func everyManagedProofConditionIsRequired() throws {
    let selected = try fixture()
    var value: [String: Any] = [
        "outcome": "passed", "extensionID": "calendar", "selectedVersion": "1.0.0",
        "hostABI": "edith-host-2", "nativeWindow": false, "disabledProcesses": 0,
    ]
    let conditions = [
        "managedNativeViewValidated", "originalDownloadedRole", "readonlyControlVerified",
        "publicCarrierCheckIn", "freshSceneGeneration", "lastCloseExited",
        "disableExitedBothRoles", "packageLeaseReleased", "noVisibleWindows",
    ]
    for key in conditions { value[key] = true }
    try ProbeApproval.validateManagedProof(
        JSONSerialization.data(withJSONObject: value), fixture: selected)
    for key in conditions + ["selectedVersion", "hostABI", "disabledProcesses"] {
        var incomplete = value
        incomplete.removeValue(forKey: key)
        #expect(throws: ProbeContractError.incompleteProof) {
            try ProbeApproval.validateManagedProof(
                JSONSerialization.data(withJSONObject: incomplete), fixture: selected)
        }
    }
}

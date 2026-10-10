import Foundation
import XCTest

@MainActor
final class ManagedNativeUITests: XCTestCase {
    func testPublicApprovalAndActualManagedCalendarView() throws {
        continueAfterFailure = false
        let environment = ProcessInfo.processInfo.environment
        let directory = try XCTUnwrap(environment["EDITH_HOSTED_FIXTURE_DIRECTORY"])
        let root = URL(fileURLWithPath: directory)
        let fixture = try JSONDecoder().decode(
            ProbeFixture.self, from: Data(contentsOf: root.appendingPathComponent("fixture.json")))
        try fixture.validate(
            home: FileManager.default.homeDirectoryForCurrentUser, environment: environment)
        let application = XCUIApplication(url: URL(fileURLWithPath: fixture.app))
        application.launchArguments = ["--extension-hosted-approval-probe", directory]
        application.launchEnvironment = environment.filter {
            ["GITHUB_ACTIONS", "RUNNER_OS", "RUNNER_ENVIRONMENT", "EDITH_HOSTED_MANAGED_PROBE"]
                .contains($0.key)
        }
        application.launch()
        defer { if application.state != .notRunning { application.terminate() } }
        let title = "Managed Calendar Approval \(fixture.identifier)"
        let window = application.windows.matching(
            NSPredicate(format: "label == %@ OR identifier == %@", title, title))
        XCTAssertTrue(window.firstMatch.waitForExistence(timeout: 30))
        XCTAssertEqual(window.count, 1)
        let ready = try readJSON(root.appendingPathComponent("approval-ready.json"))
        XCTAssertEqual(ready["hostIdentifier"] as? String, fixture.identifier)
        XCTAssertEqual(ready["workerIdentifier"] as? String, fixture.workerIdentifier)
        XCTAssertEqual(ready["publicBrowser"] as? Bool, true)
        let label = try XCTUnwrap(ready["expectedLabel"] as? String)
        XCTAssertEqual(label, "Edith calendar")
        let scope = window.element(boundBy: 0)
        let available = wait(30) {
            scope.checkBoxes.count > 0 || scope.switches.count > 0
        }
        XCTAssertTrue(available, "Public approval browser did not expose toggle controls")
        let control = try exactControl(scope: scope, label: label)
        guard control.value as? String == "0" else {
            throw ProbeContractError.unsupportedControl
        }
        control.click()
        XCTAssertTrue(
            wait(60) {
                FileManager.default.fileExists(
                    atPath: root.appendingPathComponent("public-identity.json").path)
            }, "Public enabled identity was not discovered")
        let identity = try readJSON(root.appendingPathComponent("public-identity.json"))
        XCTAssertEqual(identity["publicDiscovery"] as? Bool, true)
        XCTAssertEqual(identity["workerIdentifier"] as? String, fixture.workerIdentifier)
        XCTAssertEqual(
            identity["extensionPointIdentifier"] as? String, fixture.identifier + ".ExtensionUI")
        application.terminate()
        let command = Process()
        command.executableURL = URL(fileURLWithPath: try XCTUnwrap(environment["EDITH_PROBE_BUN"]))
        command.arguments = ["scripts/test-managed-shipping-ui.mjs", directory]
        command.currentDirectoryURL = URL(
            fileURLWithPath: try XCTUnwrap(environment["EDITH_PROBE_ROOT"]))
        command.environment = environment
        let logURL = root.appendingPathComponent("managed-view.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let log = try FileHandle(forWritingTo: logURL)
        defer { try? log.close() }
        command.standardOutput = log
        command.standardError = log
        try command.run()
        defer { if command.isRunning { command.terminate() } }
        XCTAssertTrue(
            wait(110) { !command.isRunning },
            "Actual managed view did not finish within its deadline")
        XCTAssertEqual(
            command.terminationStatus, 0, "Actual managed fixture failed; inspect managed-view.log")
        let proof = try Data(
            contentsOf: root.appendingPathComponent("result-managed-shipping.json"))
        try ProbeApproval.validateManagedProof(proof, fixture: fixture)
        try JSONSerialization.data(
            withJSONObject: [
                "outcome": "passed", "publicBrowserApproval": true,
                "publicIdentityDiscovered": true,
                "managedNativeViewValidated": true, "extensionID": fixture.extensionID,
                "hostIdentifier": fixture.identifier, "version": fixture.version,
                "installerUpdateRemovalValidated": false, "visibleOriginalUXValidated": false,
            ], options: [.sortedKeys]
        ).write(to: root.appendingPathComponent("hosted-probe-result.json"), options: .atomic)
    }

    private func exactControl(scope: XCUIElement, label: String) throws -> XCUIElement {
        let rows = scope.descendants(matching: .tableRow).allElementsBoundByIndex
        guard rows.count <= 128 else { throw ProbeContractError.ambiguousControl }
        let matchingRows = rows.filter {
            $0.staticTexts.matching(NSPredicate(format: "label == %@", label)).count == 1
        }
        let controls: [XCUIElement]
        let rowLabel: [String]
        if !matchingRows.isEmpty {
            guard matchingRows.count == 1 else { throw ProbeContractError.ambiguousControl }
            controls =
                matchingRows[0].checkBoxes.allElementsBoundByIndex
                + matchingRows[0].switches.allElementsBoundByIndex
            guard controls.count == 1 else { throw ProbeContractError.ambiguousControl }
            rowLabel = [label]
        } else {
            controls =
                scope.checkBoxes.allElementsBoundByIndex + scope.switches.allElementsBoundByIndex
            rowLabel = []
        }
        let index = try ProbeApproval.select(
            controls.map {
                ProbeApprovalControl(
                    kind: $0.elementType == .checkBox ? "checkbox" : "switch",
                    labels: [$0.label, $0.identifier] + rowLabel, value: $0.value as? String,
                    enabled: $0.isEnabled, hittable: $0.isHittable)
            }, expectedLabel: label)
        return controls[index]
    }

    private func readJSON(_ url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        guard data.count <= 16_384 else { throw ProbeContractError.invalidFixture }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func wait(_ seconds: TimeInterval, _ condition: @escaping () -> Bool) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in condition() }, object: nil)
        return XCTWaiter.wait(for: [expectation], timeout: seconds) == .completed
    }
}

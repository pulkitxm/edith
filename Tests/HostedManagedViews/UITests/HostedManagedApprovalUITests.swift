import Foundation
import XCTest

@MainActor
final class HostedManagedApprovalUITests: XCTestCase {
    func testPublicApprovalAndOwnedHostCompletion() throws {
        continueAfterFailure = false
        let environment = ProcessInfo.processInfo.environment
        let directory = URL(
            fileURLWithPath: try XCTUnwrap(environment["EDITH_HOSTED_MANAGED_DIRECTORY"]))
        let route = try HostedManagedApprovalRoute.load(
            directory: directory, environment: environment)
        XCTAssertEqual(environment["EDITH_HOSTED_MANAGED_IDENTIFIER"], route.hostIdentifier)
        try route.validateHostedDirectory()
        let application = XCUIApplication(bundleIdentifier: route.hostIdentifier)
        application.launchArguments = ["--extension-remote-registration-fixture", directory.path]
        application.launchEnvironment = try route.applicationEnvironment(environment)
        application.launch()
        defer { if application.state != .notRunning { application.terminate() } }
        let windows = application.windows.matching(
            NSPredicate(
                format: "label == %@ OR identifier == %@", route.windowTitle, route.windowTitle))
        XCTAssertTrue(wait(45) { windows.count > 0 || application.state == .notRunning })
        var clicked = false
        if windows.count > 0 {
            XCTAssertEqual(windows.count, 1)
            let window = windows.element(boundBy: 0)
            XCTAssertTrue(wait(30) { window.checkBoxes.count > 0 || window.switches.count > 0 })
            try exactControl(window: window, label: route.expectedLabel).click()
            clicked = true
            XCTAssertTrue(
                wait(90) { windows.count == 0 }, "Owned public approval browser did not close")
        }
        XCTAssertTrue(
            wait(180) { application.state == .notRunning },
            "Owned managed fixture host did not finish")
        let data = try JSONSerialization.data(
            withJSONObject: [
                "schema": 1, "sourceCommit": route.sourceCommit, "extensionID": route.extensionID,
                "hostIdentifier": route.hostIdentifier, "workerIdentifier": route.workerIdentifier,
                "approvalClickPerformed": clicked, "approvalWindowRemaining": windows.count,
                "hostExited": application.state == .notRunning, "managedViewReady": false,
                "producerReceiptRequired": true,
            ], options: [.sortedKeys])
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "Hosted approval interaction " + route.extensionID
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func exactControl(window: XCUIElement, label: String) throws -> XCUIElement {
        let rows = window.descendants(matching: .tableRow).allElementsBoundByIndex
        guard rows.count <= 128 else { throw HostedManagedApprovalError.ambiguousControl }
        let matching = rows.filter {
            $0.staticTexts.matching(NSPredicate(format: "label == %@", label)).count == 1
        }
        let controls: [XCUIElement]
        let rowLabel: [String]
        if !matching.isEmpty {
            guard matching.count == 1 else { throw HostedManagedApprovalError.ambiguousControl }
            controls =
                matching[0].checkBoxes.allElementsBoundByIndex
                + matching[0].switches.allElementsBoundByIndex
            guard controls.count == 1 else { throw HostedManagedApprovalError.ambiguousControl }
            rowLabel = [label]
        } else {
            controls =
                window.checkBoxes.allElementsBoundByIndex + window.switches.allElementsBoundByIndex
            rowLabel = []
        }
        let index = try HostedManagedApprovalSelection.select(
            controls.map {
                HostedManagedApprovalControl(
                    kind: $0.elementType == .checkBox ? "checkbox" : "switch",
                    labels: [$0.label, $0.identifier] + rowLabel, value: $0.value as? String,
                    enabled: $0.isEnabled, hittable: $0.isHittable)
            }, expectedLabel: label)
        return controls[index]
    }

    private func wait(_ seconds: TimeInterval, _ condition: @escaping () -> Bool) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in condition() }, object: nil)
        return XCTWaiter.wait(for: [expectation], timeout: seconds) == .completed
    }
}

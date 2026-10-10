import AppKit
import CoreServices
import CryptoKit
import Darwin
import Foundation
import Security
import XCTest

@MainActor
final class OriginalShellJourneyTests: XCTestCase {
    private var root = URL(fileURLWithPath: "/")
    private var snapshots: [[String: Any]] = []
    private var startup: [String: Any] = [:]
    private var outcomeSequence = 0
    private var windowImages: [String: Data] = [:]

    func testOriginalCalendarInstallCustomizeReplaceUpdateDisableAndRemove() throws {
        continueAfterFailure = false
        let environment = ProcessInfo.processInfo.environment
        root = URL(fileURLWithPath: try XCTUnwrap(environment["EDITH_GUI_FIXTURE_DIRECTORY"]))
        let fixture = try JSONDecoder().decode(
            JourneyFixture.self, from: Data(contentsOf: root.appendingPathComponent("journey.json"))
        )
        let accountHome = try XCTUnwrap(environment["EDITH_JOURNEY_ACCOUNT_HOME"])
        try fixture.validate(accountHome: accountHome, environment: environment)
        let application = XCUIApplication(bundleIdentifier: fixture.identifier)
        application.launchEnvironment = try fixture.applicationEnvironment(from: environment)
        defer {
            if application.state != .notRunning { application.terminate() }
            try? saveOutcome()
        }
        try registerApplication(fixture)
        application.launch()
        let windowPresent = application.windows.firstMatch.waitForExistence(timeout: 30)
        startup.merge([
            "windowPresent": windowPresent, "applicationState": application.state.rawValue,
            "windowCount": application.windows.count,
        ]) { _, next in next }
        try saveOutcome()
        XCTAssertTrue(windowPresent)
        try waitState("empty-idle") { state in
            (state["downloaded"] as? [String]) == [] && (state["workers"] as? [String: Int]) == [:]
        }
        XCTAssertFalse(application.buttons["journey.navigation.machines"].exists)
        XCTAssertFalse(application.buttons["journey.navigation.docs"].exists)
        try click(application.buttons["Essentials"], in: application)
        let indexData = try Data(
            contentsOf: URL(fileURLWithPath: fixture.application)
                .appendingPathComponent("Contents/Resources/index.json"))
        let entries = try XCTUnwrap(
            JSONSerialization.jsonObject(with: indexData) as? [[String: Any]])
        XCTAssertEqual(entries.count, 39)
        for id in ["clipboard", "system", "keepAwake", "emoji"] {
            let entry = try XCTUnwrap(entries.first { $0["id"] as? String == id })
            let title = try XCTUnwrap(entry["title"] as? String)
            let checkbox = application.checkBoxes[title]
            try reveal(checkbox, in: application)
            XCTAssertEqual(checkbox.value as? String, "1")
            checkbox.click()
            XCTAssertEqual(checkbox.value as? String, "0")
        }
        try click(application.buttons["Install 1 extensions"], in: application)
        try waitState("recommended-calendar-installed") {
            ($0["versions"] as? [String: String])?["calendar"] == "1.0.0"
                && ($0["active"] as? [String]) == ["calendar"]
        }
        try click(application.buttons["Go to Home"], in: application)
        try click(application.buttons["journey.navigation.calendar"], in: application)
        try approveCalendarIfNeeded(application, identifier: fixture.identifier)
        XCTAssertTrue(
            application.staticTexts["Synthetic Calendar review"].waitForExistence(timeout: 45))
        try waitState("calendar-native-view") {
            ($0["presentationCounts"] as? [String: Int])?["calendar", default: 0] ?? 0 > 0
                && ($0["ownedProcesses"] as? [[String: Any]])?.contains {
                    $0["role"] as? String == "managedUI" && $0["running"] as? Bool == true
                } == true
        }
        try click(application.buttons["Details"].firstMatch, in: application)
        XCTAssertTrue(
            application.staticTexts["Synthetic agenda notes"].waitForExistence(timeout: 15))
        try capture("calendar-native-use")
        try click(application.buttons["journey.navigation.home"], in: application)
        try click(application.buttons["Widget editor"], in: application)
        let before = try state()
        try click(application.buttons["Add Meetings"], in: application)
        try waitState("home-customized") {
            Self.tiles($0, target: "home").count > Self.tiles(before, target: "home").count
        }
        try click(application.buttons["Notch"], in: application)
        let beforeNotch = try state()
        try click(application.buttons["Add Meetings"], in: application)
        try waitState("notch-customized") {
            Self.tiles($0, target: "notch").count > Self.tiles(beforeNotch, target: "notch").count
        }
        let customized = try state()
        let home = try canonical(customized["home"])
        let notch = try canonical(customized["notch"])
        try click(application.buttons["journey.navigation.extensions"], in: application)
        try findCalendar(application)
        try captureWindow(application, fixture: fixture, name: "marketplace-installed-calendar.png")
        try click(application.buttons["Disable"], in: application)
        try waitState("disabled-drained") {
            ($0["workers"] as? [String: Int]) == [:]
                && ($0["presentationCounts"] as? [String: Int]) == [:]
                && !Self.running($0, role: "engine")
                && !Self.running($0, role: "managedUI")
        }
        try assertLayouts(home: home, notch: notch)
        XCTAssertFalse(application.buttons["journey.navigation.calendar"].exists)
        try click(application.buttons["Enable"], in: application)
        try waitState("reenabled-original-version") {
            ($0["versions"] as? [String: String])?["calendar"] == "1.0.0"
        }
        application.terminate()
        XCTAssertTrue(wait(15) { !self.latestRunningProcesses() })
        try replaceApplication(fixture)
        try Data(contentsOf: root.appendingPathComponent("updated-catalog.json"))
            .write(to: root.appendingPathComponent("active-catalog.json"), options: .atomic)
        try registerApplication(fixture)
        application.launch()
        XCTAssertTrue(application.windows.firstMatch.waitForExistence(timeout: 30))
        try waitState("replacement-restored-installed-state") {
            $0["applicationVersion"] as? String == "2.0.0"
                && ($0["versions"] as? [String: String])?["calendar"] == "1.0.0"
        }
        try assertLayouts(home: home, notch: notch)
        try click(application.buttons["journey.navigation.extensions"], in: application)
        try findCalendar(application)
        try click(application.buttons["Check for Updates"], in: application)
        try click(application.buttons["Update"], in: application)
        try waitState("updated-calendar-version") {
            ($0["versions"] as? [String: String])?["calendar"] == "1.1.0"
        }
        try assertLayouts(home: home, notch: notch)
        try click(application.buttons["Open"], in: application)
        try approveCalendarIfNeeded(application, identifier: fixture.identifier)
        XCTAssertTrue(
            application.staticTexts["Synthetic Calendar review"].waitForExistence(timeout: 45))
        try click(application.buttons["journey.navigation.extensions"], in: application)
        try findCalendar(application)
        try click(application.buttons["Disable"], in: application)
        try waitState("updated-disabled-drained") {
            ($0["workers"] as? [String: Int]) == [:]
                && ($0["presentationCounts"] as? [String: Int]) == [:]
                && !Self.running($0, role: "engine")
                && !Self.running($0, role: "managedUI")
        }
        try click(application.buttons["Remove"], in: application)
        try waitState("removed-packages") { ($0["downloaded"] as? [String]) == [] }
        try assertLayouts(home: home, notch: notch)
        try verifyProtected(fixture)
        try click(application.buttons["journey.navigation.settings"], in: application)
        try click(application.buttons["journey.section.settings.storage"], in: application)
        XCTAssertTrue(application.staticTexts["Measured storage"].waitForExistence(timeout: 30))
        XCTAssertTrue(
            application.staticTexts[
                "Actual files on this Mac, with download sizes shown separately."
            ].exists)
        try capture("storage-after-removal")
        try captureWindow(application, fixture: fixture, name: "storage-distribution.png")
        application.terminate()
        try verifyProtected(fixture)
        XCTAssertEqual(snapshots.count, 13)
        XCTAssertEqual(windowImages.count, 2)
        for name in ["marketplace-installed-calendar.png", "storage-distribution.png"] {
            let bytes = try XCTUnwrap(windowImages[name])
            let attachment = XCTAttachment(data: bytes, uniformTypeIdentifier: "public.png")
            attachment.name = "edith-journey-" + name
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    private func captureWindow(
        _ application: XCUIApplication, fixture: JourneyFixture, name: String
    ) throws {
        let environment = ProcessInfo.processInfo.environment
        try fixture.validate(
            accountHome: try XCTUnwrap(environment["EDITH_JOURNEY_ACCOUNT_HOME"]),
            environment: environment)
        try fixture.validateApplicationEnvironment(application.launchEnvironment)
        XCTAssertEqual(root.resolvingSymlinksInPath().standardizedFileURL, root.standardizedFileURL)
        XCTAssertTrue(
            ["marketplace-installed-calendar.png", "storage-distribution.png"].contains(name))
        let window = application.windows.firstMatch
        XCTAssertTrue(window.exists)
        let bytes = window.screenshot().pngRepresentation
        XCTAssertGreaterThan(bytes.count, 0)
        XCTAssertLessThanOrEqual(bytes.count, 8_388_608)
        XCTAssertNil(windowImages[name])
        windowImages[name] = bytes
    }

    private func findCalendar(_ application: XCUIApplication) throws {
        let search = application.textFields["Find extensions"]
        try reveal(search, in: application)
        search.click()
        search.typeKey("a", modifierFlags: .command)
        search.typeText("Calendar")
    }

    private func approveCalendarIfNeeded(_ application: XCUIApplication, identifier: String) throws
    {
        XCTAssertTrue(
            wait(30) {
                application.buttons["Extension settings"].exists
                    || application.staticTexts["Synthetic Calendar review"].exists
            })
        if !application.buttons["Extension settings"].exists { return }
        try click(application.buttons["Extension settings"], in: application)
        let expected = "Edith calendar"
        let matching = application.checkBoxes.matching(
            NSPredicate(format: "label == %@ OR identifier == %@", expected, expected))
        let switches = application.switches.matching(
            NSPredicate(format: "label == %@ OR identifier == %@", expected, expected))
        XCTAssertTrue(wait(15) { application.sheets.firstMatch.exists })
        let sheet = application.sheets.firstMatch
        let rows = sheet.descendants(matching: .tableRow).allElementsBoundByIndex
        XCTAssertLessThanOrEqual(rows.count, 128)
        let selected = rows.filter { $0.staticTexts[expected].exists }
        let control: XCUIElement
        if selected.count == 1 {
            let controls =
                selected[0].checkBoxes.allElementsBoundByIndex
                + selected[0].switches.allElementsBoundByIndex
            XCTAssertEqual(controls.count, 1)
            control = try XCTUnwrap(controls.first)
        } else {
            XCTAssertEqual(selected.count, 0)
            XCTAssertTrue(wait(15) { matching.count + switches.count == 1 })
            control = matching.count == 1 ? matching.element : switches.element
        }
        XCTAssertTrue(control.isHittable)
        if control.value as? String == "0" { control.click() }
        XCTAssertEqual(control.value as? String, "1")
        application.typeKey(.escape, modifierFlags: [])
        if application.buttons["Try again"].exists {
            try click(application.buttons["Try again"], in: application)
        }
    }

    private func click(_ element: XCUIElement, in application: XCUIApplication) throws {
        try reveal(element, in: application)
        XCTAssertTrue(wait(30) { element.isEnabled })
        element.click()
    }

    private func reveal(_ element: XCUIElement, in application: XCUIApplication) throws {
        XCTAssertTrue(element.waitForExistence(timeout: 30))
        for _ in 0..<20 where !element.isHittable {
            let label = element.identifier.isEmpty ? element.label : element.identifier
            let scroll = application.scrollViews.containing(element.elementType, identifier: label)
                .allElementsBoundByIndex.min {
                    $0.frame.height * $0.frame.width < $1.frame.height * $1.frame.width
                }
            try XCTUnwrap(scroll).scroll(byDeltaX: 0, deltaY: -400)
        }
        XCTAssertTrue(element.isHittable)
    }

    private func state() throws -> [String: Any] {
        let data = try Data(contentsOf: root.appendingPathComponent("state.json"))
        XCTAssertLessThanOrEqual(data.count, 131_072)
        let state = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(state["protectedDataUnchanged"] as? Bool, true)
        XCTAssertEqual(state["declinedPermissionRequests"] as? Int, 0)
        return state
    }

    private func waitState(_ stage: String, predicate: @escaping ([String: Any]) -> Bool) throws {
        XCTAssertTrue(wait(45) { (try? self.state()).map(predicate) == true }, stage)
        try capture(stage)
    }

    private func capture(_ stage: String) throws {
        snapshots.append(["stage": stage, "state": try state()])
        try saveOutcome()
    }

    private func saveOutcome() throws {
        outcomeSequence += 1
        XCTAssertLessThanOrEqual(outcomeSequence, 64)
        let bytes = try JSONSerialization.data(
            withJSONObject: [
                "schema": 1, "sequence": outcomeSequence, "startup": startup,
                "snapshots": snapshots,
            ], options: .sortedKeys)
        XCTAssertLessThanOrEqual(bytes.count, 2_097_152)
        let attachment = XCTAttachment(data: bytes, uniformTypeIdentifier: "public.json")
        attachment.name = String(format: "edith-journey-outcome-%04d.json", outcomeSequence)
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func canonical(_ value: Any?) throws -> Data {
        try JSONSerialization.data(withJSONObject: XCTUnwrap(value), options: .sortedKeys)
    }

    private func assertLayouts(home: Data, notch: Data) throws {
        let current = try state()
        XCTAssertEqual(try canonical(current["home"]), home)
        XCTAssertEqual(try canonical(current["notch"]), notch)
    }

    private func verifyProtected(_ fixture: JourneyFixture) throws {
        let actual = try Dictionary(
            uniqueKeysWithValues: fixture.protectedRelativePaths.map {
                (
                    $0,
                    SHA256.hash(data: try Data(contentsOf: root.appendingPathComponent($0))).map {
                        String(format: "%02x", $0)
                    }.joined()
                )
            })
        try fixture.verifyProtectedDigests(actual)
    }

    private func registerApplication(_ fixture: JourneyFixture) throws {
        let environment = ProcessInfo.processInfo.environment
        let accountHome = try XCTUnwrap(environment["EDITH_JOURNEY_ACCOUNT_HOME"])
        let account = try XCTUnwrap(getpwuid(getuid()))
        let actualHome = String(cString: account.pointee.pw_dir)
        startup.merge([
            "stage": "before-registration",
            "runnerHomeCategory": fixture.homeCategory(
                environment["HOME"], accountHome: actualHome),
            "fixedHomeCategory": fixture.homeCategory(
                environment["CFFIXED_USER_HOME"], accountHome: actualHome),
            "foundationHomeCategory": fixture.homeCategory(
                NSHomeDirectory(), accountHome: actualHome),
            "accountHomeMatched": accountHome == actualHome,
        ]) { _, next in next }
        try saveOutcome()
        XCTAssertEqual(accountHome, actualHome)
        XCTAssertEqual(environment["HOME"], actualHome)
        XCTAssertNotEqual(environment["CFFIXED_USER_HOME"], fixture.home)
        let app = URL(fileURLWithPath: fixture.application)
        let executable = URL(fileURLWithPath: fixture.executable)
        for (url, type) in [
            (root, FileAttributeType.typeDirectory), (app, .typeDirectory),
            (executable, .typeRegular),
        ] {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            XCTAssertEqual(attributes[.type] as? FileAttributeType, type)
            XCTAssertEqual((attributes[.ownerAccountID] as? NSNumber)?.uint32Value, getuid())
            XCTAssertEqual(url.resolvingSymlinksInPath().path, url.path)
            XCTAssertEqual(
                ((attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1) & 0o022, 0)
        }
        let info = try XCTUnwrap(
            PropertyListSerialization.propertyList(
                from: Data(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
                format: nil) as? [String: Any])
        let bytes = try Data(contentsOf: executable)
        try fixture.validateRegistrationMetadata(
            identifier: info["CFBundleIdentifier"] as? String,
            executableName: info["CFBundleExecutable"] as? String,
            packageType: info["CFBundlePackageType"] as? String,
            version: info["CFBundleShortVersionString"] as? String,
            executableDigest: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
        var code: SecStaticCode?
        let creation = SecStaticCodeCreateWithPath(app as CFURL, [], &code)
        startup["signatureCreationStatus"] = creation
        try saveOutcome()
        XCTAssertEqual(creation, errSecSuccess)
        let signature = SecStaticCodeCheckValidity(
            try XCTUnwrap(code),
            SecCSFlags(
                rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures | kSecCSCheckNestedCode
            ), nil)
        startup.merge([
            "signatureStatus": signature, "canonicalLayoutMatched": true,
            "metadataMatched": true, "stage": "registering",
        ]) { _, next in next }
        try saveOutcome()
        XCTAssertEqual(signature, errSecSuccess)
        let status = LSRegisterURL(app as CFURL, true)
        startup["registrationStatus"] = status
        try saveOutcome()
        XCTAssertEqual(status, noErr)
        let registered = NSWorkspace.shared.urlsForApplications(
            withBundleIdentifier: fixture.identifier)
        let matched = registered.map { $0.resolvingSymlinksInPath().path } == [fixture.application]
        startup.merge([
            "registeredCount": registered.count, "uniqueRegisteredPathMatched": matched,
            "stage": "registered",
        ]) { _, next in next }
        try saveOutcome()
        XCTAssertTrue(matched)
    }

    private func replaceApplication(_ fixture: JourneyFixture) throws {
        let original = URL(fileURLWithPath: fixture.application)
        let replacement = root.appendingPathComponent("replacement/Host.payload")
        XCTAssertEqual(original.path, root.appendingPathComponent("Host.app").path)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent("previous/Host.payload").path))
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("previous"), withIntermediateDirectories: false)
        try FileManager.default.moveItem(
            at: original, to: root.appendingPathComponent("previous/Host.payload"))
        try FileManager.default.copyItem(at: replacement, to: original)
    }

    private func latestRunningProcesses() -> Bool {
        guard let value = try? state() else { return false }
        let owned = value["ownedProcesses"] as? [[String: Any]] ?? []
        return owned.contains { item in
            guard let pid = item["pid"] as? Int32, let generation = item["generation"] as? String,
                ["engine", "managedUI"].contains(item["role"] as? String ?? "")
            else { return false }
            var info = proc_bsdinfo()
            let size = MemoryLayout<proc_bsdinfo>.size
            return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(size)) == size
                && info.pbi_uid == getuid()
                && "\(info.pbi_start_tvsec):\(info.pbi_start_tvusec)" == generation
        }
    }

    private static func running(_ state: [String: Any], role: String) -> Bool {
        (state["ownedProcesses"] as? [[String: Any]])?.contains {
            $0["role"] as? String == role && $0["running"] as? Bool == true
        } == true
    }

    private static func tiles(_ state: [String: Any], target: String) -> [[String: Any]] {
        (state[target] as? [String: Any])?["tiles"] as? [[String: Any]] ?? []
    }

    private func wait(_ seconds: TimeInterval, _ condition: @escaping () -> Bool) -> Bool {
        XCTWaiter.wait(
            for: [
                XCTNSPredicateExpectation(
                    predicate: NSPredicate { _, _ in condition() }, object: nil)
            ], timeout: seconds) == .completed
    }
}

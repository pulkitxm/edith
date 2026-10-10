import AppKit
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
    private var lastState: [String: Any] = [:]
    private var windowImages: [String: Data] = [:]

    func testOriginalCalendarInstallCustomizeReplaceUpdateDisableAndRemove() async throws {
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
        var journeyFinished = false
        defer {
            if !journeyFinished { try? captureFailureDiagnostics(application, fixture: fixture) }
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
        try await waitState("empty-idle") { state in
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
        var reviewScroll: XCUIElement?
        for id in ["clipboard", "system", "keepAwake", "emoji"] {
            let entry = try XCTUnwrap(entries.first { $0["id"] as? String == id })
            let title = try XCTUnwrap(entry["title"] as? String)
            let checkbox = application.checkBoxes[title]
            try reveal(checkbox, in: application)
            reviewScroll = application.scrollViews.containing(.checkBox, identifier: title)
                .allElementsBoundByIndex.min {
                    $0.frame.height * $0.frame.width < $1.frame.height * $1.frame.width
                }
            XCTAssertEqual(checkbox.value as? String, "1")
            checkbox.click()
            XCTAssertEqual(checkbox.value as? String, "0")
        }
        let install = application.buttons["workflow.install-selection"]
        let scroll = try XCTUnwrap(reviewScroll)
        for _ in 0..<12 {
            if install.exists && install.isHittable { break }
            scroll.scroll(byDeltaX: 0, deltaY: -400)
        }
        XCTAssertTrue(install.exists)
        XCTAssertTrue(install.isHittable)
        XCTAssertEqual(install.label, "Install 1 extensions")
        try click(install, in: application)
        try await waitState("recommended-calendar-installed") {
            ($0["versions"] as? [String: String])?["calendar"] == "1.0.0"
                && ($0["active"] as? [String]) == ["calendar"]
        }
        try click(application.buttons["Go to Home"], in: application)
        try click(application.buttons["journey.navigation.calendar"], in: application)
        try approveCalendarIfNeeded(application, identifier: fixture.identifier)
        XCTAssertTrue(
            application.staticTexts["Synthetic Calendar review"].waitForExistence(timeout: 45))
        try await waitState("calendar-native-view") {
            ($0["presentationCounts"] as? [String: Int])?["calendar", default: 0] ?? 0 > 0
                && ($0["ownedProcesses"] as? [[String: Any]])?.contains {
                    $0["role"] as? String == "managedUI" && $0["running"] as? Bool == true
                } == true
        }
        try click(application.buttons["Details"].firstMatch, in: application)
        XCTAssertTrue(
            application.staticTexts["Synthetic agenda notes"].waitForExistence(timeout: 15))
        try await capture("calendar-native-use")
        try click(application.buttons["journey.navigation.home"], in: application)
        try click(application.buttons["Widget editor"], in: application)
        let before = try await state()
        try click(application.buttons["Add Meetings"], in: application)
        try await waitState("home-customized") {
            Self.tiles($0, target: "home").count > Self.tiles(before, target: "home").count
        }
        try click(application.buttons["Notch"], in: application)
        let beforeNotch = try await state()
        try click(application.buttons["Add Meetings"], in: application)
        try await waitState("notch-customized") {
            Self.tiles($0, target: "notch").count > Self.tiles(beforeNotch, target: "notch").count
        }
        let customized = try await state()
        let home = try canonical(customized["home"])
        let notch = try canonical(customized["notch"])
        try click(application.buttons["journey.navigation.extensions"], in: application)
        try findCalendar(application)
        try captureWindow(application, fixture: fixture, name: "marketplace-installed-calendar.png")
        try click(application.buttons["Disable"], in: application)
        try await waitState("disabled-drained") {
            ($0["workers"] as? [String: Int]) == [:]
                && ($0["presentationCounts"] as? [String: Int]) == [:]
                && !Self.running($0, role: "engine")
                && !Self.running($0, role: "managedUI")
        }
        try await assertLayouts(home: home, notch: notch)
        XCTAssertFalse(application.buttons["journey.navigation.calendar"].exists)
        try click(application.buttons["Enable"], in: application)
        try await waitState("reenabled-original-version") {
            ($0["versions"] as? [String: String])?["calendar"] == "1.0.0"
        }
        application.terminate()
        XCTAssertTrue(wait(15) { !self.latestRunningProcesses() })
        try await replaceApplication(fixture)
        try registerApplication(fixture)
        application.launch()
        XCTAssertTrue(application.windows.firstMatch.waitForExistence(timeout: 30))
        try await waitState("replacement-restored-installed-state") {
            $0["applicationVersion"] as? String == "2.0.0"
                && ($0["versions"] as? [String: String])?["calendar"] == "1.0.0"
        }
        try await assertLayouts(home: home, notch: notch)
        try click(application.buttons["journey.navigation.extensions"], in: application)
        try findCalendar(application)
        try click(application.buttons["Check for Updates"], in: application)
        try click(application.buttons["Update"], in: application)
        try await waitState("updated-calendar-version") {
            ($0["versions"] as? [String: String])?["calendar"] == "1.1.0"
        }
        try await assertLayouts(home: home, notch: notch)
        try click(application.buttons["Open"], in: application)
        try approveCalendarIfNeeded(application, identifier: fixture.identifier)
        XCTAssertTrue(
            application.staticTexts["Synthetic Calendar review"].waitForExistence(timeout: 45))
        try click(application.buttons["journey.navigation.extensions"], in: application)
        try findCalendar(application)
        try click(application.buttons["Disable"], in: application)
        try await waitState("updated-disabled-drained") {
            ($0["workers"] as? [String: Int]) == [:]
                && ($0["presentationCounts"] as? [String: Int]) == [:]
                && !Self.running($0, role: "engine")
                && !Self.running($0, role: "managedUI")
        }
        try click(application.buttons["Remove"], in: application)
        try await waitState("removed-packages") { ($0["downloaded"] as? [String]) == [] }
        try await assertLayouts(home: home, notch: notch)
        try verifyProtected(fixture)
        try click(application.buttons["journey.navigation.settings"], in: application)
        try click(application.buttons["journey.section.settings.storage"], in: application)
        XCTAssertTrue(application.staticTexts["Measured storage"].waitForExistence(timeout: 30))
        XCTAssertTrue(
            application.staticTexts[
                "Actual files on this Mac, with download sizes shown separately."
            ].exists)
        try await capture("storage-after-removal")
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
        journeyFinished = true
    }

    private func captureFailureDiagnostics(
        _ application: XCUIApplication, fixture: JourneyFixture
    ) throws {
        guard application.state != .notRunning else { return }
        let environment = ProcessInfo.processInfo.environment
        try fixture.validate(
            accountHome: try XCTUnwrap(environment["EDITH_JOURNEY_ACCOUNT_HOME"]),
            environment: environment)
        try fixture.validateApplicationEnvironment(application.launchEnvironment)
        guard root.path == fixture.directory,
            root.resolvingSymlinksInPath().standardizedFileURL == root.standardizedFileURL
        else { throw JourneyContractError.invalidEnvironment }
        let description = application.debugDescription
        let hierarchy = String(decoding: description.utf8.prefix(65_536), as: UTF8.self)
        var diagnostic: [String: Any] = [
            "schema": 1, "lastStage": snapshots.last?["stage"] as? String ?? "startup",
            "hierarchy": hierarchy, "hierarchyTruncated": description.utf8.count > 65_536,
            "applicationState": application.state.rawValue,
            "buttons": application.buttons.allElementsBoundByIndex.prefix(128).map { element in
                [
                    "identifier": String(element.identifier.prefix(256)),
                    "label": String(element.label.prefix(256)),
                    "enabled": element.isEnabled, "hittable": element.isHittable,
                    "frame": Self.frame(element.frame),
                ] as [String: Any]
            },
            "scrollViews": application.scrollViews.allElementsBoundByIndex.prefix(16).map {
                element in
                [
                    "identifier": String(element.identifier.prefix(256)),
                    "hittable": element.isHittable, "frame": Self.frame(element.frame),
                ] as [String: Any]
            },
        ]
        let window = application.windows.firstMatch
        if window.exists {
            let bytes = window.screenshot().pngRepresentation
            guard !bytes.isEmpty, bytes.count <= 8_388_608 else {
                throw JourneyContractError.invalidMetadata
            }
            diagnostic["windowFrame"] = Self.frame(window.frame)
            diagnostic["privateWindowSnapshotBytes"] = bytes.count
            diagnostic["privateWindowSnapshotSHA256"] = SHA256.hash(data: bytes).map {
                String(format: "%02x", $0)
            }.joined()
            let attachment = XCTAttachment(data: bytes, uniformTypeIdentifier: "public.png")
            attachment.name = "hosted-shell-private-failure-window.png"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        let bytes = try JSONSerialization.data(withJSONObject: diagnostic, options: .sortedKeys)
        guard bytes.count <= 131_072 else { throw JourneyContractError.invalidMetadata }
        startup["privateFailureDiagnostics"] = diagnostic
    }

    private static func frame(_ value: CGRect) -> [String: Double] {
        [
            "x": Double(value.origin.x), "y": Double(value.origin.y),
            "width": Double(value.width), "height": Double(value.height),
        ]
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

    private func state() async throws -> [String: Any] {
        let environment = ProcessInfo.processInfo.environment
        let fixture = try JSONDecoder().decode(
            JourneyFixture.self, from: Data(contentsOf: root.appendingPathComponent("journey.json"))
        )
        let endpoint = try XCTUnwrap(environment["EDITH_JOURNEY_OPERATOR_ENDPOINT"])
        let token = try XCTUnwrap(environment["EDITH_JOURNEY_OPERATOR_TOKEN"])
        guard let replacement = URL(string: endpoint), replacement.scheme == "http",
            replacement.host == "127.0.0.1", let port = replacement.port,
            (1...65535).contains(port), replacement.path == "/replace",
            replacement.query == nil, replacement.fragment == nil,
            replacement.user == nil, replacement.password == nil,
            token.utf8.count == 64, token.allSatisfy({ $0.isHexDigit && !$0.isUppercase }),
            let url = URL(string: "http://127.0.0.1:\(port)/state")
        else { throw JourneyContractError.invalidEnvironment }
        var request = URLRequest(url: url)
        request.timeoutInterval = 3
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 131_072,
            let result = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            result["schema"] as? Int == 1, result["operation"] as? String == "state",
            result["hostIdentifier"] as? String == fixture.identifier,
            result["sourceCommit"] as? String == fixture.sourceCommit,
            let state = result["state"] as? [String: Any],
            state["hostIdentifier"] as? String == fixture.identifier,
            state["sourceCommit"] as? String == fixture.sourceCommit,
            state["protectedDataUnchanged"] as? Bool == true,
            state["declinedPermissionRequests"] as? Int == 0
        else { throw JourneyContractError.invalidMetadata }
        lastState = state
        return state
    }

    private func waitState(_ stage: String, predicate: @escaping ([String: Any]) -> Bool)
        async throws
    {
        let deadline = ContinuousClock.now.advanced(by: .seconds(45))
        while ContinuousClock.now < deadline {
            if let value = try? await state(), predicate(value) {
                try await capture(stage)
                return
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTFail(stage)
        throw JourneyContractError.invalidMetadata
    }

    private func capture(_ stage: String) async throws {
        snapshots.append(["stage": stage, "state": try await state()])
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

    private func assertLayouts(home: Data, notch: Data) async throws {
        let current = try await state()
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
        let runnerHome = try XCTUnwrap(environment["HOME"])
        try fixture.validateRunnerHome(
            runnerHome, accountHome: actualHome,
            canonicalHome: URL(fileURLWithPath: runnerHome).resolvingSymlinksInPath().path)
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
        let registration = try registrationReceipt()
        XCTAssertEqual(registration["hostIdentifier"] as? String, fixture.identifier)
        XCTAssertEqual(registration["sourceCommit"] as? String, fixture.sourceCommit)
        XCTAssertEqual(
            registration["applicationVersion"] as? String,
            info["CFBundleShortVersionString"] as? String)
        XCTAssertEqual(
            registration["executableSHA256"] as? String,
            SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
        XCTAssertEqual(registration["registrationStatus"] as? Int, 0)
        XCTAssertEqual(registration["registeredCount"] as? Int, 1)
        XCTAssertEqual(registration["uniqueRegisteredPathMatched"] as? Bool, true)
        startup["registrationStatus"] = registration["registrationStatus"]
        startup["registrationOwner"] = "hosted-producer"
        try saveOutcome()
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

    private func registrationReceipt() throws -> [String: Any] {
        let path = root.appendingPathComponent("registration.json").path
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw JourneyContractError.invalidPaths }
        defer { close(descriptor) }
        var before = stat()
        guard fstat(descriptor, &before) == 0,
            before.st_mode & S_IFMT == S_IFREG, before.st_uid == getuid(),
            before.st_mode & 0o777 == 0o600, before.st_nlink == 1,
            before.st_size > 0, before.st_size <= 1024,
            URL(fileURLWithPath: path).resolvingSymlinksInPath().path == path
        else { throw JourneyContractError.invalidPaths }
        var buffer = [UInt8](repeating: 0, count: 1025)
        let count = Darwin.read(descriptor, &buffer, buffer.count)
        var after = stat()
        var current = stat()
        guard count == before.st_size, fstat(descriptor, &after) == 0,
            lstat(path, &current) == 0,
            before.st_dev == after.st_dev, before.st_ino == after.st_ino,
            before.st_size == after.st_size, before.st_mode == after.st_mode,
            before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
            before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
            before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
            before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec,
            after.st_dev == current.st_dev, after.st_ino == current.st_ino
        else { throw JourneyContractError.invalidPaths }
        let value = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(buffer.prefix(count))) as? [String: Any])
        XCTAssertEqual(
            Set(value.keys),
            Set([
                "schema", "hostIdentifier", "sourceCommit", "applicationVersion",
                "executableSHA256", "registrationStatus", "registeredCount",
                "uniqueRegisteredPathMatched",
            ]))
        XCTAssertEqual(value["schema"] as? Int, 1)
        return value
    }

    private func replaceApplication(_ fixture: JourneyFixture) async throws {
        let environment = ProcessInfo.processInfo.environment
        let endpoint = try XCTUnwrap(environment["EDITH_JOURNEY_OPERATOR_ENDPOINT"])
        let token = try XCTUnwrap(environment["EDITH_JOURNEY_OPERATOR_TOKEN"])
        guard let url = URL(string: endpoint), url.scheme == "http",
            url.host == "127.0.0.1", let port = url.port, (1...65535).contains(port),
            url.path == "/replace", url.query == nil, url.fragment == nil,
            url.user == nil, url.password == nil, token.utf8.count == 64,
            token.allSatisfy({ $0.isHexDigit && !$0.isUppercase })
        else { throw JourneyContractError.invalidEnvironment }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(
            withJSONObject: [
                "operation": "replaceApplication", "hostIdentifier": fixture.identifier,
                "sourceCommit": fixture.sourceCommit, "previousVersion": "1.0.0",
                "nextVersion": "2.0.0",
            ], options: .sortedKeys)
        XCTAssertLessThanOrEqual(request.httpBody?.count ?? 0, 1024)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertLessThanOrEqual(bytes.count, 1024)
        let result = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        XCTAssertEqual(result["schema"] as? Int, 1)
        XCTAssertEqual(result["operation"] as? String, "replaceApplication")
        XCTAssertEqual(result["hostIdentifier"] as? String, fixture.identifier)
        XCTAssertEqual(result["sourceCommit"] as? String, fixture.sourceCommit)
        XCTAssertEqual(result["applicationVersion"] as? String, "2.0.0")
        XCTAssertEqual(result["executableSHA256"] as? String, fixture.executableSHA256["2.0.0"])
        XCTAssertEqual(result["priorOwnedGenerationsExited"] as? Bool, true)
    }

    private func latestRunningProcesses() -> Bool {
        let owned = lastState["ownedProcesses"] as? [[String: Any]] ?? []
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

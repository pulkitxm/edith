import assert from "node:assert/strict";

const replaceOne = (source, anchor, replacement) => {
  assert.equal(
    source.split(anchor).length,
    2,
    "Reviewed original journey anchor changed",
  );
  return source.replace(anchor, replacement);
};
const manualReplacement = `        application.terminate()
        XCTAssertTrue(wait(15) { !self.latestRunningProcesses() })
        try await replaceApplication(fixture)
        try registerApplication(fixture)
        application.launch()
        XCTAssertTrue(application.windows.firstMatch.waitForExistence(timeout: 30))`;
const arm = `        try click(application.buttons["journey.navigation.calendar"], in: application)
        try await approveCalendarIfNeeded(application, identifier: fixture.identifier)
        XCTAssertTrue(application.staticTexts["Synthetic Calendar review"].waitForExistence(timeout: 45))
        try await sparkleAction("armSparkle", fixture: fixture)
        application.menuBars.menuBarItems["Edith"].click()
        try click(application.menuItems["Check for App Updates"], in: application)
        try click(application.buttons["Install Update"].firstMatch, in: application)`;
const installed = `${arm}
        try click(application.buttons["Install and Relaunch"].firstMatch, in: application)
        try await sparkleAction("awaitSparkleInstall", fixture: fixture)
        application = XCUIApplication(bundleIdentifier: fixture.identifier)
        application.launchEnvironment = try fixture.applicationEnvironment(from: environment)
        failureContext = (application, fixture)
        XCTAssertTrue(application.windows.firstMatch.waitForExistence(timeout: 30))`;
const lifecycle = `        try await assertLayouts(home: home, notch: notch)
        try click(application.buttons["journey.navigation.extensions"], in: application)
        try findCalendar(application)
        try click(application.buttons["Check for Updates"], in: application)`;
const reopened = `        try await assertLayouts(home: home, notch: notch)
        try click(application.buttons["journey.navigation.calendar"], in: application)
        try await approveCalendarIfNeeded(application, identifier: fixture.identifier)
        XCTAssertTrue(application.staticTexts["Synthetic Calendar review"].waitForExistence(timeout: 45))
        try await sparkleAction("captureSparkleReopened", fixture: fixture)
        try click(application.buttons["journey.navigation.extensions"], in: application)
        try findCalendar(application)
        try click(application.buttons["Disable"], in: application)
        XCTAssertTrue(wait(30) { application.buttons["Enable"].exists })
        try await sparkleAction("captureSparkleDisabled", fixture: fixture)
        try click(application.buttons["Enable"], in: application)
        try await sparkleAction("captureSparkleResumed", fixture: fixture)
        try click(application.buttons["Check for Updates"], in: application)`;
const method = `    private func sparkleAction(_ operation: String, fixture: JourneyFixture) async throws {
        let environment = ProcessInfo.processInfo.environment
        let endpoint = try XCTUnwrap(environment["EDITH_JOURNEY_OPERATOR_ENDPOINT"])
        let token = try XCTUnwrap(environment["EDITH_JOURNEY_OPERATOR_TOKEN"])
        guard let url = URL(string: endpoint), url.scheme == "http", url.host == "127.0.0.1",
            let port = url.port, (1...65535).contains(port), url.path == "/replace",
            url.query == nil, url.fragment == nil, url.user == nil, url.password == nil,
            token.utf8.count == 64, token.allSatisfy({ $0.isHexDigit && !$0.isUppercase })
        else { throw JourneyContractError.invalidEnvironment }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 75
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "operation": operation, "hostIdentifier": fixture.identifier,
            "sourceCommit": fixture.sourceCommit, "previousVersion": "1.0.0", "nextVersion": "2.0.0"
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
        XCTAssertEqual(Set(result.keys), Set(["schema", "operation", "hostIdentifier", "sourceCommit", "outcome"]))
        XCTAssertEqual(result["schema"] as? Int, 1)
        XCTAssertEqual(result["operation"] as? String, operation)
        XCTAssertEqual(result["hostIdentifier"] as? String, fixture.identifier)
        XCTAssertEqual(result["sourceCommit"] as? String, fixture.sourceCommit)
        XCTAssertEqual(result["outcome"] as? String, "observed")
    }

`;

export function sparkleJourneyUIOverlay(original, recipe = "valid") {
  assert(["valid", "wrong-signature", "tampered-archive"].includes(recipe));
  let source = replaceOne(
    original,
    "final class OriginalShellJourneyTests: XCTestCase",
    "final class HostedSparkleJourneyTests: XCTestCase",
  );
  source = replaceOne(
    source,
    "func testOriginalCalendarInstallCustomizeReplaceUpdateDisableAndRemove()",
    "func testActualSparkleUpdateThroughOriginalCalendarJourney()",
  );
  source = replaceOne(
    source,
    "        let application = XCUIApplication(bundleIdentifier: fixture.identifier)",
    "        var application = XCUIApplication(bundleIdentifier: fixture.identifier)",
  );
  source = replaceOne(
    source,
    "    private func requireCheckboxState(",
    `${method}    private func requireCheckboxState(`,
  );
  if (recipe === "valid") {
    source = replaceOne(source, manualReplacement, installed);
    source = replaceOne(source, lifecycle, reopened);
    source = replaceOne(
      source,
      `        try captureWindow(application, fixture: fixture, name: "storage-distribution.png")
        application.terminate()`,
      `        try captureWindow(application, fixture: fixture, name: "storage-distribution.png")
        try await sparkleAction("verifySparkleFinished", fixture: fixture)
        application.terminate()`,
    );
    const updated = `        try click(application.buttons["journey.navigation.extensions"], in: application)
        try findCalendar(application)
        try click(application.buttons["Disable"], in: application)
        try await waitState("updated-disabled-drained")`;
    source = replaceOne(
      source,
      updated,
      `        try await sparkleAction("captureSparkleUpdated", fixture: fixture)
${updated}`,
    );
  } else {
    const beginning = source.slice(0, source.indexOf(manualReplacement));
    assert(source.includes(manualReplacement));
    const end = source.indexOf("    private func sparkleAction(");
    assert(end > source.indexOf(manualReplacement));
    source = `${beginning}${arm}
        try await sparkleAction("verifySparkleRejection", fixture: fixture)
        XCTAssertTrue(application.buttons["OK"].firstMatch.waitForExistence(timeout: 15))
        try click(application.buttons["OK"].firstMatch, in: application)
        XCTAssertFalse(application.buttons["Install and Relaunch"].exists)
        try verifyProtected(fixture)
        journeyFinished = true
        application.terminate()
    }

${source.slice(end)}`;
  }
  const unusedStart = source.indexOf(
    "    private func replaceApplication(_ fixture:",
  );
  const unusedEnd = source.indexOf(
    "    private func latestRunningProcesses()",
    unusedStart,
  );
  assert(unusedStart >= 0 && unusedEnd > unusedStart);
  source = source.slice(0, unusedStart) + source.slice(unusedEnd);
  assert.equal(source.split("application.launch()").length, 2);
  assert(!source.includes("replaceApplication(fixture)"));
  return source;
}

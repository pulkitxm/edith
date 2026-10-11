import { expect, test } from "bun:test";
import { readFile } from "node:fs/promises";
import { sparkleJourneyUIOverlay } from "./hosted-sparkle-update/source-ui.mjs";

test("all original acceptance stages remain around standard updater controls without replacement or post-install launch", async () => {
  const original = await readFile(
    "Tests/HostedOriginalShell/UITests/OriginalShellJourneyTests.swift",
    "utf8",
  );
  const source = sparkleJourneyUIOverlay(original);
  expect(source).toContain("final class OriginalShellJourneyTests: XCTestCase");
  expect(source).toContain(
    "func testOriginalCalendarInstallCustomizeReplaceUpdateDisableAndRemove()",
  );
  for (const stage of [
    "empty-idle",
    "recommended-calendar-installed",
    "calendar-native-view",
    "calendar-native-use",
    "home-customized",
    "notch-customized",
    "disabled-drained",
    "reenabled-original-version",
    "replacement-restored-installed-state",
    "updated-calendar-version",
    "updated-disabled-drained",
    "removed-packages",
    "storage-after-removal",
  ])
    expect(source).toContain(`"${stage}"`);
  for (const control of [
    "Check for App Updates",
    "Install Update",
    "Install and Relaunch",
  ])
    expect(source).toContain(`"${control}"`);
  expect(source.split("application.launch()")).toHaveLength(2);
  expect(source).not.toContain("replaceApplication(fixture)");
  expect(source).not.toContain('"operation": "replaceApplication"');
  expect(source.indexOf('sparkleAction("armSparkle"')).toBeLessThan(
    source.indexOf('buttons["Install Update"]'),
  );
  expect(source.indexOf('sparkleAction("awaitSparkleInstall"')).toBeLessThan(
    source.indexOf("\n        application = XCUIApplication"),
  );
  expect(source).toContain('sparkleAction("captureSparkleUpdated"');
  expect(source).toContain("XCTAssertEqual(snapshots.count, 13)");
  expect(() =>
    sparkleJourneyUIOverlay(
      original.replace(
        "        application.terminate()\n        XCTAssertTrue(wait(15)",
        "        changed()\n        XCTAssertTrue(wait(15)",
      ),
    ),
  ).toThrow();
});

test("each closed negative recipe clicks actual updater and requires producer-observed validation rejection without a relaunch action", async () => {
  const original = await readFile(
    "Tests/HostedOriginalShell/UITests/OriginalShellJourneyTests.swift",
    "utf8",
  );
  for (const recipe of ["wrong-signature", "tampered-archive"]) {
    const source = sparkleJourneyUIOverlay(original, recipe);
    expect(source).toContain('buttons["Install Update"]');
    expect(source).toContain('sparkleAction("verifySparkleRejection"');
    expect(source).toContain('buttons["Cancel Update"].firstMatch');
    expect(
      source.indexOf('try click(application.buttons["Cancel Update"]'),
    ).toBeLessThan(source.indexOf('sparkleAction("verifySparkleRejection"'));
    expect(source).not.toContain('buttons["OK"]');
    expect(source).not.toContain('buttons["Install and Relaunch"].firstMatch');
    expect(source.split("application.launch()")).toHaveLength(2);
    expect(source).not.toContain("XCTAssertEqual(snapshots.count, 13)");
    expect(source).not.toContain('attachment.name = "edith-journey-"');
  }
  expect(() => sparkleJourneyUIOverlay(original, "foreign")).toThrow();
});

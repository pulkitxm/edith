import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";

const releaseWorkflow = readFileSync(".github/workflows/release.yml", "utf8");
const ciWorkflow = readFileSync(".github/workflows/ci.yml", "utf8");
const makefile = readFileSync("Makefile", "utf8");
const contributing = readFileSync("CONTRIBUTING.md", "utf8");
const homebrewInternals = readFileSync("docs/homebrew-internals.md", "utf8");
const releaseTagRef = ["$", "{RELEASE_TAG}"].join("");

test("CI gates the reusable release on every required check", () => {
  expect(ciWorkflow).toContain(
    "needs: [changes, checks, ubuntu, promo-video, swift-build, swift-test]",
  );
  expect(ciWorkflow).toContain("github.event_name == 'push'");
  expect(ciWorkflow).toContain("github.ref == 'refs/heads/main'");
  expect(ciWorkflow).toContain("!contains(needs.*.result, 'failure')");
  expect(ciWorkflow).toContain("!contains(needs.*.result, 'cancelled')");
  expect(ciWorkflow).toContain("uses: ./.github/workflows/release.yml");
});

test("the release is reusable and supports manual rebuilds", () => {
  expect(releaseWorkflow).toContain("workflow_call:");
  expect(releaseWorkflow).toContain("workflow_dispatch:");
  expect(releaseWorkflow).toContain("inputs.rebuild");
  expect(releaseWorkflow).not.toContain('tags: ["v*"]');
});

test("automated commits do not re-run CI", () => {
  expect(ciWorkflow).toContain("'Release v'");
  expect(ciWorkflow).toContain("'Refresh the contributor list'");
  expect(ciWorkflow).toContain("github.event_name != 'push'");
});

test("release waits for and publishes every platform asset", () => {
  expect(releaseWorkflow).toContain("needs: [version, dmg, deb]");
  expect(releaseWorkflow).toContain("release-assets/Edith.dmg");
  expect(releaseWorkflow).toContain("release-assets/Edith.deb");
  expect(releaseWorkflow).toContain("release-assets/appcast.xml");
  expect(releaseWorkflow).toContain("-name 'edith_*.deb'");
  expect(releaseWorkflow).toContain("gh release create");
  expect(releaseWorkflow).toContain("gh release upload");
  expect(releaseWorkflow).toContain('apt-get install -y "./$DEB"');
});

test("macOS notarization is conditional on its optional credentials", () => {
  expect(releaseWorkflow).toContain("HAS_NOTARY:");
  expect(releaseWorkflow).toContain("if: env.HAS_NOTARY == 'true'");
  expect(releaseWorkflow).not.toContain("env.HAS_NOTARY != 'true'");
});

test("macOS release accepts the configured development certificate", () => {
  expect(releaseWorkflow).toContain('EDITH_RELEASE_ALLOW_DEV_SIGNING: "1"');
});

test("the publisher uses a token that clears the ruleset", () => {
  const pushToken = ["$", "{{ secrets.RELEASE_PUSH_TOKEN }}"].join("");
  expect(releaseWorkflow).toContain(`token: ${pushToken}`);
  expect(releaseWorkflow).toContain("RELEASE_PUSH_TOKEN is required");
});

test("the release commit carries every versioned file and its tag atomically", () => {
  expect(releaseWorkflow).toContain(
    "git add Resources/Info.plist Resources/HelperInfo.plist Casks/edith.rb",
  );
  expect(releaseWorkflow).toContain(`git commit -m "Release ${releaseTagRef}"`);
  expect(releaseWorkflow).toContain('git tag "$RELEASE_TAG"');
  expect(releaseWorkflow).toContain(
    'git push --atomic origin HEAD:main "refs/tags/$RELEASE_TAG"',
  );
});

test("the obsolete tag-only manual release path is retired", () => {
  expect(makefile).not.toMatch(/^release:/m);
  expect(makefile).not.toContain("make release");
  expect(contributing).not.toContain("make release");
  expect(homebrewInternals).not.toContain("make release");
});

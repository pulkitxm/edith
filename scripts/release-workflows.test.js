import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";

const releaseWorkflow = readFileSync(".github/workflows/release.yml", "utf8");
const ciWorkflow = readFileSync(".github/workflows/ci.yml", "utf8");
const releaseStateScript = readFileSync(
  "scripts/publish-release-state.sh",
  "utf8",
);
const makefile = readFileSync("Makefile", "utf8");
const contributing = readFileSync("CONTRIBUTING.md", "utf8");
const homebrewInternals = readFileSync("docs/homebrew-internals.md", "utf8");
const releaseTagRef = ["$", "{RELEASE_TAG}"].join("");
const releaseJob = ciWorkflow.slice(ciWorkflow.indexOf("\n  release:"));

test("CI gates the reusable release only on relevant checks", () => {
  expect(ciWorkflow).toContain(
    "needs: [changes, checks, ubuntu, swift-build, swift-test]",
  );
  expect(releaseJob).not.toContain("promo-video");
  expect(releaseJob).toContain("always()");
  expect(releaseJob).toContain(
    "always()\n      && github.ref == 'refs/heads/main'",
  );
  expect(releaseJob).toContain("github.event_name == 'push'");
  expect(releaseJob).toContain("github.ref == 'refs/heads/main'");
  expect(releaseJob).toContain("needs.checks.result == 'success'");
  expect(releaseJob).toContain("!contains(needs.*.result, 'failure')");
  expect(releaseJob).toContain("!contains(needs.*.result, 'cancelled')");
  expect(releaseJob).toContain(
    "needs.changes.outputs.workflows != 'true') || needs.ubuntu.result == 'success'",
  );
  expect(releaseJob).toContain(
    "needs.changes.outputs.workflows != 'true') || needs.swift-build.result == 'success'",
  );
  expect(releaseJob).toContain("needs.changes.outputs.docs != 'true'");
  expect(releaseJob).toContain("|| needs.swift-test.result == 'success'");
  expect(releaseJob).toContain(
    "github.event_name == 'workflow_dispatch' && inputs.release",
  );
  expect(releaseJob).toContain("cut_release: true");
  expect(releaseJob).toContain("uses: ./.github/workflows/release.yml");
});

test("the release is reusable and supports manual rebuilds", () => {
  expect(releaseWorkflow).toContain("workflow_call:");
  expect(releaseWorkflow).toContain("workflow_dispatch:");
  expect(releaseWorkflow).toContain("inputs.rebuild");
  expect(releaseWorkflow).toContain("cut_release:");
  expect(releaseWorkflow).toContain("CUT_RELEASE:");
  expect(releaseWorkflow).toContain("new releases must pass through CI");
  expect(releaseWorkflow).toContain("run the workflow from main");
  expect(releaseWorkflow).toContain(
    "Current release tag to rebuild and re-upload.",
  );
  expect(releaseWorkflow).toContain("refs/tags/{0}");
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

test("build jobs cannot retain write credentials", () => {
  expect(releaseWorkflow).toContain("permissions:\n  contents: read");
  expect(releaseWorkflow).toContain(
    "publish:\n    needs: [version, dmg, deb]\n    runs-on: ubuntu-latest\n    permissions:\n      contents: write",
  );
  expect(releaseWorkflow.match(/persist-credentials: false/g)?.length).toBe(4);
  expect(releaseWorkflow.match(/persist-credentials: true/g)?.length).toBe(1);
});

test("the release commit carries every versioned file and its tag atomically", () => {
  expect(releaseStateScript).toContain(
    "git add Resources/Info.plist Resources/HelperInfo.plist Casks/edith.rb",
  );
  expect(releaseStateScript).toContain(
    `git commit -m "Release ${releaseTagRef}"`,
  );
  expect(releaseStateScript).toContain('git tag "$RELEASE_TAG"');
  expect(releaseStateScript).toContain(
    'git push --atomic origin HEAD:main "refs/tags/$RELEASE_TAG"',
  );
  expect(releaseStateScript).toContain(
    '[[ "$(git rev-parse HEAD)" == "$BUILT_SHA" ]]',
  );
  expect(releaseStateScript).toContain(
    '[[ "$(git rev-parse origin/main)" == "$BUILT_SHA" ]]',
  );
  expect(releaseStateScript).not.toContain("git reset --hard origin/main");
  expect(releaseStateScript).not.toContain("for attempt in");
});

test("release publication can recover after a partial failure", () => {
  expect(releaseStateScript).toContain("refs/tags/$RELEASE_TAG^{commit}");
  expect(releaseWorkflow).toContain("Update the rebuilt release checksum");
  expect(releaseStateScript).toContain(
    "only the current release can be rebuilt",
  );
  expect(releaseStateScript).toContain(
    `git commit -m "Refresh ${releaseTagRef} release checksum"`,
  );
  const mirror = releaseWorkflow.slice(
    releaseWorkflow.indexOf("- name: Mirror the cask to the tap repository"),
  );
  expect(mirror).not.toContain("if: env.REBUILD == ''");
});

test("the obsolete tag-only manual release path is retired", () => {
  expect(makefile).not.toMatch(/^release:/m);
  expect(makefile).not.toContain("make release");
  expect(contributing).not.toContain("make release");
  expect(homebrewInternals).not.toContain("make release");
});

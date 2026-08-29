import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";

const releaseWorkflow = readFileSync(".github/workflows/release.yml", "utf8");
const ciWorkflow = readFileSync(".github/workflows/ci.yml", "utf8");
const releaseStateScript = readFileSync(
  "scripts/publish-release-state.sh",
  "utf8",
);
const makefile = readFileSync("Makefile", "utf8");
const buildScript = readFileSync("build.sh", "utf8");
const contributing = readFileSync("CONTRIBUTING.md", "utf8");
const homebrewInternals = readFileSync("docs/homebrew-internals.md", "utf8");
const sourceShaRef = ["$", "{{ inputs.source_sha || github.sha }}"].join("");
const releaseTagRef = ["$", "{RELEASE_TAG}"].join("");
const releaseBuildJob = ciWorkflow.slice(
  ciWorkflow.indexOf("\n  release-build:"),
);
const ciGateJob = releaseWorkflow.slice(
  releaseWorkflow.indexOf("\n  ci:"),
  releaseWorkflow.indexOf("\n  publish:"),
);

test("CI starts release builds as soon as release routing succeeds", () => {
  expect(releaseBuildJob).toContain("needs: changes");
  expect(releaseBuildJob).not.toContain("needs.swift-build");
  expect(releaseBuildJob).not.toContain("needs.swift-test");
  expect(releaseBuildJob).not.toContain("needs.companion");
  expect(releaseBuildJob).not.toContain("promo-video");
  expect(releaseBuildJob).toContain("github.event_name == 'push'");
  expect(releaseBuildJob).toContain("github.ref == 'refs/heads/main'");
  expect(releaseBuildJob).toContain("needs.changes.result == 'success'");
  expect(releaseBuildJob).not.toContain("needs.changes.outputs.docs != 'true'");
  expect(releaseBuildJob).toContain(
    "github.event_name == 'workflow_dispatch' && inputs.release",
  );
  expect(releaseBuildJob).toContain(
    "&& ((github.event_name == 'push'\n      && needs.changes.outputs.swift == 'true')",
  );
  expect(releaseBuildJob).toContain(
    "|| (github.event_name == 'workflow_dispatch' && inputs.release))",
  );
  expect(releaseBuildJob).toContain("actions: write");
  expect(releaseBuildJob).toContain("gh workflow run release.yml");
  expect(releaseBuildJob).toContain('--repo "$GITHUB_REPOSITORY"');
  expect(releaseBuildJob).toContain("--field cut_release=true");
  expect(releaseBuildJob).toContain('--field source_sha="$RELEASE_SHA"');
  expect(releaseBuildJob).toContain('--field ci_run_id="$CI_RUN_ID"');
  expect(releaseBuildJob).not.toContain(
    "uses: ./.github/workflows/release.yml",
  );
});

test("the standalone release supports gated cuts and manual rebuilds", () => {
  expect(releaseWorkflow).not.toContain("workflow_call:");
  expect(releaseWorkflow).toContain("workflow_dispatch:");
  expect(releaseWorkflow).toContain("inputs.rebuild");
  expect(releaseWorkflow).toContain("inputs.source_sha");
  expect(releaseWorkflow).toContain("inputs.ci_run_id");
  expect(releaseWorkflow).toContain("cut_release:");
  expect(releaseWorkflow).toContain("CUT_RELEASE:");
  expect(releaseWorkflow).toContain("SOURCE_SHA:");
  expect(releaseWorkflow).toContain("CI_RUN_ID:");
  expect(releaseWorkflow).toContain("new releases must pass through CI");
  expect(releaseWorkflow).toContain("CI must provide the approved commit");
  expect(releaseWorkflow).toContain("CI must provide its run ID");
  expect(releaseWorkflow).toContain(
    "checkout does not match the approved commit",
  );
  expect(releaseWorkflow).toContain("run the workflow from main");
  expect(releaseWorkflow).toContain(
    "Current release tag to rebuild and re-upload.",
  );
  expect(releaseWorkflow).toContain("refs/tags/{0}");
  expect(releaseWorkflow).toContain(`ref: ${sourceShaRef}`);
  expect(releaseWorkflow).toContain("../scripts/resolve-release-version.sh");
  expect(releaseWorkflow).not.toContain('tags: ["v*"]');
});

test("automatic cuts and manual rebuilds cannot replace each other", () => {
  expect(releaseWorkflow).toContain("&& 'rebuild'");
  expect(releaseWorkflow).toContain("|| 'automatic'");
  expect(releaseWorkflow).not.toContain("format('rebuild-{0}'");
  expect(releaseWorkflow).toContain(
    "concurrency:\n      group: release-publication\n      cancel-in-progress: false",
  );
});

test("automated commits do not re-run CI", () => {
  expect(ciWorkflow).toContain("'Release v'");
  expect(ciWorkflow).toContain("'Refresh the contributor list'");
  expect(ciWorkflow).toContain("github.event_name != 'push'");
});

test("release publication waits for the exact successful CI run", () => {
  expect(ciGateJob).toContain("needs: version");
  expect(ciGateJob).toContain("actions: read");
  expect(ciGateJob).toContain("inputs.ci_run_id");
  expect(ciGateJob).toContain("needs.version.outputs.sha");
  expect(ciGateJob).toContain('if [ -n "$REBUILD" ]; then');
  expect(ciGateJob).toContain('gh run view "$CI_RUN_ID"');
  expect(ciGateJob).toContain('gh run watch "$CI_RUN_ID"');
  expect(ciGateJob).toContain("--exit-status");
  expect(ciGateJob).toContain("workflowName");
  expect(ciGateJob).toContain("headSha");
  expect(ciGateJob).toContain("conclusion");
  expect(releaseWorkflow).toContain("needs: [version, ci, dmg]");
});

test("release builds and publishes the macOS assets", () => {
  const dmgJob = releaseWorkflow.slice(
    releaseWorkflow.indexOf("\n  dmg:"),
    releaseWorkflow.indexOf("\n  ci:"),
  );
  expect(dmgJob).toContain("timeout-minutes: 60");
  expect(dmgJob).toContain("name: Cache libghostty");
  expect(dmgJob).toContain("name: Build libghostty");
  expect(dmgJob).toContain("make ghostty");
  expect(dmgJob).toContain("name: Verify the release bundle");
  expect(dmgJob).toContain("run: make verify-bundle");
  expect(dmgJob.indexOf("run: make verify-bundle")).toBeLessThan(
    dmgJob.indexOf("name: Package the DMG"),
  );
  expect(dmgJob).toContain("ditto dist/Edith.app dmg-root/Edith.app");
  expect(dmgJob).toContain("-format ULMO Edith.dmg");
  expect(dmgJob).toContain("hdiutil verify Edith.dmg");
  expect(dmgJob).toContain("name: Enforce the release size budget");
  expect(dmgJob).toContain('test "$DMG_BYTES" -le 17000000');
  expect(buildScript).toContain(
    '[ "$RELEASE" = 1 ] && XCODE_BUILD_SETTING=SWIFT_OPTIMIZATION_LEVEL=-Osize',
  );
  expect(makefile).toContain("Release SWIFT_OPTIMIZATION_LEVEL must be -Osize");
  expect(releaseWorkflow).toContain("release-assets/Edith.dmg");
  expect(releaseWorkflow).toContain("release-assets/appcast.xml");
  expect(releaseWorkflow).toContain("gh release create");
  expect(releaseWorkflow).toContain("gh release upload");
});

test("swift tests leave enough time for a cold libghostty build", () => {
  const swiftTestJob = ciWorkflow.slice(
    ciWorkflow.indexOf("\n  swift-test:"),
    ciWorkflow.indexOf("\n  companion:"),
  );
  expect(swiftTestJob).toContain("timeout-minutes: 30");
  expect(swiftTestJob).toContain("name: Cache libghostty");
  expect(swiftTestJob).toContain("name: Build libghostty");
});

test("superseded release builds yield the lane before packaging", () => {
  const dmgJob = releaseWorkflow.slice(
    releaseWorkflow.indexOf("\n  dmg:"),
    releaseWorkflow.indexOf("\n  publish:"),
  );
  const supersededOutput = [
    "$",
    "{{ steps.release_build.outputs.superseded }}",
  ].join("");
  expect(dmgJob).toContain(`superseded: ${supersededOutput}`);
  expect(dmgJob).toContain(
    "./scripts/run-current-release-build.sh ./build.sh --no-open --release",
  );
  expect(dmgJob).toContain('RELEASE_SUPERSEDED_FILE="$SUPERSEDED_FILE"');
  expect(dmgJob).toContain('if [ -f "$SUPERSEDED_FILE" ]; then');
  expect(dmgJob).not.toContain('if [ "$BUILD_STATUS" -eq 75 ]; then');
  expect(dmgJob).toContain('echo "superseded=true" >> "$GITHUB_OUTPUT"');
  expect(
    dmgJob.match(/if: steps\.release_build\.outputs\.superseded != 'true'/g)
      ?.length,
  ).toBe(11);
  expect(releaseWorkflow).toContain(
    "needs: [version, ci, dmg]\n    if: needs.dmg.outputs.superseded != 'true'",
  );
});

test("bundle verification requires one executable and its CLI launcher", () => {
  expect(makefile).toContain("test ! -L dist/Edith.app/Contents/MacOS/Edith");
  expect(makefile).toContain("test -L dist/Edith.app/Contents/MacOS/ed");
  expect(makefile).toContain(
    'readlink dist/Edith.app/Contents/MacOS/ed)" = ../Resources/ed-launcher',
  );
  expect(makefile).toContain(
    "test -f dist/Edith.app/Contents/Resources/ed-launcher",
  );
  expect(makefile).toContain("grep -qx '#!/bin/sh'");
  expect(makefile).toContain("test ! -e dist/Edith.app/Contents/MacOS/edh");
  expect(makefile).toContain("-type l -name ed");
  expect(makefile).toContain("@set -e; install_dir=");
  expect(makefile).toContain("for name in ed edith; do");
});

test("macOS notarization is conditional on its optional credentials", () => {
  expect(releaseWorkflow).toContain("HAS_NOTARY:");
  expect(releaseWorkflow).toContain(
    "if: steps.release_build.outputs.superseded != 'true' && env.HAS_NOTARY == 'true'",
  );
  expect(releaseWorkflow).not.toContain("env.HAS_NOTARY != 'true'");
});

test("macOS release accepts the configured development certificate", () => {
  expect(releaseWorkflow).toContain('EDITH_RELEASE_ALLOW_DEV_SIGNING: "1"');
});

test("the publisher uses a token that clears the ruleset", () => {
  const pushToken = ["$", "{{ secrets.RELEASE_PUSH_TOKEN }}"].join("");
  expect(releaseWorkflow).toContain(`token: ${pushToken}`);
  expect(releaseWorkflow).toContain("RELEASE_PUSH_TOKEN is required");
  expect(releaseWorkflow).toContain("TAP_PUSH_TOKEN is required");
  expect(releaseWorkflow).not.toContain("create-github-app-token");
  expect(releaseWorkflow).not.toContain("PUKBOT");
});

test("build jobs cannot retain write credentials", () => {
  expect(releaseWorkflow).toContain("permissions:\n  contents: read");
  expect(releaseWorkflow).toContain(
    "publish:\n    name: Publish release\n    needs: [version, ci, dmg]\n    if: needs.dmg.outputs.superseded != 'true'\n    runs-on: ubuntu-latest\n    concurrency:\n      group: release-publication\n      cancel-in-progress: false\n    permissions:\n      contents: write",
  );
  expect(releaseWorkflow.match(/persist-credentials: false/g)?.length).toBe(4);
  expect(releaseWorkflow.match(/persist-credentials: true/g)?.length).toBe(1);
});

test("the release commit carries every versioned file and its tag atomically", () => {
  expect(releaseStateScript).toContain('-c user.name="github-actions[bot]"');
  expect(releaseStateScript).toContain(
    '-c user.email="41898282+github-actions[bot]@users.noreply.github.com"',
  );
  expect(releaseStateScript).toContain(
    "commit Resources/Info.plist Resources/HelperInfo.plist Casks/edith.rb",
  );
  expect(releaseStateScript).toContain(
    `-m "Release ${releaseTagRef} [skip ci]"`,
  );
  expect(releaseStateScript).toContain(
    'tag -a "$RELEASE_TAG" -m "Edith $RELEASE_TAG build $RELEASE_BUILD"',
  );
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
});

test("release publication can recover after a partial failure", () => {
  expect(releaseStateScript).toContain("remote_tag_sha");
  expect(releaseWorkflow).toContain("Update the rebuilt release checksum");
  expect(releaseStateScript).toContain(
    "only the current release can be rebuilt",
  );
  expect(releaseStateScript).toContain(
    `-m "Refresh ${releaseTagRef} release checksum"`,
  );
  const mirror = releaseWorkflow.slice(
    releaseWorkflow.indexOf("- name: Mirror the cask to the tap repository"),
  );
  expect(mirror).not.toContain("if: env.REBUILD == ''");
});

test("superseded release cuts finish cleanly without publishing", () => {
  expect(releaseStateScript).toContain(
    'echo "release superseded: main moved after the release build" >&2',
  );
  expect(releaseStateScript).toContain("exit 75");
  expect(releaseWorkflow).toContain(
    "bash ../scripts/publish-release-state.sh cut || PUBLISH_STATUS=$?",
  );
  expect(releaseWorkflow).toContain(
    "bash ../scripts/publish-release-state.sh rebuild",
  );
  expect(releaseWorkflow).toContain('if [ "$PUBLISH_STATUS" -eq 75 ]; then');
  expect(releaseWorkflow).toContain(
    'echo "superseded=true" >> "$GITHUB_OUTPUT"',
  );
  expect(
    releaseWorkflow.match(
      /if: steps\.release_state\.outputs\.superseded != 'true'/g,
    )?.length,
  ).toBe(2);
  expect(releaseWorkflow).toContain('exit "$PUBLISH_STATUS"');
});

test("the obsolete tag-only manual release path is retired", () => {
  expect(makefile).not.toMatch(/^release:/m);
  expect(makefile).not.toContain("make release");
  expect(contributing).not.toContain("make release");
  expect(homebrewInternals).not.toContain("make release");
});

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
const sourceShaRef = ["$", "{{ inputs.source_sha || github.sha }}"].join("");
const releaseTagRef = ["$", "{RELEASE_TAG}"].join("");
const releaseJob = ciWorkflow.slice(ciWorkflow.indexOf("\n  release:"));

test("CI gates and dispatches the release only on relevant checks", () => {
  expect(ciWorkflow).toContain(
    "needs: [changes, checks, swift-build, swift-test, companion]",
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
  expect(releaseJob).toContain("&& (github.event_name == 'push'");
  expect(releaseJob).toContain("|| needs.swift-build.result == 'success'))");
  expect(releaseJob).not.toContain("needs.changes.outputs.docs != 'true'");
  expect(releaseJob).toContain("|| needs.swift-test.result == 'success'");
  expect(releaseJob).toContain(
    "github.event_name == 'workflow_dispatch' && inputs.release",
  );
  expect(releaseJob).toContain(
    "&& ((github.event_name == 'push'\n      && needs.changes.outputs.release_artifact == 'true')",
  );
  expect(releaseJob).toContain(
    "|| (github.event_name == 'workflow_dispatch' && inputs.release))",
  );
  expect(releaseJob).toContain("actions: write");
  expect(releaseJob).toContain("gh workflow run release.yml");
  expect(releaseJob).toContain('--repo "$GITHUB_REPOSITORY"');
  expect(releaseJob).toContain("--field cut_release=true");
  expect(releaseJob).toContain('--field source_sha="$RELEASE_SHA"');
  expect(releaseJob).not.toContain("uses: ./.github/workflows/release.yml");
});

test("the standalone release supports gated cuts and manual rebuilds", () => {
  expect(releaseWorkflow).not.toContain("workflow_call:");
  expect(releaseWorkflow).toContain("workflow_dispatch:");
  expect(releaseWorkflow).toContain("inputs.rebuild");
  expect(releaseWorkflow).toContain("inputs.source_sha");
  expect(releaseWorkflow).toContain("cut_release:");
  expect(releaseWorkflow).toContain("CUT_RELEASE:");
  expect(releaseWorkflow).toContain("SOURCE_SHA:");
  expect(releaseWorkflow).toContain("new releases must pass through CI");
  expect(releaseWorkflow).toContain("CI must provide the approved commit");
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
  expect(releaseJob).not.toContain("PUKBOT_PRIVATE_KEY");
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

test("release waits for and publishes the macOS assets", () => {
  expect(releaseWorkflow).toContain("needs: [version, dmg]");
  const dmgJob = releaseWorkflow.slice(
    releaseWorkflow.indexOf("\n  dmg:"),
    releaseWorkflow.indexOf("\n  publish:"),
  );
  expect(dmgJob).toContain("timeout-minutes: 60");
  expect(dmgJob).toContain("name: Cache libghostty");
  expect(dmgJob).toContain("name: Build libghostty");
  expect(dmgJob).toContain("make ghostty");
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
  ).toBe(9);
  expect(releaseWorkflow).toContain(
    "needs: [version, dmg]\n    if: needs.dmg.outputs.superseded != 'true'",
  );
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

test("the publisher uses the repository-scoped Pukbot token", () => {
  const appToken = ["$", "{{ steps.app-token.outputs.token }}"].join("");
  const privateKey = ["$", "{{ secrets.PUKBOT_PRIVATE_KEY }}"].join("");
  expect(releaseWorkflow).toContain(
    "actions/create-github-app-token@bcd2ba49218906704ab6c1aa796996da409d3eb1",
  );
  expect(releaseWorkflow).toContain(
    "repositories: |\n            edith\n            homebrew-tap",
  );
  expect(releaseWorkflow).toContain("permission-contents: write");
  expect(releaseWorkflow).toContain(`private-key: ${privateKey}`);
  expect(releaseWorkflow).not.toContain("secrets[format(");
  expect(releaseWorkflow).toContain(
    "publish:\n    name: Publish release\n    needs: [version, dmg]\n    if: needs.dmg.outputs.superseded != 'true'\n    runs-on: ubuntu-latest\n    environment: pukbot-production",
  );
  expect(releaseWorkflow).toContain(`token: ${appToken}`);
  expect(releaseWorkflow).not.toContain("RELEASE_PUSH_TOKEN");
  expect(releaseWorkflow).not.toContain("TAP_PUSH_TOKEN");
});

test("build jobs cannot retain write credentials", () => {
  expect(releaseWorkflow).toContain("permissions:\n  contents: read");
  expect(releaseWorkflow).toContain(
    "publish:\n    name: Publish release\n    needs: [version, dmg]\n    if: needs.dmg.outputs.superseded != 'true'\n    runs-on: ubuntu-latest\n    environment: pukbot-production\n    concurrency:\n      group: release-publication\n      cancel-in-progress: false\n    permissions:\n      contents: read",
  );
  expect(releaseWorkflow.match(/persist-credentials: false/g)?.length).toBe(4);
  expect(releaseWorkflow.match(/persist-credentials: true/g)?.length).toBe(1);
});

test("the release commit carries every versioned file and its tag atomically", () => {
  expect(releaseStateScript).toContain('-c user.name="pukbot[bot]"');
  expect(releaseStateScript).toContain(
    '-c user.email="320458784+pukbot[bot]@users.noreply.github.com"',
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

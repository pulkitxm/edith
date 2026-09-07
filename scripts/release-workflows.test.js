import { expect, test } from "bun:test";
import { existsSync, readFileSync } from "node:fs";

const ciWorkflow = readFileSync(".github/workflows/ci.yml", "utf8");
const releaseStateScript = readFileSync(
  "scripts/publish-release-state.sh",
  "utf8",
);
const makefile = readFileSync("Makefile", "utf8");
const buildScript = readFileSync("build.sh", "utf8");
const contributing = readFileSync("CONTRIBUTING.md", "utf8");
const homebrewInternals = readFileSync("docs/homebrew-internals.md", "utf8");
const workflow = Bun.YAML.parse(ciWorkflow);
const { version, dmg, publish } = workflow.jobs;
const releaseWorkflow = ciWorkflow;
const releaseTagRef = ["$", "{RELEASE_TAG}"].join("");
const jobText = (job) => JSON.stringify(job).replaceAll("\\n", "\n");

function condition(expression, context) {
  const source = expression
    .replace(/^\s*\$\{\{([\s\S]*)\}\}\s*$/, "$1")
    .replace(/needs\.([\w-]+)/g, 'needs["$1"]');
  return Function(
    "needs",
    "github",
    "inputs",
    "cancelled",
    "contains",
    "fromJSON",
    `return (${source});`,
  )(
    context.needs,
    context.github,
    context.inputs,
    () => context.cancelled ?? false,
    (values, value) => values.includes(value),
    JSON.parse,
  );
}

function releaseContext(overrides = {}) {
  return {
    github: { event_name: "push", ref: "refs/heads/main" },
    inputs: { release: false, rebuild: "" },
    needs: { changes: { result: "success", outputs: { swift: "true" } } },
    ...overrides,
  };
}

function publicationContext() {
  return {
    needs: Object.fromEntries(
      publish.needs.map((name) => [
        name,
        { result: "success", outputs: { superseded: "false" } },
      ]),
    ),
  };
}

test("release preparation belongs to the same CI run and starts after routing", () => {
  expect(existsSync(".github/workflows/release.yml")).toBe(false);
  expect(workflow.jobs["release-build"]).toBeUndefined();
  expect(workflow.jobs.ci).toBeUndefined();
  expect(version.needs).toBe("changes");
  expect(dmg.needs).toBe("version");
  expect(ciWorkflow).not.toContain("gh workflow run");
  expect(ciWorkflow).not.toContain("gh run watch");
  expect(ciWorkflow).not.toContain("gh run view");
  expect(ciWorkflow).not.toContain("CI_RUN_ID");
  expect(ciWorkflow).not.toContain("inputs.source_sha");
});

test("release routing accepts only main product pushes or explicit manual releases", () => {
  expect(condition(version.if, releaseContext())).toBe(true);
  expect(
    condition(
      version.if,
      releaseContext({
        needs: { changes: { result: "success", outputs: { swift: "false" } } },
      }),
    ),
  ).toBe(false);
  for (const event_name of ["pull_request", "workflow_dispatch"]) {
    expect(
      condition(
        version.if,
        releaseContext({
          github: { event_name, ref: "refs/heads/main" },
        }),
      ),
    ).toBe(false);
  }
  for (const inputs of [
    { release: true, rebuild: "" },
    { release: false, rebuild: "v0.0.240" },
  ]) {
    expect(
      condition(
        version.if,
        releaseContext({
          github: { event_name: "workflow_dispatch", ref: "refs/heads/main" },
          inputs,
        }),
      ),
    ).toBe(true);
    expect(
      condition(
        version.if,
        releaseContext({
          github: {
            event_name: "workflow_dispatch",
            ref: "refs/heads/feature",
          },
          inputs,
        }),
      ),
    ).toBe(false);
  }
  for (const result of ["failure", "cancelled", "skipped"]) {
    expect(
      condition(
        version.if,
        releaseContext({
          needs: { changes: { result, outputs: { swift: "true" } } },
        }),
      ),
    ).toBe(false);
  }
});

test("manual release and rebuild inputs resolve the current run source", () => {
  expect(workflow.on.workflow_dispatch.inputs.release.type).toBe("boolean");
  expect(workflow.on.workflow_dispatch.inputs.rebuild.type).toBe("string");
  expect(workflow.on.workflow_dispatch.inputs.rebuild.description).toContain(
    "Current release tag to rebuild and re-upload.",
  );
  expect(version.env.SOURCE_SHA).toBe(["$", "{{ github.sha }}"].join(""));
  expect(version.env.CUT_RELEASE).toContain("inputs.release");
  expect(version.env.CUT_RELEASE).toContain("github.event_name == 'push'");
  expect(jobText(version)).toContain(
    "checkout does not match the approved commit",
  );
  expect(jobText(version)).toContain("run the workflow from main");
  expect(jobText(version)).toContain("refs/tags/{0}");
  expect(jobText(version)).toContain("../scripts/resolve-release-version.sh");
});

test("release publication is serialized without interrupting an active publication", () => {
  expect(publish.concurrency).toEqual({
    group: "release-publication",
    "cancel-in-progress": false,
  });
});

test("automated commits do not re-run CI", () => {
  expect(ciWorkflow).toContain("'Release v'");
  expect(ciWorkflow).toContain("'Refresh the contributor list'");
  expect(ciWorkflow).toContain("github.event_name != 'push'");
});

test("publication depends directly on every required check in the current run", () => {
  expect([...publish.needs].sort()).toEqual([
    "checks",
    "companion",
    "dmg",
    "promo-video",
    "swift-build",
    "swift-test",
    "version",
  ]);
  expect(publish.if).toContain("!cancelled()");
  expect(condition(publish.if, publicationContext())).toBe(true);
  for (const name of publish.needs) {
    for (const result of ["failure", "cancelled"]) {
      const context = publicationContext();
      context.needs[name].result = result;
      expect(condition(publish.if, context)).toBe(false);
    }
  }
  for (const name of ["version", "dmg", "checks"]) {
    const context = publicationContext();
    context.needs[name].result = "skipped";
    expect(condition(publish.if, context)).toBe(false);
  }
  const optional = ["swift-test", "companion", "promo-video", "swift-build"];
  for (let mask = 0; mask < 2 ** optional.length; mask += 1) {
    const context = publicationContext();
    optional.forEach((name, index) => {
      context.needs[name].result = mask & (1 << index) ? "skipped" : "success";
    });
    expect(condition(publish.if, context)).toBe(true);
  }
  const superseded = publicationContext();
  superseded.needs.dmg.outputs.superseded = "true";
  expect(condition(publish.if, superseded)).toBe(false);
  expect(
    condition(publish.if, { ...publicationContext(), cancelled: true }),
  ).toBe(false);
});

test("release builds and publishes the macOS assets", () => {
  const dmgJob = ciWorkflow.slice(
    ciWorkflow.indexOf("\n  dmg:"),
    ciWorkflow.indexOf("\n  publish:"),
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
  expect(dmgJob).toContain("for attempt in 1 2 3 4 5; do");
  expect(dmgJob).toContain("sleep 2");
  expect(dmgJob).toContain('exit "$verify_status"');
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
  expect(swiftTestJob).toContain("timeout-minutes: 45");
  expect(swiftTestJob).toContain("name: Cache libghostty");
  expect(swiftTestJob).toContain("name: Build libghostty");
});

test("superseded release builds yield the lane before packaging", () => {
  const dmgJob = ciWorkflow.slice(
    ciWorkflow.indexOf("\n  dmg:"),
    ciWorkflow.indexOf("\n  publish:"),
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
  ).toBe(10);
  expect(publish.if).toContain("needs.dmg.outputs.superseded != 'true'");
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
  expect(workflow.permissions).toEqual({ contents: "read" });
  expect(publish.permissions).toEqual({ contents: "write" });
  for (const job of [version, dmg]) {
    expect(job.permissions?.contents).not.toBe("write");
    const checkouts = job.steps.filter((step) =>
      step.uses?.startsWith("actions/checkout@"),
    );
    expect(checkouts.length).toBeGreaterThan(0);
    for (const checkout of checkouts) {
      expect(checkout.with["persist-credentials"]).toBe(false);
    }
  }
  const retainedCredentials = publish.steps.filter(
    (step) =>
      step.uses?.startsWith("actions/checkout@") &&
      step.with["persist-credentials"],
  );
  expect(retainedCredentials).toHaveLength(1);
  expect(retainedCredentials[0].with.token).toBe(
    ["$", "{{ secrets.RELEASE_PUSH_TOKEN }}"].join(""),
  );
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

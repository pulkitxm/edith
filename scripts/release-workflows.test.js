import { expect, test } from "bun:test";
import { existsSync, readFileSync } from "node:fs";

const ciWorkflow = readFileSync(".github/workflows/ci.yml", "utf8");
const releaseStateScript = readFileSync(
  "scripts/publish-release-state.sh",
  "utf8",
);
const makefile = readFileSync("Makefile", "utf8");
const buildScript = readFileSync("build.sh", "utf8");
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
    needs: { changes: { result: "success", outputs: { host: "true" } } },
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
        needs: { changes: { result: "success", outputs: { host: "false" } } },
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
          needs: { changes: { result, outputs: { host: "true" } } },
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
    "music-player",
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
  const optional = [
    "swift-test",
    "companion",
    "music-player",
    "promo-video",
    "swift-build",
  ];
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

test("release builds and publishes only empty-host macOS assets", () => {
  const text = jobText(dmg);
  expect(text).toContain("make verify-bundle");
  expect(text.indexOf("make verify-bundle")).toBeLessThan(
    text.indexOf("package-host-dmg.py"),
  );
  expect(text).toContain(
    "python3 scripts/package-host-dmg.py dist/Edith.app Edith.dmg",
  );
  expect(text).not.toContain("ghostty");
  expect(text).not.toContain("edith-database");
  expect(text).toContain("Packages/EdithHost/.build/artifacts");
  expect(text).toContain("SPARKLE_PRIVATE_KEY");
  expect(text).toContain("xcrun notarytool submit Edith.dmg --wait");
  expect(buildScript).toContain("scripts/build-minimal-host.mjs");
  expect(buildScript).not.toContain("xcodebuild -project");
  expect(buildScript).not.toContain("cargo build");
  expect(jobText(publish)).toContain("release-assets/Edith.dmg");
  expect(jobText(publish)).toContain("release-assets/appcast.xml");
  expect(jobText(publish)).not.toContain("edith-database");
  expect(jobText(publish)).toContain(
    "node scripts/publish-host-release.mjs release-assets",
  );
  expect(jobText(publish)).toContain(
    "pukbot commit create --repo pulkitxm/homebrew-tap",
  );
  expect(jobText(publish)).not.toContain("git push");
  expect(jobText(publish)).not.toContain("git commit");
});

test("host test lanes exclude optional terminal dependencies", () => {
  const job = workflow.jobs["swift-test"];
  const tests = job.steps.find((step) => step.name === "Tests");
  expect(job["timeout-minutes"]).toBeGreaterThan(tests["timeout-minutes"]);
  expect(JSON.stringify(job)).not.toContain("make ghostty");
  expect(JSON.stringify(job)).not.toContain("Packages/Edith/");
  expect(tests.run).toContain('read -r -a targets <<< "$TARGETS"');
  expect(tests.run).toContain('make "${targets[@]}"');
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

test("bundle verification enforces the empty host and same executable launcher", () => {
  expect(makefile).toContain(
    "python3 scripts/verify-shipping-host.py dist/Edith.app",
  );
  const verifier = readFileSync("scripts/verify_shipping_host.py", "utf8");
  expect(verifier).toContain("Unexpected host executable");
  expect(verifier).toContain("Feature resources in host");
  expect(verifier).toContain("../Resources/ed-launcher");
  expect(verifier).toContain("10_000_000");
  expect(verifier).toContain("--deep");
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
  expect(releaseWorkflow).toContain("pukbot capabilities --json");
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
  for (const step of publish.steps.filter((step) =>
    step.uses?.startsWith("actions/checkout@"),
  )) {
    expect(step.with["persist-credentials"]).toBe(false);
  }
  expect(publish.env.GH_TOKEN).toBe(
    ["$", "{{ secrets.RELEASE_PUSH_TOKEN }}"].join(""),
  );
});

test("release version commits and tags use the release client with source verification", () => {
  expect(releaseStateScript).toContain("pukbot commit create");
  expect(releaseStateScript).toContain("pukbot tag create");
  expect(releaseStateScript).toContain(
    "git add Resources/Info.plist Resources/HelperInfo.plist Casks/edith.rb",
  );
  expect(releaseStateScript).toContain(
    `--message "Release ${releaseTagRef} [skip ci]"`,
  );
  expect(releaseStateScript).toContain('git rev-parse "$RELEASE_SHA^"');
  expect(releaseStateScript).not.toContain("git push");
  expect(releaseStateScript).not.toContain("git reset --hard");
});

test("release publication can recover after a partial failure", () => {
  expect(releaseStateScript).toContain("remote_tag_sha");
  expect(releaseWorkflow).toContain("Update the rebuilt release checksum");
  expect(releaseStateScript).toContain(
    "only the current release can be rebuilt",
  );
  expect(releaseStateScript).toContain(
    `--message "Refresh ${releaseTagRef} release checksum"`,
  );
  const mirror = releaseWorkflow.slice(
    releaseWorkflow.indexOf("- name: Mirror the cask to the tap repository"),
  );
  expect(mirror).not.toContain("if: env.REBUILD == ''");
  expect(mirror).toContain("mkdir -p tap/Casks");
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

test("GitHub Actions publishes a release from main", () => {
  expect(existsSync(".github/workflows/ci.yml")).toBe(true);
  const agents = readFileSync("AGENTS.md", "utf8");
  expect(agents).toContain("GitHub Actions");
  expect(agents).not.toContain("workflows-disabled");
  expect(agents).not.toContain("make ci-all");
});

test("local releases use the same guarded commit and asset publisher as CI", () => {
  const local = readFileSync("scripts/release-local.sh", "utf8");
  expect(local).toContain(
    "run-current-release-build.sh ./build.sh --no-open --release",
  );
  expect(local).toContain("scripts/publish-release-state.sh cut");
  expect(local).toContain(
    "scripts/publish-host-release.mjs dist/host-release-assets",
  );
  expect(local).toContain("package-host-dmg.py dist/Edith.app Edith.dmg");
  expect(local).not.toContain("package-database-pack");
  expect(local).not.toContain("git reset --hard");
  expect(local).not.toContain("git push");
  expect(local).not.toContain('pukbot release create "$RELEASE_TAG"');
});

test("release asset capacity is checked before any release commit", () => {
  const preflight = publish.steps.findIndex(
    (step) => step.name === "Require the release client to accept both assets",
  );
  const commit = publish.steps.findIndex(
    (step) => step.name === "Commit and tag the release",
  );
  expect(preflight).toBeGreaterThan(-1);
  expect(preflight).toBeLessThan(commit);
  expect(publish.steps[preflight].run).toContain("--preflight release-assets");
  const local = readFileSync("scripts/release-local.sh", "utf8");
  expect(local.indexOf("--preflight dist/host-release-assets")).toBeLessThan(
    local.indexOf("bash scripts/publish-release-state.sh cut"),
  );
});

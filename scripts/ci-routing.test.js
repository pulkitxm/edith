import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";

const ciWorkflow = readFileSync(".github/workflows/ci.yml", "utf8");
const packageManifest = readFileSync("Packages/Edith/Package.swift", "utf8");
const swiftCache = Bun.YAML.parse(
  readFileSync(".github/actions/cache-swift/action.yml", "utf8"),
);
const ciJobs = Bun.YAML.parse(ciWorkflow).jobs;
const pagesWorkflow = readFileSync(".github/workflows/pages.yml", "utf8");
const wikiWorkflow = readFileSync(".github/workflows/wiki-sync.yml", "utf8");

const areaPatterns = new Map(
  [...ciWorkflow.matchAll(/area ([a-z_]+) '([^']+)'/g)].map(
    ([, area, pattern]) => [area, new RegExp(pattern)],
  ),
);

const matchesArea = (area, path) => areaPatterns.get(area)?.test(path) ?? false;

const pushPaths = (workflow) => {
  const push = workflow.slice(
    workflow.indexOf("  push:"),
    workflow.indexOf("  workflow_dispatch:"),
  );
  return [...push.matchAll(/^ {6}- "([^"]+)"$/gm)].map(([, path]) => path);
};

test("a pull request is compared against its base, not its last push", () => {
  const baseFirst = ciWorkflow.indexOf('if [ -n "$BASE_REF" ]');
  const beforeFallback = ciWorkflow.indexOf('elif [ -n "$BEFORE" ]');
  expect(baseFirst).toBeGreaterThan(-1);
  expect(beforeFallback).toBeGreaterThan(baseFirst);
});

test("every change area covers its repository inputs", () => {
  const cases = {
    swift: [
      "Packages/Edith/Sources/Edith/App.swift",
      "Resources/Info.plist",
      "edth.xcodeproj/project.pbxproj",
      "scripts/test-swift-test-isolation.py",
      "build.sh",
      "Makefile",
      ".swift-format",
    ],
    docs: ["docs/cli/README.md"],
    workflows: [
      ".github/workflows/ci.yml",
      ".github/actions/cache-swift/action.yml",
    ],
    promo: ["apps/promo-video/src/Promo.tsx"],
    site: ["apps/site/index.html"],
    scripts: [
      "scripts/check-secrets.mjs",
      "Casks/edith.rb",
      "README.md",
      "Makefile",
      "package.json",
      "bun.lock",
      "biome.json",
    ],
    performance: [
      "Packages/Edith/Sources/Edith/App.swift",
      "Packages/Edith/Tests/EdithTests/PerformanceTraceTests.swift",
      "performance/audit.json",
      "scripts/check-performance-audit.mjs",
      "scripts/check-performance-audit.test.js",
      "scripts/bench-helper.sh",
      "scripts/bench-helper.test.js",
      "Makefile",
    ],
    source: [
      "Packages/Edith/Sources/Edith/App.swift",
      "apps/companion/compose.yaml",
      "apps/promo-video/src/Promo.tsx",
      "apps/site/styles.css",
    ],
    companion: ["apps/companion/src/main.rs"],
    companion_runtime: [
      "apps/companion/Dockerfile",
      "apps/companion/compose.yaml",
      "apps/companion/compose.cpu.yaml",
      "apps/companion/compose.mac.yaml",
      "apps/companion/compose.gpu.yaml",
    ],
  };

  for (const [area, paths] of Object.entries(cases)) {
    for (const path of paths) {
      expect(matchesArea(area, path), `${area}: ${path}`).toBeTrue();
    }
  }
});

test("a main push releases when the Swift area changed", () => {
  const releaseBuildJob = ciWorkflow.slice(ciWorkflow.indexOf("\n  version:"));
  expect(releaseBuildJob).toContain(
    "&& ((github.event_name == 'push'\n      && needs.changes.outputs.swift == 'true')",
  );
  expect(ciWorkflow).not.toContain("release_artifact");
  expect(ciWorkflow).not.toContain("release-artifact-changed.sh");
});

test("embedded companion runtime changes run their focused guard", () => {
  const swiftTest = ciWorkflow.slice(
    ciWorkflow.indexOf("\n  swift-test:"),
    ciWorkflow.indexOf("\n  companion:"),
  );
  expect(swiftTest).not.toContain(
    "needs.changes.outputs.companion_runtime == 'true'",
  );
  expect(ciWorkflow).toContain(
    "needs.changes.outputs.companion_runtime == 'true' || needs.changes.outputs.workflows == 'true'",
  );
  expect(ciWorkflow).toContain("run: make ci-companion-runtime");
});

test("documentation changes run focused documentation tests", () => {
  const swiftTest = ciWorkflow.slice(
    ciWorkflow.indexOf("\n  swift-test:"),
    ciWorkflow.indexOf("\n  companion:"),
  );
  expect(swiftTest).not.toContain("needs.changes.outputs.docs == 'true'");
  expect(ciWorkflow).toContain(
    "needs.changes.outputs.docs == 'true' || needs.changes.outputs.workflows == 'true'",
  );
  expect(ciWorkflow).toContain("run: make ci-docs");
});

test("performance inputs run structural contracts against the compared revision", () => {
  expect(ciWorkflow).toContain("area performance '");
  expect(ciWorkflow).toContain(
    "needs.changes.outputs.performance == 'true' || needs.changes.outputs.workflows == 'true'",
  );
  expect(ciWorkflow).toContain("PERFORMANCE_BASE:");
  expect(ciWorkflow).toContain("run: make ci-performance");
  const checks = ciWorkflow.slice(
    ciWorkflow.indexOf("\n  checks:"),
    ciWorkflow.indexOf("\n  promo-video:"),
  );
  expect(checks).toContain("fetch-depth: 0");
});

test("main releases skip the redundant debug app build", () => {
  const swiftBuild = ciWorkflow.slice(
    ciWorkflow.indexOf("\n  swift-build:"),
    ciWorkflow.indexOf("\n  swift-test:"),
  );
  expect(swiftBuild).toContain("github.event_name != 'push'");
  const releaseBuild = ciWorkflow.slice(
    ciWorkflow.indexOf("\n  version:"),
    ciWorkflow.indexOf("\n  dmg:"),
  );
  expect(releaseBuild).toContain("&& ((github.event_name == 'push'");
  expect(releaseBuild).not.toContain("needs.swift-build");
});

test("Swift tests build their CLI fixture in one package graph", () => {
  const testTarget = packageManifest.slice(
    packageManifest.indexOf('name: "EdithTests"'),
  );
  expect(testTarget).toContain('"Highlighter", "ed"');
});

test("Swift tests cache a successful build before bounded execution", () => {
  const job = ciJobs["swift-test"];
  const steps = job.steps;
  const restore = steps.find((step) => step.id === "swift-cache");
  const isolation = steps.find((step) => step.name === "Verify test isolation");
  const build = steps.find((step) => step.name === "Build tests");
  const save = steps.find((step) => step.name === "Save compiled tests");
  const run = steps.find((step) => step.name === "Tests");
  expect(job["timeout-minutes"]).toBe(45);
  expect(restore.uses).toBe("./.github/actions/cache-swift");
  expect(restore.with.variant).toBe("tests-debug");
  expect(isolation.run).toBe("python3 -B scripts/test-swift-test-isolation.py");
  expect(build.run).toBe("./test.sh --build-only");
  expect(build["working-directory"]).toBe("Packages/Edith");
  expect(build["timeout-minutes"]).toBe(20);
  expect(build.if).toBeUndefined();
  expect(run.run).toBe("./test.sh --skip-build");
  expect(run["working-directory"]).toBe(build["working-directory"]);
  expect(run["timeout-minutes"]).toBe(10);
  expect(run.if).toBeUndefined();
  expect(run.env.EDITH_REQUIRE_FISH_COMPLETION_TEST).toBe("1");
  expect(save.if).toBe(
    "steps.swift-cache.outputs.compiled-cache-hit != 'true'",
  );
  expect(save.uses).toBe(
    "actions/cache/save@55cc8345863c7cc4c66a329aec7e433d2d1c52a9",
  );
  expect(save.with.key).toBe(
    `\${{ steps.swift-cache.outputs.compiled-cache-key }}`,
  );
  for (const [before, after] of [
    [restore, build],
    [isolation, build],
    [build, save],
    [save, run],
  ]) {
    expect(steps.indexOf(before)).toBeLessThan(steps.indexOf(after));
  }
  const compiled = swiftCache.runs.steps.find((step) => step.id === "compiled");
  expect(save.with.path).toBe(compiled.with.path);
  expect(swiftCache.outputs["compiled-cache-key"].value).toBe(
    compiled.with.key,
  );
  expect(swiftCache.outputs["compiled-cache-hit"].value).toBe(
    `\${{ steps.compiled.outputs.cache-hit }}`,
  );
});

test("Swift build consumers retain automatic compiled cache saves", () => {
  const compiled = swiftCache.runs.steps.find((step) => step.id === "compiled");
  expect(compiled.uses).toBe(
    "actions/cache@55cc8345863c7cc4c66a329aec7e433d2d1c52a9",
  );
  for (const [job, variant] of [
    ["swift-build", "app-debug"],
    ["dmg", "app-release"],
  ]) {
    const cache = ciJobs[job].steps.find(
      (step) => step.uses === "./.github/actions/cache-swift",
    );
    expect(cache.with.variant).toBe(variant);
  }
});

test("targeted publishing workflows watch every deployment input", () => {
  expect(pushPaths(pagesWorkflow)).toEqual([
    "apps/site/**",
    ".github/workflows/pages.yml",
  ]);
  expect(pushPaths(wikiWorkflow)).toEqual([
    "docs/**",
    "scripts/sync-wiki.mjs",
    ".github/workflows/wiki-sync.yml",
  ]);
});

test("every workflow change runs the runtime guard", () => {
  expect(ciWorkflow).toContain(
    "area workflows '^\\.github/(workflows|actions)/'",
  );
  expect(ciWorkflow).toContain(
    "needs.changes.outputs.scripts == 'true' || needs.changes.outputs.workflows == 'true'",
  );
  expect(ciWorkflow).toContain(
    "needs.changes.outputs.promo == 'true' || needs.changes.outputs.workflows == 'true'",
  );
  expect(ciWorkflow).toContain(
    "needs.changes.outputs.site == 'true' || needs.changes.outputs.workflows == 'true'",
  );
  const swiftTest = ciWorkflow.slice(
    ciWorkflow.indexOf("\n  swift-test:"),
    ciWorkflow.indexOf("\n  version:"),
  );
  expect(swiftTest).toContain("needs.changes.outputs.workflows == 'true'");
  expect(ciWorkflow).toContain(
    "go run github.com/rhysd/actionlint/cmd/actionlint@v1.7.12",
  );
});

test("contributor refresh pushes cannot replace pending product validation", () => {
  expect(ciWorkflow).toContain(
    "github.event_name == 'workflow_dispatch' && github.run_id",
  );
  expect(ciWorkflow).toContain(
    "startsWith(github.event.head_commit.message, 'Refresh the contributor list')",
  );
  expect(ciWorkflow).toContain("&& github.sha)");
  expect(ciWorkflow).toContain("|| 'active'");
});

test("manual production workflows require main", () => {
  expect(pagesWorkflow).toContain("Require main for manual deployment");
  expect(pagesWorkflow).toContain('test "$GITHUB_REF" = refs/heads/main');
  expect(wikiWorkflow).toContain("Require main for manual sync");
  expect(wikiWorkflow).toContain('test "$GITHUB_REF" = refs/heads/main');
});

test("backend changes run the companion job", () => {
  expect(ciWorkflow).toContain("area companion '^apps/companion/'");
  expect(ciWorkflow).toContain("needs.changes.outputs.companion == 'true'");
  expect(ciWorkflow).toMatch(/pgvector\/pgvector:pg18@sha256:[a-f0-9]{64}/);
  expect(ciWorkflow).toContain("runs-on: ubuntu-latest");
  expect(ciWorkflow).toContain("cargo test --locked");
  expect(ciWorkflow).toContain(
    "cargo clippy --all-targets --locked -- -D warnings",
  );
  expect(ciWorkflow).toContain("--migrate-only");
});

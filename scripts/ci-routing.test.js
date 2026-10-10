import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { planSwiftTests } from "./ci-test-plan.mjs";

const ciWorkflow = readFileSync(".github/workflows/ci.yml", "utf8");
const ciJobs = Bun.YAML.parse(ciWorkflow).jobs;
const pagesWorkflow = readFileSync(".github/workflows/pages.yml", "utf8");
const wikiWorkflow = readFileSync(".github/workflows/wiki-sync.yml", "utf8");

const areaPatterns = new Map(
  [...ciWorkflow.matchAll(/area ([a-z_]+) '([^']+)'/g)].map(
    ([, area, pattern]) => [area, new RegExp(pattern)],
  ),
);

const matchesArea = (area, path) => areaPatterns.get(area)?.test(path) ?? false;

test("Spotify catalog changes run native and locked Rust checks", () => {
  for (const path of [
    "apps/music-player/src/catalog.rs",
    "apps/music-player/Cargo.toml",
    "apps/music-player/Cargo.lock",
  ]) {
    expect(matchesArea("music_player", path)).toBe(true);
    expect(matchesArea("swift", path)).toBe(true);
  }
  expect(matchesArea("music_player", "docs/music.md")).toBe(false);
  const job = ciJobs["music-player"];
  expect(job.needs).toBe("changes");
  expect(job.if).toBe("needs.changes.outputs.music_player == 'true'");
  expect(job["runs-on"]).toBe("macos-26");
  const checks = job.steps.find(
    (step) => step["working-directory"] === "apps/music-player",
  );
  expect(checks.run).toContain("cargo +stable fmt --check");
  expect(checks.run).toContain(
    "cargo +stable clippy --locked --all-targets -- -D warnings",
  );
  expect(checks.run).toContain("cargo +stable test --locked");
});

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
      "Packages/EdithDocsWorker/Sources/EdithDocsWorker/DocsLibrary.swift",
      "Packages/EdithDocsWorker/Sources/EdithDocsWorker/Resources/cli-docs.json",
      "Packages/EdithDocsWorker/Tests/EdithDocsWorkerTests/DocsTests.swift",
      "Packages/EdithDocsWorker/Package.swift",
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

test("a main push releases when the host area changed", () => {
  const releaseBuildJob = ciWorkflow.slice(ciWorkflow.indexOf("\n  version:"));
  expect(releaseBuildJob).toContain(
    "&& ((github.event_name == 'push'\n      && needs.changes.outputs.host == 'true')",
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

test("pull requests build the release app that main releases rebuild", () => {
  const swiftBuild = ciWorkflow.slice(
    ciWorkflow.indexOf("\n  swift-build:"),
    ciWorkflow.indexOf("\n  swift-test:"),
  );
  expect(swiftBuild).toContain("github.event_name == 'pull_request'");
  expect(swiftBuild).toContain("needs.changes.outputs.host == 'true'");
  expect(swiftBuild).not.toContain(
    "needs.changes.outputs.swift == 'true'\n      ||",
  );
  expect(swiftBuild).toContain("run: ./build.sh --no-open --release");
  expect(swiftBuild).toContain('EDITH_RELEASE_ALLOW_DEV_SIGNING: "1"');
  const releaseBuild = ciWorkflow.slice(
    ciWorkflow.indexOf("\n  version:"),
    ciWorkflow.indexOf("\n  dmg:"),
  );
  expect(releaseBuild).toContain("&& ((github.event_name == 'push'");
  expect(releaseBuild).not.toContain("needs.swift-build");
});

test("Swift lanes exercise only independent host and extension packages", () => {
  const job = ciJobs["swift-test"];
  expect(job.strategy["fail-fast"]).toBe(false);
  expect(job.strategy["max-parallel"]).toBe(3);
  expect(job.strategy.matrix).toBe(
    ["$", "{{ fromJSON(needs.changes.outputs.swift_matrix) }}"].join(""),
  );
  expect(job.if).toBe("needs.changes.outputs.swift_tests == 'true'");
  expect(planSwiftTests([], { all: true }).include).toEqual([
    { lane: "host-runtime", targets: "ci-host ci-marketplace-runtime" },
    {
      lane: "feature-models",
      targets: "ci-extension-support ci-extension-docs",
    },
    { lane: "native-music", targets: "ci-music-native" },
  ]);
  expect(JSON.stringify(job)).not.toContain("Packages/Edith/");
  expect(JSON.stringify(job)).not.toContain("make ghostty");
  const tests = job.steps.find((step) => step.name === "Tests");
  expect(tests.run).toContain('read -r -a targets <<< "$TARGETS"');
  expect(tests.run).toContain('make "${targets[@]}"');
  expect(tests.env.TARGETS).toBe("${{ matrix.targets }}");
  expect(job["timeout-minutes"]).toBeGreaterThan(tests["timeout-minutes"]);
  const cache = job.steps.find(
    (step) => step.name === "Cache independent test products",
  );
  expect(cache.with.path).toContain("Packages/ExtensionSupport/.build");
  expect(cache.with.path).toContain("Extensions/.build");
  expect(cache.with.key).toContain("runner.arch");
  expect(cache.with.key).toContain("matrix.lane");
});

test("host build consumers use the narrow host cache", () => {
  for (const job of ["swift-build", "dmg", "swift-test"]) {
    expect(
      ciJobs[job].steps.some(
        (step) => step.uses === "./.github/actions/cache-host",
      ),
    ).toBe(true);
  }
  const hostCache = Bun.YAML.parse(
    readFileSync(".github/actions/cache-host/action.yml", "utf8"),
  );
  const products = hostCache.runs.steps.find((step) =>
    step.uses?.startsWith("actions/cache@"),
  );
  expect(products.with.path).toBe("Packages/EdithHost/.build");
  expect(products.with.key).not.toContain("Packages/Edith/");
  expect(products.with.key).not.toContain("EdithExtensionDocuments");
});

test("Swift jobs restore commit times from full history before reusing builds", () => {
  const hostCache = Bun.YAML.parse(
    readFileSync(".github/actions/cache-host/action.yml", "utf8"),
  );
  expect(hostCache.runs.steps[0].run).toBe(
    "python3 -B scripts/restore-source-mtimes.py",
  );
  for (const name of ["swift-build", "swift-test", "dmg"]) {
    const steps = ciJobs[name].steps;
    const checkout = steps.find((step) =>
      step.uses?.startsWith("actions/checkout@"),
    );
    const cache = steps.findIndex((step) =>
      [
        "./.github/actions/cache-swift",
        "./.github/actions/cache-host",
      ].includes(step.uses),
    );
    expect(checkout.with["fetch-depth"], name).toBe(0);
    expect(steps.indexOf(checkout), name).toBeLessThan(cache);
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
  expect(swiftTest).toContain("needs.changes.outputs.swift_tests == 'true'");
  expect(ciWorkflow).toContain(
    "go run github.com/rhysd/actionlint/cmd/actionlint@v1.7.12",
  );
});

test("a push never queues behind or replaces another run of the workflow", () => {
  expect(ciWorkflow).toContain(
    "github.event_name == 'workflow_dispatch' && github.run_id",
  );
  expect(ciWorkflow).toContain("|| github.event_name == 'push' && github.sha");
  expect(ciWorkflow).toContain("|| 'active'");
  expect(ciWorkflow).toContain(
    // biome-ignore lint/suspicious/noTemplateCurlyInString: a GitHub expression, not a template
    "cancel-in-progress: ${{ github.event_name == 'pull_request' }}",
  );
});

test("only a push that changes product code cancels the checks of an older push", () => {
  const productPush =
    "github.event_name == 'push' && needs.changes.outputs.swift == 'true'";
  for (const job of [
    "checks",
    "promo-video",
    "swift-build",
    "swift-test",
    "companion",
  ]) {
    const start = ciWorkflow.indexOf(`\n  ${job}:`);
    const body = ciWorkflow.slice(
      start,
      ciWorkflow.indexOf("\n    steps:", start),
    );
    expect(body).toContain(`group: ci-${job}-`);
    expect(body).toContain(`${productPush} && 'product' || github.run_id`);
    expect(body).toContain(`cancel-in-progress: \${{ ${productPush} }}`);
  }
  expect(ciWorkflow).toContain(
    // biome-ignore lint/suspicious/noTemplateCurlyInString: a GitHub expression, not a template
    "group: ci-swift-test-${{ matrix.lane }}-",
  );
});

test("the release jobs are never cancelled by a newer push", () => {
  for (const job of ["version", "dmg", "publish"]) {
    const start = ciWorkflow.indexOf(`\n  ${job}:`);
    const next = ciWorkflow.indexOf("\n  ", start + 5);
    const body = ciWorkflow.slice(
      start,
      next > start ? ciWorkflow.indexOf("\n    steps:", start) : undefined,
    );
    expect(body).not.toContain("cancel-in-progress: ${{");
    expect(body).not.toContain("cancel-in-progress: true");
  }
  const publish = ciWorkflow.slice(ciWorkflow.indexOf("\n  publish:"));
  expect(publish).toContain("group: release-publication");
  expect(publish).toContain("cancel-in-progress: false");
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

test("independent feature changes do not release or invalidate the host", () => {
  for (const path of [
    "Extensions/calendar/Runtime.swift",
    "Packages/EdithHost/Tests/EdithHostCoreTests/HostTests.swift",
    "Packages/ExtensionMarketplace/Tests/ExtensionMarketplaceTests/StoreTests.swift",
    "apps/music-player/src/main.rs",
    "Packages/ExtensionSupport/Sources/EdithExtensionDocuments/DocumentRenderer.swift",
  ]) {
    expect(matchesArea("host", path), path).toBe(false);
  }
  for (const path of [
    "Packages/EdithHost/Sources/EdithHost/HostApplication.swift",
    "Packages/ExtensionMarketplace/Sources/ExtensionMarketplace/PackageStore.swift",
    "Packages/ExtensionSupport/Sources/EdithExtensionUI/PageScaffold.swift",
    "scripts/package-shipping-host.py",
    "scripts/verify_shipping_host.py",
    ".github/actions/cache-host/action.yml",
  ]) {
    expect(matchesArea("host", path), path).toBe(true);
  }
});

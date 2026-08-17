import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";

const ciWorkflow = readFileSync(".github/workflows/ci.yml", "utf8");
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
      "build.sh",
      "Makefile",
      ".swift-format",
    ],
    docs: ["docs/cli/README.md"],
    workflows: [".github/workflows/ci.yml"],
    promo: ["apps/promo-video/src/Promo.tsx"],
    site: ["apps/site/index.html"],
    scripts: [
      "scripts/check-secrets.mjs",
      "Casks/edith.rb",
      "README.md",
      "Makefile",
      "lefthook.yml",
      "package.json",
      "bun.lock",
      "biome.json",
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

test("embedded companion runtime changes run Swift tests", () => {
  const swiftTest = ciWorkflow.slice(
    ciWorkflow.indexOf("\n  swift-test:"),
    ciWorkflow.indexOf("\n  companion:"),
  );
  expect(swiftTest).toContain(
    "needs.changes.outputs.companion_runtime == 'true'",
  );
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
  expect(ciWorkflow).toContain("area workflows '^\\.github/workflows/'");
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
    ciWorkflow.indexOf("\n  release:"),
  );
  expect(swiftTest).toContain("needs.changes.outputs.workflows == 'true'");
  expect(ciWorkflow).toContain(
    "go run github.com/rhysd/actionlint/cmd/actionlint@v1.7.12",
  );
});

test("generated pushes cannot replace pending product validation", () => {
  expect(ciWorkflow).toContain(
    "github.event_name == 'workflow_dispatch' && github.run_id",
  );
  expect(ciWorkflow).toContain(
    "startsWith(github.event.head_commit.message, 'Release v')",
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

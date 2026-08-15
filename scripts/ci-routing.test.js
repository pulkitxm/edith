import { expect, test } from "bun:test";
import { existsSync, readFileSync } from "node:fs";

const ciWorkflow = readFileSync(".github/workflows/ci.yml", "utf8");
const pagesWorkflow = readFileSync(".github/workflows/pages.yml", "utf8");
const wikiWorkflow = readFileSync(".github/workflows/wiki-sync.yml", "utf8");
const linuxOutput = ["$", "{{ steps.areas.outputs.linux }}"].join("");

test("Linux validation uses the shared changed-area router", () => {
  expect(ciWorkflow).toContain(`linux: ${linuxOutput}`);
  expect(ciWorkflow).toContain("area linux '");
  expect(ciWorkflow).toContain("needs.changes.outputs.linux == 'true'");
  expect(ciWorkflow).toContain("make linux-package");
  expect(existsSync(".github/workflows/linux.yml")).toBeFalse();
});

test("a pull request is compared against its base, not its last push", () => {
  const baseFirst = ciWorkflow.indexOf('if [ -n "$BASE_REF" ]');
  const beforeFallback = ciWorkflow.indexOf('elif [ -n "$BEFORE" ]');
  expect(baseFirst).toBeGreaterThan(-1);
  expect(beforeFallback).toBeGreaterThan(baseFirst);
});

test("Linux inputs and workflow changes select Ubuntu validation", () => {
  for (const path of [
    "Packages/Edith/",
    "Resources/",
    "packaging/",
    "Makefile$",
    ".github/workflows/",
  ]) {
    expect(ciWorkflow).toContain(path);
  }
  expect(ciWorkflow).toContain(
    "needs.changes.outputs.linux == 'true' || needs.changes.outputs.workflows == 'true'",
  );
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
  expect(ciWorkflow).toContain("pgvector/pgvector:pg18");
  expect(ciWorkflow).toContain("cargo test --locked");
  expect(ciWorkflow).toContain(
    "cargo clippy --all-targets --locked -- -D warnings",
  );
  expect(ciWorkflow).toContain("--migrate-only");
});

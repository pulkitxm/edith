import { expect, test } from "bun:test";
import { existsSync, readFileSync } from "node:fs";

const ciWorkflow = readFileSync(".github/workflows/ci.yml", "utf8");
const mergeWorkflow = readFileSync(
  ".github/workflows/release-on-merge.yml",
  "utf8",
);
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
    ".github/workflows/(ci|release)",
  ]) {
    expect(ciWorkflow).toContain(path);
  }
  expect(mergeWorkflow).toContain('".github/workflows/ci.yml"');
});

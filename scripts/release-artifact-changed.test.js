import { afterEach, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";

const script = resolve("scripts/release-artifact-changed.sh");
const roots = [];

afterEach(() => {
  for (const root of roots.splice(0)) {
    rmSync(root, { force: true, recursive: true });
  }
});

function command(cwd, executable, args) {
  const result = Bun.spawnSync([executable, ...args], {
    cwd,
    stderr: "pipe",
    stdout: "pipe",
  });
  if (result.exitCode !== 0) {
    throw new Error(`${result.stdout.toString()}${result.stderr.toString()}`);
  }
  return result.stdout.toString().trim();
}

function git(cwd, ...args) {
  return command(cwd, "git", args);
}

function repository() {
  const root = mkdtempSync(join(tmpdir(), "edith-release-routing-"));
  roots.push(root);
  git(root, "init", "--initial-branch=main");
  git(root, "config", "user.name", "Release Test");
  git(root, "config", "user.email", "release@example.com");
  git(root, "config", "commit.gpgsign", "false");
  return root;
}

function commit(root, path, content) {
  const target = join(root, path);
  mkdirSync(dirname(target), { recursive: true });
  writeFileSync(target, content);
  git(root, "add", path);
  git(root, "commit", "-m", `Update ${path}`);
}

function changed(root) {
  return Bun.spawnSync(["bash", script], {
    cwd: root,
    stderr: "pipe",
    stdout: "pipe",
  });
}

test("a workflow-only push after a successful release stays unpublished", () => {
  const root = repository();
  commit(root, "Packages/Edith/Sources/Edith/App.swift", "released");
  git(root, "tag", "v0.0.139");
  commit(root, ".github/workflows/ci.yml", "workflow only");

  const result = changed(root);

  expect(result.exitCode).toBe(1);
  expect(result.stderr.toString()).toContain("release artifact unchanged");
});

test("a workflow-only fix dispatches when app changes remain unreleased", () => {
  const root = repository();
  commit(root, "Packages/Edith/Sources/Edith/App.swift", "released");
  git(root, "tag", "v0.0.139");
  commit(root, "Packages/Edith/Sources/Edith/App.swift", "unreleased");
  commit(root, ".github/workflows/release.yml", "network fix");

  const result = changed(root);

  expect(result.exitCode).toBe(0);
  expect(result.stderr.toString()).toContain(
    "release artifact changed: Packages/Edith/Sources/Edith/App.swift",
  );
});

test("docs-only history never dispatches a release", () => {
  const root = repository();
  commit(root, "README.md", "released baseline");
  git(root, "tag", "v0.0.139");
  commit(root, "docs/cli/README.md", "first");
  commit(root, "docs/cli/README.md", "second");

  const result = changed(root);

  expect(result.exitCode).toBe(1);
  expect(result.stderr.toString()).toContain("release artifact unchanged");
});

test.each([
  "Packages/Edith/Sources/Edith/App.swift",
  "Resources/Info.plist",
  "Packages/Edith/Sources/EdithCLI/Root.swift",
])("a shipped app path dispatches after the latest release: %s", (path) => {
  const root = repository();
  commit(root, "README.md", "released baseline");
  git(root, "tag", "v0.0.139");
  commit(root, path, "shipped change");

  const result = changed(root);

  expect(result.exitCode).toBe(0);
  expect(result.stderr.toString()).toContain(
    `release artifact changed: ${path}`,
  );
});

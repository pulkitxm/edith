import { afterEach, expect, test } from "bun:test";
import { mkdtempSync, rmSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";

const script = resolve("scripts/restore-source-mtimes.py");
const roots = [];

afterEach(() => {
  for (const root of roots.splice(0)) rmSync(root, { recursive: true });
});

function run(command, cwd, env = {}) {
  const result = Bun.spawnSync(command, {
    cwd,
    env: { ...process.env, ...env },
    stdout: "pipe",
    stderr: "pipe",
  });
  return {
    code: result.exitCode,
    stdout: result.stdout.toString(),
    stderr: result.stderr.toString(),
  };
}

function git(cwd, ...args) {
  const result = run(["git", ...args], cwd);
  expect(result.code, result.stderr).toBe(0);
  return result.stdout.trim();
}

function commit(root, time, files) {
  for (const [path, contents] of Object.entries(files)) {
    writeFileSync(join(root, path), contents);
  }
  git(root, "add", "-A");
  const date = `${time} +0000`;
  const result = run(["git", "commit", "-q", "-m", `at ${time}`], root, {
    GIT_AUTHOR_DATE: date,
    GIT_COMMITTER_DATE: date,
  });
  expect(result.code, result.stderr).toBe(0);
}

function repository() {
  const root = mkdtempSync(join(tmpdir(), "edith-source-times-"));
  roots.push(root);
  git(root, "init", "-q");
  git(root, "config", "user.name", "Edith Tests");
  git(root, "config", "user.email", "tests@example.invalid");
  git(root, "config", "commit.gpgsign", "false");
  commit(root, 1_700_000_000, { "first.swift": "one", "second.swift": "two" });
  commit(root, 1_700_000_500, { "second.swift": "changed" });
  return root;
}

function expectedTime(root, path, seconds) {
  const blob = git(root, "rev-parse", `HEAD:${path}`);
  const offset = BigInt(Number.parseInt(blob.slice(0, 8), 16) % 1_000_000_000);
  return BigInt(seconds) * 1_000_000_000n + offset;
}

test("each tracked file takes the time of the last commit that changed it", () => {
  const root = repository();
  const result = run(["python3", "-B", script], root);
  expect(result.code, result.stderr).toBe(0);
  expect(result.stdout).toContain("Restored commit times for 2 tracked files.");
  for (const [path, seconds] of [
    ["first.swift", 1_700_000_000],
    ["second.swift", 1_700_000_500],
  ]) {
    expect(statSync(join(root, path), { bigint: true }).mtimeNs).toBe(
      expectedTime(root, path, seconds),
    );
  }
});

test("a content change moves the time even within the same second", () => {
  const root = repository();
  run(["python3", "-B", script], root);
  const before = statSync(join(root, "first.swift"), { bigint: true }).mtimeNs;
  commit(root, 1_700_000_500, { "first.swift": "rewritten" });
  const result = run(["python3", "-B", script], root);
  expect(result.code, result.stderr).toBe(0);
  const after = statSync(join(root, "first.swift"), { bigint: true }).mtimeNs;
  expect(after).not.toBe(before);
  expect(after).toBe(expectedTime(root, "first.swift", 1_700_000_500));
});

test("a shallow checkout is refused instead of stamping every file alike", () => {
  const origin = repository();
  const clone = mkdtempSync(join(tmpdir(), "edith-source-times-shallow-"));
  roots.push(clone);
  git(clone, "clone", "-q", "--depth", "1", `file://${origin}`, ".");
  const result = run(["python3", "-B", script], clone);
  expect(result.code).not.toBe(0);
  expect(result.stderr).toContain("fetch-depth: 0");
});

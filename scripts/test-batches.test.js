import { expect, test } from "bun:test";
import { spawnSync } from "node:child_process";

const run = (args) =>
  spawnSync("python3", ["scripts/test-batches.py", ...args], {
    encoding: "utf8",
  });

test("test batches partition swift, studio, and script suites", () => {
  const result = run(["check"]);
  expect(result.stderr).toBe("");
  expect(result.status).toBe(0);
  expect(result.stdout).toContain("core=");
  expect(result.stdout).toContain("app=");
}, 15_000);

test("named batches resolve to swift and studio filters", () => {
  const cli = run(["swift-args", "cli"]);
  expect(cli.status).toBe(0);
  expect(cli.stdout).toBe("--filter\n^EdithTests\\.CLI\n");

  const app = run(["swift-args", "app"]);
  expect(app.status).toBe(0);
  expect(app.stdout.startsWith("--skip\n")).toBe(true);
  expect(app.stdout).toContain("EdithTests\\.CLI");

  const pdf = run(["studio-args", "pdf"]);
  expect(pdf.status).toBe(0);
  expect(pdf.stdout).toBe("--filter\n^EdithStudioTests\\.PDF\n");
});

test("script batches list their files and reject an unknown name", () => {
  const usage = run(["script-paths", "usage"]);
  expect(usage.status).toBe(0);
  const paths = usage.stdout.trim().split("\n");
  expect(paths).toContain("scripts/usage-session-input.test.js");
  expect(paths).toContain("scripts/refresh-usage-jq.test.js");
  expect(paths.some((path) => path.includes("ci-routing"))).toBe(false);

  const missing = run(["script-paths", "missing"]);
  expect(missing.status).not.toBe(0);
});

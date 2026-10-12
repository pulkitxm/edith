import { expect, test } from "bun:test";

test("privileged shipping verification runs only synthetic callback lifecycle", () => {
  const result = Bun.spawnSync(
    ["python3", "-B", "scripts/test-privileged-extension-worker-tests.py"],
    { stdout: "pipe", stderr: "pipe", timeout: 30000 },
  );
  expect(result.exitCode, result.stderr.toString()).toBe(0);
});

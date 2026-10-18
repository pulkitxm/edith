import { expect, test } from "bun:test";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

test("host packaging and branch arguments pass the actual Bash regression suite", () => {
  const result = spawnSync(
    "python3",
    ["-I", "-B", "scripts/test-host-packaging-arguments.py"],
    {
      cwd: fileURLToPath(new URL("..", import.meta.url)),
      env: {
        PATH: process.env.PATH,
        TMPDIR: process.env.TMPDIR,
        PYTHONDONTWRITEBYTECODE: "1",
      },
      encoding: "utf8",
      timeout: 10_000,
      maxBuffer: 64 * 1024,
    },
  );
  expect(result.error).toBeUndefined();
  expect(result.status).toBe(0);
  expect(result.stderr).toContain("Ran 3 tests");
  expect(result.stderr).toContain("OK");
});

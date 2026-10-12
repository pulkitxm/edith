import { test } from "bun:test";
import { execFileSync } from "node:child_process";

test("size inventories require the pure filesystem and signed evidence suites", () => {
  for (const file of [
    "test-extension-size-report.py",
    "test-extension-host-size-report.py",
    "test-extension-release-size-report.py",
    "test-release-evidence-sizes.py",
    "test-size-report-filesystem.py",
  ]) {
    execFileSync("python3", ["-B", `scripts/${file}`], {
      timeout: 60000,
      maxBuffer: 262144,
      stdio: "pipe",
      env: { ...process.env, PYTHONDONTWRITEBYTECODE: "1" },
    });
  }
}, 300000);

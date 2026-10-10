import { expect, test } from "bun:test";
import { execFileSync } from "node:child_process";

test("source-bound host release proof rejects synthetic source, seal, payload and appcast mismatches", () => {
  const output = execFileSync(
    "python3",
    ["scripts/test-host-release-proof.py", "HostReleaseProofTests", "-v"],
    { encoding: "utf8", timeout: 30000, maxBuffer: 65536, stdio: "pipe" },
  );
  expect(output).toBe("");
});

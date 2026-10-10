import { expect, test } from "bun:test";
import { mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { runOwnedJourneyCommand } from "./hosted-original-shell/owned-command.mjs";

test("owned process command resolves only successful actual exit and rejects nonzero and launch failures", async () => {
  await runOwnedJourneyCommand(process.execPath, ["-e", "process.exit(0)"]);
  await expect(
    runOwnedJourneyCommand(process.execPath, ["-e", "process.exit(7)"]),
  ).rejects.toThrow("failed: 7");
  await expect(
    runOwnedJourneyCommand("/nonexistent-owned-fixture-command", []),
  ).rejects.toThrow();
  expect(() =>
    runOwnedJourneyCommand(process.execPath, [], { timeoutMs: 0 }),
  ).toThrow();
});

test("timeout waits for actual owned child exit and escalates a child refusing termination", async () => {
  const root = await mkdtemp(join(tmpdir(), "edith-owned-command-"));
  const pidFile = join(root, "pid");
  try {
    await expect(
      runOwnedJourneyCommand(
        process.execPath,
        [
          "-e",
          "const fs=require('fs'); process.on('SIGTERM',()=>{}); fs.writeFileSync(process.argv[1],String(process.pid)); setInterval(()=>{},1000)",
          pidFile,
        ],
        { timeoutMs: 500, terminateGraceMs: 100, stdio: "ignore" },
      ),
    ).rejects.toThrow("after confirmed exit");
    const pid = Number(await readFile(pidFile, "utf8"));
    expect(Number.isInteger(pid) && pid > 1).toBe(true);
    expect(() => process.kill(pid, 0)).toThrow();
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

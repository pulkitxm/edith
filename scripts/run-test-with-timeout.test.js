import { expect, test } from "bun:test";
import { resolve } from "node:path";

const script = resolve("scripts/run-test-with-timeout.py");

function run(source, timeout = 10) {
  const result = Bun.spawnSync([
    "python3",
    "-B",
    script,
    "--timeout",
    String(timeout),
    "--",
    "python3",
    "-c",
    source,
  ]);
  return {
    code: result.exitCode,
    stdout: result.stdout.toString(),
    stderr: result.stderr.toString(),
  };
}

test("test results and output pass through", () => {
  const result = run('import sys; print("synthetic result"); sys.exit(7)');
  expect(result.code).toBe(7);
  expect(result.stdout).toContain("synthetic result");
});

test("stalled tests terminate with an explicit timeout result", () => {
  const result = run("import time; time.sleep(60)", 0.2);
  expect(result.code).toBe(124);
  expect(result.stderr).toContain("Test command exceeded 0.2 seconds");
});

test("tests ignoring termination are killed within the cleanup deadline", () => {
  const start = performance.now();
  const result = run(
    "import signal, time; signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(60)",
    0.2,
  );
  expect(result.code).toBe(124);
  expect(performance.now() - start).toBeLessThan(9000);
}, 10000);

test("test descendants in separate process groups are also cleaned up", () => {
  const result = run(
    'import subprocess, sys, time; child = subprocess.Popen([sys.executable, "-c", "import signal, time; signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(60)"], start_new_session=True); print(child.pid, flush=True); time.sleep(60)',
    0.5,
  );
  expect(result.code).toBe(124);
  const pid = result.stdout.trim();
  expect(pid).toMatch(/^\d+$/);
  const status = Bun.spawnSync(["ps", "-p", pid, "-o", "stat="])
    .stdout.toString()
    .trim();
  expect(status === "" || status.startsWith("Z")).toBe(true);
});

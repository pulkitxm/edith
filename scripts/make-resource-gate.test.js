import { afterEach, expect, test } from "bun:test";
import { mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";

const script = resolve("scripts/make-resource-gate.py");
const roots = [];
const children = [];

const healthy = {
  cpus: 14,
  load: 1,
  mem_total_mb: 24576,
  mem_available_mb: 16384,
  pressure: "normal",
};

const loaded = {
  cpus: 14,
  load: 6.3,
  mem_total_mb: 24576,
  mem_available_mb: 9940,
  pressure: "normal",
};

afterEach(() => {
  for (const child of children.splice(0)) {
    if (child.exitCode === null) child.kill();
  }
  for (const root of roots.splice(0)) rmSync(root, { recursive: true, force: true });
});

function tempDir() {
  const root = mkdtempSync(join(tmpdir(), "make-resource-gate-"));
  roots.push(root);
  return root;
}

function seated(index, overrides = {}) {
  return {
    pid: 4100 + index,
    label: "make build",
    cwd: "/tmp/edith-a",
    threads: 4,
    mem_mb: 4096,
    profile: "xcode build",
    started: 0,
    measured_threads: 0,
    measured_rss_mb: 0,
    ...overrides,
  };
}

function decide(goals, host, jobs, now = 0, ramp = 20) {
  const result = Bun.spawnSync(
    [
      "python3",
      "-B",
      script,
      "decide",
      "--goals",
      ...goals,
      "--host-json",
      JSON.stringify(host),
      "--jobs-json",
      JSON.stringify(jobs),
      "--now",
      String(now),
      "--ramp",
      String(ramp),
    ],
    { stdout: "pipe", stderr: "pipe" },
  );
  expect(result.exitCode, result.stderr.toString()).toBe(0);
  return JSON.parse(result.stdout.toString());
}

function gateEnv(root, overrides = {}) {
  const env = {
    ...process.env,
    EDITH_MAKE_GATE_DIR: root,
    EDITH_MAKE_GATE_CPUS: "14",
    EDITH_MAKE_GATE_LOAD: "1",
    EDITH_MAKE_GATE_MEM_TOTAL_MB: "24576",
    EDITH_MAKE_GATE_MEM_AVAILABLE_MB: "16384",
    EDITH_MAKE_GATE_PRESSURE: "normal",
    EDITH_MAKE_GATE_INTERVAL: "1",
    EDITH_MAKE_GATE_TIMEOUT: "20",
    EDITH_MAKE_GATE_RAMP: "60",
    ...overrides,
  };
  delete env.EDITH_MAKE_GATE;
  return env;
}

test("light targets skip the budget", () => {
  const decision = decide(["ci-comments"], loaded, [seated(0), seated(1), seated(2)]);
  expect(decision.action).toBe("skip");
  expect(decision.need_threads).toBeNull();
});

test("a quiet machine fits three app builds and waits on the fourth", () => {
  expect(decide(["build"], healthy, []).action).toBe("run");
  const third = decide(["build"], healthy, [seated(0), seated(1)]);
  expect(third.action).toBe("run");
  expect(third.threads_left).toBeCloseTo(5, 1);
  expect(third.mem_left_mb).toBeCloseTo(4505.6, 0);
  const fourth = decide(["build"], healthy, [seated(0), seated(1), seated(2)]);
  expect(fourth.action).toBe("wait");
  expect(fourth.lines.join("\n")).toContain("waiting to start `make build`");
  expect(fourth.lines.join("\n")).toContain("pid 4100");
  expect(fourth.lines.join("\n")).toContain(
    "plus the reserved cpu and memory it has not consumed yet",
  );
});

test("a loaded machine keeps a second app build waiting", () => {
  expect(decide(["build"], loaded, []).action).toBe("run");
  const second = decide(["build"], loaded, [seated(0)]);
  expect(second.action).toBe("wait");
  expect(second.lines.join("\n")).toContain("load 6.3");
});

test("live usage is not subtracted twice after startup", () => {
  const host = {
    cpus: 8,
    load: 4,
    mem_total_mb: 16384,
    mem_available_mb: 10240,
    pressure: "normal",
  };
  const running = seated(0, {
    measured_threads: 4,
    measured_rss_mb: 4096,
  });
  const decision = decide(["build"], host, [running], 30, 20);
  expect(decision.action).toBe("run");
  expect(decision.threads_left).toBeCloseTo(4, 1);
});

test("live cpu counts even when load average has not caught up", () => {
  const host = {
    cpus: 8,
    load: 0.5,
    mem_total_mb: 16384,
    mem_available_mb: 10240,
    pressure: "normal",
  };
  const hot = seated(0, { measured_threads: 6, measured_rss_mb: 1024 });
  expect(decide(["build"], host, [hot], 30, 20).action).toBe("wait");
});

test("a build that has not allocated yet still holds its reservation", () => {
  const host = {
    cpus: 8,
    load: 0.2,
    mem_total_mb: 16384,
    mem_available_mb: 10240,
    pressure: "normal",
  };
  const decision = decide(["build"], host, [seated(0)], 1, 20);
  expect(decision.action).toBe("wait");
});

test("memory pressure shrinks the budget", () => {
  const warned = { ...healthy, pressure: "warn" };
  expect(decide(["build"], warned, [seated(0)]).action).toBe("run");
  expect(decide(["build"], warned, [seated(0), seated(1)]).action).toBe("wait");
});

test("the only gated make still starts when the host is already tight", () => {
  const tight = {
    cpus: 4,
    load: 3.6,
    mem_total_mb: 8192,
    mem_available_mb: 2800,
    pressure: "critical",
  };
  const decision = decide(["build"], tight, []);
  expect(decision.action).toBe("run");
  expect(decision.lines.join("\n")).toContain("no other gated make is running");
  expect(decision.lines.join("\n")).toContain("already tight");
});

test("mixed goals take the heavier target", () => {
  const heavy = decide(["ci-comments", "build"], healthy, [seated(0), seated(1), seated(2)]);
  expect(heavy.action).toBe("wait");
  expect(heavy.profile).toBe("xcode build");
  const tests = decide(["ci-swift-test"], healthy, []);
  expect(tests.need_threads).toBe(2.5);
  expect(tests.profile).toBe("swift test");
});

test("five concurrent app builds stay inside the live budget", async () => {
  const root = tempDir();
  const env = gateEnv(root);
  const runs = Array.from({ length: 5 }, (_, index) => {
    const trace = join(root, `trace-${index}`);
    const child = Bun.spawn(
      [
        "python3",
        "-B",
        script,
        "exec",
        "--goals",
        "build",
        "--",
        "python3",
        "-B",
        "-c",
        "import pathlib,sys,time; p=pathlib.Path(sys.argv[1]); p.write_text('start %s\\n' % time.time()); time.sleep(float(sys.argv[2])); p.write_text(p.read_text() + 'end %s\\n' % time.time())",
        trace,
        "3",
      ],
      { cwd: process.cwd(), env, stdout: "pipe", stderr: "pipe" },
    );
    children.push(child);
    return { child, trace };
  });
  const finished = await Promise.all(
    runs.map(async ({ child, trace }) => {
      const stderrPromise = new Response(child.stderr).text();
      const code = await child.exited;
      return { code, stderr: await stderrPromise, trace };
    }),
  );
  const stderr = finished.map((item) => item.stderr).join("\n");
  expect(finished.every((item) => item.code === 0), stderr).toBe(true);
  const events = [];
  for (const item of finished) {
    const lines = readFileSync(item.trace, "utf8").trim().split("\n");
    events.push({ t: Number(lines[0].split(" ")[1]), d: 1 });
    events.push({ t: Number(lines[1].split(" ")[1]), d: -1 });
  }
  events.sort((left, right) => left.t - right.t || left.d - right.d);
  let current = 0;
  let peak = 0;
  for (const event of events) {
    current += event.d;
    peak = Math.max(peak, current);
  }
  expect(peak, stderr).toBeGreaterThanOrEqual(2);
  expect(peak, stderr).toBeLessThanOrEqual(3);
  expect(stderr).toContain("waiting to start `make build`");
  expect(stderr).toContain("reason:");
  expect(stderr).toContain("cpu threads");
  expect(stderr).toContain("still waiting");
  expect(stderr).toContain("slot table");
  expect(stderr).toContain("checking every 1s, giving up after 20s");
  expect(readdirSync(root).filter((name) => name.endsWith(".json"))).toEqual([]);
}, 25000);

test("a stale slot is dropped and a full budget gives up", async () => {
  const root = tempDir();
  writeFileSync(
    join(root, "99999999.json"),
    JSON.stringify({
      pid: 99999999,
      label: "make build",
      threads: 4,
      mem_mb: 4096,
      profile: "xcode build",
      cwd: "/tmp/edith-stale",
      started: Date.now() / 1000,
    }),
  );
  writeFileSync(join(root, "broken.json"), "{");
  const fresh = Bun.spawn(
    [
      "python3",
      "-B",
      script,
      "exec",
      "--goals",
      "build",
      "--",
      "python3",
      "-B",
      "-c",
      "print('ran')",
    ],
    { env: gateEnv(root), stdout: "pipe", stderr: "pipe" },
  );
  children.push(fresh);
  expect(await fresh.exited).toBe(0);
  expect(await new Response(fresh.stdout).text()).toContain("ran");
  const names = readdirSync(root);
  expect(names).not.toContain("99999999.json");
  expect(names).not.toContain("broken.json");

  const holder = Bun.spawn(
    [
      "python3",
      "-B",
      script,
      "exec",
      "--goals",
      "build",
      "--",
      "python3",
      "-B",
      "-c",
      "import time; time.sleep(8)",
    ],
    {
      env: gateEnv(root, {
        EDITH_MAKE_GATE_LOAD: "6.3",
        EDITH_MAKE_GATE_MEM_AVAILABLE_MB: "9940",
        EDITH_MAKE_GATE_TIMEOUT: "8",
      }),
      stdout: "pipe",
      stderr: "pipe",
    },
  );
  children.push(holder);
  await new Promise((resolvePromise) => setTimeout(resolvePromise, 1000));
  const waiter = Bun.spawn(
    [
      "python3",
      "-B",
      script,
      "exec",
      "--goals",
      "ci-swift",
      "--",
      "python3",
      "-B",
      "-c",
      "print('should-not-run')",
    ],
    {
      env: gateEnv(root, {
        EDITH_MAKE_GATE_LOAD: "6.3",
        EDITH_MAKE_GATE_MEM_AVAILABLE_MB: "9940",
        EDITH_MAKE_GATE_TIMEOUT: "2",
      }),
      stdout: "pipe",
      stderr: "pipe",
    },
  );
  children.push(waiter);
  expect(await waiter.exited).toBe(1);
  const stderr = await new Response(waiter.stderr).text();
  expect(stderr).toContain("stopped waiting after 2s and did not start `make ci-swift`");
  expect(stderr).toContain("reason:");
  expect(await new Response(waiter.stdout).text()).not.toContain("should-not-run");
  expect(await holder.exited).toBe(0);
}, 20000);

test("make runs light targets through the gate without waiting", async () => {
  const env = { ...process.env };
  delete env.EDITH_MAKE_GATE;
  const printed = Bun.spawnSync(["make", "-n", "ci-community"], {
    env,
    stdout: "pipe",
    stderr: "pipe",
  });
  expect(printed.exitCode, printed.stderr.toString()).toBe(0);
  expect(printed.stdout.toString()).toContain("scripts/make-resource-gate.py");

  const root = tempDir();
  const ran = Bun.spawn(
    ["make", "ci-community"],
    {
      env: gateEnv(root, { EDITH_MAKE_GATE_TIMEOUT: "5" }),
      stdout: "pipe",
      stderr: "pipe",
    },
  );
  children.push(ran);
  expect(await ran.exited).toBe(0);
  const stderr = await new Response(ran.stderr).text();
  expect(stderr).not.toContain("waiting to start");
  expect(readdirSync(root).filter((name) => name.endsWith(".json"))).toEqual([]);
}, 20000);

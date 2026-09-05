import { afterEach, expect, test as processTest } from "bun:test";
import {
  chmodSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";

const script = resolve("scripts/run-current-release-build.sh");
const roots = [];
const processes = [];
const spawnedPids = [];
const inheritedGitVariables = [
  "GIT_ALTERNATE_OBJECT_DIRECTORIES",
  "GIT_COMMON_DIR",
  "GIT_CONFIG",
  "GIT_CONFIG_COUNT",
  "GIT_CONFIG_PARAMETERS",
  "GIT_DIR",
  "GIT_GRAFT_FILE",
  "GIT_IMPLICIT_WORK_TREE",
  "GIT_INDEX_FILE",
  "GIT_NO_REPLACE_OBJECTS",
  "GIT_OBJECT_DIRECTORY",
  "GIT_PREFIX",
  "GIT_REPLACE_REF_BASE",
  "GIT_SHALLOW_FILE",
  "GIT_WORK_TREE",
];

afterEach(async () => {
  for (const pid of spawnedPids.splice(0)) {
    Bun.spawnSync(["kill", "-KILL", String(pid)], {
      stderr: "ignore",
      stdout: "ignore",
    });
  }
  const children = processes.splice(0);
  for (const child of children) {
    if (child.exitCode === null) child.kill();
  }
  await Promise.all(
    children.map(async (child) => {
      await Promise.race([child.exited, Bun.sleep(2_000)]);
      if (child.exitCode === null) child.kill("SIGKILL");
      await Promise.race([child.exited, Bun.sleep(1_000)]);
      if (child.exitCode === null)
        throw new Error("release fixture process did not exit during cleanup");
    }),
  );
  for (const root of roots.splice(0)) {
    rmSync(root, { force: true, recursive: true });
  }
});

function test(name, body) {
  processTest(name, body, 20_000);
}

function environment(values = {}) {
  const result = { ...process.env, ...values };
  for (const variable of inheritedGitVariables) {
    delete result[variable];
  }
  return result;
}

function command(cwd, executable, args) {
  const result = Bun.spawnSync([executable, ...args], {
    cwd,
    env: environment(),
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

function configureRepository(path) {
  git(path, "config", "user.name", "Release Test");
  git(path, "config", "user.email", "release@example.com");
  git(path, "config", "commit.gpgsign", "false");
}

function createFixture() {
  const root = mkdtempSync(join(tmpdir(), "edith-current-release-build-"));
  roots.push(root);
  const remote = join(root, "remote.git");
  const seed = join(root, "seed");
  const checkout = join(root, "checkout");

  git(root, "init", "--bare", "--initial-branch=main", remote);
  git(root, "init", "--initial-branch=main", seed);
  configureRepository(seed);
  git(seed, "commit", "--allow-empty", "-m", "Initial release source");
  git(seed, "remote", "add", "origin", remote);
  git(seed, "push", "-u", "origin", "main");
  git(root, "clone", remote, checkout);
  configureRepository(checkout);

  return {
    checkout,
    expectedSha: git(checkout, "rev-parse", "HEAD"),
    remote,
    root,
  };
}

function prepareMainAdvance(fixture) {
  const mover = join(fixture.root, `mover-${Date.now()}`);
  git(fixture.root, "clone", fixture.remote, mover);
  configureRepository(mover);
  git(mover, "commit", "--allow-empty", "-m", "Advance main");
  return mover;
}

function advanceMain(fixture) {
  const mover = prepareMainAdvance(fixture);
  git(mover, "push", "origin", "main");
}

function unreliableGit(fixture, failCalls, warnCalls = [], hangCalls = []) {
  const directory = join(fixture.root, `git-shim-${Date.now()}`);
  const executable = join(directory, "git");
  const state = join(directory, "calls");
  mkdirSync(directory);
  writeFileSync(
    executable,
    `#!/usr/bin/env bash
set -euo pipefail
if [[ "\${1:-}" == "ls-remote" ]]; then
  calls=0
  [[ ! -f "$RELEASE_TEST_GIT_STATE" ]] || read -r calls < "$RELEASE_TEST_GIT_STATE"
  calls=$((calls + 1))
  printf '%s\n' "$calls" > "$RELEASE_TEST_GIT_STATE"
  case ",$RELEASE_TEST_GIT_FAIL_CALLS," in
    *,$calls,*) echo "fatal: simulated remote outage" >&2; exit 128 ;;
  esac
  case ",$RELEASE_TEST_GIT_WARN_CALLS," in
    *,$calls,*) echo "warning: simulated remote warning" >&2 ;;
  esac
  case ",$RELEASE_TEST_GIT_HANG_CALLS," in
    *,$calls,*)
      trap "" TERM
      printf '%s' "$$" > "$RELEASE_TEST_GIT_STATE.parent.$calls"
      bash -c 'trap "" TERM; printf "%s" "$$" > "$1"; while :; do sleep 1; done' \
        -- "$RELEASE_TEST_GIT_STATE.descendant.$calls" &
      wait
      ;;
  esac
  "$RELEASE_TEST_REAL_GIT" "$@"
  printf '%s\n' complete > "$RELEASE_TEST_GIT_STATE.succeeded.$calls"
  exit 0
fi
exec "$RELEASE_TEST_REAL_GIT" "$@"
`,
  );
  chmodSync(executable, 0o755);
  return {
    PATH: `${directory}:${process.env.PATH}`,
    RELEASE_TEST_GIT_FAIL_CALLS: failCalls.join(","),
    RELEASE_TEST_GIT_HANG_CALLS: hangCalls.join(","),
    RELEASE_TEST_GIT_WARN_CALLS: warnCalls.join(","),
    RELEASE_TEST_GIT_STATE: state,
    RELEASE_TEST_REAL_GIT: command(fixture.checkout, "which", ["git"]),
    state,
  };
}

function run(fixture, args, values = {}) {
  return Bun.spawn(["bash", script, ...args], {
    cwd: fixture.checkout,
    env: environment({
      BUILT_SHA: fixture.expectedSha,
      RELEASE_CHECK_INTERVAL_SECONDS: "1",
      RELEASE_REMOTE_RETRY_ATTEMPTS: "3",
      RELEASE_REMOTE_RETRY_DELAY_SECONDS: "0",
      RELEASE_REMOTE_TERMINATION_GRACE_TICKS: "2",
      RELEASE_REMOTE_TIMEOUT_SECONDS: "5",
      RELEASE_SUPERSEDED_FILE: join(fixture.root, "superseded"),
      RELEASE_TERMINATION_GRACE_TICKS: "2",
      ...values,
    }),
    stderr: "pipe",
    stdout: "pipe",
  });
}

async function waitForFile(path) {
  const deadline = performance.now() + 10_000;
  while (performance.now() < deadline) {
    if (existsSync(path) && readFileSync(path, "utf8").trim().length > 0)
      return;
    await Bun.sleep(10);
  }
  throw new Error(`timed out waiting for nonempty fixture signal ${path}`);
}

function readPid(path) {
  const pid = Number(readFileSync(path, "utf8"));
  if (!Number.isSafeInteger(pid) || pid <= 1)
    throw new Error(`invalid fixture process identity in ${path}`);
  return pid;
}

async function waitForExit(pid) {
  const deadline = performance.now() + 10_000;
  while (performance.now() < deadline) {
    const result = Bun.spawnSync(["kill", "-0", String(pid)], {
      stderr: "ignore",
      stdout: "ignore",
    });
    if (result.exitCode !== 0) {
      const index = spawnedPids.indexOf(pid);
      if (index >= 0) spawnedPids.splice(index, 1);
      return;
    }
    await Bun.sleep(10);
  }
  throw new Error(`timed out waiting for process ${pid}`);
}

test("a current release build returns the command status", async () => {
  const fixture = createFixture();
  const marker = join(fixture.root, "completed");
  const child = run(fixture, [
    "bash",
    "-c",
    'printf complete > "$1"',
    "--",
    marker,
  ]);
  processes.push(child);

  expect(await child.exited).toBe(0);
  expect(readFileSync(marker, "utf8")).toBe("complete");
});

test("a current release build keeps command failures fatal", async () => {
  const fixture = createFixture();
  const child = run(fixture, ["bash", "-c", "exit 23"]);
  processes.push(child);

  expect(await child.exited).toBe(23);
});

test("a transient remote outage recovers before the build starts", async () => {
  const fixture = createFixture();
  const marker = join(fixture.root, "completed");
  const shim = unreliableGit(fixture, [1, 2], [3, 4]);
  const child = run(
    fixture,
    ["bash", "-c", 'printf complete > "$1"', "--", marker],
    shim,
  );
  processes.push(child);

  expect(await child.exited).toBe(0);
  expect(readFileSync(marker, "utf8")).toBe("complete");
  expect(Number(readFileSync(shim.state, "utf8"))).toBeGreaterThanOrEqual(4);
  expect(await new Response(child.stderr).text()).toContain(
    "release remote check unavailable: retrying (1/3)",
  );
});

test("an unavailable remote exhausts retries without starting a build", async () => {
  const fixture = createFixture();
  const marker = join(fixture.root, "unexpected");
  const superseded = join(fixture.root, "superseded");
  const shim = unreliableGit(fixture, [1, 2, 3]);
  const child = run(
    fixture,
    ["bash", "-c", 'printf started > "$1"', "--", marker],
    shim,
  );
  processes.push(child);

  expect(await child.exited).toBe(1);
  expect(existsSync(marker)).toBe(false);
  expect(existsSync(superseded)).toBe(false);
  expect(Number(readFileSync(shim.state, "utf8"))).toBe(3);
  expect(await new Response(child.stderr).text()).toContain(
    "release build blocked: could not resolve refs/heads/main",
  );
});

test("a stalled remote attempt is killed with its descendants and retried", async () => {
  const fixture = createFixture();
  const marker = join(fixture.root, "completed");
  const shim = unreliableGit(fixture, [], [], [1]);
  const child = run(
    fixture,
    ["bash", "-c", 'printf complete > "$1"', "--", marker],
    { ...shim, RELEASE_REMOTE_TIMEOUT_SECONDS: "1" },
  );
  processes.push(child);

  expect(await child.exited).toBe(0);
  expect(readFileSync(marker, "utf8")).toBe("complete");
  const parentPid = readPid(`${shim.state}.parent.1`);
  const descendantPid = readPid(`${shim.state}.descendant.1`);
  spawnedPids.push(parentPid, descendantPid);
  await waitForExit(parentPid);
  await waitForExit(descendantPid);
  expect(await new Response(child.stderr).text()).toContain(
    "release remote check timed out after 1s",
  );
});

test("a current release build does not reinterpret child status 75", async () => {
  const fixture = createFixture();
  const superseded = join(fixture.root, "superseded");
  const child = run(fixture, ["bash", "-c", "exit 75"]);
  processes.push(child);

  expect(await child.exited).toBe(75);
  expect(existsSync(superseded)).toBe(false);
});

test("a manual rebuild returns direct child status 75", async () => {
  const fixture = createFixture();
  const superseded = join(fixture.root, "superseded");
  const child = run(fixture, ["bash", "-c", "exit 75"], {
    REBUILD: "v0.0.126",
  });
  processes.push(child);

  expect(await child.exited).toBe(75);
  expect(existsSync(superseded)).toBe(false);
});

test("a stale release never starts its build", async () => {
  const fixture = createFixture();
  const marker = join(fixture.root, "unexpected");
  advanceMain(fixture);
  const child = run(fixture, [
    "bash",
    "-c",
    'printf started > "$1"',
    "--",
    marker,
  ]);
  processes.push(child);

  expect(await child.exited).toBe(75);
  expect(existsSync(marker)).toBe(false);
  expect(existsSync(join(fixture.root, "superseded"))).toBe(true);
  expect(await new Response(child.stderr).text()).toContain(
    "release superseded: main moved during the release build",
  );
});

test("a main advance stops an active release build", async () => {
  const fixture = createFixture();
  const started = join(fixture.root, "started");
  const child = run(fixture, [
    "bash",
    "-c",
    'printf started > "$1"; while :; do sleep 1; done',
    "--",
    started,
  ]);
  processes.push(child);
  await waitForFile(started);
  advanceMain(fixture);

  expect(await child.exited).toBe(75);
  expect(existsSync(join(fixture.root, "superseded"))).toBe(true);
  expect(await new Response(child.stderr).text()).toContain(
    "release superseded: main moved during the release build",
  );
});

test("a transient monitoring outage does not interrupt a current build", async () => {
  const fixture = createFixture();
  const started = join(fixture.root, "started");
  const completed = join(fixture.root, "completed");
  const release = join(fixture.root, "release-build");
  const shim = unreliableGit(fixture, [2, 3]);
  const child = run(
    fixture,
    [
      "bash",
      "-c",
      'printf started > "$1"; for ((attempt = 0; attempt < 1000; attempt += 1)); do [[ ! -f "$3" ]] || break; sleep 0.01; done; [[ -f "$3" ]] || exit 97; printf complete > "$2"',
      "--",
      started,
      completed,
      release,
    ],
    shim,
  );
  processes.push(child);

  await waitForFile(started);
  await waitForFile(`${shim.state}.succeeded.4`);
  expect(child.exitCode).toBeNull();
  expect(existsSync(completed)).toBe(false);
  writeFileSync(release, "complete");
  expect(await child.exited).toBe(0);
  expect(readFileSync(completed, "utf8")).toBe("complete");
  expect(Number(readFileSync(shim.state, "utf8"))).toBeGreaterThanOrEqual(5);
  expect(await new Response(child.stderr).text()).toContain(
    "release remote check unavailable: retrying (2/3)",
  );
});

test("a main advance found after monitoring retries stops the build", async () => {
  const fixture = createFixture();
  const started = join(fixture.root, "started");
  const shim = unreliableGit(fixture, [2, 3]);
  const child = run(
    fixture,
    [
      "bash",
      "-c",
      'printf started > "$1"; while :; do sleep 1; done',
      "--",
      started,
    ],
    shim,
  );
  processes.push(child);
  await waitForFile(started);
  advanceMain(fixture);

  expect(await child.exited).toBe(75);
  expect(existsSync(join(fixture.root, "superseded"))).toBe(true);
  expect(Number(readFileSync(shim.state, "utf8"))).toBe(4);
});

test("stopping a stale build terminates its parent and grandchild", async () => {
  const fixture = createFixture();
  const parentFile = join(fixture.root, "parent-pid");
  const grandchildFile = join(fixture.root, "grandchild-pid");
  const child = run(fixture, [
    "bash",
    "-c",
    'trap "" TERM; printf "%s" "$$" > "$1"; bash -c \'trap "" TERM; printf "%s" "$$" > "$1"; while :; do sleep 1; done\' -- "$2" & wait',
    "--",
    parentFile,
    grandchildFile,
  ]);
  processes.push(child);
  await waitForFile(parentFile);
  await waitForFile(grandchildFile);
  const parentPid = readPid(parentFile);
  const grandchildPid = readPid(grandchildFile);
  spawnedPids.push(parentPid, grandchildPid);
  advanceMain(fixture);

  expect(await child.exited).toBe(75);
  await waitForExit(parentPid);
  await waitForExit(grandchildPid);
});

test("a successful leader cannot leave its process group running", async () => {
  const fixture = createFixture();
  const descendantFile = join(fixture.root, "descendant-pid");
  const child = run(fixture, [
    "bash",
    "-c",
    'bash -c \'trap "" TERM; printf "%s" "$$" > "$1"; while :; do sleep 1; done\' -- "$1" & while [ ! -s "$1" ]; do sleep 0.01; done',
    "--",
    descendantFile,
  ]);
  processes.push(child);

  expect(await child.exited).toBe(0);
  const descendantPid = readPid(descendantFile);
  spawnedPids.push(descendantPid);
  await waitForExit(descendantPid);
});

test("a final main advance after child exit supersedes the build", async () => {
  const fixture = createFixture();
  const mover = prepareMainAdvance(fixture);
  const child = run(fixture, ["git", "-C", mover, "push", "origin", "main"], {
    RELEASE_CHECK_INTERVAL_SECONDS: "60",
  });
  processes.push(child);

  expect(await child.exited).toBe(75);
  expect(existsSync(join(fixture.root, "superseded"))).toBe(true);
});

test("a final remote outage fails closed after a successful build", async () => {
  const fixture = createFixture();
  const artifact = join(fixture.root, "artifact");
  const shim = unreliableGit(fixture, [2, 3, 4]);
  const child = run(
    fixture,
    ["bash", "-c", 'printf built > "$1"', "--", artifact],
    shim,
  );
  processes.push(child);

  expect(await child.exited).toBe(1);
  expect(readFileSync(artifact, "utf8")).toBe("built");
  expect(existsSync(join(fixture.root, "superseded"))).toBe(false);
  expect(Number(readFileSync(shim.state, "utf8"))).toBe(4);
  expect(await new Response(child.stderr).text()).toContain(
    "release build blocked: could not resolve refs/heads/main",
  );
});

test("a stalled final remote check fails closed without live transport processes", async () => {
  const fixture = createFixture();
  const artifact = join(fixture.root, "artifact");
  const shim = unreliableGit(fixture, [], [], [2, 3]);
  const child = run(
    fixture,
    ["bash", "-c", 'printf built > "$1"', "--", artifact],
    {
      ...shim,
      RELEASE_REMOTE_RETRY_ATTEMPTS: "2",
      RELEASE_REMOTE_TIMEOUT_SECONDS: "1",
    },
  );
  processes.push(child);

  expect(await child.exited).toBe(1);
  expect(readFileSync(artifact, "utf8")).toBe("built");
  for (const call of [2, 3]) {
    const parentPid = readPid(`${shim.state}.parent.${call}`);
    const descendantPid = readPid(`${shim.state}.descendant.${call}`);
    spawnedPids.push(parentPid, descendantPid);
    await waitForExit(parentPid);
    await waitForExit(descendantPid);
  }
  expect(existsSync(join(fixture.root, "superseded"))).toBe(false);
  expect(await new Response(child.stderr).text()).toContain(
    "release build blocked: could not resolve refs/heads/main",
  );
});

test("a final retry still detects a superseded build", async () => {
  const fixture = createFixture();
  const mover = prepareMainAdvance(fixture);
  const shim = unreliableGit(fixture, [2, 3]);
  const child = run(fixture, ["git", "-C", mover, "push", "origin", "main"], {
    ...shim,
    RELEASE_CHECK_INTERVAL_SECONDS: "60",
  });
  processes.push(child);

  expect(await child.exited).toBe(75);
  expect(existsSync(join(fixture.root, "superseded"))).toBe(true);
  expect(Number(readFileSync(shim.state, "utf8"))).toBe(4);
});

test("invalid monitoring configuration stays fatal", async () => {
  const fixture = createFixture();
  const child = run(fixture, ["true"], {
    RELEASE_CHECK_INTERVAL_SECONDS: "0",
  });
  processes.push(child);

  expect(await child.exited).toBe(1);
  expect(await new Response(child.stderr).text()).toContain(
    "release build blocked: check interval must be a positive integer",
  );
});

test("invalid remote retry configuration stays fatal", async () => {
  const fixture = createFixture();
  const attempts = run(fixture, ["true"], {
    RELEASE_REMOTE_RETRY_ATTEMPTS: "0",
  });
  const delay = run(fixture, ["true"], {
    RELEASE_REMOTE_RETRY_DELAY_SECONDS: "later",
  });
  const timeout = run(fixture, ["true"], {
    RELEASE_REMOTE_TIMEOUT_SECONDS: "0",
  });
  processes.push(attempts, delay, timeout);

  expect(await attempts.exited).toBe(1);
  expect(await new Response(attempts.stderr).text()).toContain(
    "release build blocked: remote retry attempts must be a positive integer",
  );
  expect(await delay.exited).toBe(1);
  expect(await new Response(delay.stderr).text()).toContain(
    "release build blocked: remote retry delay must be a non-negative integer",
  );
  expect(await timeout.exited).toBe(1);
  expect(await new Response(timeout.stderr).text()).toContain(
    "release build blocked: remote timeout must be a positive integer",
  );
});

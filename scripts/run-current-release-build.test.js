import { afterEach, expect, test } from "bun:test";
import {
  existsSync,
  mkdtempSync,
  readFileSync,
  rmSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";

const script = resolve("scripts/run-current-release-build.sh");
const roots = [];
const processes = [];
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

afterEach(() => {
  for (const process of processes.splice(0)) {
    process.kill();
  }
  for (const root of roots.splice(0)) {
    rmSync(root, { force: true, recursive: true });
  }
});

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

function advanceMain(fixture) {
  const mover = join(fixture.root, `mover-${Date.now()}`);
  git(fixture.root, "clone", fixture.remote, mover);
  configureRepository(mover);
  git(mover, "commit", "--allow-empty", "-m", "Advance main");
  git(mover, "push", "origin", "main");
}

function run(fixture, args, values = {}) {
  return Bun.spawn(["bash", script, ...args], {
    cwd: fixture.checkout,
    env: environment({
      BUILT_SHA: fixture.expectedSha,
      RELEASE_CHECK_INTERVAL_SECONDS: "1",
      ...values,
    }),
    stderr: "pipe",
    stdout: "pipe",
  });
}

async function waitForFile(path) {
  for (let attempt = 0; attempt < 100; attempt += 1) {
    if (existsSync(path)) return;
    await Bun.sleep(10);
  }
  throw new Error(`timed out waiting for ${path}`);
}

test("a current release build returns the command status", async () => {
  const fixture = createFixture();
  const marker = join(fixture.root, "completed");
  const child = run(fixture, ["bash", "-c", 'printf complete > "$1"', "--", marker]);
  processes.push(child);

  expect(await child.exited).toBe(0);
  expect(readFileSync(marker, "utf8")).toBe("complete");
});

test("a stale release never starts its build", async () => {
  const fixture = createFixture();
  const marker = join(fixture.root, "unexpected");
  advanceMain(fixture);
  const child = run(fixture, ["bash", "-c", 'printf started > "$1"', "--", marker]);
  processes.push(child);

  expect(await child.exited).toBe(75);
  expect(existsSync(marker)).toBe(false);
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
  expect(await new Response(child.stderr).text()).toContain(
    "release superseded: main moved during the release build",
  );
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

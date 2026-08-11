import { afterEach, expect, test } from "bun:test";
import {
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";

const script = resolve("scripts/publish-release-state.sh");
const roots = [];
const firstChecksum = "b".repeat(64);
const secondChecksum = "c".repeat(64);
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
  for (const root of roots.splice(0)) {
    rmSync(root, { force: true, recursive: true });
  }
});

function command(cwd, executable, args, env = {}) {
  const environment = { ...process.env, ...env };
  for (const variable of inheritedGitVariables) {
    delete environment[variable];
  }
  const result = Bun.spawnSync([executable, ...args], {
    cwd,
    env: environment,
    stderr: "pipe",
    stdout: "pipe",
  });
  return {
    exitCode: result.exitCode,
    stderr: result.stderr.toString(),
    stdout: result.stdout.toString(),
  };
}

function git(cwd, ...args) {
  const result = command(cwd, "git", args);
  if (result.exitCode !== 0) {
    throw new Error(`${result.stdout}${result.stderr}`);
  }
  return result.stdout.trim();
}

function configureRepository(path) {
  git(path, "config", "user.name", "Release Test");
  git(path, "config", "user.email", "release@example.com");
  git(path, "config", "commit.gpgsign", "false");
  git(path, "config", "tag.gpgsign", "false");
}

function createFixture() {
  const root = mkdtempSync(join(tmpdir(), "edith-release-state-"));
  roots.push(root);
  const remote = join(root, "remote.git");
  const seed = join(root, "seed");
  const checkout = join(root, "checkout");
  const plists = join(root, "release-plists");

  git(root, "init", "--bare", "--initial-branch=main", remote);
  git(root, "init", "--initial-branch=main", seed);
  configureRepository(seed);
  mkdirSync(join(seed, "Casks"), { recursive: true });
  mkdirSync(join(seed, "Resources"), { recursive: true });
  writeFileSync(
    join(seed, "Casks/edith.rb"),
    `cask "edith" do\n  version "0.0.79"\n  sha256 "${"a".repeat(64)}"\nend\n`,
  );
  writeFileSync(join(seed, "Resources/Info.plist"), "old app plist\n");
  writeFileSync(join(seed, "Resources/HelperInfo.plist"), "old helper plist\n");
  git(seed, "add", ".");
  git(seed, "commit", "-m", "Initial release state");
  git(seed, "remote", "add", "origin", remote);
  git(seed, "push", "-u", "origin", "main");

  git(root, "clone", remote, checkout);
  configureRepository(checkout);
  mkdirSync(plists);
  writeFileSync(join(plists, "Info.plist"), "new app plist\n");
  writeFileSync(join(plists, "HelperInfo.plist"), "new helper plist\n");

  return {
    builtSha: git(checkout, "rev-parse", "HEAD"),
    checkout,
    plists,
    remote,
    root,
  };
}

function releaseEnvironment(fixture, checksum = firstChecksum) {
  return {
    BUILT_SHA: fixture.builtSha,
    RELEASE_PLISTS_DIR: fixture.plists,
    RELEASE_SHA256: checksum,
    RELEASE_TAG: "v0.0.80",
    RELEASE_VERSION: "0.0.80",
  };
}

function publish(fixture, mode, checksum = firstChecksum) {
  return command(
    fixture.checkout,
    "bash",
    [script, mode],
    releaseEnvironment(fixture, checksum),
  );
}

test("a release cut publishes one atomic commit and retries cleanly", () => {
  const fixture = createFixture();
  expect(publish(fixture, "cut").exitCode).toBe(0);

  const main = git(fixture.remote, "rev-parse", "refs/heads/main");
  const tag = git(fixture.remote, "rev-parse", "refs/tags/v0.0.80^{commit}");
  expect(tag).toBe(main);
  expect(git(fixture.remote, "show", "main:Casks/edith.rb")).toContain(
    `sha256 "${firstChecksum}"`,
  );
  expect(git(fixture.remote, "show", "main:Resources/Info.plist")).toBe(
    "new app plist",
  );
  expect(git(fixture.remote, "show", "main:Resources/HelperInfo.plist")).toBe(
    "new helper plist",
  );

  expect(publish(fixture, "cut").exitCode).toBe(0);
  expect(git(fixture.remote, "rev-parse", "refs/heads/main")).toBe(main);
});

test("a release cut aborts when main moves after the build", () => {
  const fixture = createFixture();
  const mover = join(fixture.root, "mover");
  git(fixture.root, "clone", fixture.remote, mover);
  configureRepository(mover);
  writeFileSync(join(mover, "moved.txt"), "new main\n");
  git(mover, "add", "moved.txt");
  git(mover, "commit", "-m", "Move main");
  git(mover, "push", "origin", "main");

  const result = publish(fixture, "cut");
  expect(result.exitCode).not.toBe(0);
  expect(result.stderr).toContain("main moved after the release build");
  expect(
    command(fixture.remote, "git", [
      "show-ref",
      "--verify",
      "refs/tags/v0.0.80",
    ]).exitCode,
  ).not.toBe(0);
});

test("a rebuild updates the checksum without moving the release tag", () => {
  const fixture = createFixture();
  expect(publish(fixture, "cut").exitCode).toBe(0);
  const tag = git(fixture.remote, "rev-parse", "refs/tags/v0.0.80^{commit}");

  expect(publish(fixture, "rebuild", secondChecksum).exitCode).toBe(0);
  const rebuiltMain = git(fixture.remote, "rev-parse", "refs/heads/main");
  expect(rebuiltMain).not.toBe(tag);
  expect(git(fixture.remote, "rev-parse", "refs/tags/v0.0.80^{commit}")).toBe(
    tag,
  );
  expect(git(fixture.remote, "show", "main:Casks/edith.rb")).toContain(
    `sha256 "${secondChecksum}"`,
  );
  expect(git(fixture.remote, "show", "v0.0.80:Casks/edith.rb")).toContain(
    `sha256 "${firstChecksum}"`,
  );

  expect(publish(fixture, "rebuild", secondChecksum).exitCode).toBe(0);
  expect(git(fixture.remote, "rev-parse", "refs/heads/main")).toBe(rebuiltMain);
});

test("invalid release metadata cannot mutate release files", () => {
  const fixture = createFixture();
  const originalInfo = readFileSync(
    join(fixture.checkout, "Resources/Info.plist"),
    "utf8",
  );

  const mismatchedTag = command(fixture.checkout, "bash", [script, "cut"], {
    ...releaseEnvironment(fixture),
    RELEASE_TAG: "v0.0.81",
  });
  expect(mismatchedTag.exitCode).not.toBe(0);
  expect(mismatchedTag.stderr).toContain("tag and version do not match");

  const malformedChecksum = command(fixture.checkout, "bash", [script, "cut"], {
    ...releaseEnvironment(fixture),
    RELEASE_SHA256: "not-a-checksum",
  });
  expect(malformedChecksum.exitCode).not.toBe(0);
  expect(malformedChecksum.stderr).toContain("invalid release checksum");
  expect(
    readFileSync(join(fixture.checkout, "Resources/Info.plist"), "utf8"),
  ).toBe(originalInfo);
});

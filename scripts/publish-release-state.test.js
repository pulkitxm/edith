import { afterEach, expect, test } from "bun:test";
import {
  chmodSync,
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

  git(root, "init", "--bare", "--initial-branch=main", remote);
  git(root, "init", "--initial-branch=main", seed);
  configureRepository(seed);
  mkdirSync(join(seed, "Casks"), { recursive: true });
  writeFileSync(
    join(seed, "Casks/edith.rb"),
    `cask "edith" do\n  version "0.0.79"\n  sha256 "${"a".repeat(64)}"\nend\n`,
  );
  git(seed, "add", ".");
  git(seed, "commit", "-m", "Initial release state");
  git(seed, "remote", "add", "origin", remote);
  git(seed, "push", "-u", "origin", "main");

  git(root, "clone", remote, checkout);
  configureRepository(checkout);
  return {
    builtSha: git(checkout, "rev-parse", "HEAD"),
    checkout,
    remote,
    root,
  };
}

function releaseEnvironment(fixture, checksum = firstChecksum) {
  return {
    BUILT_SHA: fixture.builtSha,
    RELEASE_BUILD: "91",
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

function installPrePushHook(fixture, commandLine) {
  const hook = join(fixture.checkout, ".git/hooks/pre-push");
  writeFileSync(hook, `#!/usr/bin/env bash\n${commandLine}\n`);
  chmodSync(hook, 0o755);
}

test("a release cut tags the approved source and retries cleanly", () => {
  const fixture = createFixture();
  expect(publish(fixture, "cut").exitCode).toBe(0);

  const main = git(fixture.remote, "rev-parse", "refs/heads/main");
  const tag = git(fixture.remote, "rev-parse", "refs/tags/v0.0.80^{commit}");
  expect(main).toBe(fixture.builtSha);
  expect(tag).toBe(fixture.builtSha);
  expect(git(fixture.remote, "show", "main:Casks/edith.rb")).toContain(
    `sha256 "${"a".repeat(64)}"`,
  );
  expect(
    readFileSync(join(fixture.checkout, "Casks/edith.rb"), "utf8"),
  ).toContain(`sha256 "${firstChecksum}"`);
  expect(
    git(
      fixture.remote,
      "for-each-ref",
      "--format=%(contents:subject)",
      "refs/tags/v0.0.80",
    ),
  ).toBe("Edith v0.0.80 build 91");

  expect(publish(fixture, "cut").exitCode).toBe(0);
  expect(git(fixture.remote, "rev-parse", "refs/heads/main")).toBe(
    fixture.builtSha,
  );
});

test("a release cut reports a superseded build without publishing", () => {
  const fixture = createFixture();
  const mover = join(fixture.root, "mover");
  git(fixture.root, "clone", fixture.remote, mover);
  configureRepository(mover);
  writeFileSync(join(mover, "moved.txt"), "new main\n");
  git(mover, "add", "moved.txt");
  git(mover, "commit", "-m", "Move main");
  git(mover, "push", "origin", "main");

  const result = publish(fixture, "cut");
  expect(result.exitCode).toBe(75);
  expect(result.stderr).toContain(
    "release superseded: main moved after the release build",
  );
  expect(git(fixture.checkout, "status", "--porcelain")).toBe("");
  expect(git(fixture.remote, "rev-parse", "refs/heads/main")).toBe(
    git(mover, "rev-parse", "HEAD"),
  );
  expect(
    command(fixture.remote, "git", [
      "show-ref",
      "--verify",
      "refs/tags/v0.0.80",
    ]).exitCode,
  ).not.toBe(0);
});

test("a release cut keeps genuine publication failures fatal", () => {
  const fixture = createFixture();
  writeFileSync(
    join(fixture.checkout, "Casks/edith.rb"),
    'cask "edith" do\nend\n',
  );
  const before = git(fixture.checkout, "status", "--porcelain");

  const result = publish(fixture, "cut");
  expect(result.exitCode).toBe(1);
  expect(result.stderr).toContain("the cask version does not match");
  expect(git(fixture.checkout, "status", "--porcelain")).toBe(before);
  expect(
    command(fixture.remote, "git", [
      "show-ref",
      "--verify",
      "refs/tags/v0.0.80",
    ]).exitCode,
  ).not.toBe(0);
});

test("a release cut stays superseded when main moves during the push", () => {
  const fixture = createFixture();
  const mover = join(fixture.root, "push-mover");
  git(fixture.root, "clone", fixture.remote, mover);
  configureRepository(mover);
  writeFileSync(join(mover, "moved-during-push.txt"), "new main\n");
  git(mover, "add", "moved-during-push.txt");
  git(mover, "commit", "-m", "Move main during push");
  installPrePushHook(
    fixture,
    `git -C ${JSON.stringify(mover)} push origin main`,
  );

  const result = publish(fixture, "cut");
  expect(result.exitCode).toBe(75);
  expect(result.stderr).toContain(
    "release superseded: main moved after the release build",
  );
  expect(git(fixture.remote, "rev-parse", "refs/heads/main")).toBe(
    git(mover, "rev-parse", "HEAD"),
  );
  expect(
    command(fixture.remote, "git", [
      "show-ref",
      "--verify",
      "refs/tags/v0.0.80",
    ]).exitCode,
  ).not.toBe(0);
});

test("a release cut keeps genuine push failures fatal", () => {
  const fixture = createFixture();
  installPrePushHook(fixture, "exit 1");

  const result = publish(fixture, "cut");
  expect(result.exitCode).toBe(1);
  expect(result.stderr).toContain("release blocked: release push failed");
  expect(git(fixture.remote, "rev-parse", "refs/heads/main")).toBe(
    fixture.builtSha,
  );
});

test("a rebuild prepares the checksum without moving protected main", () => {
  const fixture = createFixture();
  expect(publish(fixture, "cut").exitCode).toBe(0);
  const tag = git(fixture.remote, "rev-parse", "refs/tags/v0.0.80^{commit}");

  expect(publish(fixture, "rebuild", secondChecksum).exitCode).toBe(0);
  const rebuiltMain = git(fixture.remote, "rev-parse", "refs/heads/main");
  expect(rebuiltMain).toBe(tag);
  expect(git(fixture.remote, "rev-parse", "refs/tags/v0.0.80^{commit}")).toBe(
    tag,
  );
  expect(
    readFileSync(join(fixture.checkout, "Casks/edith.rb"), "utf8"),
  ).toContain(`sha256 "${secondChecksum}"`);
  expect(git(fixture.remote, "show", "v0.0.80:Casks/edith.rb")).toContain(
    `sha256 "${"a".repeat(64)}"`,
  );

  expect(publish(fixture, "rebuild", secondChecksum).exitCode).toBe(0);
  expect(git(fixture.remote, "rev-parse", "refs/heads/main")).toBe(rebuiltMain);
});

test("invalid release metadata cannot mutate release files", () => {
  const fixture = createFixture();
  const originalCask = readFileSync(
    join(fixture.checkout, "Casks/edith.rb"),
    "utf8",
  );

  const mismatchedTag = command(fixture.checkout, "bash", [script, "cut"], {
    ...releaseEnvironment(fixture),
    RELEASE_TAG: "v0.0.81",
  });
  expect(mismatchedTag.exitCode).not.toBe(0);
  expect(mismatchedTag.exitCode).not.toBe(75);
  expect(mismatchedTag.stderr).toContain("tag and version do not match");

  const malformedChecksum = command(fixture.checkout, "bash", [script, "cut"], {
    ...releaseEnvironment(fixture),
    RELEASE_SHA256: "not-a-checksum",
  });
  expect(malformedChecksum.exitCode).not.toBe(0);
  expect(malformedChecksum.exitCode).not.toBe(75);
  expect(malformedChecksum.stderr).toContain("invalid release checksum");
  expect(readFileSync(join(fixture.checkout, "Casks/edith.rb"), "utf8")).toBe(
    originalCask,
  );
});

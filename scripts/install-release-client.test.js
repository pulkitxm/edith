import { afterEach, expect, test } from "bun:test";
import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const script = join(import.meta.dir, "install-release-client.sh");
const roots = [];
const payload = "synthetic release client\n";

afterEach(() => {
  for (const root of roots.splice(0))
    rmSync(root, { recursive: true, force: true });
});

function checksum(name) {
  return `${createHash("sha256").update(payload).digest("hex")}  ${name}\n`;
}

function install(system, architecture, sums, succeeds) {
  const root = mkdtempSync(join(tmpdir(), "release-client-fixture-"));
  roots.push(root);
  const tools = join(root, "tools");
  const runner = join(root, "runner");
  const home = join(root, "home");
  const pathFile = join(root, "github-path");
  for (const path of [tools, runner, home]) mkdirSync(path, { mode: 0o700 });
  const stubs = {
    uname:
      '#!/bin/sh\ncase "$1" in -s) printf "%s\\n" "$FIXTURE_SYSTEM" ;; -m) printf "%s\\n" "$FIXTURE_ARCH" ;; *) exit 1 ;; esac\n',
    curl: '#!/bin/sh\nwhile [ "$#" -gt 0 ]; do\n  case "$1" in --output) destination="$2"; shift 2 ;; *) shift ;; esac\ndone\ncase "$destination" in */SHA256SUMS) printf "%s" "$FIXTURE_SUMS" > "$destination" ;; *) printf "%s" "$FIXTURE_PAYLOAD" > "$destination" ;; esac\n',
    rg: "#!/bin/sh\nexit 97\n",
  };
  for (const [name, source] of Object.entries(stubs))
    writeFileSync(join(tools, name), source, { mode: 0o700 });
  const result = spawnSync("/bin/bash", [script], {
    encoding: "utf8",
    timeout: 5000,
    env: {
      PATH: `${tools}:/usr/bin:/bin`,
      HOME: home,
      TMPDIR: root,
      RUNNER_TEMP: runner,
      GITHUB_PATH: pathFile,
      FIXTURE_SYSTEM: system,
      FIXTURE_ARCH: architecture,
      FIXTURE_SUMS: sums,
      FIXTURE_PAYLOAD: payload,
    },
  });
  expect(result.error).toBeUndefined();
  const installed = join(runner, "bin/pukbot");
  if (succeeds) {
    expect(result.status, result.stdout + result.stderr).toBe(0);
    expect(readFileSync(installed, "utf8")).toBe(payload);
    expect(statSync(installed).mode & 0o100).toBe(0o100);
    expect(readFileSync(pathFile, "utf8")).toBe(`${join(runner, "bin")}\n`);
  } else {
    expect(result.status).not.toBe(0);
    expect(existsSync(installed)).toBe(false);
    expect(existsSync(pathFile)).toBe(false);
  }
}

test("Linux installs only its exact checksum without optional tools", () => {
  const sums = `${"0".repeat(64)}  pukbot-macos-aarch64\n${checksum("pukbot-linux-x86_64")}${"0".repeat(64)}  pukbot-linux-x86_64-extra\n`;
  install("Linux", "x86_64", sums, true);
});

test("macOS installs only its exact checksum without optional tools", () => {
  install(
    "Darwin",
    "arm64",
    `${"0".repeat(64)}  pukbot-linux-x86_64\n${checksum("pukbot-macos-aarch64")}`,
    true,
  );
});

test("wrong selected checksum rejects before install and path registration", () => {
  install("Linux", "x86_64", `${"0".repeat(64)}  pukbot-linux-x86_64\n`, false);
});

test("missing exact platform checksum rejects before install", () => {
  install(
    "Linux",
    "x86_64",
    checksum("pukbot-macos-aarch64") + checksum("pukbot-linux-x86_64-extra"),
    false,
  );
});

test("unsupported platform rejects before install", () => {
  install("Linux", "arm64", checksum("pukbot-linux-x86_64"), false);
});

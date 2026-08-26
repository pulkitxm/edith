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

const script = resolve("scripts/resolve-release-version.sh");
const roots = [];
const plist = `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleShortVersionString</key>
  <string>0.0.164</string>
  <key>CFBundleVersion</key>
  <string>175</string>
</dict>
</plist>
`;

afterEach(() => {
  for (const root of roots.splice(0)) {
    rmSync(root, { force: true, recursive: true });
  }
});

function command(cwd, executable, args, env = {}) {
  return Bun.spawnSync([executable, ...args], {
    cwd,
    env: { ...process.env, ...env },
    stderr: "pipe",
    stdout: "pipe",
  });
}

function git(cwd, ...args) {
  const result = command(cwd, "git", args);
  if (result.exitCode !== 0) {
    throw new Error(`${result.stdout}${result.stderr}`);
  }
  return result.stdout.toString().trim();
}

function fixture() {
  const root = mkdtempSync(join(tmpdir(), "edith-release-version-"));
  roots.push(root);
  git(root, "init", "--initial-branch=main");
  git(root, "config", "user.name", "Release Test");
  git(root, "config", "user.email", "release@example.com");
  git(root, "config", "commit.gpgsign", "false");
  git(root, "config", "tag.gpgsign", "false");
  mkdirSync(join(root, "Resources"));
  writeFileSync(join(root, "Resources/Info.plist"), plist);
  git(root, "add", ".");
  git(root, "commit", "-m", "Release v0.0.164");
  git(root, "tag", "v0.0.164");
  return root;
}

function commit(root, value) {
  writeFileSync(join(root, "source.txt"), `${value}\n`);
  git(root, "add", "source.txt");
  git(root, "commit", "-m", value);
}

function resolveVersion(root, rebuild = "") {
  const output = join(root, "output");
  const result = command(root, "bash", [script], {
    GITHUB_OUTPUT: output,
    REBUILD: rebuild,
  });
  const values = {};
  if (result.exitCode === 0) {
    for (const line of readFileSync(output, "utf8").trim().split("\n")) {
      const separator = line.indexOf("=");
      values[line.slice(0, separator)] = line.slice(separator + 1);
    }
  }
  return { result, values };
}

test("the first tag-only release continues the committed version", () => {
  const root = fixture();
  commit(root, "Add a feature");

  const { result, values } = resolveVersion(root);

  expect(result.exitCode).toBe(0);
  expect(values).toEqual({
    build: "176",
    sha: git(root, "rev-parse", "HEAD"),
    tag: "v0.0.165",
    version: "0.0.165",
  });
});

test("annotated release metadata advances versions without source bumps", () => {
  const root = fixture();
  commit(root, "Release source");
  git(root, "tag", "-a", "v0.0.165", "-m", "Edith v0.0.165 build 176");
  commit(root, "Next source");

  const { result, values } = resolveVersion(root);

  expect(result.exitCode).toBe(0);
  expect(values.version).toBe("0.0.166");
  expect(values.build).toBe("177");
});

test("an annotated release can be rebuilt from its tag", () => {
  const root = fixture();
  commit(root, "Release source");
  git(root, "tag", "-a", "v0.0.165", "-m", "Edith v0.0.165 build 176");
  git(root, "switch", "--detach", "v0.0.165");

  const { result, values } = resolveVersion(root, "v0.0.165");

  expect(result.exitCode).toBe(0);
  expect(values.version).toBe("0.0.165");
  expect(values.build).toBe("176");
  expect(values.sha).toBe(git(root, "rev-parse", "v0.0.165^{commit}"));
});

test("a tag without matching build metadata is rejected", () => {
  const root = fixture();
  commit(root, "Release source");
  git(root, "tag", "v0.0.165");
  commit(root, "Next source");

  const { result } = resolveVersion(root);

  expect(result.exitCode).toBe(1);
  expect(result.stderr.toString()).toContain(
    "release blocked: v0.0.165 has no release build metadata",
  );
});

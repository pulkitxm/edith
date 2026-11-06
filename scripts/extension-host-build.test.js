import { afterEach, expect, test } from "bun:test";
import { execFileSync } from "node:child_process";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { minimumHostBuild } from "./extension-host-build.mjs";

const roots = [];

afterEach(() => {
  for (const root of roots.splice(0))
    rmSync(root, { force: true, recursive: true });
});

const plist = (version, build) => `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
\t<key>CFBundleShortVersionString</key>
\t<string>${version}</string>
\t<key>CFBundleVersion</key>
\t<string>${build}</string>
</dict>
</plist>
`;

function git(root, ...args) {
  return execFileSync("git", args, {
    cwd: root,
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
    env: {
      ...process.env,
      GIT_CONFIG_GLOBAL: "/dev/null",
      GIT_CONFIG_NOSYSTEM: "1",
    },
  }).trim();
}

function write(root, path, contents) {
  mkdirSync(dirname(join(root, path)), { recursive: true });
  writeFileSync(join(root, path), contents);
}

function commit(root, path, contents) {
  write(root, path, contents);
  git(root, "add", path);
  git(root, "commit", "-m", `change ${path}`);
}

function release(root, version, build) {
  commit(root, "Resources/Info.plist", plist(version, build));
  git(
    root,
    "tag",
    "-a",
    `v${version}`,
    "-m",
    `Edith v${version} build ${build}`,
  );
}

function repository() {
  const root = mkdtempSync(join(tmpdir(), "edith-host-build-"));
  roots.push(root);
  git(root, "init", "--initial-branch=main");
  git(root, "config", "user.name", "Release Test");
  git(root, "config", "user.email", "release@example.com");
  git(root, "config", "commit.gpgsign", "false");
  git(root, "config", "tag.gpgsign", "false");
  commit(
    root,
    "Packages/ExtensionSupport/Sources/EdithExtensionCore/Kit.swift",
    "public struct Kit {}\n",
  );
  release(root, "0.0.384", 395);
  return root;
}

test("a package built from the released kit is loadable by that release", () => {
  const root = repository();
  expect(minimumHostBuild(root)).toBe(395);
  commit(root, "Extensions/usage/Sources/Usage.swift", "let usage = 1\n");
  expect(minimumHostBuild(root)).toBe(395);
});

test("a package built against an unreleased kit needs the next host build", () => {
  const root = repository();
  commit(
    root,
    "Packages/ExtensionSupport/Sources/EdithExtensionCore/Kit.swift",
    "public struct Kit { public init() {} }\n",
  );
  expect(minimumHostBuild(root)).toBe(396);
  release(root, "0.0.385", 396);
  expect(minimumHostBuild(root)).toBe(396);
});

test("uncommitted kit edits and icon changes count as a newer kit", () => {
  const root = repository();
  write(
    root,
    "Packages/ExtensionSupport/Sources/EdithExtensionCore/Kit.swift",
    "public struct Kit { public let edited = true }\n",
  );
  expect(minimumHostBuild(root)).toBe(396);
  git(root, "checkout", "--", ".");
  commit(
    root,
    "Packages/EdithIcons/Sources/EdithIcons/Icon.swift",
    "let a = 1\n",
  );
  expect(minimumHostBuild(root)).toBe(396);
});

test("only release tags reachable from the build source are trusted", () => {
  const root = repository();
  git(root, "tag", "verification-20261010-keepAwake-v9");
  git(root, "checkout", "-b", "unmerged");
  commit(
    root,
    "Packages/ExtensionSupport/Sources/EdithExtensionCore/Kit.swift",
    "public struct Kit { public let branch = true }\n",
  );
  release(root, "0.0.390", 401);
  git(root, "checkout", "main");
  expect(minimumHostBuild(root)).toBe(395);
});

test("missing or inconsistent release metadata blocks the build", () => {
  const untagged = mkdtempSync(join(tmpdir(), "edith-host-build-"));
  roots.push(untagged);
  git(untagged, "init", "--initial-branch=main");
  git(untagged, "config", "user.name", "Release Test");
  git(untagged, "config", "user.email", "release@example.com");
  commit(untagged, "README.md", "fixture\n");
  expect(() => minimumHostBuild(untagged)).toThrow("A release tag is required");
  const mismatched = repository();
  commit(mismatched, "Resources/Info.plist", plist("0.0.999", 395));
  git(mismatched, "tag", "-a", "v0.0.400", "-m", "Edith v0.0.400 build 411");
  expect(() => minimumHostBuild(mismatched)).toThrow(
    "v0.0.400 has no release build metadata",
  );
});

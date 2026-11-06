import { execFileSync } from "node:child_process";

export const kitInputs = [
  "Packages/ExtensionSupport/Package.swift",
  "Packages/ExtensionSupport/Package.resolved",
  "Packages/ExtensionSupport/Sources",
  "Packages/EdithIcons/Package.swift",
  "Packages/EdithIcons/Sources",
  "scripts/argument-parser-source.mjs",
  "scripts/prepare-argument-parser.py",
  "scripts/build-extension-support.mjs",
];

const releaseTag = /^v([0-9]+\.[0-9]+\.[0-9]+)$/;

function plistString(plist, key) {
  return plist.match(
    new RegExp(`<key>${key}</key>\\s*<string>([^<]*)</string>`),
  )?.[1];
}

export function minimumHostBuild(root = process.cwd()) {
  const git = (...args) =>
    execFileSync("git", args, {
      cwd: root,
      encoding: "utf8",
      stdio: ["ignore", "pipe", "pipe"],
      maxBuffer: 16 * 1024 * 1024,
    });
  const tag = git("tag", "--merged", "HEAD", "--sort=-version:refname")
    .split("\n")
    .find((name) => releaseTag.test(name));
  if (!tag)
    throw new Error(
      "A release tag is required to record the minimum host build",
    );
  const plist = git("show", `${tag}:Resources/Info.plist`);
  const build = plistString(plist, "CFBundleVersion");
  if (
    plistString(plist, "CFBundleShortVersionString") !==
      tag.match(releaseTag)[1] ||
    !/^[1-9][0-9]{0,8}$/.test(build ?? "")
  )
    throw new Error(`${tag} has no release build metadata`);
  try {
    git("diff", "--quiet", tag, "--", ...kitInputs);
    return Number(build);
  } catch (error) {
    if (error.status !== 1) throw error;
    return Number(build) + 1;
  }
}

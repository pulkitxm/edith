import { createHash, generateKeyPairSync, sign } from "node:crypto";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { publishHostRelease } from "./publish-host-release.mjs";

export const assetNames = [
  "Edith.dmg",
  "appcast.xml",
  "host-release-proof.json",
  "build-metadata.json",
  "toolchain-provenance.json",
];
const hash = (bytes) => createHash("sha256").update(bytes).digest("hex");

export function fixture(existing = false) {
  const directory = mkdtempSync(join(tmpdir(), "edith-host-publication-"));
  writeFileSync(join(directory, "Edith.dmg"), Buffer.alloc(50_000, 42));
  const { publicKey, privateKey } = generateKeyPairSync("ed25519");
  const signature = sign(
    null,
    readFileSync(join(directory, "Edith.dmg")),
    privateKey,
  ).toString("base64");
  writeFileSync(
    join(directory, "appcast.xml"),
    `<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item><sparkle:version>123</sparkle:version><sparkle:shortVersionString>1.2.3</sparkle:shortVersionString><enclosure url="https://github.com/synthetic/fixture/releases/download/v1.2.3/Edith.dmg" length="50000" sparkle:edSignature="${signature}" /></item></channel></rss>`,
  );
  const sourceCommit = "a".repeat(40);
  const hostExecutableSHA256 = "b".repeat(64);
  const metadata = {
    sourceCommit,
    sourceTreeDirty: false,
    configuration: "Release",
    optimization: "Osize",
    linkTimeOptimization: "full",
    architecture: "arm64",
    hostExecutableSHA256,
  };
  const toolchain = {
    schema: 1,
    sourceCommit,
    hostExecutableSHA256,
    xcode: "Xcode 26.0\nBuild version 17A400",
    sdk: "26.0",
    builderSignature: "ad-hoc",
  };
  const proof = {
    schema: 1,
    sourceCommit,
    version: "1.2.3",
    build: "123",
    installedBytes: 1234,
    extensionPayloadBytes: 0,
    indexedExtensions: 39,
    indexSHA256: "c".repeat(64),
    hostExecutableSHA256,
    certificateCategory: "Apple Development",
    teamIdentifier: "ABCDEFGHIJ",
    verifiedDesignatedRequirement:
      'identifier "com.pulkit.edith" and anchor apple generic and certificate leaf[subject.OU] = "ABCDEFGHIJ"',
    deepStrictSignatureVerified: true,
    dmgBytes: 50000,
    dmgSHA256: hash(readFileSync(join(directory, "Edith.dmg"))),
    dmgURL:
      "https://github.com/synthetic/fixture/releases/download/v1.2.3/Edith.dmg",
    appcastSHA256: hash(readFileSync(join(directory, "appcast.xml"))),
    sparklePublicKey: publicKey
      .export({ format: "der", type: "spki" })
      .subarray(-32)
      .toString("base64"),
    sparkleEd25519Verified: true,
    notarization: "skipped",
    publicationVerified: false,
    managedViewsVerified: false,
    hardwareVerified: false,
    sourceQualification: "clean",
    workflowSourceCommit: sourceCommit,
    sourceMode: "current-workflow-source",
  };
  for (const [name, content] of [
    ["host-release-proof.json", proof],
    ["build-metadata.json", metadata],
    ["toolchain-provenance.json", toolchain],
  ])
    writeFileSync(join(directory, name), JSON.stringify(content));
  const calls = [];
  const tagReference = {
    ref: "refs/tags/v1.2.3",
    object: { type: "commit", sha: "a".repeat(40) },
  };
  const annotatedTags = new Map();
  const remoteBytes = new Map();
  const asset = (name, id, bytes = readFileSync(join(directory, name))) => {
    remoteBytes.set(id, Buffer.from(bytes));
    return { id, name, size: bytes.length, state: "uploaded" };
  };
  let release = existing
    ? {
        id: 7,
        tag_name: "v1.2.3",
        target_commitish: "a".repeat(40),
        draft: true,
        prerelease: false,
        assets: [],
      }
    : undefined;
  const execute = (command, args) => {
    calls.push([command, ...args]);
    if (command === "gh" && args[1].endsWith("git/ref/heads/main"))
      return JSON.stringify({
        ref: "refs/heads/main",
        object: { type: "commit", sha: "a".repeat(40) },
      });
    if (command === "gh" && args[1].endsWith("git/ref/tags/v1.2.3"))
      return JSON.stringify(tagReference);
    if (command === "gh" && args[1].includes("/git/tags/"))
      return JSON.stringify(annotatedTags.get(args[1].split("/").at(-1)));
    if (command === "gh" && /\/commits\/[a-f0-9]{40}$/.test(args[1]))
      return JSON.stringify({
        sha: args[1].split("/").at(-1),
        parents: [{ sha: "c".repeat(40) }],
        commit: { message: "Synthetic unrelated source change" },
      });
    if (command === "gh" && args[1].includes("/releases/tags/")) {
      if (release && !release.draft) return JSON.stringify(release);
      throw Object.assign(new Error("Missing release"), { stderr: "HTTP 404" });
    }
    if (command === "gh" && /\/releases\/[0-9]+$/.test(args[1])) {
      if (release && String(release.id) === args[1].split("/").at(-1))
        return JSON.stringify(release);
      throw Object.assign(new Error("Missing release"), { stderr: "HTTP 404" });
    }
    if (command === "gh" && args[1].includes("/releases?"))
      return JSON.stringify(release ? [release] : []);
    if (command === "gh" && args.includes("Accept: application/octet-stream")) {
      const id = Number(args.at(-1).split("/").at(-1));
      return remoteBytes.get(id);
    }
    if (command === "pukbot" && !args.includes("--dry-run")) {
      if (args[1] === "create")
        release = {
          id: 7,
          tag_name: "v1.2.3",
          target_commitish: args[args.indexOf("--target") + 1],
          draft: true,
          prerelease: args.includes("--prerelease"),
          assets: [],
        };
      if (args[1] === "upload-asset") {
        const name = args[args.indexOf("--name") + 1];
        if (release.assets.some((value) => value.name === name))
          throw new Error("HTTP 422 duplicate asset");
        release.assets.push(
          asset(name, 100 + release.assets.length, readFileSync(args[3])),
        );
      }
    }
    if (command === "pukbot" && args[1] === "edit") {
      release.draft = false;
      if (args.includes("--prerelease"))
        release.prerelease = args[args.indexOf("--prerelease") + 1] === "true";
    }
    if (command === "gh" && args[0] === "api")
      throw new Error("Unexpected synthetic API request");
    return "{}";
  };
  return {
    directory,
    proof,
    metadata,
    toolchain,
    calls,
    asset,
    remoteBytes,
    tagReference,
    annotatedTags,
    execute,
    matchesAsset: async ({ asset, file }) =>
      remoteBytes.get(asset.id).equals(readFileSync(file)),
    get release() {
      return release;
    },
    clean() {
      rmSync(directory, { force: true, recursive: true });
    },
  };
}
export function publish(value, options = {}) {
  if (options.rebuild) {
    value.proof.sourceMode = "tag-rebuild";
    writeFileSync(
      join(value.directory, "host-release-proof.json"),
      JSON.stringify(value.proof),
    );
  }
  return publishHostRelease({
    directory: value.directory,
    repository: "synthetic/fixture",
    tag: "v1.2.3",
    target: "a".repeat(40),
    execute: value.execute,
    matchesAsset: value.matchesAsset,
    ...options,
  });
}

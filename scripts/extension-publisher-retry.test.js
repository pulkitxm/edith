import { expect, test } from "bun:test";
import { spawnSync } from "node:child_process";
import { createHash, generateKeyPairSync } from "node:crypto";
import {
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { extensionChecksum } from "./extension-publish.mjs";
import { extensionReleaseTag } from "./extension-release-plan.mjs";

const repository = "pulkitxm/edith";
const target = "a".repeat(40);
const catalogTag = "extension-catalog-v1";
const entry = {
  id: "calendar",
  version: "1.0.0",
  fingerprint: "b".repeat(64),
};
entry.tag = extensionReleaseTag(entry);

const client = `#!/usr/bin/env node
const fs = require("node:fs");
const crypto = require("node:crypto");
const path = require("node:path");
const args = process.argv.slice(2);
const command = path.basename(process.argv[1]);
const stateFile = process.env.FIXTURE_STATE;
const state = JSON.parse(fs.readFileSync(stateFile));
const save = () => fs.writeFileSync(stateFile, JSON.stringify(state));
const output = value => process.stdout.write(JSON.stringify(value));
const option = name => args[args.indexOf(name) + 1];
if (command === "swift") {
  if (args[1] === "check-key") process.exit(0);
  if (args[1] === "sign") {
    const payload = fs.readFileSync(args[2]);
    const signature = crypto.sign(null, payload, process.env.FIXTURE_PRIVATE_KEY);
    fs.writeFileSync(args[3], JSON.stringify({ payload: payload.toString("base64"), signature: signature.toString("base64") }));
  } else if (args[1] === "verify") {
    const envelope = JSON.parse(fs.readFileSync(args[2]));
    fs.writeFileSync(args[3], Buffer.from(envelope.payload, "base64"));
  } else process.exit(2);
} else if (command === "gh") {
  if (args[0] !== "api") process.exit(2);
  const route = args.at(-1);
  if (route.endsWith("git/ref/heads/main")) output({ object: { sha: state.target } });
  else if (route.includes("releases/assets/")) {
    const id = Number(route.split("/").at(-1));
    const asset = state.releases.flatMap(item => item.assets).find(item => item.id === id);
    if (!asset) process.exit(2);
    process.stdout.write(Buffer.from(state.bytes[id], "base64"));
  } else if (route.includes("releases/tags/")) {
    const tag = decodeURIComponent(route.split("/").at(-1));
    const item = state.releases.find(item => item.tag_name === tag && !item.draft);
    if (!item) { process.stderr.write("gh: Not Found (HTTP 404)"); process.exit(1); }
    output(item);
  } else if (route.includes("releases?")) output(state.releases);
  else process.exit(2);
} else if (command === "pukbot") {
  if (args[0] !== "release") process.exit(2);
  if (args.includes("--dry-run")) { output({ ok: true }); process.exit(0); }
  if (args[1] === "create") {
    if (state.releases.some(item => item.tag_name === args[4])) process.exit(2);
    state.releases.push({ id: state.next++, tag_name: args[4], draft: true, body: option("--body"), assets: [] });
  } else if (args[1] === "upload-asset") {
    const item = state.releases.find(item => item.id === Number(args[2]));
    const name = option("--name");
    if (!item || item.assets.some(asset => asset.name === name)) {
      state.duplicateUploads++; save(); process.exit(2);
    }
    const data = fs.readFileSync(args[3]);
    const asset = { id: state.next++, name, size: data.length, digest: "sha256:" + crypto.createHash("sha256").update(data).digest("hex") };
    item.assets.push(asset); state.bytes[asset.id] = data.toString("base64");
    state.uploads.push(name); save();
    if (!state.interrupted && (state.interrupt === name || (state.interrupt === "catalog" && name.startsWith("catalog-")))) {
      state.interrupted = true; save(); process.stderr.write("synthetic upload response lost"); process.exit(1);
    }
  } else if (args[1] === "edit") {
    const item = state.releases.find(item => item.id === Number(args[4]));
    if (!item) process.exit(2);
    if (args.includes("--draft")) item.draft = option("--draft") === "true";
    if (args.includes("--body")) { item.body = option("--body"); state.pointerEdits++; }
  } else process.exit(2);
  save(); output({ ok: true });
} else process.exit(2);
`;

function publisherFixture(interrupt) {
  const directory = mkdtempSync(join(tmpdir(), "extension-publisher-retry-"));
  const binary = join(directory, "bin");
  mkdirSync(binary, { mode: 0o700 });
  const stateFile = join(directory, "state.json");
  const state = {
    target,
    releases: [],
    bytes: {},
    next: 1,
    uploads: [],
    duplicateUploads: 0,
    pointerEdits: 0,
    interrupt,
    interrupted: false,
  };
  writeFileSync(stateFile, JSON.stringify(state));
  for (const name of ["gh", "pukbot", "swift"])
    writeFileSync(join(binary, name), client, { mode: 0o700 });
  const { privateKey, publicKey } = generateKeyPairSync("ed25519");
  const rawKey = Buffer.from(
    publicKey.export({ format: "jwk" }).x,
    "base64url",
  ).toString("base64");
  const original = Buffer.from("owned immutable signed archive fixture");
  const record = (bytes) => ({
    id: entry.id,
    version: entry.version,
    hostABI: "edith-host-2",
    architecture: "arm64",
    sha256: createHash("sha256").update(bytes).digest("hex"),
    sourceFingerprint: entry.fingerprint,
    minimumSystemVersion: "14.0.0",
    downloadBytes: bytes.length,
    installedBytes: 100,
    dependencies: [],
    downloadURL: `https://github.com/${repository}/releases/download/${encodeURIComponent(entry.tag)}/calendar.zip`,
  });
  const build = (bytes) => {
    writeFileSync(join(directory, "calendar.zip"), bytes);
    writeFileSync(
      join(directory, "calendar.json"),
      JSON.stringify(record(bytes)),
    );
    writeFileSync(
      join(directory, "calendar.zip.sha256"),
      extensionChecksum(record(bytes)),
    );
  };
  build(original);
  writeFileSync(
    join(directory, "previous.json"),
    JSON.stringify({ schemaVersion: 1, revision: 0, packages: [] }),
  );
  writeFileSync(
    join(directory, "plan.json"),
    JSON.stringify({ include: [entry] }),
  );
  const runner = join(directory, "publisher.mjs");
  writeFileSync(
    runner,
    `
import { readFileSync, writeFileSync } from "node:fs";
import { sign } from "node:crypto";
import { join } from "node:path";
import { publishExtensions } from ${JSON.stringify(resolve("scripts/extension-publish.mjs"))};
const directory = process.env.EXTENSION_OUTPUT;
const result = await publishExtensions({
  directory,
  repository: process.env.GITHUB_REPOSITORY,
  target: process.env.GITHUB_SHA,
  ref: process.env.GITHUB_REF,
  catalogTag: process.env.EXTENSION_CATALOG_TAG,
  publicKey: process.env.EXTENSION_CATALOG_PUBLIC_KEY,
  publishEvidence: async () => {
    const packageRecord = JSON.parse(readFileSync(join(directory, "calendar.json")));
    const sourceCommit = process.env.GITHUB_SHA;
    const payload = Buffer.from(JSON.stringify({
      schema: 1, kind: "extension-native-lineage", repository: process.env.GITHUB_REPOSITORY,
      package: packageRecord, sourceCommit, runID: 101, runAttempt: 1,
      evidenceTag: "extension-evidence/" + sourceCommit + "/101-1",
      evidenceSHA256: "c".repeat(64), evidenceBytes: 200,
    }));
    writeFileSync(join(directory, "calendar.native-evidence.json"), JSON.stringify({
      payload: payload.toString("base64"),
      signature: sign(null, payload, process.env.FIXTURE_PRIVATE_KEY).toString("base64"),
    }));
    return { tag: "synthetic", originalArchiveBytes: 0, totalEvidenceBytes: 0 };
  },
  publishComposition: async ({ nativeEvidence }) => nativeEvidence,
  verifyOriginal: async ({ origin }) => ({ payload: {
    sourceCommit: origin.sourceCommit,
    plannedIDs: [origin.package.id],
    fingerprints: { [origin.package.id]: origin.package.sourceFingerprint },
  } }),
});
process.stdout.write(JSON.stringify(result));
`,
  );
  const environment = {
    PATH: `${binary}:${process.env.PATH}`,
    HOME: directory,
    CFFIXED_USER_HOME: directory,
    TMPDIR: directory,
    FIXTURE_STATE: stateFile,
    FIXTURE_PRIVATE_KEY: privateKey.export({ format: "pem", type: "pkcs8" }),
    GITHUB_REPOSITORY: repository,
    GITHUB_SHA: target,
    GITHUB_REF: "refs/heads/main",
    EXTENSION_CATALOG_TAG: catalogTag,
    EXTENSION_CATALOG_PUBLIC_KEY: rawKey,
    EXTENSION_CATALOG_PRIVATE_KEY: "synthetic",
    EXTENSION_OUTPUT: directory,
  };
  return {
    directory,
    original,
    record,
    build,
    state: () => JSON.parse(readFileSync(stateFile)),
    updateState: (change) => {
      const current = JSON.parse(readFileSync(stateFile));
      change(current);
      writeFileSync(stateFile, JSON.stringify(current));
    },
    run: () =>
      spawnSync(process.execPath, [runner], {
        env: environment,
        encoding: "utf8",
        timeout: 15_000,
      }),
    close: () => rmSync(directory, { recursive: true, force: true }),
  };
}

test("an archive-only retry recovers original immutable bytes and signed lineage after a different rebuild", () => {
  const fixture = publisherFixture("calendar.zip");
  try {
    expect(fixture.run().status).not.toBe(0);
    const partial = fixture.state();
    const originalAssets = structuredClone(partial.bytes);
    fixture.build(Buffer.from("byte-different rebuilt signed archive"));
    const resumed = fixture.run();
    expect(resumed.status).toBe(0);
    expect(readFileSync(join(fixture.directory, "calendar.zip"))).toEqual(
      fixture.original,
    );
    const complete = fixture.state();
    expect(complete.duplicateUploads).toBe(0);
    expect(
      complete.uploads.filter((name) => name === "calendar.zip"),
    ).toHaveLength(1);
    expect(
      complete.uploads.filter(
        (name) => name === "calendar.native-evidence.json",
      ),
    ).toHaveLength(1);
    for (const [id, bytes] of Object.entries(originalAssets))
      expect(complete.bytes[id]).toBe(bytes);
  } finally {
    fixture.close();
  }
}, 30_000);

for (const interruption of [
  "calendar.json",
  "calendar.zip.sha256",
  "catalog",
]) {
  test(`a rebuilt retry restores verified original artifacts after ${interruption}`, () => {
    const fixture = publisherFixture(interruption);
    try {
      expect(fixture.run().status).not.toBe(0);
      const originalAssets = structuredClone(fixture.state().bytes);
      fixture.build(Buffer.from("byte-different rebuilt signed archive"));
      const resumed = fixture.run();
      expect(resumed.status).toBe(0);
      expect(readFileSync(join(fixture.directory, "calendar.zip"))).toEqual(
        fixture.original,
      );
      expect(
        JSON.parse(readFileSync(join(fixture.directory, "calendar.json"))),
      ).toEqual(fixture.record(fixture.original));
      expect(
        readFileSync(join(fixture.directory, "calendar.zip.sha256"), "utf8"),
      ).toBe(extensionChecksum(fixture.record(fixture.original)));
      const complete = fixture.state();
      expect(complete.duplicateUploads).toBe(0);
      expect(
        complete.uploads.filter((name) => name === "calendar.zip"),
      ).toHaveLength(1);
      for (const [id, bytes] of Object.entries(originalAssets))
        expect(complete.bytes[id]).toBe(bytes);
    } finally {
      fixture.close();
    }
  }, 30_000);
}

test("recovery rejects tampered original bytes before replacing local artifacts or promoting the catalog", () => {
  const fixture = publisherFixture("calendar.json");
  try {
    expect(fixture.run().status).not.toBe(0);
    fixture.updateState((state) => {
      const archive = state.releases
        .flatMap((item) => item.assets)
        .find((asset) => asset.name === "calendar.zip");
      const changed = Buffer.from(state.bytes[archive.id], "base64");
      changed[0] ^= 1;
      state.bytes[archive.id] = changed.toString("base64");
    });
    const rebuilt = Buffer.from("byte-different rebuilt signed archive");
    fixture.build(rebuilt);
    const before = fixture.state();
    const rejected = fixture.run();
    expect(rejected.status).not.toBe(0);
    expect(rejected.stderr).toContain("Release asset checksum mismatch");
    expect(readFileSync(join(fixture.directory, "calendar.zip"))).toEqual(
      rebuilt,
    );
    expect(fixture.state().bytes).toEqual(before.bytes);
    expect(fixture.state().uploads).toEqual(before.uploads);
    expect(fixture.state().pointerEdits).toBe(0);
  } finally {
    fixture.close();
  }
}, 30_000);

for (const interruption of [
  "calendar.zip",
  "calendar.json",
  "calendar.zip.sha256",
  "catalog",
]) {
  test(`the full nonempty publisher resumes identical artifacts after ${interruption} response loss`, () => {
    const fixture = publisherFixture(interruption);
    try {
      const interrupted = fixture.run();
      expect(interrupted.status).not.toBe(0);
      expect(interrupted.stderr).toContain("synthetic upload response lost");
      const partial = fixture.state();
      expect(partial.interrupted).toBe(true);
      expect(partial.pointerEdits).toBe(0);
      const originalAssets = structuredClone(partial.bytes);
      const retry = fixture.run();
      expect(retry.status).toBe(0);
      const result = JSON.parse(retry.stdout);
      expect(result.published).toEqual([{ id: "calendar", version: "1.0.0" }]);
      const final = fixture.state();
      expect(final.duplicateUploads).toBe(0);
      expect(final.pointerEdits).toBe(1);
      for (const [id, bytes] of Object.entries(originalAssets))
        expect(final.bytes[id]).toBe(bytes);
      const release = final.releases.find(
        (item) => item.tag_name === entry.tag,
      );
      expect(release.draft).toBe(false);
      expect(release.assets.map(({ name }) => name)).toEqual([
        "calendar.native-evidence.json",
        "calendar.zip",
        "calendar.json",
        "calendar.zip.sha256",
      ]);
      const catalog = final.releases.find(
        (item) => item.tag_name === catalogTag,
      );
      expect(catalog.draft).toBe(false);
      const pointer = JSON.parse(catalog.body);
      const asset = catalog.assets.find(
        (item) => item.name === pointer.assetName,
      );
      const envelope = JSON.parse(Buffer.from(final.bytes[asset.id], "base64"));
      const payload = JSON.parse(Buffer.from(envelope.payload, "base64"));
      expect(payload.revision).toBe(result.revision);
      expect(payload.packages).toEqual([fixture.record(fixture.original)]);
    } finally {
      fixture.close();
    }
  }, 30_000);
}

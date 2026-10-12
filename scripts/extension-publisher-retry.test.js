import { expect, test } from "bun:test";
import { spawnSync } from "node:child_process";
import { createHash, generateKeyPairSync, sign } from "node:crypto";
import {
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { catalogPointer } from "./extension-catalog-pointer.mjs";
import { extensionChecksum } from "./extension-publish.mjs";
import { extensionReleaseTag } from "./extension-release-plan.mjs";
import { shippingNativeTestSteps } from "./hosted-managed-views/native-ci-contract.mjs";
import {
  closedAssetInventory,
  stagedEvidence,
} from "./hosted-public-release/evidence.mjs";

const repository = "pulkitxm/edith";
const target = "a".repeat(40);
const catalogTag = "extension-catalog-v1";
const entry = {
  id: "keepAwake",
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
    downloadURL: `https://github.com/${repository}/releases/download/${encodeURIComponent(entry.tag)}/keepAwake.zip`,
  });
  const build = (bytes) => {
    writeFileSync(join(directory, "keepAwake.zip"), bytes);
    writeFileSync(
      join(directory, "keepAwake.json"),
      JSON.stringify(record(bytes)),
    );
    writeFileSync(
      join(directory, "keepAwake.zip.sha256"),
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
    if (process.env.FIXTURE_EMPTY_RESUME) return JSON.parse(readFileSync(join(directory, "native-evidence-preparation.json")));
    const packageRecord = JSON.parse(readFileSync(join(directory, "keepAwake.json")));
    const sourceCommit = process.env.GITHUB_SHA;
    const payload = Buffer.from(JSON.stringify({
      schema: 1, kind: "extension-native-lineage", repository: process.env.GITHUB_REPOSITORY,
      package: packageRecord, sourceCommit, runID: 101, runAttempt: 1,
      evidenceTag: "extension-evidence/" + sourceCommit + "/101-1",
      evidenceSHA256: "c".repeat(64), evidenceBytes: 200,
    }));
    writeFileSync(join(directory, "keepAwake.native-evidence.json"), JSON.stringify({
      payload: payload.toString("base64"),
      signature: sign(null, payload, process.env.FIXTURE_PRIVATE_KEY).toString("base64"),
    }));
    return { tag: "synthetic", originalArchiveBytes: 0, totalEvidenceBytes: 0 };
  },
  publishComposition: process.env.FIXTURE_EMPTY_RESUME ? undefined : async ({ nativeEvidence }) => nativeEvidence,
  verifyOriginal: async ({ origin }) => ({ payload: {
    sourceCommit: origin.sourceCommit,
    plannedIDs: process.env.FIXTURE_EMPTY_RESUME ? Object.keys(JSON.parse(readFileSync(join(directory, "native-evidence-preparation.json"))).fixtureFingerprints) : [origin.package.id],
    fingerprints: process.env.FIXTURE_EMPTY_RESUME ? JSON.parse(readFileSync(join(directory, "native-evidence-preparation.json"))).fixtureFingerprints : { [origin.package.id]: origin.package.sourceFingerprint },
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
    preparePublishedVersion: (change) => {
      const published = { ...record(original), ...change };
      const tag = extensionReleaseTag({
        id: published.id,
        version: published.version,
        fingerprint: published.sourceFingerprint,
      });
      published.downloadURL = `https://github.com/${repository}/releases/download/${encodeURIComponent(tag)}/keepAwake.zip`;
      const previous = { schemaVersion: 1, revision: 1, packages: [published] };
      const payload = Buffer.from(JSON.stringify(previous));
      const envelope = Buffer.from(
        JSON.stringify({
          payload: payload.toString("base64"),
          signature: sign(null, payload, privateKey).toString("base64"),
        }),
      );
      writeFileSync(join(directory, "previous.json"), JSON.stringify(previous));
      const current = JSON.parse(readFileSync(stateFile));
      const asset = {
        id: current.next++,
        name: "catalog-1.json",
        size: envelope.length,
        digest: `sha256:${createHash("sha256").update(envelope).digest("hex")}`,
      };
      current.bytes[asset.id] = envelope.toString("base64");
      current.releases.push({
        id: current.next++,
        tag_name: catalogTag,
        draft: false,
        body: JSON.stringify(catalogPointer(envelope, 1)),
        assets: [asset],
      });
      writeFileSync(stateFile, JSON.stringify(current));
    },
    prepareEmptyDraft: () => {
      environment.FIXTURE_EMPTY_RESUME = "true";
      const definitions = JSON.parse(readFileSync("Extensions/manifest.json"));
      const fingerprints = Object.fromEntries(
        definitions.map(({ id }) => [id, "b".repeat(64)]),
      );
      const records = definitions.map((definition) => ({
        id: definition.id,
        version: "1.0.0",
        hostABI: definition.hostABI,
        architecture: "arm64",
        minimumSystemVersion: definition.minimumSystemVersion,
        dependencies: definition.dependencies,
        sourceFingerprint: fingerprints[definition.id],
        sha256: "d".repeat(64),
        downloadBytes: 1,
        installedBytes: 1,
        downloadURL: `https://github.com/${repository}/releases/download/${encodeURIComponent(`extensions/${definition.id}/1.0.0-${fingerprints[definition.id].slice(0, 20)}`)}/${definition.id}.zip`,
      }));
      const previous = { schemaVersion: 1, revision: 1, packages: records };
      const signed = (value) => {
        const bytes = Buffer.from(JSON.stringify(value));
        return Buffer.from(
          JSON.stringify({
            payload: bytes.toString("base64"),
            signature: sign(null, bytes, privateKey).toString("base64"),
          }),
        );
      };
      const resume = {
        plan: { include: [] },
        previous,
        state: { draft: true },
        definitions,
        fingerprints,
      };
      const run = {
        id: 1001,
        run_attempt: 1,
        repository: { full_name: repository },
        path: ".github/workflows/extensions.yml",
        head_sha: target,
        head_branch: "main",
        event: "push",
        status: "in_progress",
        conclusion: null,
      };
      const jobs = ["plan", "frozen-host", "tests", "build", "publish"].map(
        (name, index) => ({
          id: 2001 + index,
          run_id: run.id,
          name,
          status: name === "publish" ? "in_progress" : "completed",
          conclusion:
            name === "publish"
              ? null
              : name === "build"
                ? "skipped"
                : "success",
          steps: (name === "tests"
            ? shippingNativeTestSteps
            : name === "publish"
              ? ["Preserve immutable native evidence before publication"]
              : []
          ).map((step, number) => ({
            name: step,
            number: number + 1,
            status: name === "publish" ? "in_progress" : "completed",
            conclusion: name === "publish" ? null : "success",
          })),
        }),
      );
      const raw = Buffer.from("synthetic finished archive");
      const artifacts = ["extension-plan", "frozen-extension-host"].map(
        (name, index) => ({
          name,
          id: 3001 + index,
          size_in_bytes: raw.length,
          digest: `sha256:${createHash("sha256").update(raw).digest("hex")}`,
          expired: false,
          workflow_run: { id: run.id, head_sha: target },
        }),
      );
      const payload = stagedEvidence({
        run,
        jobs,
        artifacts,
        source: target,
        plannedIDs: [],
        fingerprints,
        resume,
        environment: {
          GITHUB_ACTIONS: "true",
          RUNNER_ENVIRONMENT: "github-hosted",
          RUNNER_OS: "macOS",
          GITHUB_REF: "refs/heads/main",
          GITHUB_REPOSITORY: repository,
          GITHUB_SHA: target,
          GITHUB_RUN_ID: String(run.id),
          GITHUB_RUN_ATTEMPT: "1",
          GITHUB_JOB: "publish",
        },
      });
      const bytes = signed(payload);
      const pin = {
        bytes: bytes.length,
        sha256: createHash("sha256").update(bytes).digest("hex"),
      };
      const tag = `extension-evidence/${target}/${run.id}-1`;
      const evidence = {
        tag,
        ...closedAssetInventory(payload, pin),
        fixtureFingerprints: fingerprints,
      };
      writeFileSync(join(directory, "native-evidence.json"), bytes);
      writeFileSync(
        join(directory, "native-evidence-preparation.json"),
        JSON.stringify(evidence),
      );
      writeFileSync(join(directory, "previous.json"), JSON.stringify(previous));
      writeFileSync(
        join(directory, "previous-state.json"),
        JSON.stringify({ draft: true }),
      );
      writeFileSync(
        join(directory, "plan.json"),
        JSON.stringify({ include: [] }),
      );
      const current = JSON.parse(readFileSync(stateFile));
      const add = (item, name, data) => {
        const asset = {
          id: current.next++,
          name,
          size: data.length,
          digest: `sha256:${createHash("sha256").update(data).digest("hex")}`,
        };
        item.assets.push(asset);
        current.bytes[asset.id] = data.toString("base64");
      };
      const catalogBytes = signed(previous);
      const catalog = {
        id: current.next++,
        tag_name: catalogTag,
        draft: true,
        body: JSON.stringify(catalogPointer(catalogBytes, 1)),
        assets: [],
      };
      add(catalog, "catalog-1.json", catalogBytes);
      current.releases.push(catalog);
      const native = {
        id: current.next++,
        tag_name: tag,
        target_commitish: target,
        draft: false,
        body: "",
        assets: [],
      };
      for (const row of payload.artifacts) add(native, row.assetName, raw);
      add(native, "native-evidence.json", bytes);
      current.releases.push(native);
      for (const record of records) {
        const old = {
          id: current.next++,
          tag_name: decodeURIComponent(
            new URL(record.downloadURL).pathname.split("/").at(-2),
          ),
          draft: false,
          body: "",
          assets: [],
        };
        add(
          old,
          `${record.id}.native-evidence.json`,
          signed({
            schema: 1,
            kind: "extension-native-lineage",
            repository,
            package: record,
            sourceCommit: "9".repeat(40),
            runID: 1000,
            runAttempt: 1,
            evidenceTag: `extension-evidence/${"9".repeat(40)}/1000-1`,
            evidenceSHA256: "c".repeat(64),
            evidenceBytes: 200,
          }),
        );
        current.releases.push(old);
      }
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

for (const change of [
  { sha256: "d".repeat(64) },
  { sourceFingerprint: "c".repeat(64) },
]) {
  test(`a conflicting published ${Object.keys(change)[0]} fails before every release mutation`, () => {
    const fixture = publisherFixture("");
    try {
      fixture.preparePublishedVersion(change);
      const before = fixture.state();
      const failed = fixture.run();
      expect(failed.status).not.toBe(0);
      expect(failed.stderr).toContain(
        "Published package versions are immutable",
      );
      expect(fixture.state()).toEqual(before);
      expect(fixture.state().uploads).toEqual([]);
      expect(fixture.state().pointerEdits).toBe(0);
      expect(fixture.state().releases).toHaveLength(1);
      expect(() =>
        readFileSync(join(fixture.directory, "keepAwake.native-evidence.json")),
      ).toThrow();
    } finally {
      fixture.close();
    }
  }, 30_000);
}

test("an archive-only retry recovers original immutable bytes and signed lineage after a different rebuild", () => {
  const fixture = publisherFixture("keepAwake.zip");
  try {
    expect(fixture.run().status).not.toBe(0);
    const partial = fixture.state();
    const originalAssets = structuredClone(partial.bytes);
    fixture.build(Buffer.from("byte-different rebuilt signed archive"));
    const resumed = fixture.run();
    expect(resumed.status).toBe(0);
    expect(readFileSync(join(fixture.directory, "keepAwake.zip"))).toEqual(
      fixture.original,
    );
    const complete = fixture.state();
    expect(complete.duplicateUploads).toBe(0);
    expect(
      complete.uploads.filter((name) => name === "keepAwake.zip"),
    ).toHaveLength(1);
    expect(
      complete.uploads.filter(
        (name) => name === "keepAwake.native-evidence.json",
      ),
    ).toHaveLength(1);
    for (const [id, bytes] of Object.entries(originalAssets))
      expect(complete.bytes[id]).toBe(bytes);
  } finally {
    fixture.close();
  }
}, 30_000);

for (const interruption of [
  "keepAwake.json",
  "keepAwake.zip.sha256",
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
      expect(readFileSync(join(fixture.directory, "keepAwake.zip"))).toEqual(
        fixture.original,
      );
      expect(
        JSON.parse(readFileSync(join(fixture.directory, "keepAwake.json"))),
      ).toEqual(fixture.record(fixture.original));
      expect(
        readFileSync(join(fixture.directory, "keepAwake.zip.sha256"), "utf8"),
      ).toBe(extensionChecksum(fixture.record(fixture.original)));
      const complete = fixture.state();
      expect(complete.duplicateUploads).toBe(0);
      expect(
        complete.uploads.filter((name) => name === "keepAwake.zip"),
      ).toHaveLength(1);
      for (const [id, bytes] of Object.entries(originalAssets))
        expect(complete.bytes[id]).toBe(bytes);
    } finally {
      fixture.close();
    }
  }, 30_000);
}

test("recovery rejects tampered original bytes before replacing local artifacts or promoting the catalog", () => {
  const fixture = publisherFixture("keepAwake.json");
  try {
    expect(fixture.run().status).not.toBe(0);
    fixture.updateState((state) => {
      const archive = state.releases
        .flatMap((item) => item.assets)
        .find((asset) => asset.name === "keepAwake.zip");
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
    expect(readFileSync(join(fixture.directory, "keepAwake.zip"))).toEqual(
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
  "keepAwake.zip",
  "keepAwake.json",
  "keepAwake.zip.sha256",
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
      expect(result.published).toEqual([{ id: "keepAwake", version: "1.0.0" }]);
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
        "keepAwake.native-evidence.json",
        "keepAwake.zip",
        "keepAwake.json",
        "keepAwake.zip.sha256",
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

test("a completed owned draft resumes through a signed full composition after response loss without rebuilding or replacing assets", () => {
  const fixture = publisherFixture("publication-composition.json");
  try {
    fixture.prepareEmptyDraft();
    const before = fixture.state();
    const interrupted = fixture.run();
    expect(interrupted.status).not.toBe(0);
    expect(interrupted.stderr).toContain("synthetic upload response lost");
    const partial = fixture.state();
    expect(
      partial.releases.find(({ tag_name }) => tag_name === catalogTag).draft,
    ).toBe(true);
    expect(partial.uploads).toEqual(["publication-composition.json"]);
    const resumed = fixture.run();
    expect(resumed.status).toBe(0);
    const after = fixture.state();
    expect(
      after.releases.find(({ tag_name }) => tag_name === catalogTag).draft,
    ).toBe(false);
    expect(after.duplicateUploads).toBe(0);
    expect(after.uploads).toEqual(["publication-composition.json"]);
    for (const [id, bytes] of Object.entries(before.bytes))
      expect(after.bytes[id]).toBe(bytes);
    for (const [id, bytes] of Object.entries(partial.bytes))
      expect(after.bytes[id]).toBe(bytes);
  } finally {
    fixture.close();
  }
}, 30000);

for (const failure of [
  "missing-draft",
  "foreign-main",
  "missing-link",
  "corrupt-link",
  "wrong-package",
]) {
  test(`empty draft resume refuses ${failure} before promotion`, () => {
    const fixture = publisherFixture("");
    try {
      fixture.prepareEmptyDraft();
      fixture.updateState((state) => {
        const catalog = state.releases.find(
          ({ tag_name }) => tag_name === catalogTag,
        );
        const owner = state.releases.find(({ tag_name }) =>
          tag_name.startsWith("extensions/"),
        );
        if (failure === "missing-draft") catalog.draft = false;
        if (failure === "foreign-main") state.target = "f".repeat(40);
        if (failure === "missing-link") owner.assets = [];
        if (failure === "corrupt-link")
          state.bytes[owner.assets[0].id] = Buffer.from(
            "bad signature fixture",
          ).toString("base64");
        if (failure === "wrong-package")
          owner.assets[0].name = "other.native-evidence.json";
      });
      expect(fixture.run().status).not.toBe(0);
      const state = fixture.state();
      expect(state.uploads).toEqual([]);
      if (failure !== "missing-draft")
        expect(
          state.releases.find(({ tag_name }) => tag_name === catalogTag).draft,
        ).toBe(true);
    } finally {
      fixture.close();
    }
  }, 30000);
}

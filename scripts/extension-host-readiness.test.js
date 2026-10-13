import { expect, test } from "bun:test";
import {
  appendFile,
  chmod,
  link,
  mkdtemp,
  readFile,
  rm,
  symlink,
  truncate,
  writeFile,
} from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  boundedReadinessFile,
  hostReadinessDescriptor,
} from "./extension-host-readiness.mjs";
import {
  bindStagedHostContinuation,
  publishStagedHostReadiness,
} from "./extension-publish.mjs";

function fixture() {
  const source = "a".repeat(40);
  const previous = {
    schemaVersion: 1,
    assetName: "catalog-1.json",
    revision: 1,
    sha256: "b".repeat(64),
    bytes: 300,
  };
  const candidate = {
    ...previous,
    assetName: "catalog-2.json",
    revision: 2,
    sha256: "c".repeat(64),
  };
  return {
    source,
    previous,
    candidate,
    intent: {
      source,
      role: "extensions",
      previousCatalog: previous,
      host: {
        kind: "pending-public-host",
        source,
        run: 10,
        runAttempt: 2,
        tag: "v0.0.402",
        version: "0.0.402",
        build: 400,
      },
      extensions: { run: 20, runAttempt: 3 },
    },
    record: {
      id: "keepAwake",
      version: "1.0.1",
      hostABI: "edith-host-2",
      architecture: "arm64",
      minimumSystemVersion: "14.0.0",
      dependencies: [],
      sourceFingerprint: "d".repeat(64),
      sha256: "e".repeat(64),
      downloadBytes: 100,
      installedBytes: 200,
      downloadURL:
        "https://github.com/pulkitxm/edith/releases/download/extensions%2FkeepAwake%2F1.0.1-dddddddddddddddddddd/keepAwake.zip",
    },
    native: {
      tag: `extension-evidence/${source}/20-3`,
      sourceCommit: source,
      runID: 20,
      runAttempt: 3,
      envelopeSHA256: "f".repeat(64),
      envelopeBytes: 200,
      compositionSHA256: "1".repeat(64),
      compositionBytes: 400,
      releaseID: 30,
      envelopeAssetID: 31,
      compositionAssetID: 32,
    },
    catalogReleaseID: 40,
    previousAssetID: 41,
    candidateAssetID: 42,
  };
}

test("readiness preserves all admitted host package evidence and catalog identities in an immutable bounded copy", () => {
  const input = fixture();
  const value = hostReadinessDescriptor(input);
  expect(value.host).toEqual(input.intent.host);
  expect(value.package).toEqual(input.record);
  expect(value.nativeEvidence).toEqual(input.native);
  expect(value.previousCatalog).toEqual(input.previous);
  expect(value.candidateCatalog).toEqual(input.candidate);
  expect(Buffer.byteLength(JSON.stringify(value))).toBeLessThan(8193);
  expect(Object.isFrozen(value)).toBe(true);
  expect(Object.isFrozen(value.host)).toBe(true);
  input.intent.host.run = 99;
  input.record.sha256 = "9".repeat(64);
  input.previous.sha256 = "8".repeat(64);
  expect(value.host.run).toBe(10);
  expect(value.package.sha256).toBe("e".repeat(64));
  expect(value.previousCatalog.sha256).toBe("b".repeat(64));
});

test.each([
  [
    "host source",
    (v) => {
      v.intent.host.source = "9".repeat(40);
    },
  ],
  [
    "host run reuse",
    (v) => {
      v.intent.host.run = v.intent.extensions.run;
    },
  ],
  [
    "host extra authority",
    (v) => {
      v.intent.host.approved = true;
    },
  ],
  [
    "host tag",
    (v) => {
      v.intent.host.tag = "v0.0.401";
    },
  ],
  [
    "wrong owner role",
    (v) => {
      v.intent.role = "host";
    },
  ],
  [
    "extension attempt",
    (v) => {
      v.intent.extensions.runAttempt++;
    },
  ],
  [
    "native source",
    (v) => {
      v.native.sourceCommit = "9".repeat(40);
    },
  ],
  [
    "native tag",
    (v) => {
      v.native.tag = "foreign";
    },
  ],
  [
    "native extra authority",
    (v) => {
      v.native.passed = true;
    },
  ],
  [
    "native reused asset",
    (v) => {
      v.native.compositionAssetID = v.native.envelopeAssetID;
    },
  ],
  [
    "native bounds",
    (v) => {
      v.native.envelopeBytes = 1024 ** 2 + 1;
    },
  ],
  [
    "catalog reused asset",
    (v) => {
      v.candidateAssetID = v.previousAssetID;
    },
  ],
  [
    "catalog unchanged revision",
    (v) => {
      v.candidate.revision = v.previous.revision;
    },
  ],
  [
    "catalog unchanged bytes",
    (v) => {
      v.candidate.sha256 = v.previous.sha256;
    },
  ],
  [
    "catalog old pointer",
    (v) => {
      v.intent.previousCatalog = { ...v.previous, sha256: "9".repeat(64) };
    },
  ],
  [
    "package wrong owner",
    (v) => {
      v.record.id = "emoji";
    },
  ],
  [
    "package old version",
    (v) => {
      v.record.version = "1.0.0";
    },
  ],
  [
    "package dependencies",
    (v) => {
      v.record.dependencies = ["emoji"];
    },
  ],
])("readiness rejects %s before producing descriptor bytes", (_, alter) => {
  const input = fixture();
  alter(input);
  expect(() => hostReadinessDescriptor(input)).toThrow();
});

test.each([publishStagedHostReadiness, bindStagedHostContinuation])(
  "unknown or copied stage objects cannot reach bootstrap authority",
  async (invoke) => {
    for (const value of [
      {},
      Object.freeze({}),
      {
        source: "a".repeat(40),
        previous: fixture().previous,
        candidate: fixture().candidate,
      },
    ])
      await expect(invoke(value, {})).rejects.toThrow(
        "Unknown or consumed staged publication",
      );
  },
);

test("readiness files preserve exact bounded bytes and reject nonowned path substitution", async () => {
  const root = await mkdtemp(join(tmpdir(), "readiness-file-"));
  try {
    const input = join(root, "input");
    const bytes = Buffer.from("synthetic signed metadata");
    await writeFile(input, bytes, { mode: 0o600 });
    expect(await boundedReadinessFile(input, bytes.length)).toEqual(bytes);
    await expect(
      boundedReadinessFile(input, bytes.length - 1),
    ).rejects.toThrow();
    const alias = join(root, "alias");
    await symlink(input, alias);
    await expect(boundedReadinessFile(alias, 100)).rejects.toThrow();
    const hard = join(root, "hard");
    await link(input, hard);
    await expect(boundedReadinessFile(input, 100)).rejects.toThrow();
    await rm(hard);
    await chmod(input, 0o666);
    await expect(boundedReadinessFile(input, 100)).rejects.toThrow();
    expect(await readFile(input)).toEqual(bytes);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test.each(["growth", "truncation", "replacement"])(
  "concurrent readiness %s cannot escape the admitted allocation or file identity",
  async (mode) => {
    const root = await mkdtemp(join(tmpdir(), "readiness-read-race-"));
    try {
      const input = join(root, "input");
      const bytes = Buffer.from("synthetic metadata");
      await writeFile(input, bytes, { mode: 0o600 });
      let allocation = 0;
      let changed = false;
      await expect(
        boundedReadinessFile(input, 100, {
          readChunk: async (handle, buffer, offset) => {
            allocation = Math.max(allocation, buffer.length);
            if (!changed) {
              changed = true;
              if (mode === "growth")
                await appendFile(input, Buffer.alloc(4096));
              if (mode === "truncation") await truncate(input, 1);
              if (mode === "replacement") {
                await rm(input);
                await writeFile(input, bytes, { mode: 0o600 });
              }
            }
            return handle.read(buffer, offset, buffer.length - offset, null);
          },
        }),
      ).rejects.toThrow();
      expect(allocation).toBe(bytes.length + 1);
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  },
);

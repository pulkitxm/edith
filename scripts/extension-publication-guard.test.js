import { expect, test } from "bun:test";
import { spawn, spawnSync } from "node:child_process";
import { generateKeyPairSync, sign } from "node:crypto";
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import {
  promoteExtensionCatalog,
  publicationPlanCatalog,
  readPublicationCatalog,
  verifiedPublicationState,
} from "./extension-publish.mjs";
import { downloadReleaseAsset } from "./release-asset-read.mjs";
import { maximumEnvelopeBytes } from "./verify-extension-catalog.mjs";

const target = "a".repeat(40);
const { publicKey, privateKey } = generateKeyPairSync("ed25519");
const rawKey = Buffer.from(
  publicKey.export({ format: "jwk" }).x,
  "base64url",
).toString("base64");
const previous = { schemaVersion: 1, revision: 1, packages: [] };
const empty = { schemaVersion: 1, revision: 0, packages: [] };
const candidate = "catalog-2.json";
function envelope(catalog) {
  const payload = Buffer.from(JSON.stringify(catalog));
  return Buffer.from(
    JSON.stringify({
      payload: payload.toString("base64"),
      signature: sign(null, payload, privateKey).toString("base64"),
    }),
  );
}
function current(catalog = previous) {
  const asset = { id: 1, name: "catalog.json" };
  return {
    release: {
      id: 10,
      draft: false,
      assets: [asset, { id: 2, name: candidate }],
    },
    asset,
    data: envelope(catalog),
    catalogRevision: catalog.revision,
  };
}
function options(changes = {}) {
  return {
    ref: "refs/heads/main",
    target,
    previous,
    publicKey: rawKey,
    readMain: async () => target,
    readCatalog: async () => current(),
    ...changes,
  };
}

test("production publication rejects unapproved refs and stale targets before reads or pointer writes", async () => {
  for (const changes of [
    { ref: "refs/heads/feature" },
    { ref: "refs/tags/v1.0.0" },
    { target: "invalid" },
    { ref: undefined },
  ]) {
    let reads = 0;
    await expect(
      verifiedPublicationState(
        options({
          ...changes,
          readMain: async () => {
            reads++;
            return target;
          },
        }),
      ),
    ).rejects.toThrow("approved main");
    expect(reads).toBe(0);
  }
  let catalogReads = 0;
  await expect(
    verifiedPublicationState(
      options({
        readMain: async () => "b".repeat(40),
        readCatalog: async () => {
          catalogReads++;
          return current();
        },
      }),
    ),
  ).rejects.toThrow("main changed");
  expect(catalogReads).toBe(0);
});

test("the second main check catches a move during trusted catalog download", async () => {
  let reads = 0;
  let renames = 0;
  await expect(
    promoteExtensionCatalog({
      candidate,
      verifyState: () =>
        verifiedPublicationState(
          options({
            readMain: async () => (++reads === 1 ? target : "b".repeat(40)),
          }),
        ),
      rename: async () => {
        renames++;
      },
    }),
  ).rejects.toThrow("main changed");
  expect(reads).toBe(2);
  expect(renames).toBe(0);
});

test("catalog changes, replays and tampering after immutable staging reject before pointer writes", async () => {
  for (const changed of [
    current({ ...previous, revision: 2 }),
    current(empty),
    { ...current(), data: Buffer.from("broken") },
  ]) {
    await verifiedPublicationState(options());
    const renames = [];
    await expect(
      promoteExtensionCatalog({
        candidate,
        verifyState: () =>
          verifiedPublicationState(
            options({ readCatalog: async () => changed }),
          ),
        rename: async (...args) => {
          renames.push(args);
        },
      }),
    ).rejects.toThrow();
    expect(renames).toEqual([]);
  }
});

test("same-revision catalog content changes are rejected even with a valid signature", async () => {
  const record = {
    id: "calendar",
    version: "1.0.0",
    hostABI: "edith-host-2",
    architecture: "arm64",
    minimumSystemVersion: 14,
    dependencies: [],
    downloadBytes: 1,
    installedBytes: 1,
    sha256: "a".repeat(64),
    sourceFingerprint: "b".repeat(64),
    downloadURL:
      "https://github.com/pulkitxm/edith/releases/download/synthetic/calendar.zip",
  };
  await expect(
    verifiedPublicationState(
      options({
        readCatalog: async () => current({ ...previous, packages: [record] }),
      }),
    ),
  ).rejects.toThrow("catalog changed");
  await expect(
    verifiedPublicationState(
      options({
        readCatalog: async () =>
          current({ ...previous, packages: [record, record] }),
      }),
    ),
  ).rejects.toThrow("Duplicate");
  const data = JSON.parse(envelope(previous));
  data.payload = Buffer.from(
    JSON.stringify({ ...previous, revision: 99 }),
  ).toString("base64");
  await expect(
    verifiedPublicationState(
      options({
        readCatalog: async () => ({
          ...current(),
          data: Buffer.from(JSON.stringify(data)),
        }),
      }),
    ),
  ).rejects.toThrow("signature");
});

test("only true initial absence or an owned draft permits bootstrap and failed stages remain retryable", async () => {
  expect(
    await verifiedPublicationState(
      options({ previous: empty, readCatalog: async () => undefined }),
    ),
  ).toBeUndefined();
  await expect(
    verifiedPublicationState(options({ readCatalog: async () => undefined })),
  ).rejects.toThrow("pointer missing");
  await expect(
    verifiedPublicationState(
      options({
        previous: empty,
        readCatalog: async () => ({
          release: { id: 10, draft: false, assets: [] },
        }),
      }),
    ),
  ).rejects.toThrow("pointer missing");
  const draft = {
    release: {
      id: 10,
      draft: true,
      assets: [
        { id: 3, name: "catalog-1.json" },
        { id: 2, name: candidate },
      ],
    },
  };
  const renames = [];
  await promoteExtensionCatalog({
    candidate,
    verifyState: () =>
      verifiedPublicationState(
        options({ previous: empty, readCatalog: async () => draft }),
      ),
    rename: async (...args) => {
      renames.push(args);
    },
  });
  expect(renames).toEqual([[2, "catalog.json"]]);
  expect(draft.release.assets).toHaveLength(2);
});

test("catalog reads propagate auth, transport and parse errors instead of treating them as initial absence", async () => {
  for (const message of [
    "HTTP403",
    "HTTP401",
    "network failure",
    "invalid response",
  ]) {
    await expect(
      readPublicationCatalog("synthetic/fixture", "catalog", {
        loadRelease: () => {
          throw new Error(message);
        },
      }),
    ).rejects.toThrow(message);
  }
  expect(
    await readPublicationCatalog("synthetic/fixture", "catalog", {
      loadRelease: () => undefined,
    }),
  ).toBeUndefined();
  const live = current();
  let request;
  const result = await readPublicationCatalog("synthetic/fixture", "catalog", {
    loadRelease: () => live.release,
    downloadAsset: async (value) => {
      request = value;
      writeFileSync(value.destination, live.data);
      return { data: undefined };
    },
  });
  expect(request.maximumBytes).toBe(maximumEnvelopeBytes);
  expect(request.asset.id).toBe(1);
  expect(existsSync(request.destination)).toBe(false);
  expect(result.data).toEqual(live.data);
  await expect(
    readPublicationCatalog("synthetic/fixture", "catalog", {
      loadRelease: () => live.release,
      downloadAsset: async () => {
        throw new Error("download failed");
      },
    }),
  ).rejects.toThrow("download failed");
});

test("unchanged trusted state promotes only after verification and rename failure restores the old pointer", async () => {
  for (const fails of [false, true]) {
    const renames = [];
    let verified = false;
    const work = promoteExtensionCatalog({
      candidate,
      verifyState: async () => {
        const value = await verifiedPublicationState(options());
        verified = true;
        return value;
      },
      rename: async (id, name) => {
        expect(verified).toBe(true);
        renames.push([id, name]);
        if (fails && id === 2) throw new Error("rename failed");
      },
    });
    if (fails) await expect(work).rejects.toThrow("rename failed");
    else await work;
    expect(renames).toEqual(
      fails
        ? [
            [1, "catalog-1.json"],
            [2, "catalog.json"],
            [1, "catalog.json"],
          ]
        : [
            [1, "catalog-1.json"],
            [2, "catalog.json"],
          ],
    );
  }
});

test("production workflow refuses feature-ref publication before native jobs", () => {
  const workflow = Bun.YAML.parse(
    readFileSync(".github/workflows/extensions.yml", "utf8"),
  );
  const guard = workflow.jobs.plan.steps.find(
    (step) => step.name === "Require production publication from main",
  );
  for (const ref of [
    "refs/heads/main",
    "refs/heads/feature",
    "refs/tags/v1.0.0",
  ]) {
    const result = spawnSync("bash", ["-c", guard.run], {
      env: { ...process.env, GITHUB_REF: ref },
      encoding: "utf8",
    });
    expect(result.status).toBe(ref === "refs/heads/main" ? 0 : 1);
  }
  expect(guard.if).toContain("inputs.publish == true");
  expect(workflow.jobs.publish.if).toContain(
    "inputs.publish == true && github.ref == 'refs/heads/main'",
  );
  expect(workflow.jobs["frozen-host"].needs).toContain("plan");
});

test("authenticated planning preserves draft revisions so rejected first publication can retry", async () => {
  const draft = {
    ...current({ ...previous, revision: 2 }),
    release: { ...current().release, draft: true },
  };
  const catalog = await publicationPlanCatalog({
    publicKey: rawKey,
    readCatalog: async () => draft,
  });
  expect(catalog.revision).toBe(2);
  expect(
    await verifiedPublicationState(
      options({ previous: catalog, readCatalog: async () => draft }),
    ),
  ).toBe(draft);
  expect(
    await publicationPlanCatalog({
      publicKey: rawKey,
      readCatalog: async () => undefined,
    }),
  ).toEqual(empty);
  expect(
    await publicationPlanCatalog({
      publicKey: rawKey,
      readCatalog: async () => ({ release: { draft: true, assets: [] } }),
    }),
  ).toEqual(empty);
  await expect(
    publicationPlanCatalog({
      publicKey: rawKey,
      readCatalog: async () => ({ release: { draft: false, assets: [] } }),
    }),
  ).rejects.toThrow("pointer missing");
  await expect(
    publicationPlanCatalog({
      publicKey: rawKey,
      readCatalog: async () => {
        throw new Error("HTTP403");
      },
    }),
  ).rejects.toThrow("HTTP403");
  await expect(
    publicationPlanCatalog({
      publicKey: rawKey,
      readCatalog: async () => ({ ...draft, data: Buffer.from("broken") }),
    }),
  ).rejects.toThrow();
  const workflow = Bun.YAML.parse(
    readFileSync(".github/workflows/extensions.yml", "utf8"),
  );
  const planning = workflow.jobs.plan.steps.find((step) => step.id === "plan");
  expect(planning.env.GH_TOKEN).toBe(["$", "{{ github.token }}"].join(""));
  expect(planning.run).toContain(
    "--read-catalog dist/extensions/previous.json",
  );
  expect(planning.run).not.toContain("curl");
  expect(workflow.permissions.contents).toBe("read");
});

test("catalog downloads support the signed envelope limit without the metadata memory cap", async () => {
  const size = 1024 ** 2 + 17;
  let destination;
  const result = await readPublicationCatalog("synthetic/fixture", "catalog", {
    loadRelease: () => ({ assets: [{ id: 1, name: "catalog.json", size }] }),
    downloadAsset: (options) => {
      destination = options.destination;
      return downloadReleaseAsset({
        ...options,
        spawnProcess: (_command, _args, settings) =>
          spawn(
            "node",
            ["-e", `process.stdout.write(Buffer.alloc(${size}, 42))`],
            settings,
          ),
      });
    },
  });
  expect(result.data).toEqual(Buffer.alloc(size, 42));
  expect(existsSync(destination)).toBe(false);
  let starts = 0;
  await expect(
    readPublicationCatalog("synthetic/fixture", "catalog", {
      loadRelease: () => ({
        assets: [
          { id: 1, name: "catalog.json", size: maximumEnvelopeBytes + 1 },
        ],
      }),
      downloadAsset: (options) =>
        downloadReleaseAsset({
          ...options,
          spawnProcess: () => {
            starts++;
            throw new Error("Must not start");
          },
        }),
    }),
  ).rejects.toThrow("size");
  expect(starts).toBe(0);
});

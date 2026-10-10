import { expect, test } from "bun:test";
import { spawn, spawnSync } from "node:child_process";
import { generateKeyPairSync, sign } from "node:crypto";
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { catalogPointer } from "./extension-catalog-pointer.mjs";
import {
  finalizeDraftCatalog,
  promoteExtensionCatalog,
  publicationPlanCatalog,
  publicationPlanningState,
  readPublicationCatalog,
  verifiedPublicationState,
} from "./extension-publish.mjs";
import {
  extensionFingerprint,
  planUnpublishedExtensions,
} from "./extension-release-plan.mjs";
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
const nextData = envelope({ ...previous, revision: 2 });
const nextPointer = catalogPointer(nextData, 2);
function current(catalog = previous) {
  const data = envelope(catalog);
  const pointer = catalogPointer(data, catalog.revision);
  const asset = { id: 1, name: pointer.assetName, size: data.length };
  return {
    release: {
      id: 10,
      tag_name: "extension-catalog-v1",
      draft: false,
      body: JSON.stringify(pointer),
      assets: [asset, { id: 2, name: candidate, size: nextData.length }],
    },
    asset,
    data,
    pointer,
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
      pointer: nextPointer,
      verifyAsset: async () => {},
      verifyState: () =>
        verifiedPublicationState(
          options({
            readMain: async () => (++reads === 1 ? target : "b".repeat(40)),
          }),
        ),
      updatePointer: async () => {
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
    { ...current(), data: envelope(empty) },
    { ...current(), data: Buffer.from("broken") },
  ]) {
    await verifiedPublicationState(options());
    const renames = [];
    await expect(
      promoteExtensionCatalog({
        pointer: nextPointer,
        verifyAsset: async () => {},
        verifyState: () =>
          verifiedPublicationState(
            options({ readCatalog: async () => changed }),
          ),
        updatePointer: async (...args) => {
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
      tag_name: "extension-catalog-v1",
      draft: true,
      assets: [
        { id: 3, name: "catalog-1.json" },
        { id: 2, name: candidate, size: nextData.length },
      ],
    },
  };
  const renames = [];
  await promoteExtensionCatalog({
    pointer: nextPointer,
    verifyAsset: async () => {},
    verifyState: () =>
      verifiedPublicationState(
        options({ previous: empty, readCatalog: async () => draft }),
      ),
    updatePointer: async (...args) => {
      renames.push(args);
    },
  });
  expect(renames).toEqual([[10, JSON.stringify(nextPointer)]]);
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

test("atomic promotion preserves immutable assets and leaves the old pointer usable on failure", async () => {
  for (const fails of [false, true]) {
    const live = current();
    const originalBody = live.release.body;
    const originalAssets = structuredClone(live.release.assets);
    let writes = 0;
    let verifiedAsset = false;
    const work = promoteExtensionCatalog({
      pointer: nextPointer,
      verifyState: () =>
        verifiedPublicationState(options({ readCatalog: async () => live })),
      verifyAsset: async () => {
        verifiedAsset = true;
      },
      updatePointer: async (id, body) => {
        expect(verifiedAsset).toBe(true);
        expect(id).toBe(10);
        writes++;
        if (fails) throw new Error("pointer edit failed");
        live.release.body = body;
      },
    });
    if (fails) await expect(work).rejects.toThrow("pointer edit failed");
    else await work;
    expect(writes).toBe(1);
    expect(live.release.assets).toEqual(originalAssets);
    expect(live.release.body).toBe(
      fails ? originalBody : JSON.stringify(nextPointer),
    );
  }
});

test("a crash after immutable upload does not change the public pointer and retries safely", async () => {
  const live = current();
  const body = live.release.body;
  await expect(
    promoteExtensionCatalog({
      pointer: nextPointer,
      verifyState: () =>
        verifiedPublicationState(options({ readCatalog: async () => live })),
      verifyAsset: async () => {
        throw new Error("interrupted before promotion");
      },
      updatePointer: async () => {
        throw new Error("must not write");
      },
    }),
  ).rejects.toThrow("interrupted");
  expect(live.release.body).toBe(body);
  let checks = 0;
  let writes = 0;
  await expect(
    promoteExtensionCatalog({
      pointer: nextPointer,
      verifyState: async () => {
        checks++;
        return verifiedPublicationState(
          options({
            readCatalog: async () =>
              checks === 1 ? live : current({ ...previous, revision: 3 }),
          }),
        );
      },
      verifyAsset: async () => {},
      updatePointer: async () => {
        writes++;
      },
    }),
  ).rejects.toThrow("catalog changed");
  expect(checks).toBe(2);
  expect(writes).toBe(0);
  expect(live.release.body).toBe(body);
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
    release: { ...current({ ...previous, revision: 2 }).release, draft: true },
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
  const data = Buffer.alloc(size, 42);
  const pointer = catalogPointer(data, 2);
  let destination;
  const result = await readPublicationCatalog("synthetic/fixture", "catalog", {
    loadRelease: () => ({
      body: JSON.stringify(pointer),
      assets: [{ id: 1, name: pointer.assetName, size }],
    }),
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
  expect(result.data).toEqual(data);
  expect(existsSync(destination)).toBe(false);
  let starts = 0;
  await expect(
    readPublicationCatalog("synthetic/fixture", "catalog", {
      loadRelease: () => ({
        body: JSON.stringify({ ...pointer, bytes: maximumEnvelopeBytes + 1 }),
        assets: [],
      }),
      downloadAsset: async () => {
        starts++;
        throw new Error("Must not start");
      },
    }),
  ).rejects.toThrow("pointer");
  expect(starts).toBe(0);
});

test("unchanged source retries finalize an authenticated draft once without package builds", async () => {
  const directory = mkdtempSync(join(tmpdir(), "catalog-draft-retry-"));
  const definition = {
    id: "music",
    version: "1.0.0",
    hostABI: "runtime-2",
    inputs: ["Extensions/music"],
    sharedInputs: [],
    dependencies: [],
  };
  try {
    mkdirSync(join(directory, "Extensions/music"), { recursive: true });
    writeFileSync(
      join(directory, "Extensions/music/Runtime.swift"),
      "synthetic owned source",
    );
    const fingerprint = await extensionFingerprint(directory, definition, [
      definition,
    ]);
    const catalog = {
      schemaVersion: 1,
      revision: 2,
      packages: [
        {
          id: "music",
          version: "1.0.0",
          hostABI: "runtime-2",
          architecture: "arm64",
          sourceFingerprint: fingerprint,
          sha256: "b".repeat(64),
          minimumSystemVersion: 14,
          downloadBytes: 1,
          installedBytes: 1,
          dependencies: [],
          downloadURL:
            "https://github.com/pulkitxm/edith/releases/download/synthetic/music.zip",
        },
      ],
    };
    const live = current(catalog);
    live.release.draft = true;
    let published = 0;
    const readCatalog = async () => live;
    const planning = await publicationPlanningState({
      publicKey: rawKey,
      readCatalog,
    });
    expect(planning.draft).toBe(true);
    expect(
      await planUnpublishedExtensions(
        directory,
        [definition],
        planning.catalog.packages,
      ),
    ).toEqual([]);
    const verifyState = () =>
      verifiedPublicationState(options({ previous: catalog, readCatalog }));
    const publish = async (id) => {
      expect(id).toBe(live.release.id);
      published++;
      live.release.draft = false;
    };
    expect(await finalizeDraftCatalog({ verifyState, publish })).toBe(true);
    expect(await finalizeDraftCatalog({ verifyState, publish })).toBe(false);
    expect(published).toBe(1);
    expect(
      (await publicationPlanningState({ publicKey: rawKey, readCatalog }))
        .draft,
    ).toBe(false);
    for (const failure of ["stale", "corrupt", "changed"]) {
      live.release.draft = true;
      live.data =
        failure === "corrupt"
          ? Buffer.from("broken")
          : envelope(
              failure === "changed" ? { ...catalog, revision: 3 } : catalog,
            );
      await expect(
        finalizeDraftCatalog({
          verifyState: () =>
            verifiedPublicationState(
              options({
                previous: catalog,
                readCatalog,
                readMain: async () =>
                  failure === "stale" ? "b".repeat(40) : target,
              }),
            ),
          publish,
        }),
      ).rejects.toThrow();
      expect(published).toBe(1);
    }
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
});

test("zero-matrix workflow verifies the frozen runtime before trusted draft finalization", () => {
  const workflow = Bun.YAML.parse(
    readFileSync(".github/workflows/extensions.yml", "utf8"),
  );
  const run = (
    job,
    needs,
    github = {
      event_name: "push",
      ref: "refs/heads/main",
      repository: "pulkitxm/edith",
    },
    cancelled = false,
  ) =>
    new Function(
      "needs",
      "github",
      "inputs",
      "cancelled",
      `return (${job.if});`,
    )(needs, github, { publish: true }, () => cancelled);
  const needs = {
    plan: { result: "success", outputs: { changed: "false", draft: "true" } },
    build: { result: "skipped" },
    tests: { result: "success" },
    "frozen-host": { result: "success" },
  };
  expect(run(workflow.jobs["frozen-host"], needs)).toBe(true);
  expect(run(workflow.jobs.tests, needs)).toBe(true);
  expect(run(workflow.jobs.build, needs)).toBe(false);
  expect(run(workflow.jobs.publish, needs)).toBe(true);
  for (const change of [
    {
      plan: {
        result: "success",
        outputs: { changed: "false", draft: "false" },
      },
    },
    {
      plan: { result: "failure", outputs: { changed: "false", draft: "true" } },
    },
    { build: { result: "failure" } },
    { build: { result: "cancelled" } },
    { tests: { result: "failure" } },
    { tests: { result: "skipped" } },
    { tests: { result: "cancelled" } },
    {
      plan: { result: "success", outputs: { changed: "true", draft: "true" } },
    },
  ])
    expect(run(workflow.jobs.publish, { ...needs, ...change })).toBe(false);
  expect(
    run(workflow.jobs.publish, needs, {
      event_name: "workflow_dispatch",
      ref: "refs/heads/feature",
    }),
  ).toBe(false);
  expect(run(workflow.jobs.publish, needs, undefined, true)).toBe(false);
  expect(
    run(workflow.jobs.publish, {
      ...needs,
      plan: { result: "success", outputs: { changed: "true", draft: "false" } },
      build: { result: "success" },
    }),
  ).toBe(true);
});

test("the actual no-argument publisher finalizes a zero-build draft and refuses stale or corrupt retries", () => {
  const directory = mkdtempSync(join(tmpdir(), "catalog-publisher-cli-"));
  const binary = join(directory, "bin");
  mkdirSync(binary);
  const stateFile = join(directory, "state.json");
  const live = current();
  live.release.draft = true;
  live.release.assets = [{ ...live.asset, size: live.data.length }];
  const state = {
    release: live.release,
    data: live.data.toString("base64"),
    target,
    mutations: 0,
  };
  writeFileSync(stateFile, JSON.stringify(state));
  const fixtureRead = `const fs = require("node:fs"); const file = process.env.FIXTURE_STATE; const state = JSON.parse(fs.readFileSync(file));`;
  writeFileSync(
    join(binary, "gh"),
    `#!/usr/bin/env node\n${fixtureRead} const args = process.argv.slice(2); const path = args.at(-1); if (path.endsWith("git/ref/heads/main")) process.stdout.write(JSON.stringify({ object: { sha: state.target } })); else if (path.includes("releases/tags/")) { if (state.release.draft) { process.stderr.write("gh: Not Found (HTTP 404)"); process.exit(1); } process.stdout.write(JSON.stringify(state.release)); } else if (path.includes("releases?")) process.stdout.write(JSON.stringify([state.release])); else if (path.endsWith("releases/assets/1")) process.stdout.write(Buffer.from(state.data, "base64")); else process.exit(2);`,
    { mode: 0o700 },
  );
  writeFileSync(
    join(binary, "pukbot"),
    `#!/usr/bin/env node\n${fixtureRead} const args = process.argv.slice(2); if (args[0] !== "release" || args[1] !== "edit" || !args.includes("--draft")) process.exit(2); state.release.draft = false; state.mutations++; fs.writeFileSync(file, JSON.stringify(state)); process.stdout.write(JSON.stringify({ ok: true }));`,
    { mode: 0o700 },
  );
  writeFileSync(
    join(binary, "swift"),
    `#!/usr/bin/env node\nconst fs = require("node:fs"); const state = JSON.parse(fs.readFileSync(process.env.FIXTURE_STATE)); if (process.argv[3] !== "check-key" || state.invalidKey) process.exit(1);`,
    { mode: 0o700 },
  );
  writeFileSync(join(directory, "previous.json"), JSON.stringify(previous));
  writeFileSync(join(directory, "plan.json"), JSON.stringify({ include: [] }));
  const environment = {
    PATH: `${binary}:${process.env.PATH}`,
    HOME: directory,
    FIXTURE_STATE: stateFile,
    GITHUB_REPOSITORY: "synthetic/fixture",
    GITHUB_SHA: target,
    GITHUB_REF: "refs/heads/main",
    GH_TOKEN: "synthetic",
    EXTENSION_CATALOG_PUBLIC_KEY: rawKey,
    EXTENSION_CATALOG_PRIVATE_KEY: "synthetic",
    EXTENSION_OUTPUT: directory,
  };
  const run = () =>
    spawnSync("bun", [resolve("scripts/extension-publish.mjs")], {
      env: environment,
      encoding: "utf8",
      timeout: 10000,
    });
  try {
    const planned = spawnSync(
      "node",
      [
        resolve("scripts/extension-publish.mjs"),
        "--read-catalog",
        join(directory, "previous.json"),
      ],
      { env: environment, encoding: "utf8", timeout: 10000 },
    );
    expect(planned.status).toBe(0);
    expect(
      JSON.parse(readFileSync(join(directory, "previous-state.json"))),
    ).toEqual({ draft: true });
    expect(planned.stdout).toBe("Verified catalog revision: 1\n");
    writeFileSync(stateFile, JSON.stringify({ ...state, invalidKey: true }));
    expect(run().status).not.toBe(0);
    expect(JSON.parse(readFileSync(stateFile)).mutations).toBe(0);
    writeFileSync(stateFile, JSON.stringify(state));
    for (let index = 0; index < 2; index++) {
      const result = run();
      expect(result.status).toBe(0);
      expect(JSON.parse(result.stdout)).toEqual({ published: [], revision: 1 });
      expect(JSON.parse(readFileSync(stateFile)).mutations).toBe(1);
    }
    for (const invalid of ["stale", "corrupt"]) {
      const invalidState = JSON.parse(readFileSync(stateFile));
      invalidState.release.draft = true;
      invalidState.target = target;
      invalidState.data = live.data.toString("base64");
      if (invalid === "stale") invalidState.target = "b".repeat(40);
      else invalidState.data = Buffer.from("broken").toString("base64");
      writeFileSync(stateFile, JSON.stringify(invalidState));
      const rejected = run();
      expect(rejected.status).not.toBe(0);
      if (invalid === "corrupt")
        expect(rejected.stderr).not.toContain("main changed");
      expect(JSON.parse(readFileSync(stateFile)).mutations).toBe(1);
    }
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
});

test("an acknowledged-lost pointer edit stays complete and the next plan reads the new trusted revision", async () => {
  const live = current();
  const assets = structuredClone(live.release.assets);
  await expect(
    promoteExtensionCatalog({
      pointer: nextPointer,
      verifyState: () =>
        verifiedPublicationState(options({ readCatalog: async () => live })),
      verifyAsset: async () => {},
      updatePointer: async (_id, body) => {
        live.release.body = body;
        live.pointer = nextPointer;
        live.asset = live.release.assets.find(
          (asset) => asset.name === nextPointer.assetName,
        );
        live.data = nextData;
        throw new Error("response lost after atomic edit");
      },
    }),
  ).rejects.toThrow("response lost");
  expect(live.release.assets).toEqual(assets);
  expect(
    (
      await publicationPlanCatalog({
        publicKey: rawKey,
        readCatalog: async () => live,
      })
    ).revision,
  ).toBe(2);
  await expect(
    verifiedPublicationState(options({ readCatalog: async () => live })),
  ).rejects.toThrow("catalog changed");
});

test("deletion or substitution of the staged immutable asset blocks the final pointer edit", async () => {
  for (const replacement of [
    [],
    [{ id: 99, name: candidate, size: nextPointer.bytes }],
  ]) {
    const live = current();
    let reads = 0;
    let writes = 0;
    await expect(
      promoteExtensionCatalog({
        pointer: nextPointer,
        verifyState: async () => {
          reads++;
          return reads === 1
            ? live
            : {
                ...live,
                release: {
                  ...live.release,
                  assets: [live.asset, ...replacement],
                },
              };
        },
        verifyAsset: async () => {},
        updatePointer: async () => {
          writes++;
        },
      }),
    ).rejects.toThrow("release changed");
    expect(writes).toBe(0);
  }
});

test("pointer publication reads reject wrong immutable bytes and signed revision mismatches", async () => {
  const live = current();
  for (const change of [
    { sha256: "a".repeat(64) },
    { revision: 2, assetName: candidate },
  ]) {
    const pointer = { ...live.pointer, ...change };
    await expect(
      publicationPlanningState({
        publicKey: rawKey,
        readCatalog: () =>
          readPublicationCatalog("synthetic/fixture", "catalog", {
            loadRelease: () => ({
              ...live.release,
              body: JSON.stringify(pointer),
              assets: [{ ...live.asset, name: pointer.assetName }],
            }),
            downloadAsset: async (options) => {
              writeFileSync(options.destination, live.data);
            },
          }),
      }),
    ).rejects.toThrow();
  }
});

import { expect, test } from "bun:test";
import { createHash } from "node:crypto";
import { mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import {
  loadManagedViewReview,
  validateManagedViewProof,
  validateManagedViewReview,
} from "./hosted-managed-views/contract.mjs";

const review = JSON.parse(
  await readFile("Tests/HostedManagedViews/routes.json", "utf8"),
);
const definitions = JSON.parse(
  await readFile("Extensions/manifest.json", "utf8"),
);

test("all39 original routes have exact current effect-reviewed source pins", async () => {
  expect(await loadManagedViewReview(process.cwd())).toEqual(review);
});

async function withSyntheticReview(check) {
  const root = await mkdtemp(join(tmpdir(), "managed-view-review-"));
  try {
    const value = structuredClone(review);
    value.reviewedSource = "a".repeat(40);
    const sources = [];
    for (const owner of value.owners) {
      owner.effects =
        "Synthetic byte-only source fixture with no executable feature actions.";
      for (const source of owner.sources) {
        const bytes = Buffer.concat([
          Buffer.from(`synthetic ${owner.id} ${sources.length}\r\n`),
          Buffer.from([0, 0xff, 0xfe, 0x0a]),
        ]);
        source.sha256 = createHash("sha256").update(bytes).digest("hex");
        const path = join(root, source.path);
        await mkdir(dirname(path), { recursive: true });
        await writeFile(path, bytes);
        sources.push({ path, bytes, owner: owner.id });
      }
    }
    const route = join(root, "Tests/HostedManagedViews/routes.json");
    await mkdir(dirname(route), { recursive: true });
    await writeFile(route, JSON.stringify(value));
    await writeFile(
      join(root, "Extensions/manifest.json"),
      JSON.stringify(value.owners.map(({ id }) => ({ id }))),
    );
    await check({ root, value, sources });
  } finally {
    await rm(root, { recursive: true, force: true });
  }
}

test("each source pin rejects a same-size byte change and accepts exact restoration", async () => {
  await withSyntheticReview(async ({ root, value, sources }) => {
    expect(await loadManagedViewReview(root)).toEqual(value);
    for (const { path, bytes, owner } of sources) {
      const changed = Buffer.from(bytes);
      changed[changed.length - 2] ^= 1;
      await writeFile(path, changed);
      await expect(loadManagedViewReview(root)).rejects.toThrow(
        `The ${owner} managed view source requires renewed effect review`,
      );
      await writeFile(path, bytes);
      expect(await loadManagedViewReview(root)).toEqual(value);
    }
  });
});

test("source pins reject line-ending normalization and trailing bytes", async () => {
  await withSyntheticReview(async ({ root, sources }) => {
    const { path, bytes, owner } = sources[0];
    const carriageReturn = bytes.indexOf(0x0d);
    const normalized = Buffer.concat([
      bytes.subarray(0, carriageReturn),
      bytes.subarray(carriageReturn + 1),
    ]);
    for (const changed of [
      normalized,
      Buffer.concat([bytes, Buffer.from([0])]),
    ]) {
      await writeFile(path, changed);
      await expect(loadManagedViewReview(root)).rejects.toThrow(
        `The ${owner} managed view source requires renewed effect review`,
      );
    }
  });
});

test("a missing final source fails closed without returning a partial review", async () => {
  await withSyntheticReview(async ({ root, sources }) => {
    await rm(sources.at(-1).path);
    await expect(loadManagedViewReview(root)).rejects.toThrow("ENOENT");
  });
});

test("unknown, duplicate and missing owners fail closed rather than skipping views", () => {
  for (const mutate of [
    (value) => value.owners.pop(),
    (value) => {
      value.owners[0].id = "unknown";
    },
    (value) => {
      value.owners[0] = value.owners[1];
    },
  ]) {
    const value = structuredClone(review);
    mutate(value);
    expect(() => validateManagedViewReview(value, definitions)).toThrow();
  }
});

test("notch panel, visible terminal and hidden factory qualifications are rejected", () => {
  for (const [id, change] of [
    ["notchShelf", { location: "notch", section: "panel.1" }],
    ["terminal", { visible: true }],
    ["attention", { uiOnly: true }],
    ["quinjet", { scope: "settings-read-only" }],
    ["plugins", { factoryOverlay: false }],
    ["calendar", { factoryOverlay: true }],
    ["studio", { functionalActionsValidated: true }],
    [
      "music",
      {
        sources: [
          { path: "Extensions/music/../Runtime.swift", sha256: "a".repeat(64) },
        ],
      },
    ],
  ]) {
    const value = structuredClone(review);
    Object.assign(
      value.owners.find((owner) => owner.id === id),
      change,
    );
    expect(() => validateManagedViewReview(value, definitions)).toThrow();
  }
});

function proof(owner) {
  return {
    schema: 1,
    outcome: "passed",
    extensionID: owner.id,
    selectedVersion: "1.0.0",
    hostABI: "worker-2",
    location: owner.location,
    section: owner.section,
    factoryOverlay: owner.factoryOverlay,
    functionalActionsValidated: false,
    productionExecutableUnchangedProof: false,
    visible: false,
    managedNativeViewValidated: true,
    publicCarrierCheckIn: true,
    freshSceneGeneration: true,
    lastCloseExited: true,
    disableExitedBothRoles: true,
    packageLeaseReleased: true,
    noVisibleWindows: true,
    disabledProcesses: 0,
    presentations: 2,
    featurePayloadUnchanged: !owner.factoryOverlay,
  };
}

test("creation proof requires actual close, reopen, dual-role exit and package release", () => {
  const owner = review.owners.find(({ id }) => id === "calendar");
  const package_ = { version: "1.0.0", hostABI: "worker-2" };
  expect(validateManagedViewProof(proof(owner), owner, package_).outcome).toBe(
    "passed",
  );
  for (const key of [
    "managedNativeViewValidated",
    "publicCarrierCheckIn",
    "freshSceneGeneration",
    "lastCloseExited",
    "disableExitedBothRoles",
    "packageLeaseReleased",
    "noVisibleWindows",
  ])
    expect(() =>
      validateManagedViewProof(
        { ...proof(owner), [key]: false },
        owner,
        package_,
      ),
    ).toThrow();
  for (const change of [
    { outcome: "skipped" },
    { disabledProcesses: 1 },
    { presentations: 1 },
    { functionalActionsValidated: true },
    { selectedVersion: "0.9.0" },
    { featurePayloadUnchanged: false },
  ])
    expect(() =>
      validateManagedViewProof({ ...proof(owner), ...change }, owner, package_),
    ).toThrow();
});

test("factory overlay proof cannot be mislabeled identical shipping payload", () => {
  const owner = review.owners.find(({ id }) => id === "studio");
  const package_ = { version: "1.0.0", hostABI: "worker-2" };
  expect(
    validateManagedViewProof(proof(owner), owner, package_).factoryOverlay,
  ).toBe(true);
  expect(() =>
    validateManagedViewProof(
      { ...proof(owner), featurePayloadUnchanged: true },
      owner,
      package_,
    ),
  ).toThrow();
});

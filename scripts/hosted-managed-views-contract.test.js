import { expect, test } from "bun:test";
import { readFile } from "node:fs/promises";
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

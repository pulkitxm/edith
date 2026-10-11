import { expect, test } from "bun:test";
import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import {
  mkdir,
  mkdtemp,
  readFile,
  readdir,
  rm,
  writeFile,
} from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import {
  assertValidationContext,
  assertValidationExtensions,
  definitionSupportInputs,
  extensionFingerprint,
  planPullRequestBuilds,
  planUnpublishedExtensions,
  supportCacheFingerprint,
  validationExtensionIDs,
} from "./extension-release-plan.mjs";

const sourceSHA = "a".repeat(40);
const manifest = JSON.parse(await readFile("Extensions/manifest.json", "utf8"));
const definitions = manifest.map((entry) => ({
  id: entry.id,
  version: entry.version,
  hostABI: entry.hostABI,
  dependencies: entry.dependencies,
  supportProduct: entry.supportProduct,
  inputs: [`Extensions/${entry.id}`],
  sharedInputs: [],
}));
const planner = resolve("scripts/extension-release-plan.mjs");

function environment(changes = {}) {
  return {
    ...process.env,
    EXTENSION_VALIDATION_SHA: sourceSHA,
    EXTENSION_PUBLISH: "false",
    GITHUB_EVENT_NAME: "workflow_dispatch",
    GITHUB_SHA: sourceSHA,
    GITHUB_REPOSITORY: "pulkitxm/edith",
    GITHUB_ACTOR_ID: "65671483",
    GITHUB_REF: "refs/heads/feat/extension-marketplace",
    ...changes,
  };
}

async function snapshot(root) {
  const files = {};
  async function visit(path) {
    for (const entry of await readdir(join(root, path), {
      withFileTypes: true,
    })) {
      const child = join(path, entry.name);
      if (entry.isDirectory()) await visit(child);
      else
        files[child] = createHash("sha256")
          .update(await readFile(join(root, child)))
          .digest("hex");
    }
  }
  await visit("");
  return files;
}

async function fixture(run) {
  const directory = await mkdtemp(join(tmpdir(), "extension-all-validation-"));
  const root = join(directory, "source");
  const binary = join(directory, "bin");
  const trace = join(directory, "trace.jsonl");
  try {
    await mkdir(root);
    await mkdir(binary);
    await writeFile(trace, "");
    for (const definition of definitions) {
      await mkdir(join(root, definition.inputs[0]), { recursive: true });
      await writeFile(
        join(root, definition.inputs[0], "Runtime.swift"),
        `synthetic ${definition.id}`,
      );
    }
    for (const path of new Set(definitions.flatMap(definitionSupportInputs))) {
      if (path.endsWith(".txt")) {
        await mkdir(join(root, path, ".."), { recursive: true });
        await writeFile(join(root, path), "synthetic license");
      } else {
        await mkdir(join(root, path), { recursive: true });
        await writeFile(join(root, path, "Support.swift"), "synthetic support");
      }
    }
    await mkdir(join(root, "scripts"));
    await writeFile(
      join(root, "scripts/build-extension-support.mjs"),
      "synthetic build input",
    );
    await writeFile(
      join(root, "Extensions/manifest.json"),
      JSON.stringify(definitions),
    );
    await writeFile(
      join(binary, "git"),
      `#!/usr/bin/env node
const fs = require("node:fs");
const args = process.argv.slice(2);
fs.appendFileSync(process.env.SYNTHETIC_TRACE, JSON.stringify(["git", ...args]) + "\\n");
if (JSON.stringify(args) === JSON.stringify(["rev-parse", "--verify", "HEAD^{commit}"])) process.stdout.write(process.env.SYNTHETIC_HEAD);
else if (JSON.stringify(args) === JSON.stringify(["status", "--porcelain=v1", "--untracked-files=all"])) {
  const calls = fs.readFileSync(process.env.SYNTHETIC_TRACE, "utf8").trim().split("\\n").length;
  process.stdout.write(process.env.SYNTHETIC_DIRTY || (process.env.SYNTHETIC_LATE_DIRTY && calls >= 6 ? " M Extensions/manifest.json\\n" : ""));
} else process.exit(91);
`,
      { mode: 0o700 },
    );
    for (const command of [
      "swift",
      "xcrun",
      "xcodebuild",
      "make",
      "ed",
      "open",
      "security",
      "defaults",
      "gh",
      "pukbot",
      "codesign",
    ]) {
      await writeFile(
        join(binary, command),
        `#!/usr/bin/env node
require("node:fs").appendFileSync(process.env.SYNTHETIC_TRACE, JSON.stringify([${JSON.stringify(command)}]) + "\\n");
process.exit(92);
`,
        { mode: 0o700 },
      );
    }
    const settings = environment({
      PATH: `${binary}:${process.env.PATH}`,
      SYNTHETIC_TRACE: trace,
      SYNTHETIC_HEAD: sourceSHA,
    });
    const invoke = (arguments_ = ["--validate-all", sourceSHA], changes = {}) =>
      spawnSync(process.execPath, [planner, ...arguments_], {
        cwd: root,
        env: { ...settings, ...changes },
        encoding: "utf8",
        timeout: 30_000,
      });
    await run({ root, trace, invoke, settings });
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
}

test("validation closes selection to the current exact 39 unique manifest IDs", () => {
  expect(manifest).toHaveLength(39);
  expect(new Set(validationExtensionIDs).size).toBe(39);
  expect(manifest.map(({ id }) => id).sort()).toEqual(
    [...validationExtensionIDs].sort(),
  );
  expect(() => assertValidationExtensions(manifest)).not.toThrow();
  for (const invalid of [
    manifest.slice(1),
    [...manifest, manifest[0]],
    [manifest[0], ...manifest.slice(0, -1)],
    [...manifest.slice(0, -1), { id: "unexpected" }],
  ])
    expect(() => assertValidationExtensions(invalid)).toThrow("exact 39");
});

test("validation admits only exact immutable source and authorized nonpublishing dispatch context", () => {
  for (const GITHUB_REF of [
    "refs/heads/main",
    "refs/heads/feat/extension-marketplace",
  ])
    for (const GITHUB_ACTOR_ID of ["65671483", "320458784"])
      expect(() =>
        assertValidationContext(
          sourceSHA,
          environment({ GITHUB_REF, GITHUB_ACTOR_ID }),
        ),
      ).not.toThrow();
  for (const validationSHA of [
    "",
    "a".repeat(39),
    "a".repeat(41),
    "A".repeat(40),
    "g".repeat(40),
    `${sourceSHA}\n`,
    "main",
    undefined,
  ])
    expect(() => assertValidationContext(validationSHA, environment())).toThrow(
      "authorized nonpublishing",
    );
  for (const changes of [
    { EXTENSION_VALIDATION_SHA: "b".repeat(40) },
    { GITHUB_SHA: "b".repeat(40) },
    { GITHUB_SHA: undefined },
    { GITHUB_EVENT_NAME: "push" },
    { GITHUB_EVENT_NAME: "pull_request" },
    { GITHUB_EVENT_NAME: "workflow_run" },
    { EXTENSION_PUBLISH: "true" },
    { EXTENSION_PUBLISH: "" },
    { EXTENSION_PUBLISH: undefined },
    { EXTENSION_PUBLISH: false },
    { GITHUB_REPOSITORY: "synthetic/edith" },
    { GITHUB_ACTOR_ID: "1" },
    { GITHUB_ACTOR_ID: undefined },
    { GITHUB_REF: "refs/heads/fix/all-extension-validation" },
    { GITHUB_REF: "refs/tags/main" },
    { GITHUB_REF: undefined },
  ])
    expect(() =>
      assertValidationContext(sourceSHA, environment(changes)),
    ).toThrow("authorized nonpublishing");
});

test("repeat validation includes unchanged published owners with current versions and exact support fingerprints without catalog reads or source writes", async () => {
  await fixture(async ({ root, trace, invoke }) => {
    const before = await snapshot(root);
    const expected = await planUnpublishedExtensions(root, definitions, []);
    const published = expected.map((entry) => ({
      id: entry.id,
      version: "9.0.0",
      architecture: "arm64",
      hostABI: definitions.find(({ id }) => id === entry.id).hostABI,
      sourceFingerprint: entry.fingerprint,
    }));
    expect(
      await planUnpublishedExtensions(root, definitions, published),
    ).toEqual([]);
    for (let repeat = 0; repeat < 2; repeat++) {
      const result = invoke();
      expect(result.status).toBe(0);
      const plan = JSON.parse(result.stdout);
      expect(plan).toEqual({
        include: expected,
        mode: "validation",
        sourceSHA,
      });
      expect(plan.include).toHaveLength(39);
      for (const entry of plan.include) {
        const definition = definitions.find(({ id }) => id === entry.id);
        expect(entry.version).toBe(definition.version);
        expect(entry.fingerprint).toBe(
          await extensionFingerprint(root, definition, definitions),
        );
        expect(entry.supportFingerprint).toBe(
          await supportCacheFingerprint(root, definition),
        );
      }
    }
    expect(await snapshot(root)).toEqual(before);
    const calls = (await readFile(trace, "utf8"))
      .trim()
      .split("\n")
      .map(JSON.parse);
    expect(calls).toHaveLength(12);
    expect(calls.every(([command]) => command === "git")).toBe(true);
  });
});

test("ordinary selective release and PR planning remain unchanged for published and changed source", async () => {
  await fixture(async ({ root }) => {
    const initial = await planUnpublishedExtensions(root, definitions, []);
    const published = initial.map((entry) => ({
      id: entry.id,
      version: "9.0.0",
      hostABI: definitions.find(({ id }) => id === entry.id).hostABI,
      architecture: "arm64",
      sourceFingerprint: entry.fingerprint,
    }));
    expect(
      await planUnpublishedExtensions(root, definitions, published),
    ).toEqual([]);
    expect(planPullRequestBuilds(definitions, [], definitions)).toEqual([]);
    await writeFile(
      join(root, "Extensions/calendar/Runtime.swift"),
      "changed synthetic calendar",
    );
    const selective = await planUnpublishedExtensions(
      root,
      definitions,
      published,
    );
    expect(selective.map(({ id, version }) => ({ id, version }))).toEqual([
      { id: "calendar", version: "9.0.1" },
    ]);
    expect(
      planPullRequestBuilds(
        definitions,
        ["Extensions/calendar/Runtime.swift"],
        definitions,
      ).map(({ id }) => id),
    ).toEqual(["calendar"]);
  });
});

test("the validation CLI rejects stale dirty and contradictory admission before native execution or writes", async () => {
  await fixture(async ({ root, trace, invoke }) => {
    const before = await snapshot(root);
    for (const changes of [
      { SYNTHETIC_HEAD: "b".repeat(40) },
      { SYNTHETIC_DIRTY: " M Extensions/calendar/Runtime.swift\n" },
      { SYNTHETIC_DIRTY: "?? untracked.txt\n" },
      { EXTENSION_PUBLISH: "true" },
      { GITHUB_REPOSITORY: "synthetic/edith" },
      { GITHUB_ACTOR_ID: "1" },
      { GITHUB_REF: "refs/heads/feature" },
      { GITHUB_EVENT_NAME: "push" },
      { GITHUB_SHA: "b".repeat(40) },
    ]) {
      const result = invoke(undefined, changes);
      expect(result.status).not.toBe(0);
      expect(result.stdout).toBe("");
    }
    for (const arguments_ of [
      ["--validate-all", "invalid"],
      ["--validate-all"],
      ["--validate-all", sourceSHA, "extra"],
      ["previous.json"],
      ["--pull-request-base", sourceSHA],
    ]) {
      expect(invoke(arguments_).status).not.toBe(0);
    }
    expect(invoke(["--check-validation-source", sourceSHA]).status).toBe(0);
    await writeFile(trace, "");
    const changedDuringPlanning = invoke(undefined, {
      SYNTHETIC_LATE_DIRTY: "1",
    });
    expect(changedDuringPlanning.status).not.toBe(0);
    expect(changedDuringPlanning.stderr).toContain("exact clean source HEAD");
    expect(changedDuringPlanning.stdout).toBe("");
    expect(await snapshot(root)).toEqual(before);
    const calls = (await readFile(trace, "utf8"))
      .trim()
      .split("\n")
      .map(JSON.parse);
    expect(calls.every(([command]) => command === "git")).toBe(true);
  });
});

test("the validation CLI refuses missing duplicate and substituted manifests", async () => {
  await fixture(async ({ root, invoke }) => {
    for (const invalid of [
      definitions.slice(1),
      [...definitions.slice(0, -1), definitions[0]],
      [
        ...definitions.slice(0, -1),
        { ...definitions.at(-1), id: "unexpected" },
      ],
    ]) {
      await writeFile(
        join(root, "Extensions/manifest.json"),
        JSON.stringify(invalid),
      );
      const result = invoke();
      expect(result.status).not.toBe(0);
      expect(result.stderr).toContain("exact 39 manifest IDs");
      expect(result.stdout).toBe("");
    }
  });
});

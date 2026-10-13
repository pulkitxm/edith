import { test } from "bun:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import {
  mkdirSync,
  mkdtempSync,
  readFileSync,
  realpathSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { parse } from "@babel/parser";
import { sanitizeProductionResult } from "./production-summary.mjs";

const source = "a".repeat(40);
const synthetic = () => ({
  schema: 1,
  source,
  application: "/Applications/Edith.app",
  hostSources: ["b".repeat(40), "c".repeat(40)],
  receipts: [
    {
      stage: "host-A-normal-launch",
      observed: {
        pid: 400,
        accountHome: "/Users/synthetic",
        secret: "synthetic-only",
        rawError: "synthetic-private",
      },
    },
  ],
  completed: false,
  primaryFailed: true,
  cleanupFailed: false,
  artifactVerificationExecuted: true,
  nativeUIExecuted: false,
  productionCompatibilityValidated: false,
  publicReleaseValidated: false,
  pending: ["synthetic-private"],
});
test("public projection discards actual observer rows private paths errors and arbitrary payloads", () => {
  const result = sanitizeProductionResult(synthetic(), source);
  const bytes = JSON.stringify(result);
  for (const text of [
    "pid",
    "accountHome",
    "/Users/",
    "secret",
    "rawError",
    "synthetic-private",
    "synthetic-only",
  ])
    assert(!bytes.includes(text));
  assert.equal(result.completed, false);
  assert.equal(result.primaryFailed, true);
  assert.equal(result.productionCompatibilityValidated, false);
});
test("projection rejects invented success without every exact observation and terminal cleanup", () => {
  for (const edit of [
    { completed: true },
    { productionCompatibilityValidated: true },
    { publicReleaseValidated: true },
    { source: "d".repeat(40) },
    { receipts: [{ stage: "unknown", observed: {} }] },
    { receipts: [...synthetic().receipts, ...synthetic().receipts] },
    { extra: "unadmitted" },
  ])
    assert.throws(() =>
      sanitizeProductionResult({ ...synthetic(), ...edit }, source),
    );
});

test("actual summary CLI binds the admitted source and writes only sanitized synthetic observations", () => {
  const module = fileURLToPath(
    new URL("./production-summary.mjs", import.meta.url),
  );
  for (const expected of [source, "d".repeat(40), undefined]) {
    const directory = mkdtempSync(
      join(realpathSync(tmpdir()), "production-summary-synthetic-"),
    );
    const output = join(directory, "local/public-host-cohort");
    mkdirSync(output, { recursive: true, mode: 0o700 });
    writeFileSync(
      join(output, "execution-result.json"),
      JSON.stringify(synthetic()),
      { mode: 0o600 },
    );
    try {
      const environment = {
        PATH: process.env.PATH,
        HOME: directory,
        TMPDIR: directory,
      };
      if (expected !== undefined) environment.EXPECTED_SOURCE_SHA = expected;
      const result = spawnSync(process.execPath, [module], {
        cwd: directory,
        env: environment,
        timeout: 60000,
        encoding: "utf8",
      });
      if (expected === source) {
        assert.equal(result.status, 0, result.stderr);
        const summary = JSON.parse(readFileSync(join(output, "summary.json")));
        assert.deepEqual(
          summary,
          sanitizeProductionResult(synthetic(), source),
        );
        assert.equal(summary.completed, false);
        assert.equal(summary.publicReleaseValidated, false);
      } else {
        assert.notEqual(result.status, 0);
        assert.throws(() => readFileSync(join(output, "summary.json")), {
          code: "ENOENT",
        });
      }
    } finally {
      rmSync(directory, { recursive: true });
    }
  }
});

function executorStages() {
  const source = readFileSync(
    new URL("./production-update.mjs", import.meta.url),
    "utf8",
  );
  const body = parse(source, { sourceType: "module" }).program.body;
  const executor = body.find(
    (node) =>
      node.type === "ExportNamedDeclaration" &&
      node.declaration?.id?.name === "executeProductionUpdate",
  ).declaration;
  const stages = [];
  const visit = (node) => {
    if (!node || typeof node !== "object") return;
    if (
      node.type === "CallExpression" &&
      node.callee.type === "Identifier" &&
      node.callee.name === "record"
    ) {
      assert.equal(node.arguments[0].type, "StringLiteral");
      stages.push(node.arguments[0].value);
    }
    for (const value of Object.values(node)) {
      if (Array.isArray(value)) value.forEach(visit);
      else if (value && typeof value === "object") visit(value);
    }
  };
  visit(executor.body);
  return stages;
}

test("the actual executor stage sequence is accepted only with complete observations and feed restoration", () => {
  const stages = executorStages();
  assert.equal(stages.length, 9);
  assert.equal(stages[0], "update-feed-route");
  assert.equal(stages.at(-1), "update-feed-restoration");
  const result = {
    ...synthetic(),
    completed: true,
    primaryFailed: false,
    nativeUIExecuted: true,
    receipts: stages.map((stage) => ({
      stage,
      observed: { secret: "synthetic-private" },
    })),
  };
  const summary = sanitizeProductionResult(result, source);
  assert.deepEqual(summary.observedStages, stages);
  assert.equal(summary.completed, true);
  assert.equal(summary.publicReleaseValidated, false);
  assert.equal(summary.productionCompatibilityValidated, false);
  assert(!JSON.stringify(summary).includes("synthetic-private"));
  for (const receipts of [
    result.receipts.slice(1),
    result.receipts.slice(0, -1),
    [...result.receipts.slice(1), result.receipts[0]],
    [...result.receipts, result.receipts[0]],
  ])
    assert.throws(() =>
      sanitizeProductionResult({ ...result, receipts }, source),
    );
});

test("failure after feed setup can emit bounded diagnostics without claiming a completed public update", () => {
  const result = {
    ...synthetic(),
    receipts: [
      {
        stage: executorStages()[0],
        observed: {
          accountHome: "/Users/synthetic",
          secret: "synthetic-private",
          rawError: "synthetic-error",
        },
      },
    ],
  };
  const summary = sanitizeProductionResult(result, source);
  assert.deepEqual(summary.observedStages, ["update-feed-route"]);
  assert.equal(summary.completed, false);
  assert.equal(summary.primaryFailed, true);
  for (const value of ["/Users/", "synthetic-private", "synthetic-error"])
    assert(!JSON.stringify(summary).includes(value));
});

test("actual summary CLI retains the executor's full sequence while omitting raw observations and public qualification claims", () => {
  const directory = mkdtempSync(
    join(realpathSync(tmpdir()), "production-summary-complete-"),
  );
  const output = join(directory, "local/public-host-cohort");
  mkdirSync(output, { recursive: true, mode: 0o700 });
  const value = {
    ...synthetic(),
    completed: true,
    primaryFailed: false,
    nativeUIExecuted: true,
    receipts: executorStages().map((stage) => ({
      stage,
      observed: {
        accountHome: "/Users/synthetic",
        secret: "synthetic-private",
      },
    })),
  };
  writeFileSync(join(output, "execution-result.json"), JSON.stringify(value), {
    mode: 0o600,
  });
  try {
    const result = spawnSync(
      process.execPath,
      [fileURLToPath(new URL("./production-summary.mjs", import.meta.url))],
      {
        cwd: directory,
        env: {
          PATH: process.env.PATH,
          HOME: directory,
          TMPDIR: directory,
          EXPECTED_SOURCE_SHA: source,
        },
        timeout: 60000,
        encoding: "utf8",
      },
    );
    assert.equal(result.status, 0, result.stderr);
    const bytes = readFileSync(join(output, "summary.json"), "utf8");
    assert.deepEqual(
      JSON.parse(bytes),
      sanitizeProductionResult(value, source),
    );
    assert.equal(JSON.parse(bytes).publicReleaseValidated, false);
    assert(!bytes.includes("synthetic-private"));
    assert(!bytes.includes("/Users/"));
  } finally {
    rmSync(directory, { recursive: true });
  }
});

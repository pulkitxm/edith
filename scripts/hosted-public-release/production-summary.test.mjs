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

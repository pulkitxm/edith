import { test } from "bun:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { productionPublicationBudget } from "./production-publication-budget.mjs";

test("stage, readiness, completed-host and observer preparation consume one original budget", () => {
  let elapsed = 100;
  const remaining = productionPublicationBudget({ now: () => elapsed });
  assert.equal(remaining(), 180 * 60 * 1000);
  elapsed += 20 * 60 * 1000;
  assert.equal(remaining(), 160 * 60 * 1000);
  elapsed += 120 * 60 * 1000;
  assert.equal(remaining(), 40 * 60 * 1000);
  elapsed += 35 * 60 * 1000;
  assert.equal(remaining(), 5 * 60 * 1000);
  elapsed += 5 * 60 * 1000;
  assert.throws(remaining, /expired/);
  elapsed = 100;
  assert.throws(remaining, /retired/);
});

test("malformed or backward clocks cannot extend or revive a publication", () => {
  for (const invalid of [NaN, Infinity, -1])
    assert.throws(() => productionPublicationBudget({ now: () => invalid }));
  for (const invalid of [NaN, Infinity, -1, 99]) {
    let elapsed = 100;
    const remaining = productionPublicationBudget({ now: () => elapsed });
    elapsed = invalid;
    assert.throws(remaining);
    elapsed = 100;
    assert.throws(remaining, /retired/);
  }
});

test("the final positive remainder is admitted but exact expiry is rejected before another phase", () => {
  let elapsed = 0;
  const remaining = productionPublicationBudget({ now: () => elapsed });
  elapsed = 180 * 60 * 1000 - 0.5;
  assert.equal(remaining(), 0.5);
  elapsed += 0.5;
  assert.throws(remaining, /expired/);
});

test("the coordinator starts its budget before staging and passes only remaining time to its owned observer", () => {
  const source = readFileSync(
    new URL("./production-publication-coordinator.mjs", import.meta.url),
    "utf8",
  );
  assert.equal(
    (source.match(/productionPublicationBudget\(\)/g) ?? []).length,
    1,
  );
  assert(
    source.indexOf("const remaining = productionPublicationBudget();") <
      source.indexOf('await import("../extension-publish.mjs")'),
  );
  assert(source.includes("await runObserver(text, binding, remaining)"));
  assert(!source.includes("180 * 60 * 1000"));
  assert.match(source, /setTimeout\([\s\S]*?remaining\(\)/);
  assert.match(
    source,
    /catch \(error\) \{\s*timedOut = true;\s*retire\(\);\s*await joined\.catch/,
  );
  assert(source.includes("}, 5000);"));
});

async function withOwnedObserver(action) {
  const directory = await mkdtemp(
    join(tmpdir(), "publication-observer-budget-"),
  );
  const original = fileURLToPath(
    new URL("./production-publication-coordinator.mjs", import.meta.url),
  );
  const old = {
    PUBLIC_RELEASE_VERIFICATION: process.env.PUBLIC_RELEASE_VERIFICATION,
    GITHUB_SHA: process.env.GITHUB_SHA,
  };
  let module;
  try {
    await mkdir(join(directory, "scripts/hosted-public-release"), {
      recursive: true,
      mode: 0o700,
    });
    await writeFile(
      join(
        directory,
        "scripts/hosted-public-release/production-coordinated-runner.mjs",
      ),
      "setInterval(() => {}, 1000);\n",
      { mode: 0o600 },
    );
    let source = readFileSync(original, "utf8");
    source = source.replace(
      'import { execFileSync, spawn } from "node:child_process";',
      'import { execFileSync, spawn as ownedSpawn } from "node:child_process";',
    );
    source = source.replace(
      'const root = resolve(dirname(fileURLToPath(import.meta.url)), "../..");',
      `const root = ${JSON.stringify(directory)};`,
    );
    source = source.replace(/from "(\.[^"]+)"/g, (match, relative) =>
      match.replace(
        relative,
        pathToFileURL(resolve(dirname(original), relative)).href,
      ),
    );
    source += `
export { runObserver };
export const observations = [];
const spawn = (...arguments_) => {
  const child = ownedSpawn(...arguments_);
  const observation = { child, closed: false };
  observation.joined = new Promise((resolve_) => child.once("close", () => {
    observation.closed = true;
    resolve_();
  }));
  observations.push(observation);
  return child;
};
`;
    const snapshot = join(directory, "coordinator.mjs");
    await writeFile(snapshot, source, { mode: 0o600 });
    module = await import(pathToFileURL(snapshot).href);
    process.env.PUBLIC_RELEASE_VERIFICATION = "1";
    process.env.GITHUB_SHA = "a".repeat(40);
    await action(module);
  } finally {
    for (const row of module?.observations ?? []) {
      if (
        !row.closed &&
        row.child.exitCode === null &&
        row.child.signalCode === null
      )
        row.child.kill("SIGTERM");
      await row.joined;
    }
    for (const [key, value] of Object.entries(old)) {
      if (value === undefined) delete process.env[key];
      else process.env[key] = value;
    }
    await rm(directory, { recursive: true, force: true });
  }
}

function assertOwnedObserverJoined(row) {
  assert(Number.isSafeInteger(row.child.pid) && row.child.pid > 0);
  assert.equal(row.closed, true);
  assert.equal(row.child.signalCode, "SIGTERM");
  assert.equal(row.child.stdio[3].destroyed, true);
  assert.equal(row.child.stdio[4].destroyed, true);
}

test("expiry after actual child creation joins owned retirement and closes both inherited descriptors before rejection", async () => {
  await withOwnedObserver(async (module) => {
    await assert.rejects(
      module.runObserver("{}", { source: "a".repeat(40) }, () => {
        throw new Error("synthetic exhausted budget");
      }),
      /synthetic exhausted budget/,
    );
    assert.equal(module.observations.length, 1);
    assertOwnedObserverJoined(module.observations[0]);
  });
});

test("an active observer cannot retain promotion authority when its shared budget expires", async () => {
  await withOwnedObserver(async (module) => {
    let current = 0;
    const remaining = productionPublicationBudget({ now: () => current });
    const observer = await module.runObserver(
      "{}",
      { source: "a".repeat(40) },
      remaining,
    );
    try {
      assert.equal(observer.isActive(), true);
      current = 180 * 60 * 1000;
      assert.equal(observer.isActive(), false);
      await assert.rejects(observer.joined, /did not complete/);
      assert.equal(module.observations.length, 1);
      assertOwnedObserverJoined(module.observations[0]);
    } finally {
      observer.retire();
      await observer.joined.catch(() => {});
      observer.channel.close();
    }
  });
});

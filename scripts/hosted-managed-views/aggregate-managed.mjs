import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdir, readFile, realpath, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { extensionFingerprint } from "../extension-release-plan.mjs";
import { readManagedChunkArtifacts } from "./chunk-intake.mjs";
import { aggregateManagedChunks } from "./chunks.mjs";
import { loadManagedViewReview } from "./contract.mjs";
import {
  admitManagedExecution,
  managedAuthenticatedFetch,
  parseManagedArtifactArguments,
} from "./execution-contract.mjs";
import { prepareFrozenHost } from "./frozen-host.mjs";
import {
  downloadCIArtifact,
  readCIArtifactSet,
} from "./package-preparation.mjs";

const root = await realpath(process.cwd());
const sourceCommit = execFileSync("git", ["rev-parse", "HEAD"], {
  encoding: "utf8",
}).trim();
admitManagedExecution(process.env, sourceCommit);
assert.equal(process.platform, "darwin");
assert.equal(process.arch, "arm64");
const options = parseManagedArtifactArguments(process.argv.slice(2));
assert.match(process.env.GITHUB_RUN_ID, /^[1-9][0-9]{0,15}$/);
const runID = Number(process.env.GITHUB_RUN_ID);
assert(Number.isSafeInteger(runID));
const fetch_ = managedAuthenticatedFetch(process.env, fetch);
const output = join(root, "local/hosted-managed-aggregate");
await mkdir(output, { mode: 0o700 });
assert.equal(await realpath(output), output);
let result = {
  schema: 1,
  outcome: "failed",
  all39Validated: false,
  fixtureSourceCommit: sourceCommit,
  originalSourceCommit: options.artifactSource,
};
try {
  const review = await loadManagedViewReview(root);
  const definitions = JSON.parse(
    await readFile(join(root, "Extensions/manifest.json")),
  );
  const fingerprints = {};
  for (const definition of definitions)
    fingerprints[definition.id] = await extensionFingerprint(
      root,
      definition,
      definitions,
    );
  const frozen = await prepareFrozenHost({
    runID: options.runID,
    sourceCommit: options.artifactSource,
    output,
    fetch: fetch_,
  });
  const originals = await readCIArtifactSet({
    repository: "pulkitxm/edith",
    runID: options.runID,
    sourceCommit: options.artifactSource,
    definitions,
    fingerprints,
    fetch: fetch_,
  });
  const digest = (value) =>
    createHash("sha256").update(JSON.stringify(value)).digest("hex");
  const bindings = {
    fixtureSourceCommit: sourceCommit,
    originalSourceCommit: options.artifactSource,
    originalCIRun: options.runID,
    managedWorkflowRun: runID,
    reviewSHA256: digest(review),
    fingerprintMapSHA256: digest(Object.entries(fingerprints).sort()),
    frozenHostArtifactSHA256: frozen.artifactSHA256,
    frozenHostExecutableSHA256: frozen.hostSHA256,
    originalArtifactSetSHA256: digest(originals.originals),
  };
  const assets = await readManagedChunkArtifacts({
    fetch: fetch_,
    runID,
    sourceCommit,
  });
  const chunks = [];
  for (const row of assets) {
    const archive = join(output, `chunk-${row.chunk}.zip`);
    await downloadCIArtifact({
      repository: "pulkitxm/edith",
      row,
      destination: archive,
      fetch: fetch_,
      totalMilliseconds: 60000,
    });
    const chunk = JSON.parse(
      execFileSync(
        "python3",
        [join(root, "scripts/hosted-managed-views/chunk-artifact.py"), archive],
        { timeout: 30000, maxBuffer: 4 * 1024 ** 2 },
      ).toString(),
    );
    assert.equal(chunk.chunk, row.chunk);
    chunks.push(chunk);
  }
  result = {
    ...aggregateManagedChunks(chunks, review, bindings),
    chunkArtifacts: assets,
  };
} catch (error) {
  result.category = error.name;
  throw error;
} finally {
  await writeFile(
    join(output, "result.json"),
    JSON.stringify(result, null, 2),
    { flag: "wx", mode: 0o600 },
  );
}
console.log(
  JSON.stringify({
    outcome: result.outcome,
    owners: result.owners,
    all39Validated: result.all39Validated,
    functionalActionsValidated: false,
    sourceCommit,
  }),
);

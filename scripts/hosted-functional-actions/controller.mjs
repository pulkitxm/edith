import assert from "node:assert/strict";
import { execFileSync, spawn } from "node:child_process";
import { createHash, randomUUID } from "node:crypto";
import { lstat, mkdir, readFile, realpath, writeFile } from "node:fs/promises";
import { join, resolve } from "node:path";
import { pathToFileURL } from "node:url";
import { parse } from "@babel/parser";
import { loadAllFunctionalActionCases } from "./case-loader.mjs";
import {
  functionalCanonicalJSON,
  functionalDigest,
  validateFunctionalActionProof,
  validateFunctionalCapability,
  verifyFunctionalEnvelope,
} from "./contract.mjs";
import {
  functionalActionCasePaths,
  functionalActionOwners,
  validateFunctionalOwnerInventory,
} from "./owners.mjs";
import {
  installedPresentationID,
  loadInstalledPresentationRecipe,
} from "./presentation.mjs";
import { prepareFunctionalOwnerPair } from "./prepare-owner.mjs";
import {
  admitFunctionalRunner,
  requireFunctionalPrivateDirectory,
  verifyFunctionalSourcePins,
} from "./producer-project.mjs";

const hash = (bytes) => createHash("sha256").update(bytes).digest("hex");
const phases = Object.freeze(["initial", "updated", "reinstalled"]);

export const functionalPresentationID = installedPresentationID;

export function functionalJourneyPlan(
  cases,
  recipes,
  sourceCommit,
  concurrency = 1,
) {
  assert.match(sourceCommit, /^[0-9a-f]{40}$/);
  assert(
    Number.isSafeInteger(concurrency) && concurrency >= 1 && concurrency <= 3,
  );
  validateFunctionalOwnerInventory(
    cases.map(({ definition }) => ({ id: definition.owner })),
  );
  assert.deepEqual(
    Object.keys(recipes).sort(),
    [...functionalActionOwners].sort(),
  );
  for (const item of cases) {
    assert.equal(item.sourceCommit, sourceCommit);
    assert.equal(
      recipes[item.definition.owner].recipe.owner,
      item.definition.owner,
    );
  }
  return Object.freeze({
    sourceCommit,
    concurrency,
    pairScope: "synthetic-development",
    owners: Object.freeze(
      functionalActionOwners.map((owner) =>
        Object.freeze({
          owner,
          definition: cases.find((item) => item.definition.owner === owner)
            .definition,
          recipe: recipes[owner].recipe,
          phases: Object.freeze(
            phases.map((phase) =>
              Object.freeze({
                phase,
                version: phase === "initial" ? "1.0.0" : "1.1.0",
              }),
            ),
          ),
        }),
      ),
    ),
  });
}

function activationPins(bytes) {
  const tree = parse(bytes.toString("utf8"), { sourceType: "module" });
  assert.equal(tree.program.body.length, 1);
  const object = tree.program.body[0].declaration?.declarations?.[0]?.init;
  const property = (node, name) => {
    assert.equal(node?.type, "ObjectExpression");
    const matches = node.properties.filter(
      (item) =>
        item.type === "ObjectProperty" &&
        !item.computed &&
        (item.key.name ?? item.key.value) === name,
    );
    assert.equal(matches.length, 1);
    return matches[0].value;
  };
  const sources = property(property(object, "activation"), "sources");
  assert.equal(sources.type, "ArrayExpression");
  return sources.elements.map((element) => {
    const path = property(element, "path"),
      sha256 = property(element, "sha256");
    assert.equal(path.type, "StringLiteral");
    assert.equal(sha256.type, "StringLiteral");
    return { path: path.value, sha256: sha256.value };
  });
}

export async function admitFunctionalSources(
  repository,
  sourceCommit,
  execute = execFileSync,
) {
  assert.match(sourceCommit, /^[0-9a-f]{40}$/);
  assert.equal(await realpath(repository), repository);
  const git = (args) =>
    execute("git", args, { cwd: repository, maxBuffer: 268_435_456 });
  assert.equal(git(["rev-parse", "HEAD"]).toString().trim(), sourceCommit);
  assert.equal(
    git(["status", "--porcelain", "--untracked-files=no"]).length,
    0,
  );
  const files = git(["ls-tree", "-r", "--name-only", "-z", sourceCommit])
    .toString()
    .split("\0")
    .filter(Boolean);
  const pins = [];
  for (const path of files) {
    const sourceBytes = git(["show", `${sourceCommit}:${path}`]);
    const current = await readFile(join(repository, path));
    assert(current.equals(sourceBytes), `Source snapshot changed ${path}`);
    pins.push({ path, sha256: hash(sourceBytes) });
  }
  const sourcePins = Object.freeze({ sourceCommit, files: pins });
  const snapshots = {};
  for (const owner of functionalActionOwners) {
    const paths = functionalActionCasePaths(owner);
    const original = activationPins(
      await readFile(join(repository, paths.definition)),
    );
    snapshots[owner] = {
      sourceCommit,
      files: [
        paths.definition,
        paths.native,
        ...original.map((pin) => pin.path),
      ].map((path) => {
        const pin = pins.find((item) => item.path === path);
        assert(pin, `Missing required original case source ${path}`);
        return pin;
      }),
    };
  }
  const cases = await loadAllFunctionalActionCases(
    repository,
    readFile,
    snapshots,
  );
  const recipes = {};
  for (const item of cases)
    recipes[item.definition.owner] = await loadInstalledPresentationRecipe(
      repository,
      item.definition.owner,
      item.definition,
    );
  await verifyFunctionalSourcePins(repository, sourcePins);
  return Object.freeze({ sourcePins, cases, recipes });
}

export class FunctionalJourneyOrder {
  #phase = 0;
  #state = "empty";
  #baseline;
  #saved;
  #generations = new Set();
  #pids = new Set();
  #held;

  captureBaseline(bytes) {
    assert(["empty", "drained", "removed"].includes(this.#state));
    assert.equal(this.#phase === 2, this.#state === "removed");
    assert(Buffer.isBuffer(bytes) || bytes === null);
    if (this.#phase > 0)
      assert.deepEqual(
        bytes,
        this.#saved,
        "Saved state must survive before construction",
      );
    this.#baseline = bytes === null ? null : Buffer.from(bytes);
    this.#state = "baseline";
  }

  hold(capability, definition) {
    assert.equal(this.#state, "baseline");
    validateFunctionalCapability(capability, definition);
    assert.equal(capability.phase, phases[this.#phase]);
    assert.equal(
      capability.dataDirectory,
      `${capability.fixtureRoot}/Edith Tests/worker-${capability.session}/Data/${capability.owner}`,
    );
    for (const birth of [capability.engine, capability.ui]) {
      const identity = `${birth.pid}:${birth.birthSeconds}:${birth.birthMicroseconds}`;
      assert(!this.#generations.has(identity), "Retired generation reused");
      assert(!this.#pids.has(birth.pid), "Retired PID reused");
      this.#generations.add(identity);
      this.#pids.add(birth.pid);
    }
    this.#held = capability;
    this.#state = "held";
    return Object.freeze({
      baseline: this.#baseline === null ? null : Buffer.from(this.#baseline),
      presentationID: functionalPresentationID(capability),
      capabilitySHA256: functionalDigest(capability),
    });
  }

  completeSaved(bytes) {
    assert.equal(this.#state, "held");
    assert(Buffer.isBuffer(bytes) || bytes === null);
    if (this.#phase === 0)
      this.#saved = bytes === null ? null : Buffer.from(bytes);
    else
      assert.deepEqual(
        bytes,
        this.#saved,
        "Original final restore must preserve saved state",
      );
    this.#state = "observed";
  }

  drain(receipt) {
    assert.equal(this.#state, "observed");
    assert.deepEqual(receipt.births, [this.#held.engine, this.#held.ui]);
    assert.equal(receipt.allTasksJoined, true);
    assert.equal(receipt.birthsAbsent, true);
    assert.equal(receipt.leasesReleased, true);
    assert.equal(receipt.signalsSent, 0);
    this.#held = undefined;
    this.#state = "drained";
    this.#phase++;
  }

  remove(receipt) {
    assert.equal(this.#phase, 2);
    assert.equal(this.#state, "drained");
    assert.deepEqual(receipt.physicallyAbsentVersions, ["1.0.0", "1.1.0"]);
    assert.equal(receipt.pendingRemoval, false);
    assert.equal(receipt.leasesReleased, true);
    assert.equal(receipt.sentinelBytesPreserved, true);
    assert.equal(receipt.semanticDataPreserved, true);
    this.#state = "removed";
  }

  finish() {
    assert.equal(this.#phase, 3);
    assert.equal(this.#state, "drained");
  }
}

export async function runFunctionalOwner({
  repository,
  sourcePins,
  ownerPlan,
  artifactBytes,
  admittedArtifact,
  policyBytes,
  admittedPolicies,
  environment,
  native,
  issuerDER,
  signal,
}) {
  for (const method of [
    "captureBeforeConstruction",
    "install",
    "prepareGeneration",
    "loadOriginal",
    "performOriginal",
    "readSaved",
    "closeAndDrain",
    "update",
    "remove",
    "reinstall",
    "sealProof",
    "cancelAndJoin",
  ])
    assert.equal(
      typeof native[method],
      "function",
      `Missing actual native boundary ${method}`,
    );
  const pair = await prepareFunctionalOwnerPair({
    repository,
    owner: ownerPlan.owner,
    artifactBytes,
    admittedArtifact,
    policyBytes,
    admittedPolicies,
    sourcePins,
    environment,
  });
  const order = new FunctionalJourneyOrder();
  const stages = [];
  const presentations = {};
  try {
    for (const [index, phase] of ownerPlan.phases.entries()) {
      signal?.throwIfAborted();
      await verifyFunctionalSourcePins(repository, sourcePins);
      const baseline = await native.captureBeforeConstruction({
        owner: ownerPlan.owner,
        phase: phase.phase,
        signal,
      });
      order.captureBaseline(baseline.bytes);
      if (index === 0) await native.install(pair.packages[0], signal);
      else if (index === 1) await native.update(pair.packages[1], signal);
      else await native.reinstall(pair.packages[1], signal);
      const generation = await native.prepareGeneration({
        ownerPlan,
        phase,
        pair,
        baseline,
        signal,
      });
      const binding = order.hold(generation.capability, ownerPlan.definition);
      assert.equal(generation.presentationID, binding.presentationID);
      presentations[phase.phase] = binding.presentationID;
      assert.equal(generation.capability.sourceCommit, sourcePins.sourceCommit);
      assert.equal(
        generation.capability.packageSHA256,
        pair.packages[index === 0 ? 0 : 1].archiveSHA256,
      );
      await native.loadOriginal({ generation, binding, baseline, signal });
      const stage = await native.performOriginal({
        generation,
        binding,
        baseline,
        recipe: ownerPlan.recipe,
        signal,
      });
      const saved = await native.readSaved({ generation, binding, signal });
      order.completeSaved(saved.bytes);
      const receipt = await native.closeAndDrain({
        generation,
        binding,
        signal,
      });
      order.drain(receipt);
      stages.push(stage);
      if (index === 1)
        order.remove(await native.remove({ pair, saved, signal }));
      await verifyFunctionalSourcePins(repository, sourcePins);
    }
    order.finish();
    const proof = await native.sealProof({
      stages,
      pair,
      definition: ownerPlan.definition,
      signal,
    });
    const result = validateFunctionalActionProof(
      proof.claim,
      ownerPlan.definition,
      proof.observation,
      issuerDER,
      undefined,
      {
        sourceCommit: sourcePins.sourceCommit,
        session: stages[0].capability.session,
        owner: ownerPlan.owner,
        caseSHA256: functionalDigest(ownerPlan.definition),
        presentations,
      },
    );
    assert.equal(result.sourceCommit, sourcePins.sourceCommit);
    return result;
  } catch (error) {
    try {
      await native.cancelAndJoin({
        reason: "controller-failure",
        timeoutMilliseconds: 30000,
      });
    } catch (cleanup) {
      throw new AggregateError(
        [error, cleanup],
        "Native failure and incomplete owned cleanup",
      );
    }
    throw error;
  }
}

export async function runFunctionalPool(
  items,
  maximum,
  execute,
  cancelAndJoin,
) {
  assert(Number.isInteger(maximum) && maximum >= 1 && maximum <= 3);
  const controller = new AbortController();
  let cursor = 0;
  const results = new Array(items.length);
  const failures = [];
  const run = async () => {
    while (!controller.signal.aborted && cursor < items.length) {
      const index = cursor++;
      try {
        results[index] = await execute(items[index], controller.signal);
      } catch (error) {
        failures.push(error);
        controller.abort(error);
      }
    }
  };
  await Promise.allSettled(
    Array.from({ length: Math.min(maximum, items.length) }, run),
  );
  if (failures.length > 0) {
    try {
      await cancelAndJoin();
    } catch (error) {
      failures.push(error);
    }
    throw new AggregateError(
      failures,
      "Functional owners failed after joined cancellation",
    );
  }
  return results;
}

export class FunctionalProducerChannel {
  #child;
  #buffer = Buffer.alloc(0);
  #pending = new Map();
  #bootstrap;
  #exited;
  #failure;
  #birth;

  constructor(child, expected) {
    this.#child = child;
    this.#exited = new Promise((resolve, reject) => {
      child.once("error", reject);
      child.once("exit", (code, signal) => {
        resolve({ code, signal });
      });
    });
    this.#bootstrap = new Promise((resolve, reject) => {
      let started = false;
      const receiveLine = (line) => {
        try {
          assert(Buffer.byteLength(line) <= 2_097_152);
          const value = JSON.parse(line);
          assert.equal(functionalCanonicalJSON(value), line);
          if (!started) {
            assert.equal(value.kind, "bootstrap");
            assert.equal(value.sourceCommit, expected.sourceCommit);
            assert.equal(value.session, expected.session);
            assert.equal(value.producer.pid, child.pid);
            assert.equal(value.producer.executable, expected.producer.path);
            assert.equal(
              value.producer.executableSHA256,
              expected.producer.executableSHA256,
            );
            assert.match(value.issuerPublicKey, /^[A-Za-z0-9+/]{43}=$/);
            this.#birth = value.producer;
            started = true;
            resolve(value);
          } else {
            const pending = this.#pending.get(value.requestID);
            assert(pending, "Uncorrelated producer response");
            assert.equal(value.operation, pending.operation);
            this.#pending.delete(value.requestID);
            pending.resolve(value);
          }
        } catch (error) {
          this.#failure = error;
          reject(error);
          this.#rejectPending(error);
        }
      };
      child.stdout.on("data", (chunk) => {
        try {
          assert(Buffer.isBuffer(chunk));
          assert(
            this.#buffer.length + chunk.length <= 2_097_152,
            "Producer output bound",
          );
          this.#buffer = Buffer.concat([this.#buffer, chunk]);
          let newline;
          while ((newline = this.#buffer.indexOf(10)) >= 0) {
            const bytes = this.#buffer.subarray(0, newline);
            this.#buffer = this.#buffer.subarray(newline + 1);
            receiveLine(
              new TextDecoder("utf-8", { fatal: true }).decode(bytes),
            );
            if (this.#failure) return;
          }
        } catch (error) {
          this.#failure = error;
          reject(error);
          this.#rejectPending(error);
        }
      });
      child.stdout.once("error", (error) => {
        this.#failure = error;
        reject(error);
        this.#rejectPending(error);
      });
      this.#exited.then(() => {
        const error = new Error("Producer exited");
        reject(error);
        this.#rejectPending(error);
      }, reject);
    });
  }

  #rejectPending(error) {
    for (const pending of this.#pending.values()) pending.reject(error);
    this.#pending.clear();
  }

  async bootstrap() {
    return this.#bounded(this.#bootstrap, "Producer bootstrap deadline");
  }

  async #bounded(promise, message) {
    let timer;
    try {
      return await Promise.race([
        promise,
        new Promise((_, reject) => {
          timer = setTimeout(() => reject(new Error(message)), 30000);
        }),
      ]);
    } finally {
      clearTimeout(timer);
    }
  }

  async closeAndJoinAfterStartupFailure() {
    assert.equal(
      this.#birth,
      undefined,
      "Admitted producer requires owned native cleanup",
    );
    this.#child.stdin.end();
    await this.#bounded(
      this.#exited,
      "Unadmitted producer did not naturally join",
    );
    this.#child.stdout.destroy();
  }

  async request(operation, fields = {}, timeoutMilliseconds = 30000) {
    assert.equal(this.#failure, undefined);
    assert(this.#pending.size < 8);
    assert(
      Number.isInteger(timeoutMilliseconds) &&
        timeoutMilliseconds > 0 &&
        timeoutMilliseconds <= 30000,
    );
    assert(
      !Object.hasOwn(fields, "operation") &&
        !Object.hasOwn(fields, "requestID"),
    );
    const requestID = randomUUID();
    let timer;
    try {
      return await new Promise((resolve, reject) => {
        timer = setTimeout(() => {
          this.#pending.delete(requestID);
          reject(new Error("Producer request deadline"));
        }, timeoutMilliseconds);
        this.#pending.set(requestID, { operation, resolve, reject });
        this.#child.stdin.write(
          `${functionalCanonicalJSON({ requestID, operation, ...fields })}\n`,
          (error) => {
            if (error) {
              this.#pending.delete(requestID);
              reject(error);
            }
          },
        );
      });
    } finally {
      clearTimeout(timer);
    }
  }

  async finish() {
    assert.equal(this.#pending.size, 0);
    await this.request("finish");
    this.#child.stdin.end();
    const result = await this.#bounded(this.#exited, "Producer join deadline");
    assert.deepEqual(result, { code: 0, signal: null });
    assert.equal(this.#buffer.length, 0, "Partial producer output on exit");
    this.#child.stdout.destroy();
  }

  get ownedBirth() {
    return this.#birth;
  }
}

export async function launchFunctionalProducer(receipt, environment) {
  admitFunctionalRunner(environment, receipt.sourceCommit);
  assert.equal(
    hash(await readFile(receipt.producer.path)),
    receipt.producer.executableSHA256,
  );
  const state = await lstat(receipt.producer.path);
  assert(
    state.isFile() && !state.isSymbolicLink() && state.uid === process.getuid(),
  );
  assert.equal(state.mode & 0o7777, 0o500);
  const child = spawn(receipt.producer.path, [], {
    env: environment,
    stdio: ["pipe", "pipe", "ignore"],
  });
  const channel = new FunctionalProducerChannel(child, receipt);
  try {
    await channel.bootstrap();
    return channel;
  } catch (error) {
    try {
      await channel.closeAndJoinAfterStartupFailure();
    } catch (cleanup) {
      throw new AggregateError(
        [error, cleanup],
        "Producer startup failed with incomplete natural cleanup",
      );
    }
    throw error;
  }
}

export function admitFunctionalBuildArtifact({
  metadata,
  run,
  job,
  sourceCommit,
  artifactSHA256,
}) {
  assert.match(sourceCommit, /^[0-9a-f]{40}$/);
  assert.match(artifactSHA256, /^[0-9a-f]{64}$/);
  assert.equal(metadata.expired, false);
  assert.equal(metadata.workflow_run.head_sha, sourceCommit);
  assert.equal(metadata.workflow_run.id, run.id);
  assert.equal(run.head_sha, sourceCommit);
  assert.equal(run.event, "workflow_dispatch");
  assert.equal(run.repository.full_name, "pulkitxm/edith");
  assert([65671483, 320458784].includes(run.actor.id));
  assert.equal(job.run_id, run.id);
  assert.equal(job.status, "completed");
  assert.equal(run.status, "completed");
  assert.equal(run.conclusion, "success");
  assert.equal(run.path, ".github/workflows/ci.yml");
  assert(!job.labels.includes("self-hosted"));
  assert.equal(job.name, "functional-build");
  assert.equal(job.conclusion, "success");
  assert(job.labels.includes("macos-26"));
  assert.equal(metadata.name, "functional-fixture-trust");
  for (const value of [metadata.id, run.id, job.id])
    assert(Number.isSafeInteger(value) && value > 0);
  return Object.freeze({
    sourceCommit,
    runID: run.id,
    jobID: job.id,
    artifactID: metadata.id,
    artifactSHA256,
  });
}

async function main() {
  assert.equal(process.platform, "darwin");
  assert.equal(process.arch, "arm64");
  const sourceCommit = process.env.EXPECTED_SOURCE_SHA;
  admitFunctionalRunner(process.env, sourceCommit);
  assert.deepEqual(process.argv.slice(2), ["--admit-source"]);
  const admitted = await admitFunctionalSources(
    await realpath(process.cwd()),
    sourceCommit,
  );
  const plan = functionalJourneyPlan(
    admitted.cases,
    admitted.recipes,
    sourceCommit,
  );
  const directory = resolve(
    process.env.RUNNER_TEMP,
    "functional-source-admission",
  );
  await mkdir(directory, { mode: 0o700 });
  await requireFunctionalPrivateDirectory(directory);
  await writeFile(
    join(directory, "source-plan.json"),
    functionalCanonicalJSON({
      schema: 1,
      sourceCommit,
      ownerCount: plan.owners.length,
      pairScope: plan.pairScope,
      sourcePins: admitted.sourcePins,
      hostedProof: false,
    }),
    { flag: "wx", mode: 0o600 },
  );
}

if (
  process.argv[1] &&
  import.meta.url === pathToFileURL(resolve(process.argv[1])).href
)
  await main();

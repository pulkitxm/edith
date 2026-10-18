import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { createHash, randomUUID } from "node:crypto";
import {
  mkdir,
  readdir,
  readFile,
  realpath,
  writeFile,
} from "node:fs/promises";
import { join, resolve } from "node:path";
import { pathToFileURL } from "node:url";
import { parse } from "@babel/parser";
import { loadAllFunctionalActionCases } from "./case-loader.mjs";
import {
  functionalCanonicalJSON,
  functionalDigest,
  validateFunctionalActionProof,
  validateFunctionalCapability,
} from "./contract.mjs";
import {
  functionalActionCasePaths,
  functionalActionOwners,
  validateFunctionalOwnerInventory,
} from "./owners.mjs";
import { prepareFunctionalOwnerPair } from "./prepare-owner.mjs";
import {
  installedPresentationID,
  installedPresentationUITestSource,
  loadInstalledPresentationRecipe,
  validateInstalledPresentationRecipe,
} from "./presentation.mjs";
import {
  admitFunctionalRunner,
  admitFunctionalSourceEnvironment,
  functionalHostProjectXML,
  functionalObservationRuleSwift,
  functionalProducerBuildForLaunch,
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
  issuerManifestBytes,
  admittedIssuer,
  compilation,
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
    issuerManifestBytes,
    admittedIssuer,
    artifactBytes,
    admittedArtifact,
    policyBytes,
    admittedPolicies,
    sourcePins,
    compilation,
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
  #stderrLength = 0;

  constructor(child, expected) {
    this.#child = child;
    this.#exited = new Promise((resolve, reject) => {
      child.once("error", reject);
      child.once("close", (code, signal) => {
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
            exactFields(value, [
              "schema",
              "kind",
              "sourceCommit",
              "session",
              "issuerPublicKey",
              "producer",
            ]);
            assert.equal(value.schema, 1);
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
          for (
            let newline = this.#buffer.indexOf(10);
            newline >= 0;
            newline = this.#buffer.indexOf(10)
          ) {
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
      child.stderr?.on("data", (chunk) => {
        this.#stderrLength += chunk.length;
        if (this.#stderrLength > 4096) {
          const error = new Error("Producer error output bound");
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
    const response = await this.request("finish");
    exactFields(response, ["requestID", "operation"]);
    this.#child.stdin.end();
    const result = await this.#bounded(this.#exited, "Producer join deadline");
    assert.deepEqual(result, { code: 0, signal: null });
    assert.equal(this.#buffer.length, 0, "Partial producer output on exit");
    assert.equal(this.#stderrLength, 0, "Producer failed on stderr");
    this.#child.stdout.destroy();
  }

  async cancelAndJoin() {
    assert.equal(this.#pending.size, 0);
    const response = await this.request("cancel");
    exactFields(response, ["requestID", "operation", "ownedCleanupComplete"]);
    assert.equal(response.ownedCleanupComplete, true);
    this.#child.stdin.end();
    const result = await this.#bounded(
      this.#exited,
      "Producer cleanup join deadline",
    );
    assert.deepEqual(result, { code: 0, signal: null });
    assert.equal(this.#buffer.length, 0, "Partial producer output on cleanup");
    assert.equal(this.#stderrLength, 0, "Producer cleanup failed on stderr");
    this.#child.stdout.destroy();
  }

  get ownedBirth() {
    return this.#birth;
  }
}

const producerChannels = new WeakMap();

export async function launchFunctionalProducer(receipt, environment) {
  admitFunctionalRunner(environment, receipt.sourceCommit);
  const built = functionalProducerBuildForLaunch(receipt);
  const { functionalCompilationForBuilder } = await import(
    "./functional-build.mjs"
  );
  const compilation = await functionalCompilationForBuilder(built.compilation);
  assert.equal(
    hash(await readFile(receipt.producer.path)),
    receipt.producer.executableSHA256,
  );
  const owned = await compilation.observer.spawn(
    {
      executable: receipt.producer.path,
      executableSHA256: receipt.producer.executableSHA256,
      identifier: receipt.producerIdentifier,
      certificateSHA256: receipt.producer.certificateSHA256,
      requirement: receipt.producer.requirement,
    },
    [],
    { cwd: compilation.root, env: { ...environment } },
  );
  const channel = new FunctionalProducerChannel(owned.child, receipt);
  try {
    const bootstrap = await channel.bootstrap();
    await compilation.observer.bind(owned, bootstrap.producer);
    producerChannels.set(channel, {
      receipt,
      plan: built.plan,
      compilation,
      compilerCapability: built.compilation,
      owned,
      bootstrap,
      docsDependency: built.docsDependency,
      observeDocs: built.observeDocs,
    });
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

export async function buildFunctionalOwnedProcessObserver({ compilation }) {
  const { functionalCompilationForBuilder } = await import(
    "./functional-build.mjs"
  );
  return (await functionalCompilationForBuilder(compilation)).observer;
}

export function functionalProducerOwnedProcess(channel) {
  const state = producerChannels.get(channel);
  assert(state, "Expected independently launched source-built producer");
  return state.owned;
}

export async function cancelFunctionalProducer(channel) {
  const state = producerChannels.get(channel);
  assert(state, "Expected independently launched source-built producer");
  await channel.cancelAndJoin();
  await state.owned.joined;
  assert.equal(state.owned.child.exitCode, 0);
  assert.equal(state.owned.child.signalCode, null);
  producerChannels.delete(channel);
}

export async function finishFunctionalProducer(channel) {
  const state = producerChannels.get(channel);
  assert(state, "Expected independently launched source-built producer");
  await channel.finish();
  await state.owned.joined;
  assert.equal(state.owned.child.exitCode, 0);
  assert.equal(state.owned.child.signalCode, null);
  producerChannels.delete(channel);
}

export function observeFunctionalProducer(channel) {
  const state = producerChannels.get(channel);
  assert(state, "Expected independently launched source-built producer");
  state.observeDocs({
    compilation: state.compilerCapability,
    plan: state.plan,
    dependency: state.docsDependency,
  });
  return state.compilation.observer.requireCurrentSync(state.owned);
}

export async function admitFunctionalProducerAuthority({
  receipt,
  plan,
  channel,
  activeJob,
  environment,
}) {
  const state = producerChannels.get(channel);
  assert(
    state && state.receipt === receipt && state.plan === plan,
    "Expected same-live source-built producer",
  );
  admitFunctionalRunner(environment, plan.sourceCommit);
  const current = requireFunctionalActiveJob(activeJob);
  assert.deepEqual(functionalActiveJobBuildPins(current), plan.hostedRunPins);
  const response = await channel.request("authority-metadata");
  exactFields(response, ["requestID", "operation", "manifest"]);
  const issuerManifestBytes = Buffer.from(
    functionalCanonicalJSON(response.manifest),
  );
  const observe = () => {
    const live = requireFunctionalActiveJob(activeJob);
    const producer = observeFunctionalProducer(channel);
    return {
      ...live,
      producer: {
        ...producer,
        certificateSHA256: receipt.producer.certificateSHA256,
        requirement: receipt.producer.requirement,
      },
    };
  };
  const observed = observe();
  const { admitFunctionalLiveIssuer } = await import("./fixture-trust.mjs");
  const admittedIssuer = admitFunctionalLiveIssuer(
    issuerManifestBytes,
    {
      ...current,
      build: {
        sourceCommit: plan.sourceCommit,
        policySHA256: plan.policySHA256,
        source: receipt.source,
        toolchain: receipt.toolchain,
        producer: receipt.producer,
      },
      launch: observed.producer,
      bootstrap: state.bootstrap,
    },
    observe,
  );
  const issuerDER = Buffer.concat([
    Buffer.from("302a300506032b6570032100", "hex"),
    Buffer.from(response.manifest.issuerPublicKey, "base64"),
  ]);
  return Object.freeze({ issuerManifestBytes, admittedIssuer, issuerDER });
}

const activeJobs = new WeakMap();
const repositoryID = 1289153439;
const workflowPath = ".github/workflows/hosted-functional-actions.yml";
const trustedActors = [65671483, 320458784];

function exactFields(value, fields) {
  assert(value && Object.getPrototypeOf(value) === Object.prototype);
  assert.deepEqual(Object.keys(value).sort(), [...fields].sort());
}

function freezeDocument(value) {
  if (value && typeof value === "object") {
    for (const item of Object.values(value)) freezeDocument(item);
    Object.freeze(value);
  }
  return value;
}

export function validateFunctionalActiveJob(value, environment) {
  exactFields(value, ["sourceCommit", "run", "job", "context"]);
  const { sourceCommit, run, job, context } = value;
  admitFunctionalSourceEnvironment(environment, sourceCommit);
  exactFields(context, [
    "event",
    "pullRequest",
    "mergeCommit",
    "workflow",
    "runAttempt",
  ]);
  const repository = (entry) => {
    assert.equal(entry.id, repositoryID);
    assert.equal(entry.full_name, "pulkitxm/edith");
  };
  const pullRequest = (entry) => {
    assert.equal(entry.number, 1014);
    assert.equal(entry.state, "open");
    assert.equal(entry.merged, false);
    assert.equal(entry.head.ref, "feat/extension-marketplace");
    assert.equal(entry.base.ref, "main");
    assert.equal(entry.head.sha, sourceCommit);
    assert.match(entry.base.sha, /^[0-9a-f]{40}$/);
    repository(entry.head.repo);
    repository(entry.base.repo);
  };
  repository(context.event.repository);
  assert.equal(context.event.number, 1014);
  assert(
    ["opened", "synchronize", "reopened", "ready_for_review"].includes(
      context.event.action,
    ),
  );
  pullRequest(context.event.pull_request);
  pullRequest(context.pullRequest);
  assert.equal(
    context.pullRequest.base.sha,
    context.event.pull_request.base.sha,
  );
  assert.equal(context.mergeCommit.sha, environment.GITHUB_SHA);
  assert.deepEqual(
    context.mergeCommit.parents.map(({ sha }) => sha),
    [context.pullRequest.base.sha, sourceCommit],
  );
  assert.equal(context.workflow.path, workflowPath);
  assert.equal(context.workflow.state, "active");
  assert(Number.isSafeInteger(context.workflow.id) && context.workflow.id > 0);
  for (const number of [run.id, job.id, context.runAttempt])
    assert(Number.isSafeInteger(number) && number > 0);
  assert.equal(context.runAttempt, Number(environment.GITHUB_RUN_ATTEMPT));
  assert.equal(run.id, Number(environment.GITHUB_RUN_ID));
  assert.equal(run.run_attempt, context.runAttempt);
  repository(run.repository);
  repository(run.head_repository);
  assert.equal(run.head_sha, sourceCommit);
  assert.equal(run.head_branch, "feat/extension-marketplace");
  assert.equal(run.event, "pull_request");
  assert.equal(run.path, workflowPath);
  assert.equal(run.workflow_id, context.workflow.id);
  assert.equal(run.status, "in_progress");
  assert.equal(run.conclusion, null);
  assert(trustedActors.includes(run.actor.id));
  assert.equal(run.actor.id, Number(environment.GITHUB_ACTOR_ID));
  assert(trustedActors.includes(run.triggering_actor.id));
  assert.equal(run.triggering_actor.login, environment.GITHUB_TRIGGERING_ACTOR);
  assert.equal(run.pull_requests.length, 1);
  const linked = run.pull_requests[0];
  assert.equal(linked.number, 1014);
  for (const side of ["head", "base"]) {
    assert.equal(linked[side].repo.id, repositoryID);
    assert.equal(linked[side].sha, context.pullRequest[side].sha);
  }
  assert.equal(job.id, Number(environment.FUNCTIONAL_JOB_ID));
  assert.equal(job.run_id, run.id);
  assert.equal(job.run_attempt, context.runAttempt);
  assert.equal(job.head_sha, sourceCommit);
  assert.equal(job.name, "functional-build");
  assert(
    typeof job.runner_name === "string" &&
      /^[ -~]{1,256}$/.test(job.runner_name),
  );
  assert.equal(job.runner_name, environment.RUNNER_NAME);
  assert.equal(job.status, "in_progress");
  assert.equal(job.conclusion, null);
  assert(
    job.labels.includes("macos-26") && !job.labels.includes("self-hosted"),
  );
  return value;
}

function observeActiveJob({ repository, sourceCommit, environment }) {
  admitFunctionalRunner(environment, sourceCommit);
  assert.equal(process.platform, "darwin");
  assert.equal(process.arch, "arm64");
  assert(environment.GITHUB_TOKEN);
  const execute = (file, args, options = {}) =>
    execFileSync(file, args, {
      cwd: repository,
      env: environment,
      timeout: 15000,
      maxBuffer: 16777216,
      stdio: ["ignore", "pipe", "pipe"],
      ...options,
    });
  const git = (args) => execute("git", args);
  assert.equal(git(["rev-parse", "HEAD"]).toString().trim(), sourceCommit);
  assert.equal(
    git(["status", "--porcelain", "--untracked-files=no"]).length,
    0,
  );
  const api = (path) =>
    JSON.parse(
      execute("gh", ["api", `repos/pulkitxm/edith/${path}`], {
        env: { ...environment, GH_TOKEN: environment.GITHUB_TOKEN },
        maxBuffer: 1048576,
      }).toString("utf8"),
    );
  const run = api(`actions/runs/${environment.GITHUB_RUN_ID}`);
  const context = {
    event: JSON.parse(
      execute("cat", [environment.GITHUB_EVENT_PATH], {
        maxBuffer: 1048576,
      }).toString("utf8"),
    ),
    pullRequest: api("pulls/1014"),
    mergeCommit: api(`commits/${environment.GITHUB_SHA}`),
    workflow: api(`actions/workflows/${run.workflow_id}`),
    runAttempt: Number(environment.GITHUB_RUN_ATTEMPT),
  };
  const jobs = api(
    `actions/runs/${run.id}/attempts/${context.runAttempt}/jobs?per_page=100`,
  );
  assert(
    Number.isSafeInteger(jobs.total_count) &&
      jobs.total_count > 0 &&
      jobs.total_count <= 100,
  );
  assert.equal(jobs.jobs.length, jobs.total_count);
  const matches = jobs.jobs.filter(
    (job) =>
      job.name === "functional-build" &&
      job.runner_name === environment.RUNNER_NAME,
  );
  assert.equal(matches.length, 1);
  const value = validateFunctionalActiveJob(
    { sourceCommit, run, job: matches[0], context },
    environment,
  );
  assert.deepEqual(
    git(["show", "-s", "--format=%P", environment.GITHUB_SHA])
      .toString()
      .trim()
      .split(" "),
    context.mergeCommit.parents.map(({ sha }) => sha),
  );
  const workflow = git(["show", `${sourceCommit}:${workflowPath}`]);
  assert(
    workflow.equals(git(["show", `${environment.GITHUB_SHA}:${workflowPath}`])),
  );
  const admitted = freezeDocument(value);
  activeJobs.set(admitted, {
    repository,
    sourceCommit,
    environment: Object.freeze({ ...environment }),
    workflowSHA256: hash(workflow),
  });
  return admitted;
}

export function observeFunctionalActiveJobSync({
  repository,
  sourceCommit,
  environment = process.env,
}) {
  return observeActiveJob({ repository, sourceCommit, environment });
}

export async function observeFunctionalActiveJob(options) {
  assert.equal(await realpath(options.repository), options.repository);
  return observeFunctionalActiveJobSync(options);
}

export function functionalActiveJobBuildPins(activeJob) {
  const state = activeJobs.get(activeJob);
  assert(state, "Expected actual observed active hosted job");
  return Object.freeze({
    sourceCommit: activeJob.sourceCommit,
    mergeCommit: activeJob.context.mergeCommit.sha,
    baseCommit: activeJob.context.pullRequest.base.sha,
    runID: activeJob.run.id,
    jobID: activeJob.job.id,
    runAttempt: activeJob.context.runAttempt,
    runnerName: activeJob.job.runner_name,
    workflowSHA256: state.workflowSHA256,
  });
}

export function functionalActiveJobContextBinding(context) {
  const repository = ({ id, full_name }) => ({ id, full_name });
  const reference = ({ sha, ref, repo }) => ({
    sha,
    ref,
    repo: repository(repo),
  });
  const pull = (value) => ({
    number: value.number,
    head: reference(value.head),
    base: reference(value.base),
  });
  return {
    event: {
      action: context.event.action,
      number: context.event.number,
      repository: repository(context.event.repository),
      pull_request: pull(context.event.pull_request),
    },
    pullRequest: {
      ...pull(context.pullRequest),
      state: context.pullRequest.state,
      merged: context.pullRequest.merged,
      merge_commit_sha: context.pullRequest.merge_commit_sha,
    },
    mergeCommit: {
      sha: context.mergeCommit.sha,
      parents: context.mergeCommit.parents.map(({ sha }) => ({ sha })),
    },
    workflow: {
      id: context.workflow.id,
      path: context.workflow.path,
      state: context.workflow.state,
    },
    runAttempt: context.runAttempt,
  };
}

export function requireFunctionalActiveJob(activeJob) {
  const state = activeJobs.get(activeJob);
  assert(state, "Expected actual observed active hosted job");
  const current = observeFunctionalActiveJobSync(state);
  assert.equal(current.run.id, activeJob.run.id);
  assert.equal(current.job.id, activeJob.job.id);
  assert.deepEqual(
    functionalActiveJobContextBinding(current.context),
    functionalActiveJobContextBinding(activeJob.context),
  );
  assert.equal(activeJobs.get(current).workflowSHA256, state.workflowSHA256);
  return current;
}

export function functionalInstalledXCTestProject({
  directory,
  sourceSHA256,
  certificateIdentity,
  helperSources = [],
  libraries = [],
}) {
  assert.equal(resolve(directory), directory);
  assert.match(sourceSHA256, /^[0-9a-f]{64}$/);
  assert(
    typeof certificateIdentity === "string" &&
      /^[ -~]{1,256}$/.test(certificateIdentity) &&
      certificateIdentity !== "-",
  );
  const objects = {};
  const add = (name, value) => {
    const id = hash(Buffer.from(`functional-installed-xctest:${name}`))
      .slice(0, 24)
      .toUpperCase();
    assert(!Object.hasOwn(objects, id));
    objects[id] = value;
    return id;
  };
  const file = add("source", {
    isa: "PBXFileReference",
    lastKnownFileType: "sourcecode.swift",
    path: join(directory, "HostedFunctionalInstalledUITests.swift"),
    sourceTree: "<absolute>",
  });
  const build = add("compile-source", { isa: "PBXBuildFile", fileRef: file });
  const helpers = helperSources.map((path) => {
    assert.equal(resolve(path), path);
    assert(path.endsWith(".swift"));
    const reference = add(`helper:${path}`, {
      isa: "PBXFileReference",
      lastKnownFileType: "sourcecode.swift",
      path,
      sourceTree: "<absolute>",
    });
    return {
      reference,
      build: add(`compile-helper:${path}`, {
        isa: "PBXBuildFile",
        fileRef: reference,
      }),
    };
  });
  for (const library of libraries) {
    exactFields(library, ["directory", "path"]);
    assert.equal(resolve(library.directory), library.directory);
    assert(
      library.path.startsWith(`${library.directory}/`) &&
        library.path.endsWith(".a"),
    );
  }
  const binary = add("product", {
    isa: "PBXFileReference",
    explicitFileType: "wrapper.cfbundle",
    path: "HostedFunctionalInstalledUITests.xctest",
    sourceTree: "BUILT_PRODUCTS_DIR",
  });
  const products = add("products", {
    isa: "PBXGroup",
    children: [binary],
    name: "Products",
    sourceTree: "<group>",
  });
  const group = add("group", {
    isa: "PBXGroup",
    children: [file, ...helpers.map(({ reference }) => reference), products],
    sourceTree: "<group>",
  });
  const phase = add("source-phase", {
    isa: "PBXSourcesBuildPhase",
    buildActionMask: 2147483647,
    files: [build, ...helpers.map(({ build }) => build)],
    runOnlyForDeploymentPostprocessing: 0,
  });
  const configuration = add("configuration", {
    isa: "XCBuildConfiguration",
    name: "Release",
    buildSettings: {
      PRODUCT_NAME: "HostedFunctionalInstalledUITests",
      PRODUCT_BUNDLE_IDENTIFIER: `com.pulkit.edith.tests.installed-${sourceSHA256.slice(0, 24)}`,
      SDKROOT: "macosx",
      MACOSX_DEPLOYMENT_TARGET: "26.0",
      ARCHS: "arm64",
      ONLY_ACTIVE_ARCH: "YES",
      SWIFT_VERSION: "6.0",
      SWIFT_INCLUDE_PATHS: libraries.map(({ directory }) => directory),
      OTHER_LDFLAGS: libraries.map(({ path }) => path),
      SWIFT_OPTIMIZATION_LEVEL: "-O",
      GENERATE_INFOPLIST_FILE: "YES",
      CODE_SIGN_STYLE: "Manual",
      CODE_SIGN_IDENTITY: certificateIdentity,
      CODE_SIGNING_ALLOWED: "YES",
      CODE_SIGNING_REQUIRED: "YES",
      ENABLE_HARDENED_RUNTIME: "YES",
      LD_RUNPATH_SEARCH_PATHS: [
        "@executable_path/../Frameworks",
        "@loader_path/../Frameworks",
      ],
    },
  });
  const configurations = add("configurations", {
    isa: "XCConfigurationList",
    buildConfigurations: [configuration],
    defaultConfigurationIsVisible: 0,
    defaultConfigurationName: "Release",
  });
  const target = add("target", {
    isa: "PBXNativeTarget",
    name: "HostedFunctionalInstalledUITests",
    productName: "HostedFunctionalInstalledUITests",
    productType: "com.apple.product-type.bundle.ui-testing",
    productReference: binary,
    buildConfigurationList: configurations,
    buildPhases: [phase],
    buildRules: [],
    dependencies: [],
  });
  const rootObject = add("project", {
    isa: "PBXProject",
    attributes: { LastUpgradeCheck: "2600" },
    buildConfigurationList: configurations,
    compatibilityVersion: "Xcode 14.0",
    developmentRegion: "en",
    hasScannedForEncodings: 0,
    knownRegions: ["en", "Base"],
    mainGroup: group,
    productRefGroup: products,
    projectDirPath: "",
    projectRoot: "",
    targets: [target],
  });
  const scheme = `<?xml version="1.0" encoding="UTF-8"?><Scheme LastUpgradeVersion="2600" version="1.3"><BuildAction parallelizeBuildables="NO" buildImplicitDependencies="NO"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="NO" buildForProfiling="NO" buildForArchiving="NO" buildForAnalyzing="NO"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="${target}" BuildableName="HostedFunctionalInstalledUITests.xctest" BlueprintName="HostedFunctionalInstalledUITests" ReferencedContainer="container:Installed.xcodeproj"/></BuildActionEntry></BuildActionEntries></BuildAction><TestAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="NO"><Testables><TestableReference skipped="NO"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="${target}" BuildableName="HostedFunctionalInstalledUITests.xctest" BlueprintName="HostedFunctionalInstalledUITests" ReferencedContainer="container:Installed.xcodeproj"/></TestableReference></Testables></TestAction></Scheme>`;
  return Object.freeze({
    project: {
      archiveVersion: "1",
      classes: {},
      objectVersion: "56",
      objects,
      rootObject,
    },
    scheme,
  });
}

const installedActors = new WeakMap();

export async function prepareFunctionalInstalledXCTestActor({
  repository,
  sourcePins,
  channel,
  issuerManifestBytes,
  admittedIssuer,
  artifactBytes,
  admittedArtifact,
  policyBytes,
  admittedPolicies,
  environment = process.env,
}) {
  admitFunctionalRunner(environment, sourcePins.sourceCommit);
  assert.equal(process.platform, "darwin");
  assert.equal(process.arch, "arm64");
  const state = producerChannels.get(channel);
  assert(
    state && state.plan.sourceCommit === sourcePins.sourceCommit,
    "Expected source-built live XCTest producer",
  );
  const current = async () => {
    observeFunctionalProducer(channel);
    await verifyFunctionalSourcePins(repository, sourcePins);
    const {
      functionalFixtureBootstrapTrustSource,
      functionalFixtureTrustSource,
    } = await import("./fixture-trust.mjs");
    functionalFixtureBootstrapTrustSource(
      issuerManifestBytes,
      admittedIssuer,
      policyBytes,
      admittedPolicies,
    );
    functionalFixtureTrustSource(
      artifactBytes,
      admittedArtifact,
      policyBytes,
      admittedPolicies,
    );
  };
  const cached = installedActors.get(channel);
  if (cached) {
    await cached.current();
    return cached.artifact;
  }
  await current();
  const manifest = JSON.parse(issuerManifestBytes.toString("utf8"));
  assert.equal(manifest.issuerPublicKey, state.bootstrap.issuerPublicKey);
  const source = Buffer.from(
    installedPresentationUITestSource({
      plan: state.plan,
      issuerPublicKey: manifest.issuerPublicKey,
    }),
  );
  const sourceSHA256 = hash(source);
  const directory = join(state.plan.root, "XCTest");
  await mkdir(directory, { mode: 0o700 });
  await requireFunctionalPrivateDirectory(directory);
  const sourcePath = join(directory, "HostedFunctionalInstalledUITests.swift");
  await writeFile(sourcePath, source, { mode: 0o600, flag: "wx" });
  const helperSources = [
    "Tests/HostedFunctionalActions/ProducerSources/FunctionalIssuer.swift",
    "Tests/HostedFunctionalActions/ProducerSources/FunctionalLifecycle.swift",
    "Tests/HostedFunctionalActions/HostSources/FunctionalHostSocket.swift",
    "Tests/HostedFunctionalActions/Sources/FunctionalActionContract/HostedFunctionalActionContext.swift",
  ].map((path) => {
    assert(sourcePins.files.some((pin) => pin.path === path));
    return join(state.compilation.sourceRepository, path);
  });
  const libraries = [
    {
      directory: join(state.plan.root, "Producer/WorkerFixtureSupport"),
      path: join(
        state.plan.root,
        "Producer/WorkerFixtureSupport/libWorkerFixtureSupport.a",
      ),
    },
    {
      directory: join(state.plan.root, "Producer/ExtensionMarketplace"),
      path: join(
        state.plan.root,
        "Producer/ExtensionMarketplace/libExtensionMarketplace.a",
      ),
    },
  ];
  assert.equal(
    hash(await readFile(libraries[0].path)),
    state.receipt.fixtureSupport.librarySHA256,
  );
  assert.equal(
    hash(await readFile(libraries[1].path)),
    state.receipt.catalog.librarySHA256,
  );
  const generated = functionalInstalledXCTestProject({
    directory,
    sourceSHA256,
    certificateIdentity: environment.EXTENSION_SIGN_IDENTITY,
    helperSources,
    libraries,
  });
  const project = join(directory, "Installed.xcodeproj");
  const schemes = join(project, "xcshareddata/xcschemes");
  await mkdir(schemes, { recursive: true, mode: 0o700 });
  await writeFile(
    join(project, "project.pbxproj"),
    functionalHostProjectXML(generated.project),
    { mode: 0o600, flag: "wx" },
  );
  await writeFile(join(schemes, "Installed.xcscheme"), generated.scheme, {
    mode: 0o600,
    flag: "wx",
  });
  const derived = join(directory, "DerivedData");
  const execute = (file, args, options = {}) =>
    execFileSync(file, args, {
      cwd: repository,
      env: environment,
      timeout: 120000,
      maxBuffer: 16777216,
      stdio: ["pipe", "pipe", "pipe"],
      ...options,
    });
  execute("xcodebuild", [
    "-project",
    project,
    "-scheme",
    "Installed",
    "-configuration",
    "Release",
    "-destination",
    "platform=macOS,arch=arm64",
    "-derivedDataPath",
    derived,
    "-jobs",
    "1",
    "build-for-testing",
  ]);
  await current();
  assert.equal(hash(await readFile(sourcePath)), sourceSHA256);
  const runnerPath = join(
    derived,
    "Build/Products/Release/HostedFunctionalInstalledUITests-Runner.app",
  );
  const testBundlePath = join(
    runnerPath,
    "Contents/PlugIns/HostedFunctionalInstalledUITests.xctest",
  );
  const testBundleIdentifier = `com.pulkit.edith.tests.installed-${sourceSHA256.slice(0, 24)}`;
  const runnerIdentifier = `${testBundleIdentifier}.xctrunner`;
  const probe = state.receipt.signatureProbe.path;
  assert.equal(
    hash(await readFile(probe)),
    state.receipt.signatureProbe.executableSHA256,
  );
  const pins = [];
  for (const [path, identifier, executable] of [
    [runnerPath, runnerIdentifier, "HostedFunctionalInstalledUITests-Runner"],
    [testBundlePath, testBundleIdentifier, "HostedFunctionalInstalledUITests"],
  ]) {
    assert.equal(await realpath(path), path);
    execute("codesign", ["--verify", "--strict", "--deep", path]);
    assert.deepEqual(
      JSON.parse(
        execute(probe, [
          path,
          identifier,
          state.plan.certificateSHA256,
        ]).toString("utf8"),
      ),
      { identifier, certificateSHA256: state.plan.certificateSHA256 },
    );
    const executablePath = join(path, "Contents/MacOS", executable);
    assert.equal(await realpath(executablePath), executablePath);
    pins.push({
      path: executablePath,
      sha256: hash(await readFile(executablePath)),
    });
  }
  const artifact = Object.freeze({
    runnerPath,
    testBundlePath,
    sourcePath,
    sourceSHA256,
    runnerIdentifier,
    runnerRequirement: `identifier "${runnerIdentifier}"`,
    runnerExecutableSHA256: pins[0].sha256,
    testBundleIdentifier,
    testBundleRequirement: `identifier "${testBundleIdentifier}"`,
    testBundleExecutableSHA256: pins[1].sha256,
  });
  const products = join(derived, "Build/Products");
  const xctestruns = (await readdir(products)).filter((name) =>
    name.endsWith(".xctestrun"),
  );
  assert.equal(xctestruns.length, 1);
  const xctestrunPath = join(products, xctestruns[0]);
  const xctestrunBytes = await readFile(xctestrunPath);
  const xctestrun = JSON.parse(
    execute("plutil", ["-convert", "json", "-o", "-", xctestrunPath]).toString(
      "utf8",
    ),
  );
  const requireArtifact = async () => {
    await current();
    assert.equal(hash(await readFile(sourcePath)), sourceSHA256);
    assert.deepEqual(await readFile(xctestrunPath), xctestrunBytes);
    for (const pin of pins)
      assert.equal(hash(await readFile(pin.path)), pin.sha256);
    for (const path of [runnerPath, testBundlePath])
      execute("codesign", ["--verify", "--strict", "--deep", path]);
  };
  installedActors.set(channel, {
    artifact,
    current: requireArtifact,
    xctestrun,
    products,
    execute,
    directory,
    environment: { ...environment },
  });
  return artifact;
}

export function functionalInstalledXCTestRunConfiguration(
  value,
  invocationPath,
  environment,
) {
  const result = structuredClone(value);
  assert.equal(result.__xctestrun_metadata__.FormatVersion, 1);
  assert.deepEqual(Object.keys(result).sort(), [
    "HostedFunctionalInstalledUITests",
    "__xctestrun_metadata__",
  ]);
  const target = result.HostedFunctionalInstalledUITests;
  assert.equal(target.IsUITestBundle, true);
  assert(
    typeof invocationPath === "string" &&
      invocationPath.startsWith("/") &&
      !invocationPath.includes("\0"),
  );
  target.EnvironmentVariables = {
    ...target.EnvironmentVariables,
    EDITH_FUNCTIONAL_XCTEST_INVOCATION: invocationPath,
  };
  for (const name of [
    "GITHUB_ACTIONS",
    "RUNNER_ENVIRONMENT",
    "RUNNER_OS",
    "GITHUB_REPOSITORY",
    "GITHUB_REPOSITORY_ID",
    "GITHUB_EVENT_NAME",
    "GITHUB_REF",
    "GITHUB_SHA",
    "EXPECTED_SOURCE_SHA",
    "EDITH_HOSTED_FUNCTIONAL_ACTIONS",
  ])
    target.EnvironmentVariables[name] = environment[name];
  return result;
}

export async function runFunctionalInstalledXCTestGeneration({
  repository,
  sourcePins,
  channel,
  nativeSession,
  generation,
  issuerManifestBytes,
  admittedIssuer,
  artifactBytes,
  admittedArtifact,
  policyBytes,
  admittedPolicies,
  environment = process.env,
}) {
  const artifact = await prepareFunctionalInstalledXCTestActor({
    repository,
    sourcePins,
    channel,
    issuerManifestBytes,
    admittedIssuer,
    artifactBytes,
    admittedArtifact,
    policyBytes,
    admittedPolicies,
    environment,
  });
  const build = installedActors.get(channel);
  const { registerFunctionalNativeXCTestActor } = await import(
    "./run-functional.mjs"
  );
  const registration = await registerFunctionalNativeXCTestActor({
    session: nativeSession,
    generation,
    artifact,
  });
  const capability = generation.capability;
  assert.equal(
    registration.invocationPath,
    join(
      build.directory,
      "invocations",
      `${capability.owner}-${capability.phase}.json`,
    ),
  );
  await build.current();
  const configuration = functionalInstalledXCTestRunConfiguration(
    build.xctestrun,
    registration.invocationPath,
    environment,
  );
  const runFile = join(
    build.products,
    `Invocation-${capability.owner}-${capability.phase}.xctestrun`,
  );
  build.execute("plutil", ["-convert", "xml1", "-o", runFile, "-"], {
    input: Buffer.from(JSON.stringify(configuration)),
  });
  const resultBundle = join(
    build.directory,
    `Result-${capability.owner}-${capability.phase}.xcresult`,
  );
  const output = build.execute("xcodebuild", [
    "-xctestrun",
    runFile,
    "-destination",
    "platform=macOS,arch=arm64",
    "-resultBundlePath",
    resultBundle,
    "-parallel-testing-enabled",
    "NO",
    "-maximum-concurrent-test-macos-destinations",
    "1",
    "-jobs",
    "1",
    "-only-testing:HostedFunctionalInstalledUITests/HostedFunctionalInstalledUITests/testOriginalDownloadedPresentationAction",
    "test-without-building",
  ]);
  await build.current();
  const outcome = JSON.parse(
    build
      .execute(
        "xcrun",
        [
          "xcresulttool",
          "get",
          "test-results",
          "summary",
          "--path",
          resultBundle,
          "--compact",
        ],
        { timeout: 15000, maxBuffer: 1048576 },
      )
      .toString("utf8"),
  );
  assert.equal(outcome.result, "Passed");
  assert.equal(outcome.passedTests, 1);
  assert.equal(outcome.failedTests, 0);
  assert.equal(outcome.skippedTests, 0);
  assert.equal(outcome.expectedFailures, 0);
  assert.equal(outcome.totalTestCount, 1);
  const outputPath = join(
    build.directory,
    `xctest-${capability.owner}-${capability.phase}.txt`,
  );
  await writeFile(outputPath, output, { mode: 0o600, flag: "wx" });
  return Object.freeze({
    sourceCommit: sourcePins.sourceCommit,
    session: capability.session,
    owner: capability.owner,
    phase: capability.phase,
    capabilitySHA256: functionalDigest(capability),
    sourceSHA256: artifact.sourceSHA256,
    resultBundle,
    outputPath,
    producerObservationRequired: true,
  });
}

export function validateFunctionalLiteralPolicies({
  cases,
  recipes,
  manifestBytes,
  nativeSources,
  literalPolicies,
  sourceCommit,
}) {
  assert.match(sourceCommit, /^[0-9a-f]{40}$/);
  assert(Buffer.isBuffer(manifestBytes));
  const manifest = JSON.parse(manifestBytes.toString("utf8"));
  validateFunctionalOwnerInventory(manifest);
  assert.equal(cases.length, 39);
  assert.deepEqual(
    Object.keys(literalPolicies).sort(),
    [...functionalActionOwners].sort(),
  );
  assert.deepEqual(
    Object.keys(nativeSources).sort(),
    [...functionalActionOwners].sort(),
  );
  const policies = [];
  const caseSources = [];
  for (const owner of functionalActionOwners) {
    const item = cases.find(({ definition }) => definition.owner === owner);
    assert(item && item.sourceCommit === sourceCommit);
    const recipe = recipes[owner].recipe;
    validateInstalledPresentationRecipe(recipe, item.definition);
    const literal = literalPolicies[owner];
    exactFields(literal, [
      "owner",
      "primaryRole",
      "operations",
      "presentations",
      "inputs",
      "outputs",
      "fileScopes",
    ]);
    assert.equal(literal.owner, owner);
    assert.deepEqual(literal.operations, item.definition.operations);
    assert(
      literal.presentations.some(
        ({ location, section }) =>
          location === recipe.location && section === recipe.section,
      ),
      `Missing original presentation policy ${owner}`,
    );
    assert(Array.isArray(literal.fileScopes));
    for (const step of recipe.steps) {
      for (const name of [
        step.ownedPath,
        step.ownedLabel?.name,
        step.scope?.ownedLabel?.name,
        step.scope?.anchor?.ownedLabel?.name,
      ].filter(Boolean))
        assert(
          literal.fileScopes.some((scope) => scope.name === name),
          `Missing source-owned chooser scope ${owner}:${name}`,
        );
    }
    const nativeBytes = nativeSources[owner];
    assert(Buffer.isBuffer(nativeBytes) && nativeBytes.length > 0);
    const path = functionalActionCasePaths(owner).native;
    const caseSHA256 = hash(nativeBytes);
    assert.equal(
      item.sourcePins.find((entry) => entry.path === path)?.sha256,
      caseSHA256,
    );
    policies.push({
      ...literal,
      manifestSHA256: hash(manifestBytes),
      caseSHA256,
    });
    caseSources.push({
      owner,
      path,
      bytes: Buffer.from(nativeBytes),
      sha256: caseSHA256,
    });
  }
  const policyBytes = Buffer.from(functionalCanonicalJSON(policies));
  const admittedPolicies = {
    sourceCommit,
    policySHA256: hash(policyBytes),
    manifest: {
      bytes: Buffer.from(manifestBytes),
      sha256: hash(manifestBytes),
    },
    cases: caseSources,
  };
  return { manifest, policyBytes, admittedPolicies };
}

export function functionalLiteralJSON(bytes, maximumBytes = 32768) {
  assert([32768, 262144, 1048576].includes(maximumBytes));
  assert(
    Buffer.isBuffer(bytes) && bytes.length > 0 && bytes.length <= maximumBytes,
  );
  const text = new TextDecoder("utf-8", { fatal: true }).decode(bytes);
  const decoded = JSON.parse(text);
  const tree = parse(`(${text})`, { sourceType: "module" });
  assert.equal(tree.program.body.length, 1);
  const literal = (node, depth = 0) => {
    assert(node && depth < 64);
    if (node.type === "NumericLiteral") {
      assert(Number.isFinite(node.value));
      return node.value;
    }
    if (node.type === "UnaryExpression") {
      assert.equal(node.operator, "-");
      assert.equal(node.argument.type, "NumericLiteral");
      assert(Number.isFinite(node.argument.value));
      return -node.argument.value;
    }
    if (["StringLiteral", "BooleanLiteral"].includes(node.type))
      return node.value;
    if (node.type === "NullLiteral") return null;
    if (node.type === "ArrayExpression")
      return node.elements.map((element) => literal(element, depth + 1));
    assert.equal(node.type, "ObjectExpression");
    const keys = new Set(),
      entries = [];
    for (const item of node.properties) {
      assert.equal(item.type, "ObjectProperty");
      assert.equal(item.computed, false);
      assert.equal(item.key.type, "StringLiteral");
      const key = item.key.value;
      assert(!keys.has(key), `Duplicate literal authority field ${key}`);
      keys.add(key);
      entries.push([key, literal(item.value, depth + 1)]);
    }
    return Object.fromEntries(entries);
  };
  assert.deepEqual(literal(tree.program.body[0].expression), decoded);
  return decoded;
}

export function validateFunctionalSavedReaderPolicy(reader, policy) {
  exactFields(reader, [
    "schema",
    "owner",
    "reads",
    "sentinels",
    "initial",
    "final",
  ]);
  assert.equal(reader.schema, 1);
  assert.equal(reader.owner, policy.owner);
  const roots = ["owner-home", "owner-data", "owner-inputs", "owner-outputs"];
  const text = (value, maximum) => {
    assert(
      typeof value === "string" &&
        Buffer.byteLength(value) > 0 &&
        Buffer.byteLength(value) <= maximum &&
        !value.includes("\0"),
    );
  };
  const path = (value) => {
    assert(roots.includes(value.root));
    assert(
      Array.isArray(value.components) &&
        value.components.length > 0 &&
        value.components.length <= 16,
    );
    const components = value.components.map((component, index) => {
      if (typeof component === "string") {
        text(component, 255);
        assert(
          ![".", ".."].includes(component) &&
            !component.includes("/") &&
            !component.includes("\\"),
        );
        return { literal: component };
      }
      exactFields(component, ["derived"]);
      assert(
        ["session", "phase", "ui-suite-plist", "engine-suite-plist"].includes(
          component.derived,
        ),
      );
      if (component.derived === "phase") return { phase: true };
      if (component.derived === "session") return { sessionUUID: "lowercase" };
      assert.equal(value.root, "owner-home");
      assert.equal(index, 2);
      assert.equal(value.components.length, 3);
      assert.deepEqual(value.components.slice(0, 2), [
        "Library",
        "Preferences",
      ]);
      return {
        workerDefaultsPlist:
          component.derived === "ui-suite-plist" ? "ui" : "engine",
      };
    });
    if (value.components.includes("Preferences")) {
      assert.equal(value.root, "owner-home");
      assert.deepEqual(value.components.slice(0, 2), [
        "Library",
        "Preferences",
      ]);
      assert.equal(value.components.length, 3);
      assert(components[2].workerDefaultsPlist);
    }
    return { root: value.root, components };
  };
  const ownedFile = (value, maximumBytes = 0, fileOnly = true) => {
    const wanted = path(value);
    let admitted = false;
    for (const scope of policy.fileScopes) {
      if (scope.root !== wanted.root) continue;
      if (
        (!fileOnly || scope.kind === "file") &&
        functionalCanonicalJSON(scope.components) ===
          functionalCanonicalJSON(wanted.components) &&
        scope.maximumBytes >= maximumBytes
      )
        admitted = true;
      if (scope.kind === "directory") {
        for (const leaf of [...scope.immutableFiles, ...scope.mutableFiles]) {
          const components = [
            ...scope.components,
            ...leaf.components.map((literal) => ({ literal })),
          ];
          if (
            functionalCanonicalJSON(components) ===
              functionalCanonicalJSON(wanted.components) &&
            leaf.maximumBytes >= maximumBytes
          )
            admitted = true;
        }
      }
    }
    assert(
      admitted,
      `Saved reader path lacks a finite compiled file grant ${reader.owner}`,
    );
    return functionalCanonicalJSON(wanted);
  };
  assert(Array.isArray(reader.reads) && reader.reads.length <= 16);
  assert(Array.isArray(reader.sentinels) && reader.sentinels.length <= 16);
  if (reader.reads.length + reader.sentinels.length === 0) {
    assert(["calendar", "audioMixer"].includes(reader.owner));
    assert((policy.outputs ?? []).length === 0);
    assert(
      policy.fileScopes.every(
        (scope) =>
          scope.purpose === "immutable-input" &&
          scope.mutableFiles.length === 0,
      ),
    );
  }
  const names = new Set(),
    paths = new Set();
  for (const [isRead, files] of [
    [true, reader.reads],
    [false, reader.sentinels],
  ]) {
    for (const file of files) {
      exactFields(file, [
        "name",
        "root",
        "components",
        "maximumBytes",
        ...(isRead ? ["format", "selections"] : []),
      ]);
      text(file.name, 128);
      assert(!names.has(file.name));
      names.add(file.name);
      assert(
        Number.isSafeInteger(file.maximumBytes) &&
          file.maximumBytes > 0 &&
          file.maximumBytes <= 16777216,
      );
      const location = ownedFile(file, file.maximumBytes);
      assert(!paths.has(location), "Duplicate saved read or sentinel path");
      paths.add(location);
      if (isRead) {
        assert(["json", "property-list"].includes(file.format));
        assert(
          Array.isArray(file.selections) &&
            file.selections.length > 0 &&
            file.selections.length <= 64,
        );
        const selections = new Set();
        for (const selected of file.selections) {
          exactFields(selected, [
            "name",
            "path",
            "codec",
            ...(Object.hasOwn(selected, "decodedPath") ? ["decodedPath"] : []),
          ]);
          text(selected.name, 256);
          assert(!selections.has(selected.name));
          selections.add(selected.name);
          assert(
            Array.isArray(selected.path) &&
              selected.path.length > 0 &&
              selected.path.length <= 16,
          );
          for (const key of selected.path) text(key, 256);
          assert(
            [
              "value",
              "data-json",
              "data-property-list",
              "masked-utf8",
            ].includes(selected.codec),
          );
          if (Object.hasOwn(selected, "decodedPath")) {
            assert(
              ["data-json", "data-property-list"].includes(selected.codec),
            );
            assert(
              Array.isArray(selected.decodedPath) &&
                selected.decodedPath.length > 0 &&
                selected.decodedPath.length <= 16,
            );
            for (const key of selected.decodedPath) text(key, 256);
          }
        }
      }
    }
  }
  const literal = (value, depth = 0) => {
    assert(depth <= 32);
    if (Array.isArray(value)) {
      for (const item of value) literal(item, depth + 1);
      return;
    }
    if (value && typeof value === "object") {
      if (Object.hasOwn(value, "$binding")) {
        if (value.$binding === "session") exactFields(value, ["$binding"]);
        else {
          assert.equal(value.$binding, "owned-path");
          exactFields(value, ["$binding", "root", "components"]);
          ownedFile(value, 0, false);
        }
      } else for (const item of Object.values(value)) literal(item, depth + 1);
    } else
      assert(
        value === null ||
          typeof value === "string" ||
          typeof value === "boolean" ||
          (typeof value === "number" && Number.isFinite(value)),
      );
  };
  for (const expected of [reader.initial, reader.final]) {
    if (reader.reads.length === 0) {
      assert.equal(expected, null);
      continue;
    }
    exactFields(
      expected,
      reader.reads.map(({ name }) => name),
    );
    for (const file of reader.reads) {
      exactFields(
        expected[file.name],
        file.selections.map(({ name }) => name),
      );
      for (const selected of file.selections) {
        const value = expected[file.name][selected.name];
        assert.equal(typeof value.present, "boolean");
        exactFields(value, value.present ? ["present", "value"] : ["present"]);
        if (value.present) literal(value.value);
      }
    }
  }
  assert(Buffer.byteLength(functionalCanonicalJSON(reader)) <= 262144);
  return reader;
}

export async function admitFunctionalSavedReaderPolicies({
  repository,
  sourcePins,
  policyBytes,
  cases,
}) {
  const policies = JSON.parse(policyBytes.toString("utf8"));
  const savedReaderPolicies = {},
    savedReaderSources = {};
  for (const owner of functionalActionOwners) {
    const path = `scripts/hosted-functional-actions/saved-readers/${owner}.json`;
    const pin = sourcePins.files.find((entry) => entry.path === path);
    assert(pin, `Missing maintained original saved reader ${path}`);
    const bytes = await readFile(join(repository, path));
    assert.equal(hash(bytes), pin.sha256);
    savedReaderSources[owner] = {
      path,
      bytes: Buffer.from(bytes),
      sha256: pin.sha256,
    };
    const definition = cases.find(
      (item) => item.definition.owner === owner,
    )?.definition;
    assert(definition);
    savedReaderPolicies[owner] = validateFunctionalSavedReaderPolicy(
      functionalLiteralJSON(bytes, 262144),
      policies.find((policy) => policy.owner === owner),
    );
  }
  for (const owner of functionalActionOwners) {
    const reader = savedReaderPolicies[owner];
    if (reader.reads.length + reader.sentinels.length === 0)
      assert.equal(
        cases.find((item) => item.definition.owner === owner).definition
          .persistence.applicable,
        false,
      );
  }
  await verifyFunctionalSourcePins(repository, sourcePins);
  return {
    savedReaderPolicies: freezeDocument(savedReaderPolicies),
    savedReaderSources,
  };
}

export function validateFunctionalPreparationPolicy(preparation, policy) {
  exactFields(preparation, ["schema", "owner", "files"]);
  assert.equal(preparation.schema, 1);
  assert.equal(preparation.owner, policy.owner);
  assert(Array.isArray(preparation.files) && preparation.files.length <= 256);
  const allowed = [];
  for (const scope of policy.fileScopes) {
    if (scope.kind === "file" && scope.initialState === "present")
      allowed.push({
        root: scope.root,
        components: scope.components,
        maximumBytes: scope.maximumBytes,
      });
    if (scope.kind === "directory") {
      for (const leaf of [
        ...scope.immutableFiles,
        ...scope.mutableFiles.filter((file) => file.initialState === "present"),
      ])
        allowed.push({
          root: scope.root,
          components: [
            ...scope.components,
            ...leaf.components.map((literal) => ({ literal })),
          ],
          maximumBytes: leaf.maximumBytes,
        });
    }
  }
  const bindings = [];
  for (const scope of policy.fileScopes) {
    bindings.push({ root: scope.root, components: scope.components });
    if (scope.kind === "directory")
      for (const leaf of [...scope.immutableFiles, ...scope.mutableFiles])
        bindings.push({
          root: scope.root,
          components: [
            ...scope.components,
            ...leaf.components.map((literal) => ({ literal })),
          ],
        });
  }
  let nodes = 0;
  const typed = (value, codec, depth = 0) => {
    assert(depth <= 32 && ++nodes <= 16384);
    if (Array.isArray(value)) {
      for (const item of value) typed(item, codec, depth + 1);
      return;
    }
    if (value && typeof value === "object") {
      if (Object.hasOwn(value, "$binding")) {
        if (value.$binding === "session") exactFields(value, ["$binding"]);
        else {
          assert.equal(value.$binding, "owned-path");
          exactFields(value, ["$binding", "root", "components"]);
          assert(
            bindings.some(
              (entry) =>
                entry.root === value.root &&
                functionalCanonicalJSON(entry.components) ===
                  functionalCanonicalJSON(value.components),
            ),
            "Preparation source path binding lacks a finite grant",
          );
        }
        return;
      }
      if (Object.hasOwn(value, "$data")) {
        assert.equal(codec, "property-list");
        exactFields(value, ["$data"]);
        const cell = value.$data;
        if (cell.codec === "base64") {
          exactFields(cell, ["codec", "bytesBase64"]);
          assert.equal(
            Buffer.from(cell.bytesBase64, "base64").toString("base64"),
            cell.bytesBase64,
          );
        } else {
          exactFields(cell, ["codec", "value"]);
          assert(["json", "property-list"].includes(cell.codec));
          typed(cell.value, cell.codec, depth + 1);
        }
        return;
      }
      assert(Object.keys(value).every((key) => !key.startsWith("$")));
      for (const item of Object.values(value)) typed(item, codec, depth + 1);
      return;
    }
    assert(
      typeof value === "string" ||
        typeof value === "boolean" ||
        (typeof value === "number" && Number.isFinite(value)) ||
        (value === null && codec === "json"),
    );
  };
  const paths = new Set();
  let total = 0;
  for (const file of preparation.files) {
    exactFields(
      file,
      Object.hasOwn(file, "bytesBase64")
        ? ["root", "components", "bytesBase64", "maximumBytes"]
        : ["root", "components", "codec", "value", "maximumBytes"],
    );
    assert(Array.isArray(file.components) && file.components.length > 0);
    const selected = allowed.find(
      (entry) =>
        entry.root === file.root &&
        functionalCanonicalJSON(entry.components) ===
          functionalCanonicalJSON(file.components),
    );
    assert(
      selected,
      "Initial preparation lacks exact source-owned present file grant",
    );
    assert(
      Number.isSafeInteger(file.maximumBytes) &&
        file.maximumBytes > 0 &&
        file.maximumBytes <= selected.maximumBytes,
    );
    if (Object.hasOwn(file, "bytesBase64")) {
      assert(
        typeof file.bytesBase64 === "string" &&
          /^[A-Za-z0-9+/]*={0,2}$/.test(file.bytesBase64),
      );
      const bytes = Buffer.from(file.bytesBase64, "base64");
      assert.equal(bytes.toString("base64"), file.bytesBase64);
      assert(bytes.length <= file.maximumBytes);
      total += bytes.length;
    } else {
      assert(["json", "property-list"].includes(file.codec));
      typed(file.value, file.codec);
      assert(Buffer.byteLength(functionalCanonicalJSON(file.value)) <= 8388608);
    }
    assert(total <= 8388608);
    const key = functionalCanonicalJSON({
      root: file.root,
      components: file.components,
    }).toLowerCase();
    assert(!paths.has(key), "Duplicate initial preparation file");
    paths.add(key);
    const last = file.components.at(-1)?.literal;
    if (last)
      assert(
        !/\.(mp4|mov|m4v|m4a|mp3|wav|aiff|caf)$/i.test(last),
        "Native media must use the original source generator",
      );
  }
  for (const file of allowed) {
    const key = functionalCanonicalJSON({
      root: file.root,
      components: file.components,
    }).toLowerCase();
    const nativeMedia =
      preparation.owner === "timeLapse" &&
      file.root === "owner-inputs" &&
      [
        [{ literal: "saved-recording" }, { literal: "video.mp4" }],
        [{ literal: "saved-recording" }, { literal: "session.json" }],
      ].some(
        (components) =>
          functionalCanonicalJSON(components) ===
          functionalCanonicalJSON(file.components),
      );
    const generatedDownloadsAudio =
      preparation.owner === "downloads" &&
      file.root === "owner-home" &&
      functionalCanonicalJSON(file.components) ===
        functionalCanonicalJSON([
          { literal: "audio-library" },
          { literal: "Synthetic saved download.m4a" },
        ]) &&
      policy.fileScopes.some(
        (scope) =>
          scope.name === "audio-library" &&
          scope.kind === "directory" &&
          scope.purpose === "immutable-input" &&
          scope.root === "owner-home" &&
          functionalCanonicalJSON(scope.components) ===
            functionalCanonicalJSON([{ literal: "audio-library" }]) &&
          scope.initialState === "present" &&
          functionalCanonicalJSON(scope.allowedStates) ===
            functionalCanonicalJSON(["present"]) &&
          scope.mutableFiles.length === 0 &&
          scope.immutableFiles.length === 1 &&
          functionalCanonicalJSON(scope.immutableFiles[0].components) ===
            functionalCanonicalJSON(["Synthetic saved download.m4a"]) &&
          scope.immutableFiles[0].maximumBytes >= 1048576,
      );
    assert(
      paths.has(key) || nativeMedia || generatedDownloadsAudio,
      "Missing genuine source preparation for an initial-present file",
    );
  }
  return preparation;
}

export async function admitFunctionalPreparationPolicies({
  repository,
  sourcePins,
  policyBytes,
}) {
  const policies = JSON.parse(policyBytes.toString("utf8"));
  const preparationPolicies = {},
    preparationSources = {};
  for (const owner of functionalActionOwners) {
    const path = `scripts/hosted-functional-actions/preparation/${owner}.json`;
    const pin = sourcePins.files.find((entry) => entry.path === path);
    assert(pin, `Missing maintained original initial preparation ${path}`);
    const bytes = await readFile(join(repository, path));
    assert.equal(hash(bytes), pin.sha256);
    preparationSources[owner] = {
      path,
      bytes: Buffer.from(bytes),
      sha256: pin.sha256,
    };
    preparationPolicies[owner] = validateFunctionalPreparationPolicy(
      functionalLiteralJSON(bytes, 1048576),
      policies.find((policy) => policy.owner === owner),
    );
  }
  await verifyFunctionalSourcePins(repository, sourcePins);
  return {
    preparationPolicies: freezeDocument(preparationPolicies),
    preparationSources,
  };
}

function validateFunctionalObservationBindings(rule, definition, policy) {
  const value = (item, depth = 0) => {
    assert(depth <= 32);
    if (Array.isArray(item)) {
      for (const child of item) value(child, depth + 1);
      return;
    }
    if (!item || typeof item !== "object") return;
    if (!Object.hasOwn(item, "$binding")) {
      for (const child of Object.values(item)) value(child, depth + 1);
      return;
    }
    assert(
      policy && policy.owner === definition.owner,
      "Observation binding lacks original literal owner policy",
    );
    if (item.$binding === "session") {
      exactFields(item, ["$binding"]);
      return;
    }
    exactFields(item, ["$binding", "root", "components"]);
    assert.equal(item.$binding, "owned-path");
    assert(
      ["owner-home", "owner-data", "owner-inputs", "owner-outputs"].includes(
        item.root,
      ),
    );
    assert(
      Array.isArray(item.components) &&
        item.components.length > 0 &&
        item.components.length <= 16,
    );
    const components = item.components.map((component, index) => {
      if (typeof component === "string") {
        assert(
          component.length > 0 &&
            Buffer.byteLength(component) <= 255 &&
            !component.includes("\0") &&
            !component.includes("/") &&
            !component.includes("\\") &&
            ![".", ".."].includes(component),
        );
        return { literal: component };
      }
      exactFields(component, ["derived"]);
      if (component.derived === "session") return { sessionUUID: "lowercase" };
      if (component.derived === "phase") return { phase: true };
      assert(
        ["engine-suite-plist", "ui-suite-plist"].includes(component.derived),
      );
      assert.equal(item.root, "owner-home");
      assert.equal(index, 2);
      assert.deepEqual(item.components.slice(0, 2), ["Library", "Preferences"]);
      assert.equal(item.components.length, 3);
      return {
        workerDefaultsPlist:
          component.derived === "ui-suite-plist" ? "ui" : "engine",
      };
    });
    assert(
      policy.fileScopes.some((scope) => {
        if (scope.root !== item.root) return false;
        const candidates = [scope.components];
        if (scope.kind === "directory")
          for (const leaf of [...scope.immutableFiles, ...scope.mutableFiles])
            candidates.push([
              ...scope.components,
              ...leaf.components.map((literal) => ({ literal })),
            ]);
        return candidates.some(
          (candidate) =>
            functionalCanonicalJSON(candidate) ===
            functionalCanonicalJSON(components),
        );
      }),
      "Observation expected path lacks an exact finite original file grant",
    );
  };
  if (rule.kind === "literal") value(rule.value);
  if (rule.kind === "oneOf") for (const item of rule.values) value(item);
  if (rule.kind === "object")
    for (const child of Object.values(rule.fields))
      validateFunctionalObservationBindings(child, definition, policy);
  if (rule.kind === "array")
    validateFunctionalObservationBindings(rule.element, definition, policy);
  if (rule.kind === "nullable")
    validateFunctionalObservationBindings(rule.rule, definition, policy);
}

export function validateFunctionalObservationPolicy(value, definition, policy) {
  exactFields(value, ["schema", "owner", "readback", "phases"]);
  assert.equal(value.schema, 1);
  assert.equal(value.owner, definition.owner);
  exactFields(value.readback, ["operation", "payload", "normalizer"]);
  assert(
    typeof value.readback.operation === "string" &&
      /^[A-Za-z0-9_.-]{1,256}$/.test(value.readback.operation),
  );
  assert(definition.operations.includes(value.readback.operation));
  assert(
    value.readback.payload &&
      Object.getPrototypeOf(value.readback.payload) === Object.prototype,
  );
  const normalizer = value.readback.normalizer;
  if (normalizer.kind === "identity") exactFields(normalizer, ["kind"]);
  else {
    exactFields(normalizer, ["kind", "fields"]);
    assert.equal(normalizer.kind, "select-object");
    assert(
      normalizer.fields &&
        Object.getPrototypeOf(normalizer.fields) === Object.prototype &&
        Object.keys(normalizer.fields).length > 0 &&
        Object.keys(normalizer.fields).length <= 64,
    );
    for (const [name, field] of Object.entries(normalizer.fields)) {
      assert(
        name.length > 0 &&
          Buffer.byteLength(name) <= 128 &&
          !name.includes("\0"),
      );
      exactFields(field, ["path", "transform"]);
      assert(Array.isArray(field.path) && field.path.length <= 16);
      for (const component of field.path)
        assert(
          (typeof component === "string" &&
            component.length > 0 &&
            Buffer.byteLength(component) <= 256 &&
            !component.includes("\0")) ||
            (Number.isSafeInteger(component) && component >= 0),
        );
      assert(
        [
          "identity",
          "sha256-string",
          "base64-json",
          "base64-property-list",
        ].includes(field.transform),
      );
    }
  }
  assert(Array.isArray(value.phases) && value.phases.length === 3);
  for (const [index, phase] of value.phases.entries()) {
    exactFields(phase, ["phase", "before", "after"]);
    assert.equal(phase.phase, phases[index]);
    functionalObservationRuleSwift(phase.before);
    functionalObservationRuleSwift(phase.after);
    validateFunctionalObservationBindings(phase.before, definition, policy);
    validateFunctionalObservationBindings(phase.after, definition, policy);
  }
  return value;
}

export async function admitFunctionalObservationPolicies({
  repository,
  sourcePins,
  cases,
  policyBytes,
}) {
  assert(Buffer.isBuffer(policyBytes));
  const policies = JSON.parse(policyBytes.toString("utf8"));
  const observationPolicies = {},
    observationSources = {};
  for (const owner of functionalActionOwners) {
    const path = `scripts/hosted-functional-actions/observation-policies/${owner}.json`;
    const pin = sourcePins.files.find((entry) => entry.path === path);
    assert(
      pin,
      `Missing maintained original authoritative observation ${path}`,
    );
    const bytes = await readFile(join(repository, path));
    assert.equal(hash(bytes), pin.sha256);
    observationSources[owner] = {
      path,
      bytes: Buffer.from(bytes),
      sha256: pin.sha256,
    };
    observationPolicies[owner] = validateFunctionalObservationPolicy(
      functionalLiteralJSON(bytes),
      cases.find((item) => item.definition.owner === owner).definition,
      policies.find((item) => item.owner === owner),
    );
  }
  await verifyFunctionalSourcePins(repository, sourcePins);
  return {
    observationPolicies: freezeDocument(observationPolicies),
    observationSources,
  };
}

export async function admitFunctionalRolePolicies({
  repository,
  sourcePins,
  cases,
  recipes,
}) {
  const literalPolicies = {},
    nativeSources = {},
    policySources = {};
  for (const owner of functionalActionOwners) {
    const path = `scripts/hosted-functional-actions/policies/${owner}.json`;
    assert(
      sourcePins.files.some((pin) => pin.path === path),
      `Missing maintained literal role policy ${path}`,
    );
    const bytes = await readFile(join(repository, path));
    assert(bytes.length > 0 && bytes.length <= 32768);
    literalPolicies[owner] = functionalLiteralJSON(bytes);
    policySources[owner] = {
      path,
      bytes: Buffer.from(bytes),
      sha256: hash(bytes),
    };
    nativeSources[owner] = await readFile(
      join(repository, functionalActionCasePaths(owner).native),
    );
  }
  const result = validateFunctionalLiteralPolicies({
    cases,
    recipes,
    sourceCommit: sourcePins.sourceCommit,
    literalPolicies,
    nativeSources,
    manifestBytes: await readFile(join(repository, "Extensions/manifest.json")),
  });
  const { functionalFixtureRolePolicySource } = await import(
    "./fixture-trust.mjs"
  );
  functionalFixtureRolePolicySource(
    result.policyBytes,
    result.admittedPolicies,
  );
  await verifyFunctionalSourcePins(repository, sourcePins);
  return { ...result, policySources };
}

export function validateFunctionalSourceModuleExports(bytes, names) {
  assert(Buffer.isBuffer(bytes) && bytes.length > 0 && bytes.length <= 1048576);
  const tree = parse(new TextDecoder("utf-8", { fatal: true }).decode(bytes), {
    sourceType: "module",
  });
  const exported = new Set();
  for (const item of tree.program.body) {
    if (
      item.type === "ExportNamedDeclaration" &&
      item.declaration?.type === "FunctionDeclaration"
    ) {
      assert(
        item.declaration.body.body.length > 0,
        "Empty source implementation",
      );
      exported.add(item.declaration.id.name);
    }
  }
  for (const name of names)
    assert(exported.has(name), `Missing maintained source API ${name}`);
}

export function validateFunctionalOriginalCaseSource(bytes, definition) {
  assert(Buffer.isBuffer(bytes) && bytes.length > 0 && bytes.length <= 65536);
  const source = new TextDecoder("utf-8", { fatal: true }).decode(bytes);
  assert(!source.includes("\0"));
  assert(
    source.includes(`static let owner = "${definition.owner}"`),
    "Native original case owner differs from source definition",
  );
  for (const method of [
    "activateOriginalControl",
    "readAuthoritativeState",
    "readPersistentState",
    "shutdownPresentation",
  ])
    assert(
      new RegExp(`func\\s+${method}\\s*\\(`).test(source),
      `Missing original native case method ${definition.owner}.${method}`,
    );
  for (const blocked of [
    /\bstatic\s+let\s+blockingReason\b/,
    /\bthrow\s+Blocked\s*\(/,
    /\btry\s+fail\s*\(context\)/,
  ])
    assert(
      !blocked.test(source),
      `Unimplemented original native case ${definition.owner}`,
    );
  return true;
}

export async function checkFunctionalSourceReady({ repository, sourceCommit }) {
  const admitted = await admitFunctionalSources(repository, sourceCommit);
  for (const { definition } of admitted.cases)
    validateFunctionalOriginalCaseSource(
      await readFile(
        join(repository, functionalActionCasePaths(definition.owner).native),
      ),
      definition,
    );
  const requiredModules = {
    "scripts/hosted-functional-actions/controller.mjs": [
      "observeFunctionalActiveJob",
      "admitFunctionalProducerAuthority",
      "runFunctionalInstalledXCTestGeneration",
      "checkFunctionalSourceReady",
      "validateFunctionalOriginalCaseSource",
    ],
    "scripts/hosted-functional-actions/producer-project.mjs": [
      "functionalProducerPlan",
      "functionalProducerBootstrapSource",
      "buildFunctionalProducer",
      "functionalHostProject",
    ],
    "scripts/hosted-functional-actions/prepare-owner.mjs": [
      "functionalPairBuildPlan",
      "prepareFunctionalOwnerPair",
    ],
    "scripts/hosted-functional-actions/functional-build.mjs": [
      "captureFunctionalCompilationToolchain",
      "createFunctionalCompilation",
      "buildFunctionalFixtureHost",
      "functionalCompilationForBuilder",
      "bindFunctionalCompilationHost",
      "prepareFunctionalDocsDependency",
      "functionalDocsDependencyForBuilder",
      "observeFunctionalDocsDependency",
    ],
    "scripts/hosted-functional-actions/fixture-trust.mjs": [
      "admitFunctionalLiveIssuer",
      "admitFunctionalFixtureHost",
      "functionalFixtureBootstrapTrustSource",
      "functionalFixtureTrustSource",
      "functionalFixtureRolePolicySource",
    ],
    "scripts/hosted-functional-actions/owned-process.mjs": [
      "createFunctionalOwnedProcessObserver",
      "validateFunctionalProcessObservation",
    ],
    "scripts/hosted-functional-actions/run-functional.mjs": [
      "runHostedFunctionalActions",
      "validateFunctionalRunNativeSourceOperations",
    ],
  };
  const pins = new Set(admitted.sourcePins.files.map(({ path }) => path));
  for (const [path, names] of Object.entries(requiredModules)) {
    assert(pins.has(path), `Missing maintained builder source ${path}`);
    validateFunctionalSourceModuleExports(
      await readFile(join(repository, path)),
      names,
    );
  }
  for (const path of [
    ".github/workflows/hosted-functional-actions.yml",
    "Tests/HostedFunctionalActions/ProducerSources/FunctionalProcessProbe.swift",
    "Tests/HostedFunctionalActions/ProducerSources/FunctionalCollectedEvidence.swift",
    "Tests/HostedFunctionalActions/ProducerSources/FunctionalEvidenceAssembly.swift",
    "Tests/HostedFunctionalActions/ProducerSources/FunctionalEvidenceSealing.swift",
    "Tests/HostedFunctionalActions/ProducerSources/FunctionalContentActionRelations.swift",
    "Tests/HostedFunctionalActions/ProducerSources/FunctionalToolsActionRelations.swift",
    "Packages/EdithDocsWorker/Package.swift",
    "Packages/EdithDocsWorker/Package.resolved",
    "Tests/HostedFunctionalActions/ProducerSources/FunctionalSignatureProbe.swift",
    "Tests/HostedFunctionalActions/HostSources/FunctionalHostApplication.swift",
    "Tests/HostedFunctionalActions/HostSources/FunctionalHostSession.swift",
    "Tests/HostedFunctionalActions/HostSources/FunctionalHostBootstrap.swift",
    "Tests/HostedFunctionalActions/HostSources/FunctionalSyntheticMedia.swift",
    "Extensions/fixtureSupport/WorkerFixtureBootstrapTrustAnchor.swift",
    "Extensions/fixtureSupport/WorkerFixtureUITrustAnchor.swift",
  ])
    assert(
      pins.has(path),
      `Missing exact maintained native build source ${path}`,
    );
  const mediaSource = await readFile(
    join(
      repository,
      "Tests/HostedFunctionalActions/HostSources/FunctionalSyntheticMedia.swift",
    ),
    "utf8",
  );
  for (const operation of ["createTimeLapse", "createDownloadsAudio"])
    assert(
      mediaSource.includes(`static func ${operation}(`),
      `Missing actual native synthetic media source ${operation}`,
    );
  const policies = await admitFunctionalRolePolicies({
    repository,
    ...admitted,
  });
  const { validateFunctionalRunNativeSourceOperations } = await import(
    pathToFileURL(
      join(repository, "scripts/hosted-functional-actions/run-functional.mjs"),
    ).href
  );
  assert.equal(typeof validateFunctionalRunNativeSourceOperations, "function");
  validateFunctionalRunNativeSourceOperations(
    await readFile(
      join(
        repository,
        "Tests/HostedFunctionalActions/ProducerSources/FunctionalProducer.swift",
      ),
    ),
  );
  const observation = await admitFunctionalObservationPolicies({
    repository,
    sourcePins: admitted.sourcePins,
    cases: admitted.cases,
    policyBytes: policies.policyBytes,
  });
  const preparation = await admitFunctionalPreparationPolicies({
    repository,
    sourcePins: admitted.sourcePins,
    policyBytes: policies.policyBytes,
  });
  const savedReaders = await admitFunctionalSavedReaderPolicies({
    repository,
    sourcePins: admitted.sourcePins,
    policyBytes: policies.policyBytes,
    cases: admitted.cases,
  });
  assert.equal(
    policies.manifest.find(({ id }) => id === "virtualCamera")
      ?.systemExtensionCarrier?.transport,
    "obs",
  );
  const plan = functionalJourneyPlan(
    admitted.cases,
    admitted.recipes,
    sourceCommit,
  );
  await verifyFunctionalSourcePins(repository, admitted.sourcePins);
  return Object.freeze({
    ...admitted,
    ...policies,
    ...savedReaders,
    ...preparation,
    ...observation,
    plan,
  });
}

export async function functionalControllerMain({
  arguments_ = process.argv.slice(2),
  repository = process.cwd(),
  environment = process.env,
} = {}) {
  assert(
    arguments_.length === 1 &&
      ["--check-source-ready", "--run"].includes(arguments_[0]),
  );
  repository = await realpath(repository);
  const sourceCommit = environment.EXPECTED_SOURCE_SHA;
  if (arguments_[0] === "--check-source-ready") {
    admitFunctionalSourceEnvironment(environment, sourceCommit);
    const ready = await checkFunctionalSourceReady({
      repository,
      sourceCommit,
    });
    const result = {
      sourceCommit,
      ownerCount: ready.plan.owners.length,
      policySHA256: ready.admittedPolicies.policySHA256,
      sourceReady: true,
      nativeProof: false,
      qualifiedEvidence: false,
    };
    process.stdout.write(`${functionalCanonicalJSON(result)}\n`);
    return result;
  }
  admitFunctionalRunner(environment, sourceCommit);
  assert.equal(process.platform, "darwin");
  assert.equal(process.arch, "arm64");
  await checkFunctionalSourceReady({ repository, sourceCommit });
  await observeFunctionalActiveJob({ repository, sourceCommit, environment });
  const { runHostedFunctionalActions } = await import("./run-functional.mjs");
  assert.equal(typeof runHostedFunctionalActions, "function");
  return runHostedFunctionalActions({ repository, sourceCommit, environment });
}

if (
  process.argv[1] &&
  import.meta.url === pathToFileURL(resolve(process.argv[1])).href
)
  await functionalControllerMain();

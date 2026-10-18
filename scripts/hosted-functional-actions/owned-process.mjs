import assert from "node:assert/strict";
import { spawn, spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { constants, fstatSync, lstatSync, realpathSync } from "node:fs";
import { lstat, open, realpath } from "node:fs/promises";
import { dirname, posix } from "node:path";
import { functionalActionOwners } from "./owners.mjs";

export const functionalProcessProbeSources = Object.freeze([
  "Tests/HostedFunctionalActions/ProducerSources/FunctionalIssuer.swift",
  "Tests/HostedFunctionalActions/ProducerSources/FunctionalLifecycle.swift",
  "Tests/HostedFunctionalActions/ProducerSources/FunctionalProcessProbe.swift",
]);
export const functionalProcessObserverSourcePaths = Object.freeze([
  ...functionalProcessProbeSources,
  "Tests/HostedFunctionalActions/Package.swift",
  "scripts/hosted-functional-actions/owned-process.mjs",
  "scripts/hosted-functional-actions/owners.mjs",
]);
const digest = (bytes) => createHash("sha256").update(bytes).digest("hex");
const birthKeys = [
  "birthMicroseconds",
  "birthSeconds",
  "executable",
  "executableSHA256",
  "pid",
  "uid",
];

function exact(value, fields) {
  assert(value && Object.getPrototypeOf(value) === Object.prototype);
  assert.deepEqual(Reflect.ownKeys(value).sort(), [...fields].sort());
  for (const field of fields) {
    const descriptor = Object.getOwnPropertyDescriptor(value, field);
    assert(descriptor.enumerable && Object.hasOwn(descriptor, "value"));
  }
}

function integer(value, minimum, maximum) {
  assert(Number.isSafeInteger(value) && !Object.is(value, -0));
  assert(value >= minimum && value <= maximum);
}

function text(value, maximum) {
  assert(
    typeof value === "string" && value.length > 0 && value.length <= maximum,
  );
  assert(/^[ -~]+$/.test(value));
}

function path(value) {
  text(value, 4096);
  assert(value.startsWith("/") && value !== "/" && !value.endsWith("/"));
  assert.equal(posix.normalize(value), value);
  assert(!value.includes("//"));
}

function sha256(value) {
  assert(typeof value === "string" && /^[0-9a-f]{64}$/.test(value));
}

function executablePin(value) {
  exact(value, ["executable", "executableSHA256"]);
  path(value.executable);
  sha256(value.executableSHA256);
  return Object.freeze({ ...value });
}

export function validateFunctionalProcessPins(value) {
  exact(value, [
    "executable",
    "executableSHA256",
    "identifier",
    "certificateSHA256",
    "requirement",
  ]);
  executablePin({
    executable: value.executable,
    executableSHA256: value.executableSHA256,
  });
  text(value.identifier, 256);
  text(value.requirement, 1024);
  assert(typeof value.certificateSHA256 === "string");
  assert(/^[A-Za-z0-9+/]{43}=$/.test(value.certificateSHA256));
  const certificate = Buffer.from(value.certificateSHA256, "base64");
  assert.equal(certificate.length, 32);
  assert.equal(certificate.toString("base64"), value.certificateSHA256);
  return Object.freeze({ ...value });
}

export function validateFunctionalProcessBirth(value) {
  exact(value, birthKeys);
  integer(value.pid, 2, 2147483647);
  integer(value.birthSeconds, 1, Number.MAX_SAFE_INTEGER);
  integer(value.birthMicroseconds, 0, 999999);
  integer(value.uid, 0, 4294967295);
  path(value.executable);
  sha256(value.executableSHA256);
  return Object.freeze({ ...value });
}

export function validateFunctionalProcessObservation(bytes) {
  assert(Buffer.isBuffer(bytes) && bytes.length > 0 && bytes.length <= 16384);
  const raw = new TextDecoder("utf-8", { fatal: true, ignoreBOM: true }).decode(
    bytes,
  );
  const value = JSON.parse(raw);
  exact(value, ["schema", "birth"]);
  assert.equal(value.schema, 1);
  const birth = validateFunctionalProcessBirth(value.birth);
  assert.equal(
    JSON.stringify(value, ["birth", ...birthKeys, "schema"].sort()),
    raw,
  );
  return Object.freeze({ schema: 1, birth });
}

export function validateFunctionalProcessAbsence(bytes, recorded) {
  const birth = validateFunctionalProcessBirth(recorded);
  assert(Buffer.isBuffer(bytes) && bytes.length > 0 && bytes.length <= 16384);
  const raw = new TextDecoder("utf-8", { fatal: true }).decode(bytes);
  const value = JSON.parse(raw);
  exact(value, ["schema", "recordedBirth", "basis", "currentBirth"]);
  assert.equal(value.schema, 1);
  exact(value.recordedBirth, [
    "pid",
    "birthSeconds",
    "birthMicroseconds",
    "uid",
  ]);
  for (const [key, item] of Object.entries(value.recordedBirth))
    assert.equal(item, birth[key]);
  if (value.basis === "pid-missing") assert.equal(value.currentBirth, null);
  else {
    assert.equal(value.basis, "pid-reused");
    exact(value.currentBirth, ["birthSeconds", "birthMicroseconds", "uid"]);
    integer(value.currentBirth.birthSeconds, 1, Number.MAX_SAFE_INTEGER);
    integer(value.currentBirth.birthMicroseconds, 0, 999999);
    integer(value.currentBirth.uid, 0, 4294967295);
    assert(
      value.currentBirth.birthSeconds !== birth.birthSeconds ||
        value.currentBirth.birthMicroseconds !== birth.birthMicroseconds,
    );
  }
  assert.equal(
    JSON.stringify(
      value,
      [
        "schema",
        "recordedBirth",
        "pid",
        "birthSeconds",
        "birthMicroseconds",
        "uid",
        "basis",
        "currentBirth",
      ].sort(),
    ),
    raw,
  );
  return Object.freeze({
    schema: 1,
    recordedBirth: Object.freeze({ ...value.recordedBirth }),
    basis: value.basis,
    currentBirth:
      value.currentBirth === null
        ? null
        : Object.freeze({ ...value.currentBirth }),
  });
}

export function matchFunctionalOwnedProcessBirth(
  observed,
  expected,
  reportedBirth,
) {
  const birth = validateFunctionalProcessBirth(observed);
  exact(expected, ["pid", "uid", "executable", "executableSHA256"]);
  integer(expected.pid, 2, 2147483647);
  integer(expected.uid, 0, 4294967295);
  executablePin({
    executable: expected.executable,
    executableSHA256: expected.executableSHA256,
  });
  for (const field of Object.keys(expected))
    assert.equal(
      birth[field],
      expected[field],
      `Independent process mismatch ${field}`,
    );
  assert.deepEqual(
    birth,
    validateFunctionalProcessBirth(reportedBirth),
    "Independent birth mismatch",
  );
  return birth;
}

async function pinExecutable(specification) {
  const spec = executablePin(specification);
  assert.equal(await realpath(spec.executable), spec.executable);
  const file = await open(
    spec.executable,
    constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK,
  );
  try {
    const state = await file.stat({ bigint: true });
    assert(
      state.isFile() &&
        state.nlink === 1n &&
        state.uid === BigInt(process.getuid()),
    );
    assert((state.mode & 0o022n) === 0n && (state.mode & 0o111n) !== 0n);
    assert(state.size > 0n && state.size <= 268435456n);
    const identity = (current) => {
      for (const field of [
        "dev",
        "ino",
        "uid",
        "mode",
        "nlink",
        "size",
        "mtimeNs",
        "ctimeNs",
      ])
        assert.equal(current[field], state[field], "Executable replaced");
    };
    const requireCurrent = async () => {
      assert.equal(await realpath(spec.executable), spec.executable);
      identity(await lstat(spec.executable, { bigint: true }));
      identity(await file.stat({ bigint: true }));
    };
    await requireCurrent();
    assert.equal(
      digest(await file.readFile()),
      spec.executableSHA256,
      "Executable hash mismatch",
    );
    await requireCurrent();
    const requireCurrentSync = () => {
      assert.equal(realpathSync(spec.executable), spec.executable);
      identity(lstatSync(spec.executable, { bigint: true }));
      identity(fstatSync(file.fd, { bigint: true }));
    };
    return { requireCurrent, requireCurrentSync, close: () => file.close() };
  } catch (error) {
    await file.close();
    throw error;
  }
}

const observationBudgets = new WeakMap();

export function createFunctionalProcessObservationBudget({
  sourceCommit,
  sourcePins,
  recipeSources,
}) {
  assert.match(sourceCommit, /^[0-9a-f]{40}$/);
  exact(sourcePins, ["sourceCommit", "files"]);
  assert.equal(sourcePins.sourceCommit, sourceCommit);
  assert(Array.isArray(sourcePins.files));
  exact(recipeSources, functionalActionOwners);
  const pins = new Map();
  for (const pin of sourcePins.files) {
    exact(pin, ["path", "sha256"]);
    text(pin.path, 4096);
    sha256(pin.sha256);
    assert(!pins.has(pin.path), "Duplicate source pin");
    pins.set(pin.path, pin.sha256);
  }
  let literalSteps = 0;
  const recipes = [];
  for (const owner of functionalActionOwners) {
    const entry = recipeSources[owner];
    exact(entry, ["path", "bytes", "sha256"]);
    assert.equal(
      entry.path,
      `scripts/hosted-functional-actions/presentations/${owner}.json`,
    );
    assert(
      Buffer.isBuffer(entry.bytes) &&
        entry.bytes.length > 0 &&
        entry.bytes.length <= 1048576,
    );
    sha256(entry.sha256);
    assert.equal(digest(entry.bytes), entry.sha256);
    assert.equal(
      pins.get(entry.path),
      entry.sha256,
      "Recipe differs from source tree",
    );
    const recipe = JSON.parse(
      new TextDecoder("utf-8", { fatal: true }).decode(entry.bytes),
    );
    assert.equal(recipe.schema, 1);
    assert.equal(recipe.owner, owner);
    assert(
      Array.isArray(recipe.steps) &&
        recipe.steps.length >= 1 &&
        recipe.steps.length <= 16,
    );
    literalSteps += recipe.steps.length;
    recipes.push(
      Object.freeze({
        owner,
        path: entry.path,
        sha256: entry.sha256,
        steps: recipe.steps.length,
      }),
    );
  }
  const owners = functionalActionOwners.length;
  const phases = 3;
  const startup = 256;
  const ownerBoundaries = owners * 64;
  const phaseBoundaries = owners * phases * 16 * 4;
  const stepBoundaries = literalSteps * phases * 12 * 4;
  const retirementBoundaries = 2;
  const limit =
    startup +
    ownerBoundaries +
    phaseBoundaries +
    stepBoundaries +
    retirementBoundaries;
  const budget = Object.freeze({
    sourceCommit,
    recipes: Object.freeze(recipes),
    phases,
    literalSteps,
    startup,
    ownerBoundaries,
    phaseBoundaries,
    stepBoundaries,
    retirementBoundaries,
    limit,
  });
  observationBudgets.set(budget, limit);
  return budget;
}

export function createFunctionalProcessObservationCounter(budget) {
  const limit = observationBudgets.get(budget);
  assert(
    Number.isSafeInteger(limit),
    "Expected source-bound observation budget",
  );
  let count = 0;
  return Object.freeze({
    consume() {
      assert(count < limit, "Process observation count bound");
      count++;
    },
    get count() {
      return count;
    },
    limit,
  });
}

export async function createFunctionalOwnedProcessObserver(configuration) {
  exact(
    configuration,
    Object.hasOwn(configuration, "deadlineMilliseconds")
      ? ["helper", "observationBudget", "deadlineMilliseconds"]
      : ["helper", "observationBudget"],
  );
  assert.equal(process.platform, "darwin");
  assert.equal(process.arch, "arm64");
  const helper = executablePin(configuration.helper);
  const deadline = configuration.deadlineMilliseconds ?? 5000;
  integer(deadline, 1000, 10000);
  const observations = createFunctionalProcessObservationCounter(
    configuration.observationBudget,
  );
  const helperPin = await pinExecutable(helper);
  const receipts = new WeakMap();
  const owned = new Set();
  const pending = new Set();
  let closed = false;
  let launches = 0;

  function retained(receipt) {
    assert(!closed, "Observer closed");
    const state = receipts.get(receipt);
    assert(
      state && !state.failed && !state.exited,
      "Unretained or stale child",
    );
    assert.equal(state.child.pid, state.pid);
    assert.equal(state.child.exitCode, null);
    assert.equal(state.child.signalCode, null);
    return state;
  }

  function probeArguments(state) {
    const spec = state.spec;
    return [
      String(state.pid),
      spec.executable,
      spec.executableSHA256,
      spec.identifier,
      spec.certificateSHA256,
      spec.requirement,
      String(deadline),
    ];
  }

  function probeOptions() {
    return {
      cwd: dirname(helper.executable),
      env: { PATH: "/usr/bin:/bin", LANG: "C" },
      shell: false,
      stdio: ["ignore", "pipe", "pipe"],
    };
  }

  function startObservation() {
    observations.consume();
  }

  function retainedExited(receipt) {
    assert(!closed, "Observer closed");
    const state = receipts.get(receipt);
    assert(
      state?.birth &&
        state.exited &&
        state.joinedComplete &&
        !state.failed &&
        !state.observing,
      "Expected retained naturally joined owned child",
    );
    assert.equal(state.child.pid, state.pid);
    assert.equal(state.child.exitCode, 0);
    assert.equal(state.child.signalCode, null);
    return state;
  }

  async function probe(state, absent = false) {
    if (absent) retainedExited(state.receipt);
    else retained(state.receipt);
    await helperPin.requireCurrent();
    await state.pin.requireCurrent();
    startObservation();
    const child = spawn(
      helper.executable,
      absent
        ? [
            "--require-absent",
            String(state.pid),
            String(state.birth.birthSeconds),
            String(state.birth.birthMicroseconds),
            String(state.birth.uid),
            String(deadline),
          ]
        : probeArguments(state),
      probeOptions(),
    );
    let resolveJoin;
    const join = new Promise((resolve) => {
      resolveJoin = resolve;
    });
    const helperReceipt = Object.freeze({ child, join });
    pending.add(helperReceipt);
    const bytes = await new Promise((resolve, reject) => {
      let stdout = Buffer.alloc(0),
        stderrLength = 0;
      const timer = setTimeout(
        () => reject(new Error("Process observation deadline")),
        deadline,
      );
      child.stdout.on("data", (chunk) => {
        if (stdout.length + chunk.length > 16384)
          reject(new Error("Process observation output bound"));
        else stdout = Buffer.concat([stdout, chunk]);
      });
      child.stderr.on("data", (chunk) => {
        stderrLength += chunk.length;
        if (stderrLength > 4096)
          reject(new Error("Process observation error bound"));
      });
      child.on("error", reject);
      child.once("close", (code, signal) => {
        clearTimeout(timer);
        pending.delete(helperReceipt);
        resolveJoin();
        if (code !== 0 || signal !== null || stderrLength !== 0)
          reject(new Error("Process observation helper failed"));
        else resolve(stdout);
      });
    });
    await helperPin.requireCurrent();
    await state.pin.requireCurrent();
    if (absent) {
      retainedExited(state.receipt);
      return validateFunctionalProcessAbsence(bytes, state.birth);
    }
    retained(state.receipt);
    return validateFunctionalProcessObservation(bytes).birth;
  }

  async function observe(receipt, reportedBirth, binding) {
    const state = retained(receipt);
    assert(!state.observing, "Concurrent process observation");
    assert(
      binding ? state.birth === undefined : state.birth !== undefined,
      "Process binding state",
    );
    const reported = binding
      ? validateFunctionalProcessBirth(reportedBirth)
      : state.birth;
    state.observing = true;
    try {
      const birth = matchFunctionalOwnedProcessBirth(
        await probe(state),
        {
          pid: state.pid,
          uid: process.getuid(),
          executable: state.spec.executable,
          executableSHA256: state.spec.executableSHA256,
        },
        reported,
      );
      state.birth = birth;
      return birth;
    } catch (error) {
      state.failed = true;
      throw error;
    } finally {
      state.observing = false;
    }
  }

  return Object.freeze({
    async spawn(specification, arguments_, options) {
      assert(!closed, "Observer closed");
      const spec = validateFunctionalProcessPins(specification);
      assert(Array.isArray(arguments_) && arguments_.length <= 128);
      const args = [...arguments_];
      assert(
        args.every(
          (value) =>
            typeof value === "string" &&
            !value.includes("\0") &&
            Buffer.byteLength(value) <= 4096,
        ),
      );
      exact(options, ["cwd", "env"]);
      const cwd = options.cwd;
      path(cwd);
      assert(
        options.env && Object.getPrototypeOf(options.env) === Object.prototype,
      );
      const environment = {};
      for (const key of Reflect.ownKeys(options.env)) {
        assert(typeof key === "string" && /^[A-Za-z_][A-Za-z0-9_]*$/.test(key));
        const descriptor = Object.getOwnPropertyDescriptor(options.env, key);
        assert(Object.hasOwn(descriptor, "value") && descriptor.enumerable);
        assert(
          typeof descriptor.value === "string" &&
            !descriptor.value.includes("\0"),
        );
        Object.defineProperty(environment, key, {
          value: descriptor.value,
          enumerable: true,
        });
      }
      assert.equal(await realpath(cwd), cwd);
      const pin = await pinExecutable({
        executable: spec.executable,
        executableSHA256: spec.executableSHA256,
      });
      launches++;
      try {
        await helperPin.requireCurrent();
        await pin.requireCurrent();
        assert(!closed, "Observer closed");
        const child = spawn(spec.executable, args, {
          cwd,
          env: environment,
          shell: false,
          stdio: ["pipe", "pipe", "pipe"],
        });
        let resolveJoined;
        const joined = new Promise((resolve) => {
          resolveJoined = resolve;
        });
        child.once("close", resolveJoined);
        const receipt = Object.freeze({ child, joined });
        const state = {
          receipt,
          child,
          spec,
          pin,
          pid: undefined,
          birth: undefined,
          exited: false,
          failed: false,
          observing: false,
          joinedComplete: false,
          exitReceipt: undefined,
          exitObserving: false,
        };
        child.once("close", () => {
          state.joinedComplete = true;
        });
        child.once("exit", () => {
          state.exited = true;
        });
        child.on("error", () => {
          state.failed = true;
        });
        await new Promise((resolve, reject) => {
          child.once("spawn", resolve);
          child.once("error", reject);
        });
        state.pid = child.pid;
        integer(state.pid, 2, 2147483647);
        receipts.set(receipt, state);
        owned.add(state);
        return receipt;
      } catch (error) {
        await pin.close();
        throw error;
      } finally {
        launches--;
      }
    },
    bind: (receipt, reportedBirth) => observe(receipt, reportedBirth, true),
    requireCurrent: (receipt) => observe(receipt, undefined, false),
    requireCurrentSync(receipt) {
      const state = retained(receipt);
      assert(
        state.birth !== undefined && !state.observing,
        "Process binding state",
      );
      state.observing = true;
      try {
        helperPin.requireCurrentSync();
        state.pin.requireCurrentSync();
        startObservation();
        const result = spawnSync(helper.executable, probeArguments(state), {
          ...probeOptions(),
          maxBuffer: Infinity,
        });
        assert(
          !result.error && result.status === 0 && result.signal === null,
          "Process observation helper failed",
        );
        integer(result.pid, 2, 2147483647);
        assert(
          Buffer.isBuffer(result.stderr) && result.stderr.length === 0,
          "Process observation error output",
        );
        helperPin.requireCurrentSync();
        state.pin.requireCurrentSync();
        retained(receipt);
        return matchFunctionalOwnedProcessBirth(
          validateFunctionalProcessObservation(result.stdout).birth,
          {
            pid: state.pid,
            uid: process.getuid(),
            executable: state.spec.executable,
            executableSHA256: state.spec.executableSHA256,
          },
          state.birth,
        );
      } catch (error) {
        state.failed = true;
        throw error;
      } finally {
        state.observing = false;
      }
    },
    async observeNaturalExit(receipt) {
      const state = receipts.get(receipt);
      assert(state?.birth, "Expected independently bound owned child");
      await receipt.joined;
      retainedExited(receipt);
      assert(
        !state.exitReceipt && !state.exitObserving,
        "Owned natural exit already observed",
      );
      state.exitObserving = true;
      try {
        const absence = await probe(state, true);
        retainedExited(receipt);
        state.exitReceipt = Object.freeze({
          schema: 1,
          birth: state.birth,
          exitCode: state.child.exitCode,
          signal: state.child.signalCode,
          absence,
          helper: Object.freeze({ ...helper }),
        });
        return state.exitReceipt;
      } finally {
        state.exitObserving = false;
      }
    },
    async close() {
      assert(!closed, "Observer closed");
      assert(launches === 0, "Owned launch in progress");
      assert(
        [...owned].every(
          (state) => state.exited && !state.observing && !state.exitObserving,
        ),
        "Owned children must naturally exit first",
      );
      closed = true;
      await Promise.all([...pending].map(({ join }) => join));
      await Promise.all([...owned].map(({ receipt }) => receipt.joined));
      await Promise.all([...owned].map((state) => state.pin.close()));
      await helperPin.close();
    },
  });
}

import assert from "node:assert/strict";
import * as childProcess from "node:child_process";
import * as crypto from "node:crypto";
import { EventEmitter } from "node:events";
import * as fs from "node:fs";
import { readFile } from "node:fs/promises";
import * as path from "node:path";
import { PassThrough } from "node:stream";
import test from "node:test";
import * as vm from "node:vm";
import {
  createFunctionalProcessObservationBudget,
  createFunctionalProcessObservationCounter,
  functionalProcessObserverSourcePaths,
  functionalProcessProbeSources,
  matchFunctionalOwnedProcessBirth,
  validateFunctionalProcessAbsence,
  validateFunctionalProcessBirth,
  validateFunctionalProcessObservation,
  validateFunctionalProcessPins,
} from "./owned-process.mjs";

import { functionalActionOwners } from "./owners.mjs";

const birth = Object.freeze({
  birthMicroseconds: 123456,
  birthSeconds: 1234567890,
  executable: "/synthetic/producer",
  executableSHA256: "a".repeat(64),
  pid: 4001,
  uid: 501,
});
const encode = (value) => Buffer.from(JSON.stringify(value));
const observation = (value = birth) => encode({ birth: value, schema: 1 });
const pins = Object.freeze({
  executable: birth.executable,
  executableSHA256: birth.executableSHA256,
  identifier: "test.synthetic.producer",
  certificateSHA256: Buffer.alloc(32, 7).toString("base64"),
  requirement: 'identifier "test.synthetic.producer"',
});
const expected = {
  pid: birth.pid,
  uid: birth.uid,
  executable: birth.executable,
  executableSHA256: birth.executableSHA256,
};

test("strict observation accepts one closed canonical payload and returns frozen copies", () => {
  const value = validateFunctionalProcessObservation(observation());
  assert.deepEqual(value, { schema: 1, birth });
  assert(Object.isFrozen(value) && Object.isFrozen(value.birth));
  assert.notEqual(value.birth, birth);
});

for (const [name, bytes] of [
  ["empty", Buffer.alloc(0)],
  ["bound", Buffer.alloc(16385, 32)],
  ["invalid UTF8", Buffer.from([255])],
  ["BOM", Buffer.concat([Buffer.from([239, 187, 191]), observation()])],
  ["trailing line", Buffer.concat([observation(), Buffer.from("\n")])],
  [
    "duplicate schema",
    Buffer.from(
      observation().toString().replace('"schema":1', '"schema":0,"schema":1'),
    ),
  ],
  [
    "duplicate birth field",
    Buffer.from(
      observation().toString().replace('"pid":4001', '"pid":2,"pid":4001'),
    ),
  ],
  [
    "alternate number",
    Buffer.from(
      observation().toString().replace('"pid":4001', '"pid":4.001e3'),
    ),
  ],
  [
    "alternate escape",
    Buffer.from(
      observation().toString().replace("/synthetic/", "\\/synthetic/"),
    ),
  ],
  ["wrong schema", encode({ birth, schema: 2 })],
  ["additional metadata", encode({ birth, metadata: "untrusted", schema: 1 })],
  ["missing schema", encode({ birth })],
  ["array", encode([birth])],
  ["null", encode(null)],
  ["two payloads", Buffer.concat([observation(), observation()])],
  ["key order", encode({ schema: 1, birth })],
])
  test(`strict observation rejects ${name}`, () => {
    assert.throws(() => validateFunctionalProcessObservation(bytes));
  });

for (const [field, values] of Object.entries({
  pid: [0, 1, -1, 2147483648, 1.5, "4001", true, null],
  birthSeconds: [0, -1, Number.MAX_SAFE_INTEGER + 1, 1.2, "1234567890", true],
  birthMicroseconds: [-1, -0, 1000000, 0.5, "123456", false],
  uid: [-1, -0, 4294967296, 0.1, "501", true],
  executable: [
    "relative",
    "/",
    "/synthetic//producer",
    "/synthetic/../producer",
    "/synthetic/producer/",
    "/synthetic/./producer",
    "/synthetic/producer\0",
    "/synthetic/é",
    `/${"a".repeat(4096)}`,
  ],
  executableSHA256: ["a".repeat(63), "A".repeat(64), "z".repeat(64), null],
}))
  test(`birth rejects invalid ${field}`, () => {
    for (const value of values)
      assert.throws(() =>
        validateFunctionalProcessBirth({ ...birth, [field]: value }),
      );
  });

test("birth and signer schemas reject missing, extra, prototype and accessor fields", () => {
  for (const validate of [
    validateFunctionalProcessBirth,
    validateFunctionalProcessAbsence,
    validateFunctionalProcessPins,
  ]) {
    const source = validate === validateFunctionalProcessBirth ? birth : pins;
    for (const key of Object.keys(source)) {
      const missing = { ...source };
      delete missing[key];
      assert.throws(() => validate(missing));
    }
    assert.throws(() => validate({ ...source, sourceCommit: "a".repeat(40) }));
    assert.throws(() => validate(Object.assign(Object.create(null), source)));
    assert.throws(() => validate(Object.create(source)));
    const accessor = { ...source };
    Object.defineProperty(accessor, "executable", {
      get() {
        throw new Error("Accessor evaluated");
      },
    });
    assert.throws(() => validate(accessor), { name: "AssertionError" });
    assert.throws(() => validate({ ...source, [Symbol("extra")]: true }));
  }
});

test("signer pins reject malformed certificates, text, and fixture authority", () => {
  assert.deepEqual(validateFunctionalProcessPins(pins), pins);
  for (const certificateSHA256 of [
    "",
    Buffer.alloc(31).toString("base64"),
    `${"A".repeat(42)}B=`,
    pins.certificateSHA256.slice(0, -1),
    null,
  ]) {
    assert.throws(() =>
      validateFunctionalProcessPins({ ...pins, certificateSHA256 }),
    );
  }
  for (const field of ["identifier", "requirement"])
    for (const value of ["", "bad\ntext", "bad\0text", "é", "a".repeat(1025)])
      assert.throws(() =>
        validateFunctionalProcessPins({ ...pins, [field]: value }),
      );
  assert.throws(() =>
    validateFunctionalProcessPins({ ...pins, fixtureInfo: { trusted: true } }),
  );
});

test("inert independent process models reject forged stdout, replacement, uid, path, and hash", () => {
  assert.deepEqual(
    matchFunctionalOwnedProcessBirth(birth, expected, birth),
    birth,
  );
  for (const [field, value] of Object.entries({
    pid: 4002,
    uid: 502,
    birthSeconds: 1234567891,
    birthMicroseconds: 123457,
    executable: "/synthetic/replaced",
    executableSHA256: "b".repeat(64),
  })) {
    const changed = { ...birth, [field]: value };
    assert.throws(() =>
      matchFunctionalOwnedProcessBirth(changed, expected, birth),
    );
    assert.throws(() =>
      matchFunctionalOwnedProcessBirth(birth, expected, changed),
    );
  }
});

test("trusted helper graph reuses lifecycle methods without GUI or generated authority", async () => {
  assert.equal(functionalProcessProbeSources.length, 3);
  assert(
    functionalProcessObserverSourcePaths.includes(
      "Tests/HostedFunctionalActions/Package.swift",
    ),
  );
  const source = await readFile(
    new URL(
      "../../Tests/HostedFunctionalActions/ProducerSources/FunctionalProcessProbe.swift",
      import.meta.url,
    ),
    "utf8",
  );
  for (const call of [
    "FunctionalBirth.observe(pid)",
    "FunctionalSigner(identifier:",
    ".verify(url, birth: birth)",
    "pinned.requireCurrent()",
    "birth.requireCurrent()",
  ])
    assert(source.replace(/\s+/g, "").includes(call.replace(/\s+/g, "")));
  assert(
    !/AppKit|SwiftUI|ApplicationServices|SecCodeCopyGuest|ProcessInfo|FunctionalProducerBuild/.test(
      source,
    ),
  );
  assert(source.includes("arguments.count == 8"));
  assert(source.includes("arguments.count == 7"));
  assert.equal(source.match(/proc_pidinfo\(/g).length, 1);
  assert(source.includes("result == 0, errno == ESRCH"));
  assert(
    source.includes(
      "state.pbi_start_tvsec != seconds || state.pbi_start_tvusec != microseconds",
    ),
  );
});

function observationBudgetFixture(steps = 1) {
  const sourceCommit = "a".repeat(40);
  const recipeSources = Object.fromEntries(
    functionalActionOwners.map((owner) => {
      const path = `scripts/hosted-functional-actions/presentations/${owner}.json`;
      const bytes = Buffer.from(
        JSON.stringify({
          schema: 1,
          owner,
          steps: Array.from({ length: steps }, () => ({
            role: "button",
            label: "Synthetic",
            action: "click",
            value: null,
          })),
        }),
      );
      return [
        owner,
        {
          path,
          bytes,
          sha256: crypto.createHash("sha256").update(bytes).digest("hex"),
        },
      ];
    }),
  );
  const sourcePins = {
    sourceCommit,
    files: Object.values(recipeSources).map(({ path, sha256 }) => ({
      path,
      sha256,
    })),
  };
  return { sourceCommit, sourcePins, recipeSources };
}

async function inertLauncher() {
  const source = await readFile(
    new URL("./owned-process.mjs", import.meta.url),
    "utf8",
  );
  const producerBytes = Buffer.from("synthetic producer executable");
  const helperBytes = Buffer.from("synthetic helper executable");
  const sha = (bytes) =>
    crypto.createHash("sha256").update(bytes).digest("hex");
  const ownedBirth = {
    ...birth,
    executableSHA256: sha(producerBytes),
    uid: process.getuid(),
  };
  const files = new Map([
    ["/synthetic/producer", producerBytes],
    ["/synthetic/helper", helperBytes],
  ]);
  const model = {
    birth: ownedBirth,
    calls: [],
    children: [],
    replaced: false,
    helperOutput: undefined,
    helperCode: 0,
    helperSignal: null,
    helperError: undefined,
    holdHelper: false,
    descriptorsClosed: 0,
  };
  const state = (name) => ({
    dev: 1n,
    ino: name.endsWith("helper") ? 2n : model.replaced ? 4n : 3n,
    uid: BigInt(process.getuid()),
    mode: 0o100700n,
    nlink: 1n,
    size: BigInt(files.get(name).length),
    mtimeNs: 1n,
    ctimeNs: 1n,
    isFile: () => true,
  });
  const descriptors = new Map();
  let descriptorCount = 10;
  const fileSystem = {
    realpath: async (name) => name,
    lstat: async (name) => state(name),
    open: async (name) => {
      const original = state(name);
      const fd = descriptorCount++;
      descriptors.set(fd, original);
      return {
        fd,
        stat: async () => original,
        readFile: async () => files.get(name),
        close: async () => {
          model.descriptorsClosed++;
        },
      };
    },
  };
  const fakeSpawn = (executable, args, options) => {
    model.calls.push({ executable, args, options });
    const child = Object.assign(new EventEmitter(), {
      pid: executable.endsWith("helper") ? 5001 : 4001,
      exitCode: null,
      signalCode: null,
      stdin: new PassThrough(),
      stdout: new PassThrough(),
      stderr: new PassThrough(),
      kill() {
        throw new Error("Signals forbidden");
      },
    });
    const finish = (code = 0, signal = null) => {
      child.exitCode = code;
      child.signalCode = signal;
      child.emit("exit", code, signal);
      child.emit("close", code, signal);
    };
    model.children.push({ child, finish });
    queueMicrotask(() => {
      child.emit("spawn");
      if (executable.endsWith("helper")) {
        const absent = encode({
          basis: "pid-missing",
          currentBirth: null,
          recordedBirth: {
            birthMicroseconds: model.birth.birthMicroseconds,
            birthSeconds: model.birth.birthSeconds,
            pid: model.birth.pid,
            uid: model.birth.uid,
          },
          schema: 1,
        });
        child.stdout.write(
          model.helperOutput ??
            (args[0] === "--require-absent"
              ? absent
              : observation(model.birth)),
        );
        if (model.helperError) child.stderr.write(model.helperError);
        if (!model.holdHelper) finish(model.helperCode, model.helperSignal);
      }
    });
    return child;
  };
  const fakeSpawnSync = (executable, args, options) => {
    model.calls.push({ executable, args, options });
    return {
      pid: 5002,
      status: model.helperCode,
      signal: model.helperSignal,
      error: undefined,
      stdout: model.helperOutput ?? observation(model.birth),
      stderr: model.helperError ?? Buffer.alloc(0),
    };
  };
  const dependencies = {
    "node:assert/strict": { default: assert },
    "node:child_process": {
      ...childProcess,
      spawn: fakeSpawn,
      spawnSync: fakeSpawnSync,
    },
    "node:crypto": crypto,
    "node:fs": {
      ...fs,
      realpathSync: (name) => name,
      lstatSync: (name) => state(name),
      fstatSync: (fd) => descriptors.get(fd),
    },
    "node:fs/promises": fileSystem,
    "node:path": path,
    "./owners.mjs": { functionalActionOwners },
  };
  const module = new vm.SourceTextModule(source);
  await module.link((name) => {
    const exports = dependencies[name];
    assert(exports, `Unreviewed dependency ${name}`);
    return new vm.SyntheticModule(Object.keys(exports), function () {
      for (const [key, value] of Object.entries(exports))
        this.setExport(key, value);
    });
  });
  await module.evaluate();
  const observationBudget =
    module.namespace.createFunctionalProcessObservationBudget(
      observationBudgetFixture(),
    );
  const observer = await module.namespace.createFunctionalOwnedProcessObserver({
    observationBudget,
    helper: {
      executable: "/synthetic/helper",
      executableSHA256: sha(helperBytes),
    },
    deadlineMilliseconds: 1000,
  });
  const receipt = await observer.spawn(
    { ...pins, executableSHA256: ownedBirth.executableSHA256 },
    [],
    { cwd: "/synthetic", env: { SYNTHETIC: "1" } },
  );
  return {
    model,
    observer,
    receipt,
    observationBudget,
    birth: ownedBirth,
    finish: () => model.children[0].finish(),
  };
}

const models = {
  skip:
    typeof vm.SourceTextModule !== "function" ||
    process.platform !== "darwin" ||
    process.arch !== "arm64",
};

test(
  "inert launcher binds actual retained spawn and independently reobserves every call",
  models,
  async () => {
    const {
      model,
      observer,
      receipt,
      birth: current,
      finish,
    } = await inertLauncher();
    assert.equal(receipt.child, model.children[0].child);
    assert(Object.isFrozen(receipt));
    await assert.rejects(observer.bind({ child: receipt.child }, current));
    await assert.rejects(observer.requireCurrent(receipt));
    assert.deepEqual(await observer.bind(receipt, current), current);
    await assert.rejects(observer.bind(receipt, current));
    await observer.requireCurrent(receipt);
    await observer.requireCurrent(receipt);
    assert.equal(model.calls.length, 4);
    for (const call of model.calls.slice(1)) {
      assert.equal(call.executable, "/synthetic/helper");
      assert.deepEqual(call.args, [
        "4001",
        pins.executable,
        current.executableSHA256,
        pins.identifier,
        pins.certificateSHA256,
        pins.requirement,
        "1000",
      ]);
      assert.equal(call.options.shell, false);
      assert.deepEqual(call.options.env, { PATH: "/usr/bin:/bin", LANG: "C" });
    }
    await assert.rejects(observer.close());
    finish();
    await assert.rejects(observer.requireCurrent(receipt));
    await observer.close();
    assert.equal(model.descriptorsClosed, 2);
  },
);

for (const failure of [
  "reused birth",
  "changed image",
  "wrong uid",
  "stdout forged",
  "helper failure",
  "helper signal",
  "helper stderr",
  "oversized",
  "noncanonical",
  "file replaced",
])
  test(`inert launcher fails closed on ${failure}`, models, async () => {
    const {
      model,
      observer,
      receipt,
      birth: current,
      finish,
    } = await inertLauncher();
    await observer.bind(receipt, current);
    if (failure === "reused birth")
      model.birth = {
        ...current,
        birthMicroseconds: current.birthMicroseconds + 1,
      };
    if (failure === "changed image")
      model.birth = { ...current, executableSHA256: "b".repeat(64) };
    if (failure === "wrong uid")
      model.birth = { ...current, uid: current.uid + 1 };
    if (failure === "stdout forged")
      model.helperOutput = observation({ ...current, pid: 4002 });
    if (failure === "helper failure") model.helperCode = 1;
    if (failure === "helper signal") model.helperSignal = "SIGTERM";
    if (failure === "helper stderr")
      model.helperError = Buffer.from("synthetic failure");
    if (failure === "oversized") model.helperOutput = Buffer.alloc(16385, 32);
    if (failure === "noncanonical")
      model.helperOutput = Buffer.concat([
        observation(current),
        Buffer.from("\n"),
      ]);
    if (failure === "file replaced") model.replaced = true;
    await assert.rejects(observer.requireCurrent(receipt));
    const calls = model.calls.length;
    await assert.rejects(observer.requireCurrent(receipt));
    assert.equal(model.calls.length, calls);
    finish();
    await observer.close();
  });

test(
  "inert helper deadline fails without signals and close retains natural join",
  models,
  async () => {
    const {
      model,
      observer,
      receipt,
      birth: current,
      finish,
    } = await inertLauncher();
    model.holdHelper = true;
    await assert.rejects(observer.bind(receipt, current), /deadline/);
    finish();
    let closed = false;
    const closing = observer.close().then(() => {
      closed = true;
    });
    await new Promise((resolve) => setTimeout(resolve, 10));
    assert.equal(closed, false);
    model.children[1].finish();
    await closing;
    assert.equal(closed, true);
  },
);

test(
  "inert synchronous compiler observer obtains fresh natural helper results every call",
  models,
  async () => {
    const {
      model,
      observer,
      receipt,
      birth: current,
      finish,
    } = await inertLauncher();
    assert.throws(() => observer.requireCurrentSync(receipt));
    await observer.bind(receipt, current);
    assert.deepEqual(observer.requireCurrentSync(receipt), current);
    assert.deepEqual(observer.requireCurrentSync(receipt), current);
    assert.equal(model.calls.length, 4);
    for (const call of model.calls.slice(2)) {
      assert.equal(call.args.at(-1), "1000");
      assert.equal(call.options.maxBuffer, Infinity);
      assert.equal(call.options.timeout, undefined);
      assert.equal(call.options.killSignal, undefined);
    }
    model.birth = {
      ...current,
      birthMicroseconds: current.birthMicroseconds + 1,
    };
    assert.throws(() => observer.requireCurrentSync(receipt));
    assert.throws(() => observer.requireCurrentSync(receipt));
    finish();
    await observer.close();
  },
);

test(
  "inert owner cleanup waits for child close after exit before releasing executable pins",
  models,
  async () => {
    const { model, observer, receipt, birth: current } = await inertLauncher();
    await observer.bind(receipt, current);
    receipt.child.exitCode = 0;
    receipt.child.emit("exit", 0, null);
    let closed = false;
    const closing = observer.close().then(() => {
      closed = true;
    });
    await new Promise((resolve) => setTimeout(resolve, 10));
    assert.equal(closed, false);
    assert.equal(model.descriptorsClosed, 0);
    receipt.child.emit("close", 0, null);
    await closing;
    assert.equal(model.descriptorsClosed, 2);
  },
);

test("finite observation budget derives all owners and three phases from exact source recipe bytes", () => {
  const minimum = createFunctionalProcessObservationBudget(
    observationBudgetFixture(),
  );
  const maximum = createFunctionalProcessObservationBudget(
    observationBudgetFixture(16),
  );
  assert.equal(minimum.recipes.length, 39);
  assert.equal(minimum.literalSteps, 39);
  assert.equal(minimum.phases, 3);
  assert.equal(
    minimum.limit,
    256 + 39 * 64 + 39 * 3 * 16 * 4 + 39 * 3 * 12 * 4 + 2,
  );
  assert.equal(maximum.limit, 100098);
  assert.equal(maximum.stepBoundaries, 39 * 16 * 3 * 12 * 4);
  assert(Object.isFrozen(maximum) && Object.isFrozen(maximum.recipes));
});

test("observation budgets reject missing or altered source-bound owner recipes", () => {
  for (const change of [
    (value) => {
      delete value.recipeSources.keepAwake;
    },
    (value) => {
      value.recipeSources.foreign = value.recipeSources.keepAwake;
    },
    (value) => {
      value.sourcePins.sourceCommit = "b".repeat(40);
    },
    (value) => {
      value.recipeSources.keepAwake.sha256 = "f".repeat(64);
    },
    (value) => {
      value.sourcePins.files[0].sha256 = "f".repeat(64);
    },
    (value) => {
      value.recipeSources.keepAwake.path = "foreign.json";
    },
    (value) => {
      value.sourcePins.files.push(value.sourcePins.files[0]);
    },
  ]) {
    const fixture = observationBudgetFixture();
    change(fixture);
    assert.throws(() => createFunctionalProcessObservationBudget(fixture));
  }
  for (const steps of [0, 17])
    assert.throws(() =>
      createFunctionalProcessObservationBudget(observationBudgetFixture(steps)),
    );
});

test("source budget counters exhaust at the precise finite bound and reject metadata clones", () => {
  const budget = createFunctionalProcessObservationBudget(
    observationBudgetFixture(),
  );
  for (const forged of [
    { limit: 1000000 },
    structuredClone(budget),
    { ...budget },
  ])
    assert.throws(() => createFunctionalProcessObservationCounter(forged));
  const counter = createFunctionalProcessObservationCounter(budget);
  for (let index = 0; index < budget.limit; index++) counter.consume();
  assert.equal(counter.count, budget.limit);
  assert.throws(() => counter.consume(), /Process observation count bound/);
  assert.equal(counter.count, budget.limit);
});

test(
  "inert async and sync observations share one derived budget and fail closed without a cached grant",
  models,
  async () => {
    const {
      model,
      observer,
      receipt,
      observationBudget,
      birth: current,
      finish,
    } = await inertLauncher();
    await observer.bind(receipt, current);
    await observer.requireCurrent(receipt);
    for (let index = 2; index < observationBudget.limit; index++)
      observer.requireCurrentSync(receipt);
    assert.equal(model.calls.length, observationBudget.limit + 1);
    const count = model.calls.length;
    await assert.rejects(
      observer.requireCurrent(receipt),
      /Process observation count bound/,
    );
    assert.equal(model.calls.length, count);
    assert.throws(
      () => observer.requireCurrentSync(receipt),
      /Unretained or stale child/,
    );
    finish();
    await observer.close();
    assert.equal(model.descriptorsClosed, 2);
  },
);

function absenceFixture(currentBirth = null) {
  const { pid, birthSeconds, birthMicroseconds, uid } = birth;
  return {
    basis: currentBirth === null ? "pid-missing" : "pid-reused",
    currentBirth,
    recordedBirth: { birthMicroseconds, birthSeconds, pid, uid },
    schema: 1,
  };
}

test("recorded kernel absence accepts missing PID or a different birth at the reused PID", () => {
  assert.equal(
    validateFunctionalProcessAbsence(encode(absenceFixture()), birth).basis,
    "pid-missing",
  );
  assert.equal(
    validateFunctionalProcessAbsence(
      encode(
        absenceFixture({
          birthMicroseconds: birth.birthMicroseconds + 1,
          birthSeconds: birth.birthSeconds,
          uid: birth.uid,
        }),
      ),
      birth,
    ).basis,
    "pid-reused",
  );
});

test("recorded absence refuses live matching births, unknown errors, selectors and noncanonical payloads", () => {
  for (const change of [
    (value) => {
      value.recordedBirth.pid++;
    },
    (value) => {
      value.recordedBirth.birthSeconds++;
    },
    (value) => {
      value.recordedBirth.uid++;
    },
    (value) => {
      value.basis = "EPERM";
    },
    (value) => {
      value.basis = "pid-reused";
      value.currentBirth = {
        birthMicroseconds: birth.birthMicroseconds,
        birthSeconds: birth.birthSeconds,
        uid: birth.uid,
      };
    },
    (value) => {
      value.basis = "pid-missing";
      value.currentBirth = {};
    },
    (value) => {
      value.absent = true;
    },
  ]) {
    const value = absenceFixture();
    change(value);
    assert.throws(() => validateFunctionalProcessAbsence(encode(value), birth));
  }
  assert.throws(() =>
    validateFunctionalProcessAbsence(
      Buffer.concat([encode(absenceFixture()), Buffer.from("\n")]),
      birth,
    ),
  );
});

test(
  "opaque natural exit requires actual close and fresh pinned kernel helper observation",
  models,
  async () => {
    const {
      model,
      observer,
      receipt,
      birth: current,
      finish,
    } = await inertLauncher();
    await observer.bind(receipt, current);
    const exit = observer.observeNaturalExit(receipt);
    await new Promise((resolve) => setImmediate(resolve));
    assert.equal(model.calls.length, 2);
    finish();
    const result = await exit;
    assert.deepEqual(result.birth, current);
    assert.equal(result.exitCode, 0);
    assert.equal(result.signal, null);
    assert.equal(result.absence.basis, "pid-missing");
    assert.deepEqual(model.calls.at(-1).args, [
      "--require-absent",
      String(current.pid),
      String(current.birthSeconds),
      String(current.birthMicroseconds),
      String(current.uid),
      "1000",
    ]);
    await assert.rejects(
      observer.observeNaturalExit({ joined: Promise.resolve() }),
      /Expected independently bound/,
    );
    await assert.rejects(
      observer.observeNaturalExit(receipt),
      /already observed/,
    );
    await observer.close();
  },
);

test(
  "actual exit cannot qualify replaced pins, helper errors or a still-present recorded birth",
  models,
  async () => {
    for (const boundary of ["pins", "helper", "present", "signal"]) {
      const {
        model,
        observer,
        receipt,
        birth: current,
        finish,
      } = await inertLauncher();
      await observer.bind(receipt, current);
      finish();
      if (boundary === "pins") model.replaced = true;
      if (boundary === "helper") model.helperCode = 1;
      if (boundary === "present")
        model.helperOutput = encode(
          absenceFixture({
            birthMicroseconds: current.birthMicroseconds,
            birthSeconds: current.birthSeconds,
            uid: current.uid,
          }),
        );
      if (boundary === "signal") receipt.child.signalCode = "SIGTERM";
      await assert.rejects(observer.observeNaturalExit(receipt));
      await observer.close();
    }
  },
);

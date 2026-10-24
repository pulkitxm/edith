import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import test from "node:test";
import {
  bindFunctionalCompilationHost,
  buildFunctionalFixtureHost,
  captureFunctionalCompilationToolchain,
  closeFunctionalCompilation,
  createFunctionalCompilation,
  functionalCompilationArguments,
  functionalCompilationForBuilder,
  functionalDocsCompilerInputs,
  functionalDocsDependencyForBuilder,
  functionalHostBuildSource,
  observeFunctionalCompilationHost,
  observeFunctionalDocsDependency,
  prepareFunctionalDocsDependency,
  probeFunctionalCompilation,
  probeFunctionalCompilationObservationBudget,
  probeFunctionalCompilationObserverSignature,
  probeFunctionalCompilationStaging,
  probeFunctionalDocsDependency,
  validateFunctionalCompilationObserverSignature,
  validateFunctionalCompilationSourcePins,
  validateFunctionalDependencyRevision,
  validateFunctionalDocsDependencyLock,
  validateFunctionalDocsDependencySignature,
} from "./functional-build.mjs";
import { createFunctionalProcessObservationCounter } from "./owned-process.mjs";
import { functionalActionOwners } from "./owners.mjs";

const hash = (value) => createHash("sha256").update(value).digest("hex");
function fixture() {
  const files = new Map([
    ["Packages/Example/Sources/Entry.swift", Buffer.from("source")],
  ]);
  const output = Buffer.from("compiled synthetic object");
  const sourcePins = {
    sourceCommit: "a".repeat(40),
    files: [...files].map(([path, bytes]) => ({ path, sha256: hash(bytes) })),
  };
  const events = [];
  const state = { compiler: hash("compiler"), alive: true, output };
  const runtime = {
    readSource: async (path) => files.get(path),
    observeCompiler: async () => state.compiler,
    requireLifetime: async () => {
      assert(state.alive, "Owned lifetime ended");
    },
    stage: async () => {
      events.push("stage");
    },
    compile: async () => {
      events.push("compile");
    },
    readOutput: async () => state.output,
    publish: async () => {
      events.push("publish");
    },
    abort: async () => {
      events.push("abort");
    },
  };
  return { files, output, sourcePins, events, state, runtime };
}
const probe = (f) =>
  probeFunctionalCompilation({
    sourcePins: f.sourcePins,
    expectedOutputSHA256: hash(f.output),
    runtime: f.runtime,
  });

test("immutable memory compilation retains honest qualification flags", async () => {
  const f = fixture();
  const result = await probe(f);
  assert.deepEqual(f.events, ["stage", "compile", "publish"]);
  assert.equal(result.sourceReady, false);
  assert.equal(result.nativeProof, false);
  assert(Object.isFrozen(result));
  await assert.rejects(
    functionalCompilationForBuilder(result),
    /Expected owned live/,
  );
});

test("consumer plain objects cannot mint compilation capability", async () => {
  await assert.rejects(
    functionalCompilationForBuilder(
      Object.freeze({ status: "ready", sourceReady: true }),
    ),
    /Expected owned live/,
  );
});

test("literal source pins reject traversal, duplicate, getters and malformed identities", () => {
  for (const path of [
    "../escape.swift",
    "/tmp/input.swift",
    "Sources//Entry.swift",
    "Sources/./Entry.swift",
    "Sources/Entry\\swift",
    "Sources/Entry\0swift",
    ".git/config",
  ])
    assert.throws(() =>
      validateFunctionalCompilationSourcePins({
        sourceCommit: "a".repeat(40),
        files: [{ path, sha256: hash("source") }],
      }),
    );
  const f = fixture();
  assert.throws(() =>
    validateFunctionalCompilationSourcePins({
      ...f.sourcePins,
      files: [...f.sourcePins.files, ...f.sourcePins.files],
    }),
  );
  assert.throws(
    () =>
      validateFunctionalCompilationSourcePins({
        get sourceCommit() {
          throw new Error("getter executed");
        },
        files: f.sourcePins.files,
      }),
    /assert|false/i,
  );
  const result = validateFunctionalCompilationSourcePins(f.sourcePins);
  f.sourcePins.files[0].sha256 = hash("changed");
  assert.equal(result.files[0].sha256, hash("source"));
  assert(Object.isFrozen(result.files[0]));
});

test("source mutation during staging refuses compilation and cleans staging", async () => {
  const f = fixture();
  f.runtime.stage = async () => {
    f.events.push("stage");
    f.files.set(f.sourcePins.files[0].path, Buffer.from("changed"));
  };
  await assert.rejects(probe(f), /Changed source/);
  assert.deepEqual(f.events, ["stage", "abort"]);
});

test("compiler mutation after compilation refuses publication", async () => {
  const f = fixture();
  f.runtime.compile = async () => {
    f.events.push("compile");
    f.state.compiler = hash("replacement compiler");
  };
  await assert.rejects(probe(f), /toolchain changed/);
  assert.deepEqual(f.events, ["stage", "compile", "abort"]);
});

test("wrong build output refuses publication", async () => {
  const f = fixture();
  f.state.output = Buffer.from("different executable");
  await assert.rejects(probe(f), /Wrong compiler output/);
  assert.deepEqual(f.events, ["stage", "compile", "abort"]);
});

test("partial staging failure preserves failure outcome and aborts", async () => {
  const f = fixture();
  const failure = new Error("staging interrupted");
  f.runtime.stage = async () => {
    f.events.push("stage");
    throw failure;
  };
  await assert.rejects(probe(f), (error) => error === failure);
  assert.deepEqual(f.events, ["stage", "abort"]);
});

test("naturally ended owned lifetime refuses further compilation", async () => {
  const f = fixture();
  f.runtime.compile = async () => {
    f.events.push("compile");
    f.state.alive = false;
  };
  await assert.rejects(probe(f), /Owned lifetime ended/);
  assert.deepEqual(f.events, ["stage", "compile", "abort"]);
});

test("cleanup failure preserves both original and cleanup errors", async () => {
  const f = fixture();
  const failure = new Error("compiler failed");
  const cleanup = new Error("cleanup failed");
  f.runtime.compile = async () => {
    throw failure;
  };
  f.runtime.abort = async () => {
    throw cleanup;
  };
  await assert.rejects(
    probe(f),
    (error) =>
      error instanceof AggregateError &&
      error.errors[0] === failure &&
      error.errors[1] === cleanup,
  );
});

function hostFixture() {
  const certificate = Buffer.alloc(32, 1).toString("base64");
  const plan = {
    sourceCommit: "a".repeat(40),
    session: "12345678-1234-4234-8234-123456789012",
    root: "/synthetic/functional-fixture-12345678-1234-4234-8234-123456789012",
    hostIdentifier:
      "com.pulkit.edith.tests.worker-12345678-1234-4234-8234-123456789012",
    producerIdentifier:
      "com.pulkit.edith.tests.functional-producer-12345678-1234-4234-8234-123456789012",
    executable:
      "/synthetic/functional-fixture-12345678-1234-4234-8234-123456789012/Producer/functional-producer",
    certificateSHA256: certificate,
    observationPolicies: Object.fromEntries(
      functionalActionOwners.map((owner) => [
        owner,
        {
          schema: 1,
          owner,
          readback: {
            operation: "surface.snapshot",
            payload: { owner },
            normalizer: { kind: "identity" },
          },
          phases: ["initial", "updated", "reinstalled"].map((phase) => ({
            phase,
            before: { kind: "literal", value: null },
            after: { kind: "literal", value: null },
          })),
        },
      ]),
    ),
    policySHA256: hash("policy"),
  };
  const activeJob = {
    sourceCommit: plan.sourceCommit,
    run: { id: 123 },
    job: { id: 456, runner_name: "synthetic-runner" },
    context: {
      mergeCommit: { sha: "b".repeat(40) },
      pullRequest: { base: { sha: "c".repeat(40) } },
      runAttempt: 1,
    },
  };
  plan.hostedRunPins = {
    sourceCommit: plan.sourceCommit,
    mergeCommit: activeJob.context.mergeCommit.sha,
    baseCommit: activeJob.context.pullRequest.base.sha,
    runID: activeJob.run.id,
    jobID: activeJob.job.id,
    runAttempt: 1,
    runnerName: activeJob.job.runner_name,
    workflowSHA256: hash("workflow"),
  };
  const manifest = {
    sourceCommit: plan.sourceCommit,
    session: plan.session,
    root: plan.root,
    hostIdentifier: plan.hostIdentifier,
    producer: {
      path: plan.executable,
      executableSHA256: hash("producer"),
      sourceSHA256: hash("sources"),
      toolchainSHA256: hash("toolchain"),
      certificateSHA256: certificate,
      requirement: `identifier "${plan.producerIdentifier}"`,
    },
    signing: { hostCertificateSHA256: certificate },
    issuerPublicKey: Buffer.alloc(32, 2).toString("base64"),
    policySHA256: plan.policySHA256,
    runID: 123,
    jobID: 456,
  };
  return { plan, manifest, activeJob };
}
const sourceForHost = (f) =>
  functionalHostBuildSource({
    plan: f.plan,
    issuerManifestBytes: Buffer.from(JSON.stringify(f.manifest)),
    activeJob: f.activeJob,
    sourceSHA256: hash("sources"),
    toolchainSHA256: hash("toolchain"),
  });

test("Host bootstrap embeds actual same-live issuer and complete genuine run pins", () => {
  const f = hostFixture();
  const source = sourceForHost(f);
  assert(
    source.includes(
      `static let issuerPublicKey = Data(base64Encoded: "${f.manifest.issuerPublicKey}")!`,
    ),
  );
  assert(
    source.includes(
      `static let producerExecutableSHA256 = "${f.manifest.producer.executableSHA256}"`,
    ),
  );
  assert(source.includes(`mergeCommit: "${f.plan.hostedRunPins.mergeCommit}"`));
  assert(source.includes(`baseCommit: "${f.plan.hostedRunPins.baseCommit}"`));
  assert(source.includes("runID: 123, jobID: 456, runAttempt: 1"));
  assert.equal(sourceForHost(f), source);
});

test("Host bootstrap rejects changed source, compiler, policy, signature and same-job identity", () => {
  const mutations = [
    (f) => {
      f.manifest.producer.sourceSHA256 = hash("different sources");
    },
    (f) => {
      f.manifest.producer.toolchainSHA256 = hash("different compiler");
    },
    (f) => {
      f.manifest.policySHA256 = hash("different policy");
    },
    (f) => {
      f.manifest.producer.executableSHA256 = "invalid";
    },
    (f) => {
      f.manifest.producer.certificateSHA256 = Buffer.alloc(32, 9).toString(
        "base64",
      );
    },
    (f) => {
      f.manifest.producer.requirement = 'identifier "another-producer"';
    },
    (f) => {
      f.manifest.issuerPublicKey = "invalid";
    },
    (f) => {
      f.manifest.jobID = 457;
    },
    (f) => {
      f.activeJob.context.runAttempt = 2;
    },
    (f) => {
      f.activeJob.context.mergeCommit.sha = "d".repeat(40);
    },
    (f) => {
      f.plan.hostedRunPins.workflowSHA256 = "invalid";
    },
    (f) => {
      f.plan.hostIdentifier += "\n";
      f.manifest.hostIdentifier = f.plan.hostIdentifier;
    },
  ];
  for (const mutate of mutations) {
    const f = hostFixture();
    mutate(f);
    assert.throws(() => sourceForHost(f));
  }
});

test("production compilation rejects untrusted environment before filesystem or command execution", async () => {
  await assert.rejects(
    captureFunctionalCompilationToolchain({
      repository: "/never-read",
      sourceCommit: "a".repeat(40),
      environment: {},
    }),
  );
  await assert.rejects(
    createFunctionalCompilation({
      repository: "/never-read",
      sourceCommit: "a".repeat(40),
      sourcePins: fixture().sourcePins,
      root: "/never-write",
      environment: {},
    }),
  );
});

test("Host build, bind, observation and close reject forged compilation or receipt", async () => {
  const compilation = Object.freeze({
    root: "/never-read",
    sourceCommit: "a".repeat(40),
  });
  const receipt = Object.freeze({
    sourceCommit: compilation.sourceCommit,
    host: { path: "/never-read/Fixture.app" },
  });
  await assert.rejects(
    buildFunctionalFixtureHost({ compilation }),
    /Expected owned live/,
  );
  await assert.rejects(
    bindFunctionalCompilationHost({
      compilation,
      receipt,
      ownedHost: { child: { pid: 2 } },
    }),
    /Expected owned live/,
  );
  assert.throws(
    () =>
      observeFunctionalCompilationHost({ compilation, receipt, ownedHost: {} }),
    /Expected owned source-built/,
  );
  await assert.rejects(
    closeFunctionalCompilation(compilation),
    /Expected owned functional/,
  );
});

test("source mutation during output observation refuses publication", async () => {
  const f = fixture();
  f.runtime.readOutput = async () => {
    f.files.set(f.sourcePins.files[0].path, Buffer.from("late mutation"));
    return f.output;
  };
  await assert.rejects(probe(f), /Changed source/);
  assert.deepEqual(f.events, ["stage", "compile", "abort"]);
});

test("ended lifetime before staging does not create or abort an unowned stage", async () => {
  const f = fixture();
  f.state.alive = false;
  await assert.rejects(probe(f), /Owned lifetime ended/);
  assert.deepEqual(f.events, []);
});

test("dependency source admission binds the exact locked repository and revision", () => {
  const pin = {
    identity: "zipfoundation",
    location: "https://github.com/weichsel/ZIPFoundation.git",
    revision: "d".repeat(40),
  };
  const observed = {
    ...pin,
    location: "https://github.com/weichsel/ZIPFoundation",
    status: "",
  };
  assert.deepEqual(validateFunctionalDependencyRevision(pin, observed), pin);
  for (const mutation of [
    { revision: "e".repeat(40) },
    { location: "https://github.com/example/ZIPFoundation" },
    { status: " M Sources/Archive.swift" },
    { status: "?? Sources/Injected.swift" },
    { identity: "different-library" },
  ])
    assert.throws(() =>
      validateFunctionalDependencyRevision(pin, { ...observed, ...mutation }),
    );
  assert.throws(() =>
    validateFunctionalDependencyRevision(
      { ...pin, location: "https://example.com/ZIPFoundation" },
      observed,
    ),
  );
});

function ownedMemory() {
  const directories = new Map();
  let inode = 0;
  return {
    directories,
    runtime: {
      create: async (path) => {
        assert(!directories.has(path), "Staging path already exists");
        const value = { dev: 1, ino: ++inode };
        directories.set(path, value);
        return value;
      },
      current: async (path) => {
        assert(directories.has(path));
        return directories.get(path);
      },
      remove: async (path) => {
        assert(directories.has(path));
        directories.delete(path);
      },
    },
  };
}

test("staging collision never removes a preexisting directory", async () => {
  const f = ownedMemory();
  const original = { dev: 1, ino: 99 };
  f.directories.set("/synthetic/existing", original);
  await assert.rejects(
    probeFunctionalCompilationStaging({
      paths: ["/synthetic/created", "/synthetic/existing"],
      runtime: f.runtime,
    }),
    /already exists/,
  );
  assert.equal(f.directories.get("/synthetic/existing"), original);
  assert(!f.directories.has("/synthetic/created"));
});

test("replaced owned staging inode refuses destructive cleanup and preserves errors", async () => {
  const f = ownedMemory();
  const failure = new Error("staging interrupted");
  const create = f.runtime.create;
  f.runtime.create = async (path) => {
    if (path === "/synthetic/second") {
      f.directories.set("/synthetic/first", { dev: 1, ino: 42 });
      throw failure;
    }
    return create(path);
  };
  await assert.rejects(
    probeFunctionalCompilationStaging({
      paths: ["/synthetic/first", "/synthetic/second"],
      runtime: f.runtime,
    }),
    (error) =>
      error instanceof AggregateError &&
      error.errors[0] === failure &&
      error.errors[1] instanceof AggregateError,
  );
  assert.deepEqual(f.directories.get("/synthetic/first"), { dev: 1, ino: 42 });
});

test("successful owned staging probe removes only its naturally retained directory graph", async () => {
  const f = ownedMemory();
  const original = { dev: 1, ino: 99 };
  f.directories.set("/synthetic/unrelated", original);
  const result = await probeFunctionalCompilationStaging({
    paths: ["/synthetic/first", "/synthetic/second"],
    runtime: f.runtime,
  });
  assert.equal(result.sourceReady, false);
  assert.equal(result.nativeProof, false);
  assert.deepEqual([...f.directories.keys()], ["/synthetic/unrelated"]);
  assert.equal(f.directories.get("/synthetic/unrelated"), original);
});

function budgetFixture() {
  const files = new Map(
    functionalActionOwners.map((owner, index) => {
      const path = `scripts/hosted-functional-actions/presentations/${owner}.json`;
      const bytes = Buffer.from(
        JSON.stringify({
          schema: 1,
          owner,
          steps: Array.from({ length: (index % 4) + 1 }, () => ({
            kind: "synthetic",
          })),
        }),
      );
      return [path, bytes];
    }),
  );
  const sourcePins = {
    sourceCommit: "a".repeat(40),
    files: [...files].map(([path, bytes]) => ({ path, sha256: hash(bytes) })),
  };
  const reads = [];
  const runtime = {
    readSource: async (path) => {
      reads.push(path);
      return files.get(path);
    },
  };
  return { files, sourcePins, reads, runtime };
}

test("compiler budget consumes every exact source-pinned recipe and retains no runtime authority", async () => {
  const f = budgetFixture();
  const result = await probeFunctionalCompilationObservationBudget(f);
  assert.deepEqual(f.reads, [...f.files.keys()]);
  assert.equal(result.recipes.length, 40);
  assert.equal(result.phases, 3);
  assert.equal(result.retirementBoundaries, 2);
  const steps = [...f.files.values()].reduce(
    (sum, bytes) => sum + JSON.parse(bytes).steps.length,
    0,
  );
  assert.equal(result.literalSteps, steps);
  assert.equal(
    result.limit,
    256 + 40 * 64 + 40 * 3 * 16 * 4 + steps * 3 * 12 * 4 + 2,
  );
  assert.equal(result.sourceReady, false);
  assert.equal(result.nativeProof, false);
  assert(Object.isFrozen(result.recipes[0]));
  assert.throws(
    () => createFunctionalProcessObservationCounter(result),
    /Expected source-bound/,
  );
});

test("compiler budget refuses omitted, stale or replaced source recipe bytes", async () => {
  const path = "scripts/hosted-functional-actions/presentations/keepAwake.json";
  for (const mutate of [
    (f) => {
      f.sourcePins.files = f.sourcePins.files.filter(
        (pin) => pin.path !== path,
      );
    },
    (f) => {
      f.files.set(path, Buffer.from("changed source recipe"));
    },
    (f) => {
      f.files.set(path, f.files.get(path).toString("utf8"));
    },
    (f) => {
      f.sourcePins.files[0].sha256 = hash("different committed recipe");
    },
  ]) {
    const f = budgetFixture();
    mutate(f);
    await assert.rejects(probeFunctionalCompilationObservationBudget(f));
  }
});

test("compiler budget refuses malformed recipes even when their bytes match a source pin", async () => {
  const path = "scripts/hosted-functional-actions/presentations/keepAwake.json";
  for (const recipe of [
    { schema: 2, owner: "keepAwake", steps: [{}] },
    { schema: 1, owner: "foreign", steps: [{}] },
    { schema: 1, owner: "keepAwake", steps: [] },
    {
      schema: 1,
      owner: "keepAwake",
      steps: Array.from({ length: 17 }, () => ({})),
    },
    { schema: 1, owner: "keepAwake", steps: "one" },
  ]) {
    const f = budgetFixture();
    const bytes = Buffer.from(JSON.stringify(recipe));
    f.files.set(path, bytes);
    f.sourcePins.files[0].sha256 = hash(bytes);
    await assert.rejects(probeFunctionalCompilationObservationBudget(f));
  }
});

test("compiler budget fails closed on source reads and rejects numerical or accessor substitutions", async () => {
  const f = budgetFixture();
  const failure = new Error("snapshot read failed");
  f.runtime.readSource = async () => {
    throw failure;
  };
  await assert.rejects(
    probeFunctionalCompilationObservationBudget(f),
    (error) => error === failure,
  );
  for (const runtime of [
    { readSource: f.runtime.readSource, observationBudget: 100098 },
    { readSource: 100098 },
    {
      get readSource() {
        throw new Error("getter executed");
      },
    },
  ])
    await assert.rejects(
      probeFunctionalCompilationObservationBudget({
        sourcePins: f.sourcePins,
        runtime,
      }),
    );
});

test("observer signer admission binds the actual helper identifier and signing certificate", () => {
  const certificate = Buffer.alloc(32, 1).toString("base64");
  const signature = {
    identifier: "com.pulkit.edith.tests.functional-process-probe",
    certificateSHA256: certificate,
  };
  const admitted = validateFunctionalCompilationObserverSignature(
    signature,
    certificate,
  );
  assert.deepEqual(admitted, signature);
  assert(Object.isFrozen(admitted));
  signature.identifier = "replacement";
  assert.equal(
    admitted.identifier,
    "com.pulkit.edith.tests.functional-process-probe",
  );
});

test("observer signer admission refuses changed selectors and open fieldsets", () => {
  const certificate = Buffer.alloc(32, 1).toString("base64");
  const signature = {
    identifier: "com.pulkit.edith.tests.functional-process-probe",
    certificateSHA256: certificate,
  };
  for (const observed of [
    { ...signature, identifier: "replacement-helper" },
    { ...signature, certificateSHA256: Buffer.alloc(32, 2).toString("base64") },
    { ...signature, verified: true },
    { identifier: signature.identifier },
    Object.assign(Object.create(null), signature),
    {
      get identifier() {
        throw new Error("getter executed");
      },
      certificateSHA256: certificate,
    },
  ])
    assert.throws(() =>
      validateFunctionalCompilationObserverSignature(observed, certificate),
    );
  for (const expected of [
    undefined,
    "invalid",
    "a".repeat(64),
    Buffer.alloc(31).toString("base64"),
    `${certificate.slice(0, 43)}A`,
  ])
    assert.throws(() =>
      validateFunctionalCompilationObserverSignature(signature, expected),
    );
});

test("observer signature probes freshly invoke each admission and never cache earlier success", () => {
  const certificateSHA256 = Buffer.alloc(32, 1).toString("base64");
  const signature = {
    identifier: "com.pulkit.edith.tests.functional-process-probe",
    certificateSHA256,
  };
  let calls = 0;
  const runtime = {
    observeSignature: () => {
      calls++;
      return { ...signature };
    },
  };
  const result = probeFunctionalCompilationObserverSignature({
    certificateSHA256,
    runtime,
  });
  assert.equal(calls, 2);
  assert.deepEqual(result.first, signature);
  assert.deepEqual(result.second, signature);
  assert.equal(result.sourceReady, false);
  assert.equal(result.nativeProof, false);
  assert(Object.isFrozen(result.second));
  calls = 0;
  runtime.observeSignature = () => {
    calls++;
    return {
      ...signature,
      certificateSHA256:
        calls === 1
          ? certificateSHA256
          : Buffer.alloc(32, 2).toString("base64"),
    };
  };
  assert.throws(
    () =>
      probeFunctionalCompilationObserverSignature({
        certificateSHA256,
        runtime,
      }),
    /Wrong process observer signing certificate/,
  );
  assert.equal(calls, 2);
  const failure = new Error("actual signature observation failed");
  runtime.observeSignature = () => {
    throw failure;
  };
  assert.throws(
    () =>
      probeFunctionalCompilationObserverSignature({
        certificateSHA256,
        runtime,
      }),
    (error) => error === failure,
  );
});

test("fixture compilation consistently targets macOS26 across helper and dependency commands", () => {
  const compiler = [
    "swiftc",
    "-parse-as-library",
    "-swift-version",
    "6",
    "-num-threads",
    "1",
    "/synthetic/Probe.swift",
    "-o",
    "/synthetic/probe",
  ];
  assert.deepEqual(functionalCompilationArguments("xcrun", compiler), [
    "swiftc",
    "-target",
    "arm64-apple-macosx26.0",
    ...compiler.slice(1),
  ]);
  assert.equal(compiler[1], "-parse-as-library");
  for (const args of [
    ["swift", "build", "--jobs", "1", "--product", "EdithHost"],
    ["swift", "build", "--show-bin-path"],
  ]) {
    const result = functionalCompilationArguments("xcrun", args);
    assert.deepEqual(result, [
      "swift",
      "build",
      "--triple",
      "arm64-apple-macosx26.0",
      ...args.slice(2),
    ]);
    assert(Object.isFrozen(result));
  }
  for (const [file, args] of [
    ["xcrun", ["swift", "package", "resolve"]],
    ["xcrun", ["--sdk", "macosx", "--show-sdk-path"]],
    ["codesign", ["--verify", "/synthetic/probe"]],
  ])
    assert.deepEqual(functionalCompilationArguments(file, args), args);
  assert.throws(
    () =>
      functionalCompilationArguments("xcrun", [
        "swiftc",
        "-target",
        "arm64-apple-macosx14.0",
      ]),
    /source-owned/,
  );
  assert.throws(
    () =>
      functionalCompilationArguments("xcrun", [
        "swift",
        "build",
        "--triple",
        "arm64-apple-macosx14.0",
      ]),
    /source-owned/,
  );
});

test("Host constants contain every exact source-owned readonly selector and shared media binding", () => {
  const f = hostFixture();
  const source = sourceForHost(f);
  for (const owner of functionalActionOwners) {
    const match = source.match(
      new RegExp(`"${owner}": Data\\(base64Encoded: "([A-Za-z0-9+/=]+)"\\)!`),
    );
    assert(match, owner);
    const bytes = Buffer.from(match[1], "base64");
    assert.deepEqual(JSON.parse(bytes.toString("utf8")), {
      schema: 1,
      owner,
      operation: "surface.snapshot",
      payload: { owner },
    });
    assert.equal(
      bytes.toString("utf8"),
      JSON.stringify({
        operation: "surface.snapshot",
        owner,
        payload: { owner },
        schema: 1,
      }),
    );
  }
  assert(
    source.includes("static let authoritativeReadPolicies: [String: Data]"),
  );
  assert(source.includes("enum FunctionalProducerBuild"));
  for (const field of ["sourceCommit", "session", "root", "hostedRunPins"])
    assert(
      source.includes(`static let ${field} = FunctionalHostBuild.${field}`),
    );
  assert.equal(sourceForHost(f), source);
});

test("Host constants reject omitted, foreign, malformed or oversized source readback policies", () => {
  for (const mutate of [
    (f) => {
      delete f.plan.observationPolicies.keepAwake;
    },
    (f) => {
      f.plan.observationPolicies.foreign = f.plan.observationPolicies.keepAwake;
    },
    (f) => {
      f.plan.observationPolicies.keepAwake.owner = "foreign";
    },
    (f) => {
      f.plan.observationPolicies.keepAwake.schema = 2;
    },
    (f) => {
      f.plan.observationPolicies.keepAwake.readback.operation =
        "arbitrary command";
    },
    (f) => {
      f.plan.observationPolicies.keepAwake.readback.payload = null;
    },
    (f) => {
      f.plan.observationPolicies.keepAwake.readback.payload = {
        source: "x".repeat(262144),
      };
    },
    (f) => {
      f.plan.observationPolicies.keepAwake.readback.verified = true;
    },
    (f) => {
      delete f.plan.observationPolicies.keepAwake.readback.normalizer;
    },
    (f) => {
      Object.defineProperty(
        f.plan.observationPolicies.keepAwake.readback,
        "operation",
        {
          get() {
            throw new Error("getter executed");
          },
          enumerable: true,
        },
      );
    },
  ]) {
    const f = hostFixture();
    mutate(f);
    assert.throws(() => sourceForHost(f));
  }
});

function docsFixture() {
  const f = fixture();
  const certificateSHA256 = Buffer.alloc(32, 1).toString("base64");
  const commands = [];
  const runtime = {
    readSource: f.runtime.readSource,
    observeCompiler: f.runtime.observeCompiler,
    requireLifetime: f.runtime.requireLifetime,
    stage: f.runtime.stage,
    run: async (file, args) => {
      commands.push({ file, args });
      f.events.push(
        args.includes("--show-bin-path")
          ? "products"
          : args.includes("resolve")
            ? "resolve"
            : "build",
      );
      return args.includes("--show-bin-path")
        ? Buffer.from("/synthetic/DocsDependencies/products\n")
        : Buffer.alloc(0);
    },
    captureSources: async () => {
      f.events.push("locked sources");
      return [];
    },
    captureProduct: async (products) => {
      assert.equal(products, "/synthetic/DocsDependencies/products");
      f.events.push("artifact inventory");
      return { libraryPath: `${products}/libEdithDocsWorker.dylib` };
    },
    sign: async () => {
      f.events.push("sign");
    },
    observeSignature: async () => {
      f.events.push("signature");
      return {
        identifier: "com.pulkit.edith.tests.functional-docs-worker",
        certificateSHA256,
      };
    },
    publish: f.runtime.publish,
    abort: f.runtime.abort,
  };
  return {
    ...f,
    runtime,
    commands,
    certificateSHA256,
    packagePath: "/synthetic/CompilationSource/Packages/EdithDocsWorker",
    buildRoot: "/synthetic/DocsDependencies",
  };
}

function docsArtifacts() {
  const root = "/synthetic/DocsDependencies";
  const products = `${root}/products`;
  const artifacts = [
    ["products/libEdithDocsWorker.dylib", "library"],
    [
      "products/EdithDocsWorker.swiftmodule/arm64-apple-macos.swiftmodule",
      "module",
    ],
    ["products/Markdown.swiftmodule/arm64-apple-macos.swiftmodule", "module"],
    ["checkouts/swift-cmark/src/include/module.modulemap", "modulemap"],
    ["checkouts/swift-cmark/extensions/include/module.modulemap", "modulemap"],
    [
      "checkouts/swift-markdown/Sources/CAtomic/include/module.modulemap",
      "modulemap",
    ],
    ["products/cmark-gfm.o", "object"],
    ["products/CAtomic.o", "object"],
    ["products/Markdown.o", "object"],
    ["products/EdithDocsWorker.o", "object"],
    [
      "products/EdithDocsWorker_EdithDocsWorker.bundle/Contents/Resources/cli-docs.json",
      "resource",
    ],
  ].map(([path, kind]) => ({
    path: `${root}/${path}`,
    kind,
    sha256: hash(path),
  }));
  return { root, products, artifacts };
}

test("Docs dependency commands resolve exact lock then build original product before signing and publication", async () => {
  const f = docsFixture();
  const result = await probeFunctionalDocsDependency(f);
  assert.deepEqual(f.events, [
    "stage",
    "resolve",
    "locked sources",
    "build",
    "products",
    "artifact inventory",
    "sign",
    "signature",
    "publish",
  ]);
  assert.deepEqual(f.commands, [
    {
      file: "xcrun",
      args: [
        "swift",
        "package",
        "--package-path",
        f.packagePath,
        "--scratch-path",
        f.buildRoot,
        "resolve",
        "--force-resolved-versions",
      ],
    },
    {
      file: "xcrun",
      args: [
        "swift",
        "build",
        "--triple",
        "arm64-apple-macosx26.0",
        "--package-path",
        f.packagePath,
        "--scratch-path",
        f.buildRoot,
        "--configuration",
        "release",
        "--jobs",
        "1",
        "--product",
        "EdithDocsWorker",
        "--disable-automatic-resolution",
      ],
    },
    {
      file: "xcrun",
      args: [
        "swift",
        "build",
        "--triple",
        "arm64-apple-macosx26.0",
        "--package-path",
        f.packagePath,
        "--scratch-path",
        f.buildRoot,
        "--configuration",
        "release",
        "--show-bin-path",
        "--disable-automatic-resolution",
      ],
    },
  ]);
  assert.equal(result.sourceReady, false);
  assert.equal(result.nativeProof, false);
  assert.equal(result.qualifiedEvidence, false);
  await assert.rejects(
    functionalDocsDependencyForBuilder({
      compilation: {},
      plan: {},
      dependency: result,
    }),
    /Expected owned Docs/,
  );
});

test("Docs command control rechecks source and compiler between every dependency boundary", async () => {
  for (const boundary of [
    "run",
    "captureSources",
    "captureProduct",
    "sign",
    "observeSignature",
    "publish",
  ]) {
    for (const changed of ["source", "compiler", "lifetime"]) {
      const f = docsFixture();
      const original = f.runtime[boundary];
      f.runtime[boundary] = async (...args) => {
        const result = await original(...args);
        if (changed === "source")
          f.files.set(f.sourcePins.files[0].path, Buffer.from("changed"));
        if (changed === "compiler") f.state.compiler = hash("changed compiler");
        if (changed === "lifetime") f.state.alive = false;
        return result;
      };
      await assert.rejects(probeFunctionalDocsDependency(f), /changed|ended/);
      assert.equal(f.events.at(-1), "abort");
      if (boundary !== "publish") assert(!f.events.includes("publish"));
    }
  }
});

test("Docs preparation preserves failed commands and refuses escaped products before signing", async () => {
  const f = docsFixture();
  const failure = new Error("original package compiler failed");
  f.runtime.run = async () => {
    throw failure;
  };
  await assert.rejects(
    probeFunctionalDocsDependency(f),
    (error) => error === failure,
  );
  assert.deepEqual(f.events, ["stage", "abort"]);
  for (const output of [
    "/foreign/products",
    "/synthetic/DocsDependencies/../foreign",
    "/synthetic/DocsDependencies",
    "relative/products",
  ]) {
    const f = docsFixture();
    const original = f.runtime.run;
    f.runtime.run = async (...args) => {
      const result = await original(...args);
      return args[1].includes("--show-bin-path") ? Buffer.from(output) : result;
    };
    await assert.rejects(probeFunctionalDocsDependency(f));
    assert(!f.events.includes("sign"));
    assert(!f.events.includes("publish"));
  }
});

test("Docs compiler input projection retains original modules C maps object closure dylib and resource paths", () => {
  const f = docsArtifacts();
  const result = functionalDocsCompilerInputs(f);
  assert.deepEqual(result.moduleSearchPaths, [f.products]);
  assert.equal(result.libraryPath, `${f.products}/libEdithDocsWorker.dylib`);
  assert.deepEqual(result.runtimeLibraryPaths, [f.products]);
  assert.deepEqual(result.resourcePaths, [
    `${f.products}/EdithDocsWorker_EdithDocsWorker.bundle`,
  ]);
  assert(result.compilerArguments.includes("-lEdithDocsWorker"));
  assert.equal(result.compilerArguments.at(-1), f.products);
  for (const map of f.artifacts.filter(({ kind }) => kind === "modulemap"))
    assert(result.compilerArguments.includes(`-fmodule-map-file=${map.path}`));
  assert(Object.isFrozen(result.compilerArguments));
});

test("Docs artifact admission refuses incomplete or escaped real compiler closure", () => {
  for (const omitted of docsArtifacts().artifacts) {
    const f = docsArtifacts();
    f.artifacts = f.artifacts.filter(({ path }) => path !== omitted.path);
    assert.throws(() => functionalDocsCompilerInputs(f));
  }
  for (const mutate of [
    (f) => {
      f.artifacts[0].path = "/foreign/libEdithDocsWorker.dylib";
    },
    (f) => {
      f.artifacts.push(f.artifacts[0]);
    },
    (f) => {
      f.artifacts[0].sha256 = "invalid";
    },
    (f) => {
      f.artifacts[0].signed = true;
    },
    (f) => {
      f.artifacts[0].kind = "fake-library";
    },
    (f) => {
      f.products = `${f.root}/../foreign`;
    },
  ]) {
    const f = docsArtifacts();
    mutate(f);
    assert.throws(() => functionalDocsCompilerInputs(f));
  }
});

function docsLock() {
  return {
    originHash: hash("manifest"),
    version: 3,
    pins: [
      {
        identity: "swift-cmark",
        kind: "remoteSourceControl",
        location: "https://github.com/swiftlang/swift-cmark.git",
        state: {
          revision: "08ddb528923cc1a6527e02b7a1aee9e516ca749a",
          version: "0.9.0",
        },
      },
      {
        identity: "swift-markdown",
        kind: "remoteSourceControl",
        location: "https://github.com/swiftlang/swift-markdown.git",
        state: {
          revision: "25cb61d3482054b09ae76ca4f281b1bfe7fe5a43",
          version: "0.9.0",
        },
      },
    ],
  };
}

test("Docs source lock requires exact original Markdown and cmark0.9 revisions and matching manifest hash", () => {
  const f = docsLock();
  const validate = (lock) =>
    validateFunctionalDocsDependencyLock(
      Buffer.from(JSON.stringify(lock)),
      hash("manifest"),
    );
  assert.equal(validate(f).length, 2);
  for (const mutate of [
    (f) => {
      f.originHash = hash("replacement manifest");
    },
    (f) => {
      f.version = 2;
    },
    (f) => {
      f.pins.pop();
    },
    (f) => {
      f.pins[1] = f.pins[0];
    },
    (f) => {
      f.pins[0].state.revision = "f".repeat(40);
    },
    (f) => {
      f.pins[1].state.version = "0.8.0";
    },
    (f) => {
      f.pins[0].location = "https://github.com/example/swift-cmark.git";
    },
    (f) => {
      f.pins[0].state.approved = true;
    },
  ]) {
    const f = docsLock();
    mutate(f);
    assert.throws(() => validate(f));
  }
});

test("production Docs preparation and every consumer admission reject forged foreign authority before filesystem access", async () => {
  const compilation = Object.freeze({ root: "/never-read", sourceReady: true });
  const plan = Object.freeze({
    sourceCommit: "a".repeat(40),
    root: compilation.root,
  });
  const dependency = Object.freeze({
    libraryPath: "/never-read/libEdithDocsWorker.dylib",
    sourceReady: true,
  });
  await assert.rejects(
    prepareFunctionalDocsDependency({ compilation, plan }),
    /Expected owned live/,
  );
  await assert.rejects(
    functionalDocsDependencyForBuilder({ compilation, plan, dependency }),
    /Expected owned Docs/,
  );
  assert.throws(
    () => observeFunctionalDocsDependency({ compilation, plan, dependency }),
    /Expected owned live Docs/,
  );
});

test("Docs signing admission freshly checks actual signer output and never reuses a previous signature", async () => {
  const certificateSHA256 = Buffer.alloc(32, 1).toString("base64");
  const signature = {
    identifier: "com.pulkit.edith.tests.functional-docs-worker",
    certificateSHA256,
  };
  assert.deepEqual(
    validateFunctionalDocsDependencySignature(signature, certificateSHA256),
    signature,
  );
  for (const mutation of [
    { identifier: "replacement-library" },
    { certificateSHA256: Buffer.alloc(32, 2).toString("base64") },
    { verified: true },
  ]) {
    const f = docsFixture();
    f.runtime.observeSignature = async () => ({ ...signature, ...mutation });
    await assert.rejects(probeFunctionalDocsDependency(f));
    assert(!f.events.includes("publish"));
    assert.equal(f.events.at(-1), "abort");
  }
  for (const expected of [
    "invalid",
    Buffer.alloc(31).toString("base64"),
    undefined,
  ])
    assert.throws(() =>
      validateFunctionalDocsDependencySignature(signature, expected),
    );
  const f = docsFixture();
  const failure = new Error("actual Docs signature probe failed");
  f.runtime.observeSignature = async () => {
    throw failure;
  };
  await assert.rejects(
    probeFunctionalDocsDependency(f),
    (error) => error === failure,
  );
});

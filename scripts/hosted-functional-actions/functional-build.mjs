import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { constants, lstatSync, readFileSync, realpathSync } from "node:fs";
import {
  chmod,
  cp,
  lstat,
  mkdir,
  open,
  readdir,
  readFile,
  realpath,
  rm,
  writeFile,
} from "node:fs/promises";
import { dirname, join, resolve } from "node:path";
import { functionalCanonicalJSON } from "./contract.mjs";
import { functionalActionOwners } from "./owners.mjs";

const digest = (value) => createHash("sha256").update(value).digest("hex");
const compilations = new WeakMap();
const hostBuilds = new WeakMap();
const toolchains = new WeakMap();
const hashPattern = /^[0-9a-f]{64}$/;
const commitPattern = /^[0-9a-f]{40}$/;
const deploymentTarget = "26.0";
const targetTriple = `arm64-apple-macosx${deploymentTarget}`;
const observerIdentifier = "com.pulkit.edith.tests.functional-process-probe";

function freeze(value) {
  if (value && typeof value === "object" && !Buffer.isBuffer(value)) {
    for (const child of Object.values(value)) freeze(child);
    Object.freeze(value);
  }
  return value;
}

function exact(value, fields) {
  assert(value && Object.getPrototypeOf(value) === Object.prototype);
  assert.deepEqual(Reflect.ownKeys(value).sort(), [...fields].sort());
  for (const descriptor of Object.values(
    Object.getOwnPropertyDescriptors(value),
  ))
    assert(descriptor.enumerable && Object.hasOwn(descriptor, "value"));
}

export function validateFunctionalCompilationSourcePins(sourcePins) {
  exact(sourcePins, ["sourceCommit", "files"]);
  assert.match(sourcePins.sourceCommit, commitPattern);
  assert(
    Array.isArray(sourcePins.files) &&
      sourcePins.files.length > 0 &&
      sourcePins.files.length <= 100000,
  );
  const seen = new Set();
  for (const pin of sourcePins.files) {
    exact(pin, ["path", "sha256"]);
    assert(
      typeof pin.path === "string" &&
        pin.path.length > 0 &&
        pin.path.length <= 4096,
    );
    assert(
      !pin.path.includes("\\") &&
        !pin.path.includes("\0") &&
        !pin.path.startsWith("/"),
    );
    assert(
      !pin.path
        .split("/")
        .some((part) =>
          ["", ".", "..", ".git", ".build", "node_modules"].includes(part),
        ),
    );
    assert.match(pin.sha256, hashPattern);
    assert(!seen.has(pin.path), `Duplicate source pin: ${pin.path}`);
    seen.add(pin.path);
  }
  return freeze(structuredClone(sourcePins));
}

async function compilationObservationBudget(sourcePins, readSource) {
  const recipeSources = {};
  const pins = new Map(sourcePins.files.map((pin) => [pin.path, pin.sha256]));
  for (const owner of functionalActionOwners) {
    const path = `scripts/hosted-functional-actions/presentations/${owner}.json`;
    assert(pins.has(path), `Unadmitted presentation recipe: ${path}`);
    const bytes = await readSource(path);
    assert(Buffer.isBuffer(bytes));
    assert.equal(
      digest(bytes),
      pins.get(path),
      `Changed presentation recipe: ${path}`,
    );
    recipeSources[owner] = {
      path,
      bytes: Buffer.from(bytes),
      sha256: pins.get(path),
    };
  }
  const { createFunctionalProcessObservationBudget } = await import(
    "./owned-process.mjs"
  );
  return createFunctionalProcessObservationBudget({
    sourceCommit: sourcePins.sourceCommit,
    sourcePins,
    recipeSources,
  });
}

export async function probeFunctionalCompilationObservationBudget({
  sourcePins,
  runtime,
}) {
  sourcePins = validateFunctionalCompilationSourcePins(sourcePins);
  exact(runtime, ["readSource"]);
  assert.equal(typeof runtime.readSource, "function");
  const budget = await compilationObservationBudget(
    sourcePins,
    runtime.readSource,
  );
  return freeze({
    ...structuredClone(budget),
    sourceReady: false,
    nativeProof: false,
    scope: "injected source recipe budget probe",
  });
}

function provenance(value) {
  const bytes = functionalCanonicalJSON(value);
  return Object.freeze({
    get bytes() {
      return Buffer.from(bytes);
    },
    sha256: digest(bytes),
  });
}

export function validateFunctionalCompilationObserverSignature(
  signature,
  certificateSHA256,
) {
  assert(
    typeof certificateSHA256 === "string" &&
      /^[A-Za-z0-9+/]{43}=$/.test(certificateSHA256),
  );
  const certificate = Buffer.from(certificateSHA256, "base64");
  assert.equal(certificate.length, 32);
  assert.equal(certificate.toString("base64"), certificateSHA256);
  exact(signature, ["identifier", "certificateSHA256"]);
  assert.equal(
    signature.identifier,
    observerIdentifier,
    "Wrong process observer signer identifier",
  );
  assert.equal(
    signature.certificateSHA256,
    certificateSHA256,
    "Wrong process observer signing certificate",
  );
  return freeze({ ...signature });
}

function requireObserverSignature(certificateSHA256, observeSignature) {
  return validateFunctionalCompilationObserverSignature(
    observeSignature(),
    certificateSHA256,
  );
}

export function probeFunctionalCompilationObserverSignature({
  certificateSHA256,
  runtime,
}) {
  exact(runtime, ["observeSignature"]);
  assert.equal(typeof runtime.observeSignature, "function");
  const first = requireObserverSignature(
    certificateSHA256,
    runtime.observeSignature,
  );
  const second = requireObserverSignature(
    certificateSHA256,
    runtime.observeSignature,
  );
  return freeze({
    first,
    second,
    sourceReady: false,
    nativeProof: false,
    scope: "injected observer signature probe",
  });
}

function observeHelperSignature(state) {
  return requireObserverSignature(state.signingCertificate, () =>
    JSON.parse(
      execute(
        state.signatureProbePin.path,
        [state.helperPin.path, observerIdentifier, state.signingCertificate],
        state.snapshot,
        state.environment,
      ).toString("utf8"),
    ),
  );
}

async function pinnedFile(path) {
  assert.equal(resolve(path), path);
  assert.equal(await realpath(path), path);
  const file = await open(
    path,
    constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK,
  );
  try {
    const before = await file.stat({ bigint: true });
    assert(
      before.isFile() && before.nlink === 1n && (before.mode & 0o022n) === 0n,
    );
    const bytes = await file.readFile();
    const identity = (state) =>
      [
        state.dev,
        state.ino,
        state.size,
        state.mode,
        state.uid,
        state.nlink,
        state.mtimeNs,
        state.ctimeNs,
      ].map(String);
    assert.deepEqual(
      identity(await file.stat({ bigint: true })),
      identity(before),
    );
    return Object.freeze({
      path,
      sha256: digest(bytes),
      identity: Object.freeze(identity(before)),
    });
  } finally {
    await file.close();
  }
}

async function requirePin(pin) {
  assert.deepEqual(
    await pinnedFile(pin.path),
    pin,
    `Changed compilation input: ${pin.path}`,
  );
}

async function requireDirectory(path) {
  assert.equal(resolve(path), path);
  assert.equal(await realpath(path), path);
  const state = await lstat(path);
  assert(
    state.isDirectory() &&
      !state.isSymbolicLink() &&
      state.uid === process.getuid(),
  );
  assert.equal(state.mode & 0o7777, 0o700);
  return Object.freeze({ dev: state.dev, ino: state.ino });
}

function ownedDirectories(
  runtime = {
    create: async (path) => {
      await mkdir(path, { mode: 0o700 });
      return requireDirectory(path);
    },
    current: requireDirectory,
    remove: async (path) => rm(path, { recursive: true }),
  },
) {
  const created = [];
  return {
    async create(path) {
      const identity = freeze(structuredClone(await runtime.create(path)));
      created.push({ path, identity });
    },
    async abort() {
      const failures = [];
      for (const entry of [...created].reverse()) {
        try {
          assert.deepEqual(
            await runtime.current(entry.path),
            entry.identity,
            "Owned staging directory changed",
          );
          await runtime.remove(entry.path);
          created.splice(created.indexOf(entry), 1);
        } catch (error) {
          failures.push(error);
        }
      }
      if (failures.length)
        throw new AggregateError(failures, "Owned staging cleanup failed");
    },
  };
}

export async function probeFunctionalCompilationStaging({ paths, runtime }) {
  assert(
    Array.isArray(paths) &&
      paths.length > 0 &&
      paths.every((path) => typeof path === "string" && resolve(path) === path),
  );
  exact(runtime, ["create", "current", "remove"]);
  for (const method of Object.values(runtime))
    assert.equal(typeof method, "function");
  const stage = ownedDirectories(runtime);
  try {
    for (const path of paths) await stage.create(path);
    await stage.abort();
    return freeze({
      sourceReady: false,
      nativeProof: false,
      scope: "injected owned staging probe",
    });
  } catch (error) {
    try {
      await stage.abort();
    } catch (cleanup) {
      throw new AggregateError(
        [error, cleanup],
        "Staging failed and owned cleanup failed",
      );
    }
    throw error;
  }
}

async function verifySources(root, pins, overrides = new Map()) {
  for (const pin of pins.files) {
    const state = await pinnedFile(join(root, pin.path));
    assert.equal(
      state.sha256,
      overrides.get(pin.path) ?? pin.sha256,
      `Changed source: ${pin.path}`,
    );
  }
}

export function functionalCompilationArguments(file, args) {
  assert.equal(typeof file, "string");
  assert(
    Array.isArray(args) && args.every((value) => typeof value === "string"),
  );
  if (file === "xcrun" && args[0] === "swiftc") {
    assert(
      !args.includes("-target"),
      "Fixture compiler target is source-owned",
    );
    return Object.freeze(["swiftc", "-target", targetTriple, ...args.slice(1)]);
  }
  if (file === "xcrun" && args[0] === "swift" && args[1] === "build") {
    assert(
      !args.includes("--triple"),
      "Fixture dependency target is source-owned",
    );
    return Object.freeze([
      "swift",
      "build",
      "--triple",
      targetTriple,
      ...args.slice(2),
    ]);
  }
  return Object.freeze([...args]);
}

function execute(file, args, repository, environment, input) {
  return execFileSync(file, functionalCompilationArguments(file, args), {
    cwd: repository,
    env: environment,
    input,
    stdio: ["pipe", "pipe", "pipe"],
    timeout: 600000,
    maxBuffer: 268435456,
  });
}

function hosted(environment, sourceCommit) {
  assert.equal(process.platform, "darwin");
  assert.equal(process.arch, "arm64");
  assert.match(sourceCommit, commitPattern);
  for (const [key, value] of Object.entries({
    GITHUB_ACTIONS: "true",
    RUNNER_ENVIRONMENT: "github-hosted",
    RUNNER_OS: "macOS",
    GITHUB_REPOSITORY: "pulkitxm/edith",
    GITHUB_REPOSITORY_ID: "1289153439",
    GITHUB_EVENT_NAME: "pull_request",
    EDITH_HOSTED_FUNCTIONAL_ACTIONS: "1",
    EXPECTED_SOURCE_SHA: sourceCommit,
    EXTENSION_SWIFT_JOBS: "1",
  }))
    assert.equal(
      environment[key],
      value,
      `Unadmitted compilation runner: ${key}`,
    );
  assert.match(environment.GITHUB_SHA, commitPattern);
  assert.notEqual(environment.GITHUB_SHA, sourceCommit);
  assert.equal(environment.GITHUB_REF, "refs/pull/1014/merge");
  assert.match(environment.GITHUB_RUN_ID, /^[1-9][0-9]*$/);
  assert.match(environment.GITHUB_RUN_ATTEMPT, /^[1-9][0-9]*$/);
  assert.match(
    environment.DEVELOPER_DIR,
    /^\/Applications\/Xcode[^/]*\.app\/Contents\/Developer$/,
  );
  assert.equal(resolve(environment.RUNNER_TEMP), environment.RUNNER_TEMP);
  assert(
    environment.EXTENSION_SIGN_IDENTITY &&
      environment.EXTENSION_SIGN_IDENTITY !== "-",
  );
  assert(
    !environment.EXTENSION_RELEASE_TAG &&
      !environment.EXTENSION_CATALOG_PRIVATE_KEY,
  );
}

async function captureToolchain({ repository, sourceCommit, environment }) {
  const run = (file, args) =>
    execute(file, args, repository, environment).toString("utf8").trim();
  const compiler = await pinnedFile(
    await realpath(run("xcrun", ["--find", "swiftc"])),
  );
  const sdk = await realpath(
    run("xcrun", ["--sdk", "macosx", "--show-sdk-path"]),
  );
  const compilerInputs = [];
  for (const name of ["swift-driver", "clang", "ld"])
    compilerInputs.push(
      await pinnedFile(await realpath(run("xcrun", ["--find", name]))),
    );
  const buildTools = [];
  for (const name of [
    "xcodebuild",
    "codesign",
    "git",
    "tar",
    "file",
    "security",
  ])
    buildTools.push(
      await pinnedFile(await realpath(run("/usr/bin/which", [name]))),
    );
  const sdkFiles = [];
  for (const name of ["SDKSettings.json", "SDKSettings.plist"])
    sdkFiles.push(await pinnedFile(join(sdk, name)));
  const settings = freeze({
    developerDirectory: await realpath(environment.DEVELOPER_DIR),
    compilerInputs: compilerInputs.map(({ path, sha256 }) => ({
      path,
      sha256,
    })),
    buildTools: buildTools.map(({ path, sha256 }) => ({ path, sha256 })),
    swiftVersion: run(compiler.path, ["--version"]),
    xcodeVersion: run("xcodebuild", ["-version"]),
    sdkVersion: run("xcrun", ["--sdk", "macosx", "--show-sdk-version"]),
    architecture: "arm64",
    deploymentTarget,
    targetTriple,
    jobs: 1,
    configuration: "release",
    fixture: true,
    swiftLanguageVersions: ["5", "6"],
  });
  const evidence = provenance({
    swiftCompilerSHA256: compiler.sha256,
    sdkSHA256: digest(
      functionalCanonicalJSON(
        sdkFiles.map(({ path, sha256 }) => ({ path, sha256 })),
      ),
    ),
    buildSettingsSHA256: digest(functionalCanonicalJSON(settings)),
  });
  const capability = freeze({
    sourceCommit,
    get bytes() {
      return evidence.bytes;
    },
    sha256: evidence.sha256,
    compiler: { path: compiler.path, sha256: compiler.sha256 },
    sdk,
    sdkFiles: sdkFiles.map(({ path, sha256 }) => ({ path, sha256 })),
    settings,
    scope:
      "compiler executable and SDK settings identity; no native qualification",
  });
  toolchains.set(capability, {
    repository,
    sourceCommit,
    environment,
    compiler,
    compilerInputs,
    buildTools,
    sdkFiles,
    settings,
  });
  return capability;
}

export async function captureFunctionalCompilationToolchain({
  repository,
  sourceCommit,
  environment = process.env,
}) {
  environment = Object.freeze({ ...environment });
  hosted(environment, sourceCommit);
  assert.equal(await realpath(repository), repository);
  return captureToolchain({ repository, sourceCommit, environment });
}

async function requireToolchain(capability) {
  const state = toolchains.get(capability);
  assert(state, "Expected captured compilation toolchain");
  await requirePin(state.compiler);
  for (const pin of [...state.compilerInputs, ...state.buildTools])
    await requirePin(pin);
  for (const pin of state.sdkFiles) await requirePin(pin);
  assert.equal(
    digest(capability.bytes),
    capability.sha256,
    "Captured toolchain bytes changed",
  );
  const current = await captureToolchain(state);
  assert.deepEqual(current, capability, "Compilation toolchain changed");
}

async function stagedBuild({
  verify,
  stage,
  compile,
  observeOutput,
  publish,
  abort,
}) {
  let staged = false;
  try {
    await verify();
    staged = true;
    await stage();
    await verify();
    await compile();
    await verify();
    const output = await observeOutput();
    await verify();
    return await publish(output);
  } catch (error) {
    if (staged) {
      try {
        await abort();
      } catch (cleanup) {
        throw new AggregateError(
          [error, cleanup],
          "Compilation failed and staging cleanup failed",
        );
      }
    }
    throw error;
  }
}

export async function probeFunctionalCompilation({
  sourcePins,
  expectedOutputSHA256,
  runtime,
}) {
  sourcePins = validateFunctionalCompilationSourcePins(sourcePins);
  assert.match(expectedOutputSHA256, hashPattern);
  exact(runtime, [
    "readSource",
    "observeCompiler",
    "requireLifetime",
    "stage",
    "compile",
    "readOutput",
    "publish",
    "abort",
  ]);
  for (const method of Object.values(runtime))
    assert.equal(typeof method, "function");
  const compiler = await runtime.observeCompiler();
  assert.match(compiler, hashPattern);
  const verify = async () => {
    await runtime.requireLifetime();
    assert.equal(
      await runtime.observeCompiler(),
      compiler,
      "Compilation toolchain changed",
    );
    for (const pin of sourcePins.files)
      assert.equal(
        digest(await runtime.readSource(pin.path)),
        pin.sha256,
        `Changed source: ${pin.path}`,
      );
  };
  return stagedBuild({
    verify,
    stage: runtime.stage,
    compile: runtime.compile,
    observeOutput: async () => {
      const bytes = await runtime.readOutput();
      assert.equal(
        digest(bytes),
        expectedOutputSHA256,
        "Wrong compiler output",
      );
      return bytes;
    },
    publish: async (bytes) => {
      await runtime.publish(bytes);
      return freeze({
        sourceCommit: sourcePins.sourceCommit,
        executableSHA256: digest(bytes),
        sourceReady: false,
        nativeProof: false,
        scope: "injected memory compilation probe",
      });
    },
    abort: runtime.abort,
  });
}

export async function functionalCompilationForBuilder(capability) {
  const state = compilations.get(capability);
  assert(
    state && state.status === "ready",
    "Expected owned live functional compilation",
  );
  await state.verify();
  return capability;
}

const packageRoots = Object.freeze([
  "Packages/EdithHost",
  "Packages/EdithDocsWorker",
  "Packages/ExtensionMarketplace",
  "Packages/ExtensionSupport",
  "Extensions/fixtureSupport",
]);
const contextPath =
  "Tests/HostedFunctionalActions/Sources/FunctionalActionContract/HostedFunctionalActionContext.swift";
const producerRoot = "Tests/HostedFunctionalActions/ProducerSources";
const hostRoot = "Tests/HostedFunctionalActions/HostSources";

async function sourceUnion(repository, sourcePins, run) {
  const { functionalProcessObserverSourcePaths } = await import(
    "./owned-process.mjs"
  );
  const tracked = run("git", [
    "ls-tree",
    "-rz",
    "--name-only",
    sourcePins.sourceCommit,
    "--",
    ...packageRoots,
    hostRoot,
  ])
    .toString("utf8")
    .split("\0")
    .filter(Boolean);
  const pins = new Map(sourcePins.files.map((pin) => [pin.path, pin.sha256]));
  for (const path of [
    ...tracked,
    contextPath,
    ...functionalProcessObserverSourcePaths,
    ...functionalActionOwners.map(
      (owner) =>
        `scripts/hosted-functional-actions/presentations/${owner}.json`,
    ),
    ...[
      "FunctionalIssuer.swift",
      "FunctionalLifecycle.swift",
      "FunctionalPersistence.swift",
      "FunctionalOriginalUI.swift",
      "FunctionalProcessProbe.swift",
      "FunctionalSignatureProbe.swift",
    ].map((name) => `${producerRoot}/${name}`),
    ...[
      "functional-build.mjs",
      "producer-project.mjs",
      "fixture-trust.mjs",
      "owned-process.mjs",
      "controller.mjs",
    ].map((name) => `scripts/hosted-functional-actions/${name}`),
  ])
    assert(pins.has(path), `Unadmitted dependency source: ${path}`);
  assert(tracked.some((path) => path.endsWith("/HostEntry.swift")));
  const complete = run("git", [
    "ls-tree",
    "-rz",
    "--name-only",
    sourcePins.sourceCommit,
  ])
    .toString("utf8")
    .split("\0")
    .filter(Boolean);
  assert.deepEqual(
    [...pins.keys()].sort(),
    complete.sort(),
    "Compilation snapshot requires the complete literal committed source union",
  );
  await verifySources(repository, sourcePins);
}

export async function createFunctionalCompilation({
  repository,
  sourceCommit,
  sourcePins,
  root,
  environment = process.env,
  toolchain,
}) {
  environment = Object.freeze({ ...environment });
  hosted(environment, sourceCommit);
  assert.equal(await realpath(repository), repository);
  sourcePins = validateFunctionalCompilationSourcePins(sourcePins);
  assert.equal(sourcePins.sourceCommit, sourceCommit);
  assert(root.startsWith(`${environment.RUNNER_TEMP}/functional-fixture-`));
  const rootIdentity = await requireDirectory(root);
  const run = (file, args, input) =>
    execute(file, args, repository, environment, input);
  const git = (args) => run("git", args).toString("utf8").trim();
  assert.equal(git(["rev-parse", "HEAD"]), sourceCommit);
  assert.equal(git(["status", "--porcelain", "--untracked-files=no"]), "");
  await sourceUnion(repository, sourcePins, run);
  const controller = await import("./controller.mjs");
  const activeJob = await controller.observeFunctionalActiveJob({
    repository,
    sourceCommit,
    environment,
  });
  assert.equal(activeJob.sourceCommit, sourceCommit);
  const jobBindings = (job) =>
    freeze({
      ...controller.functionalActiveJobBuildPins(job),
      workflowID: job.context.workflow.id,
      repositoryID: job.run.repository.id,
      headRepositoryID: job.run.head_repository.id,
      eventRepositoryID: job.context.event.repository.id,
      pullRequestHeadRepositoryID: job.context.pullRequest.head.repo.id,
      pullRequestBaseRepositoryID: job.context.pullRequest.base.repo.id,
      actorID: job.run.actor.id,
      triggeringActorID: job.run.triggering_actor.id,
      eventAction: job.context.event.action,
    });
  const admittedJobBindings = jobBindings(activeJob);
  toolchain ??= await captureFunctionalCompilationToolchain({
    repository,
    sourceCommit,
    environment,
  });
  assert.equal(toolchain.sourceCommit, sourceCommit);
  await requireToolchain(toolchain);
  const capturedEnvironment = toolchains.get(toolchain).environment;
  assert.deepEqual(
    Object.keys(capturedEnvironment).sort(),
    Object.keys(environment).sort(),
    "Compilation environment keys changed after toolchain capture",
  );
  for (const key of Object.keys(environment))
    assert(
      capturedEnvironment[key] === environment[key],
      `Compilation environment changed after toolchain capture: ${key}`,
    );
  const projectBuilder = await import("./producer-project.mjs");
  const signingCertificate =
    await projectBuilder.captureFunctionalSigningCertificate({
      environment,
      sourceCommit,
    });
  const source = provenance(sourcePins);
  const snapshot = join(root, "CompilationSource");
  const observerDirectory = join(root, "ProcessObserver");
  const catalogueDirectory = join(observerDirectory, "ExtensionMarketplace");
  const catalogueSources = [
    "ExtensionCatalog.swift",
    "ExtensionSystemVersion.swift",
  ].map(
    (name) =>
      `Packages/ExtensionMarketplace/Sources/ExtensionMarketplace/${name}`,
  );
  const catalogueLibrary = join(
    catalogueDirectory,
    "libExtensionMarketplace.a",
  );
  const catalogueModule = join(
    catalogueDirectory,
    "ExtensionMarketplace.swiftmodule",
  );
  let cataloguePins;
  let signatureProbePin;
  const verify = async () => {
    assert.deepEqual(
      await requireDirectory(root),
      rootIdentity,
      "Owned compilation root changed",
    );
    assert.equal(git(["rev-parse", "HEAD"]), sourceCommit);
    assert.equal(git(["status", "--porcelain", "--untracked-files=no"]), "");
    await verifySources(repository, sourcePins);
    await requireToolchain(toolchain);
    const current = await controller.observeFunctionalActiveJob({
      repository,
      sourceCommit,
      environment,
    });
    assert.deepEqual(
      jobBindings(current),
      admittedJobBindings,
      "Functional compilation job changed",
    );
  };
  let state;
  const staging = ownedDirectories();
  return stagedBuild({
    verify,
    stage: async () => {
      await staging.create(snapshot);
      await staging.create(observerDirectory);
      await staging.create(catalogueDirectory);
      const archive = run("git", ["archive", "--format=tar", sourceCommit]);
      run("tar", ["-xf", "-", "-C", snapshot], archive);
      await verifySources(snapshot, sourcePins);
    },
    compile: async () => {
      await verifySources(snapshot, sourcePins);
      const executable = join(observerDirectory, "functional-process-probe");
      execute(
        "xcrun",
        [
          "swiftc",
          "-parse-as-library",
          "-emit-module",
          "-emit-library",
          "-static",
          "-swift-version",
          "6",
          "-O",
          "-num-threads",
          "1",
          "-module-name",
          "ExtensionMarketplace",
          ...catalogueSources.map((path) => join(snapshot, path)),
          "-emit-module-path",
          catalogueModule,
          "-o",
          catalogueLibrary,
        ],
        snapshot,
        environment,
      );
      cataloguePins = await Promise.all(
        [catalogueLibrary, catalogueModule].map(pinnedFile),
      );
      await verifySources(snapshot, sourcePins);
      execute(
        "xcrun",
        [
          "swiftc",
          "-parse-as-library",
          "-swift-version",
          "6",
          "-O",
          "-num-threads",
          "1",
          "-framework",
          "Security",
          "-I",
          catalogueDirectory,
          ...[
            "FunctionalIssuer.swift",
            "FunctionalLifecycle.swift",
            "FunctionalProcessProbe.swift",
          ].map((name) => join(snapshot, producerRoot, name)),
          catalogueLibrary,
          "-o",
          executable,
        ],
        snapshot,
        environment,
      );
      execute(
        "codesign",
        [
          "--sign",
          environment.EXTENSION_SIGN_IDENTITY,
          "--identifier",
          observerIdentifier,
          "--options",
          "runtime",
          "--timestamp",
          executable,
        ],
        snapshot,
        environment,
      );
      execute(
        "codesign",
        ["--verify", "--strict", executable],
        snapshot,
        environment,
      );
      await chmod(executable, 0o500);
      const signatureProbe = join(
        observerDirectory,
        "functional-signature-probe",
      );
      execute(
        "xcrun",
        [
          "swiftc",
          "-parse-as-library",
          "-swift-version",
          "6",
          "-O",
          "-num-threads",
          "1",
          join(snapshot, producerRoot, "FunctionalSignatureProbe.swift"),
          "-o",
          signatureProbe,
        ],
        snapshot,
        environment,
      );
      await chmod(signatureProbe, 0o500);
      signatureProbePin = await pinnedFile(signatureProbe);
      await verifySources(snapshot, sourcePins);
    },
    observeOutput: async () =>
      pinnedFile(join(observerDirectory, "functional-process-probe")),
    publish: async (helperPin) => {
      await requirePin(helperPin);
      await requirePin(signatureProbePin);
      const helperIdentity = {
        helperPin,
        signatureProbePin,
        signingCertificate,
        snapshot,
        environment,
      };
      observeHelperSignature(helperIdentity);
      await requirePin(helperPin);
      await requirePin(signatureProbePin);
      const { createFunctionalOwnedProcessObserver } = await import(
        "./owned-process.mjs"
      );
      const observerHelper = Object.freeze({
        executable: helperPin.path,
        executableSHA256: helperPin.sha256,
      });
      const observationBudget = await compilationObservationBudget(
        sourcePins,
        (path) => readFile(join(snapshot, path)),
      );
      const observer = await createFunctionalOwnedProcessObserver({
        helper: observerHelper,
        observationBudget,
      });
      const capability = freeze({
        sourceCommit,
        root,
        sourceRepository: snapshot,
        source,
        toolchain: Object.freeze({
          get bytes() {
            return toolchain.bytes;
          },
          sha256: toolchain.sha256,
        }),
        observerHelper,
        observerDependencies: cataloguePins.map(({ path, sha256 }) => ({
          path,
          sha256,
        })),
        observer,
        sourceReady: false,
        nativeProof: false,
      });
      state = {
        repository,
        sourceCommit,
        sourcePins,
        root,
        rootIdentity,
        snapshot,
        observerDirectory,
        helperPin,
        signatureProbePin,
        signingCertificate,
        cataloguePins,
        observer,
        environment,
        toolchain,
        activeJob,
        status: "ready",
        hostStatus: "unbuilt",
        docsStatus: "unbuilt",
        generated: new Map(),
      };
      state.verify = async () => {
        assert.equal(state.status, "ready", "Compilation lifetime ended");
        await verify();
        await requireDirectory(snapshot);
        await verifySources(snapshot, sourcePins, state.generated);
        await requirePin(helperPin);
        await requirePin(signatureProbePin);
        assert.equal(
          await projectBuilder.captureFunctionalSigningCertificate({
            environment,
            sourceCommit,
          }),
          signingCertificate,
          "Process observer signing identity changed",
        );
        observeHelperSignature(state);
        await requirePin(helperPin);
        await requirePin(signatureProbePin);
        for (const pin of cataloguePins) await requirePin(pin);
        if (state.docsDependency)
          await verifyDocsDependency(
            docsDependencies.get(state.docsDependency),
          );
      };
      compilations.set(capability, state);
      return capability;
    },
    abort: async () => {
      if (state) state.status = "failed";
      await staging.abort();
    },
  });
}

export function functionalHostBuildSource({
  plan,
  issuerManifestBytes,
  activeJob,
  sourceSHA256,
  toolchainSHA256,
}) {
  const manifest = JSON.parse(issuerManifestBytes.toString("utf8"));
  assert.equal(manifest.sourceCommit, plan.sourceCommit);
  assert.equal(manifest.session, plan.session);
  assert.equal(manifest.root, plan.root);
  assert.equal(manifest.hostIdentifier, plan.hostIdentifier);
  assert.equal(manifest.producer.path, plan.executable);
  assert.equal(manifest.producer.sourceSHA256, sourceSHA256);
  assert.equal(manifest.producer.toolchainSHA256, toolchainSHA256);
  assert.equal(manifest.policySHA256, plan.policySHA256);
  assert.equal(manifest.signing.hostCertificateSHA256, plan.certificateSHA256);
  assert.equal(manifest.producer.certificateSHA256, plan.certificateSHA256);
  assert.equal(
    manifest.producer.requirement,
    `identifier "${plan.producerIdentifier}"`,
  );
  const quote = (value) => {
    assert(
      typeof value === "string" && value.length > 0 && /^[ -~]+$/.test(value),
    );
    return JSON.stringify(value);
  };
  const data = (value) => {
    assert(/^[A-Za-z0-9+/]{43}=$/.test(value));
    assert.equal(Buffer.from(value, "base64").length, 32);
    assert.equal(Buffer.from(value, "base64").toString("base64"), value);
    return `Data(base64Encoded: ${quote(value)})!`;
  };
  const { context, run, job } = activeJob;
  assert.equal(activeJob.sourceCommit, plan.sourceCommit);
  assert.equal(manifest.runID, run.id);
  assert.equal(manifest.jobID, job.id);
  const pins = {
    sourceCommit: plan.sourceCommit,
    mergeCommit: context.mergeCommit.sha,
    baseCommit: context.pullRequest.base.sha,
    runID: run.id,
    jobID: job.id,
    runAttempt: context.runAttempt,
    runnerName: job.runner_name,
    workflowSHA256: plan.hostedRunPins.workflowSHA256,
  };
  assert.deepEqual(
    pins,
    plan.hostedRunPins,
    "Host and producer hosted run pins differ",
  );
  for (const name of ["sourceCommit", "mergeCommit", "baseCommit"])
    assert.match(pins[name], commitPattern);
  for (const name of ["runID", "jobID", "runAttempt"])
    assert(Number.isSafeInteger(pins[name]) && pins[name] > 0);
  assert.match(pins.workflowSHA256, hashPattern);
  assert.match(sourceSHA256, hashPattern);
  assert.match(toolchainSHA256, hashPattern);
  assert.match(manifest.producer.executableSHA256, hashPattern);
  exact(plan.observationPolicies, functionalActionOwners);
  const readPolicies = functionalActionOwners.map((owner) => {
    const policy = plan.observationPolicies[owner];
    exact(policy, ["schema", "owner", "readback", "phases"]);
    assert.equal(policy.schema, 1);
    assert.equal(policy.owner, owner);
    exact(policy.readback, ["operation", "payload", "normalizer"]);
    assert(
      typeof policy.readback.operation === "string" &&
        /^[A-Za-z0-9_.-]{1,256}$/.test(policy.readback.operation),
    );
    assert(
      policy.readback.payload &&
        Object.getPrototypeOf(policy.readback.payload) === Object.prototype,
    );
    const bytes = Buffer.from(
      functionalCanonicalJSON({
        schema: 1,
        owner,
        operation: policy.readback.operation,
        payload: policy.readback.payload,
      }),
    );
    assert(bytes.length > 0 && bytes.length <= 262144);
    return `${quote(owner)}: Data(base64Encoded: ${quote(bytes.toString("base64"))})!`;
  });
  const values = {
    "authoritativeReadPolicies: [String: Data]": `[${readPolicies.join(", ")}]`,
    sourceCommit: quote(plan.sourceCommit),
    session: quote(plan.session),
    root: quote(plan.root),
    hostIdentifier: quote(plan.hostIdentifier),
    producerIdentifier: quote(plan.producerIdentifier),
    certificateSHA256: data(plan.certificateSHA256),
    issuerPublicKey: data(manifest.issuerPublicKey),
    producerExecutable: quote(plan.executable),
    producerExecutableSHA256: quote(manifest.producer.executableSHA256),
    sourceSHA256: quote(sourceSHA256),
    toolchainSHA256: quote(toolchainSHA256),
    policySHA256: quote(plan.policySHA256),
    hostedRunPins: `FunctionalHostedRunPins(sourceCommit: ${quote(pins.sourceCommit)}, mergeCommit: ${quote(pins.mergeCommit)}, baseCommit: ${quote(pins.baseCommit)}, runID: ${pins.runID}, jobID: ${pins.jobID}, runAttempt: ${pins.runAttempt}, runnerName: ${quote(pins.runnerName)}, workflowSHA256: ${quote(pins.workflowSHA256)})`,
  };
  return `import Foundation\n\nenum FunctionalHostBuild {\n${Object.entries(
    values,
  )
    .map(([key, value]) => `    static let ${key} = ${value}`)
    .join(
      "\n",
    )}\n}\n\nenum FunctionalProducerBuild {\n${["sourceCommit", "session", "root", "hostedRunPins"].map((name) => `    static let ${name} = FunctionalHostBuild.${name}`).join("\n")}\n}\n`;
}

async function artifactsUnder(root) {
  const result = [];
  const visited = new Set();
  async function visit(path) {
    const canonical = await realpath(path);
    assert(
      canonical === root || canonical.startsWith(`${root}/`),
      "Dependency artifact escaped owned build",
    );
    if (visited.has(canonical)) return;
    visited.add(canonical);
    const state = await lstat(canonical);
    if (state.isDirectory()) {
      for (const name of (await readdir(canonical)).sort())
        await visit(join(canonical, name));
    } else {
      assert(state.isFile());
      if (canonical.includes("/EdithHost.build/")) return;
      const kind = canonical.endsWith(".o")
        ? "object"
        : /\.(swiftmodule|swiftdoc|swiftsourceinfo)$/.test(canonical)
          ? "module"
          : canonical.endsWith(".dylib")
            ? "library"
            : canonical.endsWith(".modulemap")
              ? "modulemap"
              : canonical.includes(".framework/")
                ? "framework"
                : canonical.includes(".bundle/")
                  ? "resource"
                  : undefined;
      if (kind)
        result.push(
          freeze({
            path: canonical,
            kind,
            sha256: digest(await readFile(canonical)),
          }),
        );
    }
  }
  await visit(root);
  return result.sort((left, right) => left.path.localeCompare(right.path));
}

async function verifyArtifacts(artifacts) {
  for (const artifact of artifacts)
    assert.equal(
      digest(await readFile(artifact.path)),
      artifact.sha256,
      `Dependency artifact changed: ${artifact.path}`,
    );
}

function hostInfoPlist(identifier) {
  assert(/^[A-Za-z0-9.-]+$/.test(identifier));
  return `<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>${identifier}</string><key>CFBundleName</key><string>Fixture</string><key>CFBundleExecutable</key><string>Edith</string><key>CFBundlePackageType</key><string>APPL</string><key>CFBundleShortVersionString</key><string>1.0.0</string><key>CFBundleVersion</key><string>1</string><key>LSMinimumSystemVersion</key><string>${deploymentTarget}</string><key>NSPrincipalClass</key><string>NSApplication</string><key>NSCameraUsageDescription</key><string>Synthetic fixture camera verification</string><key>NSMicrophoneUsageDescription</key><string>Synthetic fixture audio verification</string></dict></plist>\n`;
}

async function signHostTree(path, state) {
  const files = [];
  async function visit(item) {
    const info = await lstat(item);
    if (info.isSymbolicLink()) {
      assert((await realpath(item)).startsWith(`${path}/`));
      return;
    }
    if (info.isDirectory()) {
      for (const name of (await readdir(item)).sort())
        await visit(join(item, name));
      if (/\.(framework|xpc|app)$/.test(item)) files.push(item);
    } else {
      assert(info.isFile());
      if (
        execute("file", ["-b", item], state.snapshot, state.environment)
          .toString("utf8")
          .includes("Mach-O")
      )
        files.push(item);
    }
  }
  await visit(path);
  for (const file of files)
    execute(
      "codesign",
      [
        "--force",
        "--sign",
        state.environment.EXTENSION_SIGN_IDENTITY,
        "--options",
        "runtime",
        "--timestamp",
        file,
      ],
      state.snapshot,
      state.environment,
    );
}

export async function buildFunctionalFixtureHost({
  compilation,
  plan,
  issuerManifestBytes,
  admittedIssuer,
  policyBytes,
  admittedPolicies,
}) {
  await functionalCompilationForBuilder(compilation);
  const state = compilations.get(compilation);
  assert.equal(
    state.hostStatus,
    "unbuilt",
    "Functional Host is compiled once per owned session",
  );
  assert.equal(plan.sourceCommit, state.sourceCommit);
  assert.equal(plan.root, state.root);
  assert.deepEqual(plan.sourcePins, state.sourcePins);
  const projectBuilder = await import("./producer-project.mjs");
  projectBuilder.functionalProducerPlanForBuild(plan);
  assert.equal(plan.sourceSHA256, compilation.source.sha256);
  assert.equal(plan.toolchainSHA256, compilation.toolchain.sha256);
  await functionalDocsDependencyForBuilder({
    compilation,
    plan,
    dependency: state.docsDependency,
  });
  const trust = await import("./fixture-trust.mjs");
  const bootstrap = trust.functionalFixtureBootstrapTrustSource(
    issuerManifestBytes,
    admittedIssuer,
    policyBytes,
    admittedPolicies,
  );
  assert.equal(bootstrap.sourceCommit, state.sourceCommit);
  assert.equal(bootstrap.sourceSHA256, digest(bootstrap.source));
  assert(
    state.sourcePins.files.some(({ path }) => path === bootstrap.generatedPath),
  );
  const hostBuild = functionalHostBuildSource({
    plan,
    issuerManifestBytes,
    activeJob: state.activeJob,
    sourceSHA256: compilation.source.sha256,
    toolchainSHA256: compilation.toolchain.sha256,
  });
  const manifest = JSON.parse(issuerManifestBytes.toString("utf8"));
  const directory = join(state.root, "HostBuild");
  const dependencyRoot = join(state.root, "HostDependencies");
  const buildRoot = join(directory, "DerivedData");
  const finalHost = join(state.root, "Fixture.app");
  let artifacts;
  let projectBytes;
  let generatedPins;
  let dependencySources;
  const staging = ownedDirectories();
  const verify = async () => {
    await state.verify();
    const current = trust.functionalFixtureBootstrapTrustSource(
      issuerManifestBytes,
      admittedIssuer,
      policyBytes,
      admittedPolicies,
    );
    assert.deepEqual(current, bootstrap, "Live bootstrap authority changed");
    if (generatedPins) for (const pin of generatedPins) await requirePin(pin);
    if (artifacts) await verifyArtifacts(artifacts);
    if (dependencySources)
      await verifyDependencySources(dependencySources, state);
  };
  state.hostStatus = "building";
  return stagedBuild({
    verify,
    stage: async () => {
      await staging.create(directory);
      await staging.create(dependencyRoot);
      await writeFile(
        join(state.snapshot, bootstrap.generatedPath),
        bootstrap.source,
        { mode: 0o600 },
      );
      state.generated.set(bootstrap.generatedPath, bootstrap.sourceSHA256);
      await writeFile(join(directory, "FunctionalHostBuild.swift"), hostBuild, {
        flag: "wx",
        mode: 0o600,
      });
      await writeFile(
        join(directory, "Info.plist"),
        hostInfoPlist(plan.hostIdentifier),
        { flag: "wx", mode: 0o600 },
      );
      generatedPins = await Promise.all(
        [
          join(state.snapshot, bootstrap.generatedPath),
          join(directory, "FunctionalHostBuild.swift"),
          join(directory, "Info.plist"),
        ].map(pinnedFile),
      );
    },
    compile: async () => {
      execute(
        "xcrun",
        [
          "swift",
          "package",
          "--package-path",
          join(state.snapshot, "Packages/EdithHost"),
          "--scratch-path",
          dependencyRoot,
          "resolve",
          "--force-resolved-versions",
        ],
        state.snapshot,
        state.environment,
      );
      await verify();
      dependencySources = await captureDependencySources(dependencyRoot, state);
      const args = [
        "swift",
        "build",
        "--package-path",
        join(state.snapshot, "Packages/EdithHost"),
        "--scratch-path",
        dependencyRoot,
        "--configuration",
        "release",
        "--jobs",
        "1",
        "--product",
        "EdithHost",
        "--disable-automatic-resolution",
        "-Xswiftc",
        "-DEDITH_FUNCTIONAL_FIXTURE",
      ];
      execute("xcrun", args, state.snapshot, state.environment);
      await verify();
      const products = await realpath(
        execute(
          "xcrun",
          [
            "swift",
            "build",
            "--package-path",
            join(state.snapshot, "Packages/EdithHost"),
            "--scratch-path",
            dependencyRoot,
            "--configuration",
            "release",
            "--show-bin-path",
          ],
          state.snapshot,
          state.environment,
        )
          .toString("utf8")
          .trim(),
      );
      assert(products.startsWith(`${dependencyRoot}/`));
      artifacts = await artifactsUnder(dependencyRoot);
      artifacts.sort(
        (left, right) =>
          Number(right.path.endsWith("/HostBootstrap.build/module.modulemap")) -
            Number(
              left.path.endsWith("/HostBootstrap.build/module.modulemap"),
            ) || left.path.localeCompare(right.path),
      );
      const moduleMap = artifacts.find(({ path }) =>
        path.endsWith("/HostBootstrap.build/module.modulemap"),
      )?.path;
      assert(moduleMap, "Missing original Host bootstrap module map");
      const frameworks = artifacts
        .filter(
          ({ kind, path }) =>
            kind === "framework" && path.includes("/Sparkle.framework/"),
        )
        .map(({ path }) =>
          path.slice(
            0,
            path.indexOf("/Sparkle.framework/") + "/Sparkle.framework".length,
          ),
        )
        .filter((path) => path.endsWith("/Sparkle.framework"));
      const sparkleFramework = [...new Set(frameworks)].find((path) =>
        path.includes("/macos-arm64_x86_64/"),
      );
      assert(sparkleFramework, "Missing locked macOS Sparkle framework");
      const resource = join(products, "EdithHost_EdithHost.bundle");
      assert((await lstat(resource)).isDirectory());
      const resources = (await readdir(products))
        .filter((name) => name.endsWith(".bundle"))
        .map((name) => join(products, name));
      assert(resources.includes(resource));
      const sourceFiles = state.sourcePins.files
        .map(({ path }) => path)
        .filter(
          (path) =>
            path.endsWith(".swift") &&
            (path.startsWith("Packages/EdithHost/Sources/EdithHost/") ||
              path.startsWith(`${hostRoot}/`) ||
              [
                "FunctionalIssuer.swift",
                "FunctionalLifecycle.swift",
                "FunctionalPersistence.swift",
                "FunctionalOriginalUI.swift",
              ].some((name) => path === `${producerRoot}/${name}`) ||
              path === contextPath),
        );
      const project = projectBuilder.functionalHostProject(plan, {
        repository: state.snapshot,
        directory,
        sourceFiles,
        generatedSources: { "FunctionalHostBuild.swift": hostBuild },
        dependencyArtifacts: artifacts,
        modulesDirectory: join(products, "Modules"),
        moduleMap,
        sparkleFramework,
        resources: [
          ...resources,
          join(
            state.snapshot,
            "Packages/EdithHost/Sources/EdithHostCore/Resources/index.json",
          ),
        ],
      });
      projectBytes = projectBuilder.functionalHostProjectXML(project);
      const projectPath = join(directory, "Fixture.xcodeproj");
      await mkdir(projectPath, { mode: 0o700 });
      await writeFile(join(projectPath, "project.pbxproj"), projectBytes, {
        flag: "wx",
        mode: 0o600,
      });
      generatedPins.push(
        await pinnedFile(join(projectPath, "project.pbxproj")),
      );
      await verify();
      execute(
        "xcodebuild",
        [
          "-project",
          projectPath,
          "-target",
          "EdithHost",
          "-configuration",
          "Release",
          "-sdk",
          "macosx",
          "-arch",
          "arm64",
          "-jobs",
          "1",
          `SYMROOT=${buildRoot}`,
          `OBJROOT=${join(directory, "Intermediates")}`,
          "CODE_SIGNING_ALLOWED=NO",
          "CODE_SIGNING_REQUIRED=NO",
          "build",
        ],
        state.snapshot,
        state.environment,
      );
      const app = join(buildRoot, "Release/Fixture.app");
      assert.equal(await realpath(app), app);
      assert((await lstat(join(app, "Contents/MacOS/Edith"))).isFile());
      const identifier = execute(
        "/usr/libexec/PlistBuddy",
        ["-c", "Print :CFBundleIdentifier", join(app, "Contents/Info.plist")],
        state.snapshot,
        state.environment,
      )
        .toString("utf8")
        .trim();
      assert.equal(
        identifier,
        plan.hostIdentifier,
        "Wrong compiled Host identity",
      );
      await verify();
      await signHostTree(app, state);
      execute(
        "codesign",
        [
          "--verify",
          "--strict",
          "--deep",
          "-R",
          manifest.signing.hostRequirement,
          app,
        ],
        state.snapshot,
        state.environment,
      );
      const probe = join(directory, "functional-signature-probe");
      execute(
        "xcrun",
        [
          "swiftc",
          "-parse-as-library",
          "-num-threads",
          "1",
          join(state.snapshot, producerRoot, "FunctionalSignatureProbe.swift"),
          "-o",
          probe,
        ],
        state.snapshot,
        state.environment,
      );
      const result = JSON.parse(
        execute(
          probe,
          [app, plan.hostIdentifier, manifest.signing.hostCertificateSHA256],
          state.snapshot,
          state.environment,
        ),
      );
      assert.deepEqual(result, {
        identifier: plan.hostIdentifier,
        certificateSHA256: manifest.signing.hostCertificateSHA256,
      });
      generatedPins.push(await pinnedFile(probe));
      await verify();
    },
    observeOutput: async () => {
      const executable = await pinnedFile(
        join(buildRoot, "Release/Fixture.app/Contents/MacOS/Edith"),
      );
      const description = execute(
        "file",
        ["-b", executable.path],
        state.snapshot,
        state.environment,
      ).toString("utf8");
      assert(
        description.includes("Mach-O") && description.includes("arm64"),
        "Host build did not produce an arm64 Mach-O executable",
      );
      return executable;
    },
    publish: async (executable) => {
      await staging.create(finalHost);
      await cp(join(buildRoot, "Release/Fixture.app"), finalHost, {
        recursive: true,
        dereference: false,
        verbatimSymlinks: true,
        errorOnExist: true,
        force: false,
      });
      const signature = JSON.parse(
        execute(
          join(directory, "functional-signature-probe"),
          [
            finalHost,
            plan.hostIdentifier,
            manifest.signing.hostCertificateSHA256,
          ],
          state.snapshot,
          state.environment,
        ),
      );
      assert.deepEqual(signature, {
        identifier: plan.hostIdentifier,
        certificateSHA256: manifest.signing.hostCertificateSHA256,
      });
      const host = freeze({
        path: finalHost,
        executableSHA256: executable.sha256,
        certificateSHA256: manifest.signing.hostCertificateSHA256,
        requirement: manifest.signing.hostRequirement,
      });
      const hostPin = await pinnedFile(join(finalHost, "Contents/MacOS/Edith"));
      assert.equal(hostPin.sha256, executable.sha256);
      const artifact = {
        schema: 2,
        sourceCommit: plan.sourceCommit,
        session: plan.session,
        root: plan.root,
        hostIdentifier: plan.hostIdentifier,
        issuerPublicKey: manifest.issuerPublicKey,
        issuerManifestSHA256: admittedIssuer.manifestSHA256,
        host,
        producer: {
          path: manifest.producer.path,
          executableSHA256: manifest.producer.executableSHA256,
        },
        workerCertificateSHA256: manifest.signing.workerCertificateSHA256,
        roleCertificateSHA256: manifest.signing.roleCertificateSHA256,
      };
      const artifactText = functionalCanonicalJSON(artifact);
      const receipt = freeze({
        sourceCommit: state.sourceCommit,
        runID: admittedIssuer.runID,
        jobID: admittedIssuer.jobID,
        source: compilation.source,
        toolchain: compilation.toolchain,
        bootstrapSHA256: bootstrap.sourceSHA256,
        host,
        hostSpecification: {
          executable: join(finalHost, "Contents/MacOS/Edith"),
          executableSHA256: host.executableSHA256,
          identifier: plan.hostIdentifier,
          certificateSHA256: host.certificateSHA256,
          requirement: host.requirement,
        },
        get artifactBytes() {
          return Buffer.from(artifactText);
        },
        dependencyArtifacts: artifacts,
        dependencySources,
        projectSHA256: digest(projectBytes),
        hostBuildSHA256: digest(hostBuild),
        sourceReady: false,
        nativeProof: false,
      });
      await writeFile(
        join(directory, "compilation-receipt.json"),
        functionalCanonicalJSON({
          ...receipt,
          source: { sha256: receipt.source.sha256 },
          toolchain: { sha256: receipt.toolchain.sha256 },
          artifactBytes: artifactText,
          artifactSHA256: digest(artifactText),
        }),
        { flag: "wx", mode: 0o600 },
      );
      hostBuilds.set(receipt, {
        compilation,
        hostPin,
        generatedPins,
        artifacts,
        dependencySources,
        plan,
        state,
      });
      state.hostStatus = "built";
      return receipt;
    },
    abort: async () => {
      state.hostStatus = "failed";
      state.status = "failed";
      await staging.abort();
    },
  });
}

export function observeFunctionalCompilationHost({
  compilation,
  receipt,
  ownedHost,
}) {
  const state = compilations.get(compilation);
  const build = hostBuilds.get(receipt);
  assert(
    state &&
      build &&
      build.compilation === compilation &&
      state.status === "ready" &&
      state.hostStatus === "built",
    "Expected owned source-built Host receipt",
  );
  const observe = () => {
    assert.equal(state.status, "ready", "Compilation lifetime ended");
    const root = lstatSync(state.root);
    assert(
      root.isDirectory() &&
        !root.isSymbolicLink() &&
        root.dev === state.rootIdentity.dev &&
        root.ino === state.rootIdentity.ino &&
        (root.mode & 0o7777) === 0o700,
    );
    assert.equal(realpathSync(build.hostPin.path), build.hostPin.path);
    assert.equal(
      digest(readFileSync(build.hostPin.path)),
      build.hostPin.sha256,
      "Compiled Host changed",
    );
    for (const pin of [
      ...build.generatedPins,
      state.helperPin,
      state.signatureProbePin,
      ...state.cataloguePins,
      toolchains.get(state.toolchain).compiler,
      ...toolchains.get(state.toolchain).compilerInputs,
      ...toolchains.get(state.toolchain).buildTools,
      ...toolchains.get(state.toolchain).sdkFiles,
    ]) {
      assert.equal(realpathSync(pin.path), pin.path);
      assert.equal(
        digest(readFileSync(pin.path)),
        pin.sha256,
        "Compilation identity changed",
      );
    }
    for (const pin of state.sourcePins.files)
      assert.equal(
        digest(readFileSync(join(state.snapshot, pin.path))),
        state.generated.get(pin.path) ?? pin.sha256,
        "Compiled source changed",
      );
    for (const dependency of build.dependencySources)
      for (const file of dependency.files) {
        assert.equal(realpathSync(file.path), file.path);
        assert.equal(
          digest(readFileSync(file.path)),
          file.sha256,
          "Locked dependency bytes changed",
        );
      }
    for (const artifact of build.artifacts)
      assert.equal(
        digest(readFileSync(artifact.path)),
        artifact.sha256,
        "Compiled dependency changed",
      );
    observeHelperSignature(state);
    observeFunctionalDocsDependency({
      compilation,
      plan: build.plan,
      dependency: state.docsDependency,
    });
    const birth = state.observer.requireCurrentSync(ownedHost);
    assert.equal(birth.executable, build.hostPin.path);
    assert.equal(birth.executableSHA256, receipt.host.executableSHA256);
    const hostProcess = {
      ...birth,
      certificateSHA256: receipt.host.certificateSHA256,
      requirement: receipt.host.requirement,
    };
    return freeze({
      sourceCommit: receipt.sourceCommit,
      runID: receipt.runID,
      jobID: receipt.jobID,
      sourceSHA256: receipt.source.sha256,
      toolchainSHA256: receipt.toolchain.sha256,
      bootstrapSHA256: receipt.bootstrapSHA256,
      host: receipt.host,
      hostProcess,
    });
  };
  observe();
  return observe;
}

export async function closeFunctionalCompilation(compilation) {
  const state = compilations.get(compilation);
  assert(
    state && state.status !== "closed",
    "Expected owned functional compilation",
  );
  if (state.docsDependency)
    await verifyDocsDependency(docsDependencies.get(state.docsDependency), {
      closing: true,
    });
  await requirePin(state.helperPin);
  await requirePin(state.signatureProbePin);
  observeHelperSignature(state);
  await requirePin(state.helperPin);
  await requirePin(state.signatureProbePin);
  await state.observer.close();
  if (state.docsDependency)
    await verifyDocsDependency(docsDependencies.get(state.docsDependency), {
      closing: true,
    });
  state.status = "closed";
}

export async function bindFunctionalCompilationHost({
  compilation,
  receipt,
  ownedHost,
}) {
  await functionalCompilationForBuilder(compilation);
  const state = compilations.get(compilation);
  const build = hostBuilds.get(receipt);
  assert(
    build && build.compilation === compilation,
    "Expected source-built Host receipt",
  );
  assert(
    Number.isSafeInteger(ownedHost?.child?.pid) && ownedHost.child.pid > 1,
  );
  await requirePin(build.hostPin);
  const spec = receipt.hostSpecification;
  const observation = execute(
    state.helperPin.path,
    [
      String(ownedHost.child.pid),
      spec.executable,
      spec.executableSHA256,
      spec.identifier,
      spec.certificateSHA256,
      spec.requirement,
      "5000",
    ],
    state.observerDirectory,
    { PATH: "/usr/bin:/bin", LANG: "C" },
  );
  const { validateFunctionalProcessObservation } = await import(
    "./owned-process.mjs"
  );
  const birth = validateFunctionalProcessObservation(observation).birth;
  await requirePin(state.helperPin);
  await requirePin(build.hostPin);
  return state.observer.bind(ownedHost, birth);
}

export function validateFunctionalDependencyRevision(pin, observed) {
  exact(pin, ["identity", "location", "revision"]);
  exact(observed, ["identity", "location", "revision", "status"]);
  assert.match(pin.revision, commitPattern);
  assert(
    typeof pin.identity === "string" && /^[a-z0-9.-]+$/.test(pin.identity),
  );
  assert(
    typeof pin.location === "string" &&
      /^https:\/\/github\.com\/[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+(?:\.git)?$/.test(
        pin.location,
      ),
  );
  assert.equal(observed.identity, pin.identity);
  assert.equal(
    observed.location.replace(/\.git$/, ""),
    pin.location.replace(/\.git$/, ""),
  );
  assert.equal(
    observed.revision,
    pin.revision,
    "Locked dependency revision changed",
  );
  assert.equal(observed.status, "", "Locked dependency source changed");
  return freeze({ ...pin });
}

async function captureDependencySources(
  root,
  state,
  packagePath = "Packages/EdithHost",
) {
  const lock = JSON.parse(
    await readFile(
      join(state.snapshot, packagePath, "Package.resolved"),
      "utf8",
    ),
  );
  assert.equal(lock.version, 3);
  assert(Array.isArray(lock.pins) && lock.pins.length > 0);
  const entries = await readdir(join(root, "checkouts"));
  const dependencies = [];
  for (const locked of lock.pins) {
    assert.equal(locked.kind, "remoteSourceControl");
    const directoryName = entries.find(
      (name) => name.toLowerCase().replace(/\.git$/, "") === locked.identity,
    );
    assert(directoryName, `Missing locked dependency: ${locked.identity}`);
    const directory = await realpath(join(root, "checkouts", directoryName));
    assert(directory.startsWith(`${root}/checkouts/`));
    const git = (args) =>
      execute("git", args, directory, state.environment)
        .toString("utf8")
        .trim();
    const pin = validateFunctionalDependencyRevision(
      {
        identity: locked.identity,
        location: locked.location,
        revision: locked.state.revision,
      },
      {
        identity: directoryName.toLowerCase().replace(/\.git$/, ""),
        location: git(["remote", "get-url", "origin"]),
        revision: git(["rev-parse", "HEAD"]),
        status: git(["status", "--porcelain", "--untracked-files=all"]),
      },
    );
    const files = execute(
      "git",
      ["ls-files", "-z"],
      directory,
      state.environment,
    )
      .toString("utf8")
      .split("\0")
      .filter(Boolean);
    assert(files.length > 0);
    const sourcePins = [];
    for (const file of files) {
      assert(!file.split("/").some((part) => ["", ".", ".."].includes(part)));
      const path = await realpath(join(directory, file));
      assert(path.startsWith(`${directory}/`));
      sourcePins.push({ path, sha256: digest(await readFile(path)) });
    }
    dependencies.push(freeze({ ...pin, directory, files: sourcePins }));
  }
  assert.equal(
    entries.length,
    dependencies.length,
    "Unexpected dependency checkout",
  );
  return freeze(dependencies);
}

async function verifyDependencySources(dependencies, state) {
  for (const dependency of dependencies) {
    const git = (args) =>
      execute("git", args, dependency.directory, state.environment)
        .toString("utf8")
        .trim();
    validateFunctionalDependencyRevision(
      {
        identity: dependency.identity,
        location: dependency.location,
        revision: dependency.revision,
      },
      {
        identity: dependency.identity,
        location: git(["remote", "get-url", "origin"]),
        revision: git(["rev-parse", "HEAD"]),
        status: git(["status", "--porcelain", "--untracked-files=all"]),
      },
    );
    for (const file of dependency.files) {
      assert.equal(await realpath(file.path), file.path);
      assert.equal(
        digest(await readFile(file.path)),
        file.sha256,
        "Locked dependency bytes changed",
      );
    }
  }
}

const docsDependencies = new WeakMap();
const docsPackage = "Packages/EdithDocsWorker";
const docsIdentifier = "com.pulkit.edith.tests.functional-docs-worker";
const docsLockedSources = freeze([
  {
    identity: "swift-cmark",
    location: "https://github.com/swiftlang/swift-cmark.git",
    revision: "08ddb528923cc1a6527e02b7a1aee9e516ca749a",
    version: "0.9.0",
  },
  {
    identity: "swift-markdown",
    location: "https://github.com/swiftlang/swift-markdown.git",
    revision: "25cb61d3482054b09ae76ca4f281b1bfe7fe5a43",
    version: "0.9.0",
  },
]);

export function validateFunctionalDocsDependencyLock(bytes, manifestSHA256) {
  assert(Buffer.isBuffer(bytes));
  assert.match(manifestSHA256, hashPattern);
  const lock = JSON.parse(bytes.toString("utf8"));
  exact(lock, ["originHash", "pins", "version"]);
  assert.equal(lock.version, 3);
  assert.equal(lock.originHash, manifestSHA256);
  assert.equal(lock.pins.length, docsLockedSources.length);
  const seen = new Set();
  for (const pin of lock.pins) {
    exact(pin, ["identity", "kind", "location", "state"]);
    exact(pin.state, ["revision", "version"]);
    assert.equal(pin.kind, "remoteSourceControl");
    assert(!seen.has(pin.identity));
    seen.add(pin.identity);
    const expected = docsLockedSources.find(
      ({ identity }) => identity === pin.identity,
    );
    assert(expected, "Unexpected Docs dependency");
    assert.deepEqual(
      { identity: pin.identity, location: pin.location, ...pin.state },
      expected,
      "Docs dependency lock changed",
    );
  }
  return docsLockedSources;
}

export function functionalDocsCompilerInputs({ root, products, artifacts }) {
  assert.equal(resolve(root), root);
  assert.equal(resolve(products), products);
  assert(products.startsWith(`${root}/`));
  assert(Array.isArray(artifacts) && artifacts.length > 0);
  const seen = new Set();
  for (const artifact of artifacts) {
    exact(artifact, ["path", "kind", "sha256"]);
    assert.equal(resolve(artifact.path), artifact.path);
    assert(artifact.path.startsWith(`${root}/`));
    assert.match(artifact.sha256, hashPattern);
    assert(!seen.has(artifact.path));
    seen.add(artifact.path);
    assert(
      ["object", "module", "modulemap", "resource", "library"].includes(
        artifact.kind,
      ),
    );
  }
  const libraryPath = join(products, "libEdithDocsWorker.dylib");
  assert(
    artifacts.some(
      ({ path, kind }) => path === libraryPath && kind === "library",
    ),
    "Missing actual Docs dynamic library",
  );
  const moduleSearchPaths = new Set();
  for (const name of ["EdithDocsWorker", "Markdown"]) {
    const module = artifacts.find(
      ({ path, kind }) =>
        kind === "module" &&
        path.startsWith(`${products}/`) &&
        (path.endsWith(`/${name}.swiftmodule`) ||
          path.includes(`/${name}.swiftmodule/`)),
    );
    assert(module, `Missing actual ${name} module`);
    const end = module.path.indexOf(`/${name}.swiftmodule`);
    moduleSearchPaths.add(module.path.slice(0, end));
  }
  const moduleMaps = [
    "checkouts/swift-cmark/src/include/module.modulemap",
    "checkouts/swift-cmark/extensions/include/module.modulemap",
    "checkouts/swift-markdown/Sources/CAtomic/include/module.modulemap",
  ].map((path) => {
    const absolute = join(root, path);
    assert(
      artifacts.some(
        (artifact) =>
          artifact.path === absolute && artifact.kind === "modulemap",
      ),
      `Missing original C module map: ${path}`,
    );
    return absolute;
  });
  for (const name of ["cmark-gfm", "CAtomic", "Markdown", "EdithDocsWorker"])
    assert(
      artifacts.some(
        ({ path, kind }) => kind === "object" && path.includes(name),
      ),
      `Missing original ${name} object`,
    );
  const resourcePath = join(products, "EdithDocsWorker_EdithDocsWorker.bundle");
  assert(
    artifacts.some(
      ({ path, kind }) =>
        kind === "resource" &&
        path.startsWith(`${resourcePath}/`) &&
        path.endsWith("/cli-docs.json"),
    ),
    "Missing original Docs resource bundle",
  );
  const compilerArguments = [
    ...[...moduleSearchPaths].flatMap((path) => ["-I", path]),
    ...moduleMaps.flatMap((path) => [
      "-Xcc",
      `-fmodule-map-file=${path}`,
      "-Xcc",
      `-I${dirname(path)}`,
    ]),
    "-L",
    products,
    "-lEdithDocsWorker",
    "-Xlinker",
    "-rpath",
    "-Xlinker",
    products,
  ];
  return freeze({
    moduleSearchPaths: [...moduleSearchPaths],
    libraryPath,
    runtimeLibraryPaths: [products],
    resourcePaths: [resourcePath],
    compilerArguments,
  });
}

export function validateFunctionalDocsDependencySignature(
  signature,
  certificateSHA256,
) {
  exact(signature, ["identifier", "certificateSHA256"]);
  assert.equal(
    signature.identifier,
    docsIdentifier,
    "Wrong Docs library signer identifier",
  );
  assert(
    typeof certificateSHA256 === "string" &&
      /^[A-Za-z0-9+/]{43}=$/.test(certificateSHA256),
  );
  const certificate = Buffer.from(certificateSHA256, "base64");
  assert.equal(certificate.length, 32);
  assert.equal(certificate.toString("base64"), certificateSHA256);
  assert.equal(
    signature.certificateSHA256,
    certificateSHA256,
    "Wrong Docs library signing certificate",
  );
  return freeze({ ...signature });
}

async function compileDocsProduct({
  certificateSHA256,
  packagePath,
  buildRoot,
  verify,
  run,
  captureSources,
  captureProduct,
  sign,
  observeSignature,
}) {
  const checkedRun = async (args) => {
    await verify();
    const result = await run(
      "xcrun",
      functionalCompilationArguments("xcrun", args),
    );
    await verify();
    return result;
  };
  await checkedRun([
    "swift",
    "package",
    "--package-path",
    packagePath,
    "--scratch-path",
    buildRoot,
    "resolve",
    "--force-resolved-versions",
  ]);
  const dependencies = await captureSources();
  await verify();
  await checkedRun([
    "swift",
    "build",
    "--package-path",
    packagePath,
    "--scratch-path",
    buildRoot,
    "--configuration",
    "release",
    "--jobs",
    "1",
    "--product",
    "EdithDocsWorker",
    "--disable-automatic-resolution",
  ]);
  const output = await checkedRun([
    "swift",
    "build",
    "--package-path",
    packagePath,
    "--scratch-path",
    buildRoot,
    "--configuration",
    "release",
    "--show-bin-path",
    "--disable-automatic-resolution",
  ]);
  assert(Buffer.isBuffer(output));
  const products = output.toString("utf8").trim();
  assert.equal(resolve(products), products);
  assert(products.startsWith(`${buildRoot}/`));
  const product = await captureProduct(products);
  await verify();
  await sign(product);
  await verify();
  const signature = validateFunctionalDocsDependencySignature(
    await observeSignature(product),
    certificateSHA256,
  );
  await verify();
  return { product, dependencies, signature };
}

export async function probeFunctionalDocsDependency({
  certificateSHA256,
  sourcePins,
  packagePath,
  buildRoot,
  runtime,
}) {
  sourcePins = validateFunctionalCompilationSourcePins(sourcePins);
  exact(runtime, [
    "readSource",
    "observeCompiler",
    "requireLifetime",
    "stage",
    "run",
    "captureSources",
    "captureProduct",
    "sign",
    "observeSignature",
    "publish",
    "abort",
  ]);
  for (const method of Object.values(runtime))
    assert.equal(typeof method, "function");
  const compiler = await runtime.observeCompiler();
  assert.match(compiler, hashPattern);
  const verify = async () => {
    await runtime.requireLifetime();
    assert.equal(
      await runtime.observeCompiler(),
      compiler,
      "Docs compilation toolchain changed",
    );
    for (const pin of sourcePins.files)
      assert.equal(
        digest(await runtime.readSource(pin.path)),
        pin.sha256,
        "Docs source changed",
      );
  };
  let result;
  return stagedBuild({
    verify,
    stage: runtime.stage,
    compile: async () => {
      result = await compileDocsProduct({
        certificateSHA256,
        packagePath,
        buildRoot,
        verify,
        ...runtime,
      });
    },
    observeOutput: async () => result,
    publish: async (output) => {
      await runtime.publish(output);
      await verify();
      return freeze({
        commandsCompleted: 3,
        sourceReady: false,
        nativeProof: false,
        qualifiedEvidence: false,
        scope: "injected Docs command control probe",
      });
    },
    abort: runtime.abort,
  });
}

async function requireDocsPlan(compilation, plan) {
  await functionalCompilationForBuilder(compilation);
  const project = await import("./producer-project.mjs");
  project.functionalProducerPlanForBuild(plan);
  const state = compilations.get(compilation);
  assert.equal(plan.sourceCommit, state.sourceCommit);
  assert.equal(plan.root, state.root);
  assert.deepEqual(plan.sourcePins, state.sourcePins);
  assert.equal(plan.sourceSHA256, compilation.source.sha256);
  assert.equal(plan.toolchainSHA256, compilation.toolchain.sha256);
  assert.deepEqual(plan.toolchain.bytes, compilation.toolchain.bytes);
  assert.equal(plan.certificateSHA256, state.signingCertificate);
  const controller = await import("./controller.mjs");
  assert.deepEqual(
    plan.hostedRunPins,
    controller.functionalActiveJobBuildPins(state.activeJob),
  );
  return state;
}

function observeDocsSignature(state, libraryPath) {
  const signature = JSON.parse(
    execute(
      state.signatureProbePin.path,
      [libraryPath, docsIdentifier, state.signingCertificate],
      state.snapshot,
      state.environment,
    ).toString("utf8"),
  );
  return validateFunctionalDocsDependencySignature(
    signature,
    state.signingCertificate,
  );
}

async function verifyDocsDependency(build, { closing = false } = {}) {
  const { state } = build;
  assert(
    state.status === "ready" || (closing && state.status === "failed"),
    "Docs compilation lifetime ended",
  );
  assert.deepEqual(await requireDirectory(build.root), build.rootIdentity);
  await verifyDependencySources(build.dependencySources, state);
  for (const pin of build.pins) await requirePin(pin);
  assert.deepEqual(
    observeDocsSignature(state, build.projection.libraryPath),
    build.projection.signature,
  );
  for (const pin of build.pins) await requirePin(pin);
}

export async function prepareFunctionalDocsDependency({ compilation, plan }) {
  const state = await requireDocsPlan(compilation, plan);
  assert.equal(
    state.docsStatus,
    "unbuilt",
    "Docs dependency is compiled once per owned session",
  );
  const manifest = await readFile(
    join(state.snapshot, docsPackage, "Package.swift"),
  );
  validateFunctionalDocsDependencyLock(
    await readFile(join(state.snapshot, docsPackage, "Package.resolved")),
    digest(manifest),
  );
  const root = join(state.root, "DocsDependencies");
  const staging = ownedDirectories();
  let dependencies;
  let artifacts;
  let pins;
  let libraryPin;
  let rootIdentity;
  const verify = async () => {
    await state.verify();
    if (rootIdentity)
      assert.deepEqual(await requireDirectory(root), rootIdentity);
    if (dependencies) await verifyDependencySources(dependencies, state);
    if (pins) for (const pin of pins) await requirePin(pin);
    if (libraryPin) await requirePin(libraryPin);
  };
  state.docsStatus = "building";
  let result;
  return stagedBuild({
    verify,
    stage: async () => {
      await staging.create(root);
      rootIdentity = await requireDirectory(root);
    },
    compile: async () => {
      result = await compileDocsProduct({
        certificateSHA256: state.signingCertificate,
        packagePath: join(state.snapshot, docsPackage),
        buildRoot: root,
        verify,
        run: (file, args) =>
          execFileSync(file, args, {
            cwd: state.snapshot,
            env: state.environment,
            stdio: ["pipe", "pipe", "pipe"],
            timeout: 600000,
            maxBuffer: 268435456,
          }),
        captureSources: async () => {
          dependencies = await captureDependencySources(
            root,
            state,
            docsPackage,
          );
          return dependencies;
        },
        captureProduct: async (products) => {
          assert.equal(await realpath(products), products);
          artifacts = await artifactsUnder(root);
          const inputs = functionalDocsCompilerInputs({
            root,
            products,
            artifacts,
          });
          libraryPin = await pinnedFile(inputs.libraryPath);
          const description = execute(
            "file",
            ["-b", inputs.libraryPath],
            state.snapshot,
            state.environment,
          ).toString("utf8");
          assert(
            description.includes("Mach-O") &&
              description.includes("arm64") &&
              description.includes("dynamically linked shared library"),
            "Docs build did not produce an arm64 Mach-O dynamic library",
          );
          pins = [];
          for (const artifact of artifacts.filter(
            ({ path }) => path !== inputs.libraryPath,
          ))
            pins.push(await pinnedFile(artifact.path));
          const resource = artifacts.find(
            ({ kind, path }) =>
              kind === "resource" &&
              path.startsWith(`${inputs.resourcePaths[0]}/`) &&
              path.endsWith("/cli-docs.json"),
          );
          const original = state.sourcePins.files.find(
            ({ path }) =>
              path ===
              `${docsPackage}/Sources/EdithDocsWorker/Resources/cli-docs.json`,
          );
          assert(original);
          assert.equal(
            resource.sha256,
            original.sha256,
            "Docs compiled resource changed",
          );
          return inputs;
        },
        sign: async (inputs) => {
          await requirePin(libraryPin);
          execute(
            "codesign",
            [
              "--force",
              "--sign",
              state.environment.EXTENSION_SIGN_IDENTITY,
              "--identifier",
              docsIdentifier,
              "--options",
              "runtime",
              "--timestamp",
              inputs.libraryPath,
            ],
            state.snapshot,
            state.environment,
          );
          libraryPin = await pinnedFile(inputs.libraryPath);
          const library = artifacts.find(
            ({ path }) => path === inputs.libraryPath,
          );
          artifacts = artifacts.map((artifact) =>
            artifact === library
              ? freeze({ ...artifact, sha256: libraryPin.sha256 })
              : artifact,
          );
        },
        observeSignature: (inputs) =>
          observeDocsSignature(state, inputs.libraryPath),
      });
    },
    observeOutput: async () => {
      await requirePin(libraryPin);
      return result;
    },
    publish: async ({ product, signature }) => {
      const projection = freeze({
        ...product,
        signature,
        sourceCommit: state.sourceCommit,
        sourceSHA256: compilation.source.sha256,
        toolchainSHA256: compilation.toolchain.sha256,
        dependencyArtifacts: artifacts,
        dependencySources: dependencies,
      });
      const capability = freeze({
        sourceCommit: state.sourceCommit,
        sourceSHA256: compilation.source.sha256,
        toolchainSHA256: compilation.toolchain.sha256,
        sourceReady: false,
        nativeProof: false,
        qualifiedEvidence: false,
      });
      const build = {
        compilation,
        plan,
        state,
        root,
        rootIdentity,
        projection,
        dependencySources: dependencies,
        pins: [...pins, libraryPin],
      };
      await verifyDocsDependency(build);
      await verify();
      docsDependencies.set(capability, build);
      state.docsDependency = capability;
      state.docsStatus = "built";
      return capability;
    },
    abort: async () => {
      state.docsStatus = "failed";
      state.status = "failed";
      await staging.abort();
    },
  });
}

export async function functionalDocsDependencyForBuilder({
  compilation,
  plan,
  dependency,
}) {
  const build = docsDependencies.get(dependency);
  assert(
    build && build.compilation === compilation && build.plan === plan,
    "Expected owned Docs dependency capability",
  );
  const state = await requireDocsPlan(compilation, plan);
  assert(
    state.docsDependency === dependency && state.docsStatus === "built",
    "Docs dependency lifetime ended",
  );
  await verifyDocsDependency(build);
  await state.verify();
  return build.projection;
}

function requireSyncPin(pin) {
  assert.equal(realpathSync(pin.path), pin.path);
  const before = lstatSync(pin.path, { bigint: true });
  const identity = [
    before.dev,
    before.ino,
    before.size,
    before.mode,
    before.uid,
    before.nlink,
    before.mtimeNs,
    before.ctimeNs,
  ].map(String);
  assert(before.isFile() && !before.isSymbolicLink());
  assert.deepEqual(
    identity,
    pin.identity,
    "Docs compilation input identity changed",
  );
  assert.equal(
    digest(readFileSync(pin.path)),
    pin.sha256,
    "Docs compilation bytes changed",
  );
  const after = lstatSync(pin.path, { bigint: true });
  assert.deepEqual(
    [
      after.dev,
      after.ino,
      after.size,
      after.mode,
      after.uid,
      after.nlink,
      after.mtimeNs,
      after.ctimeNs,
    ].map(String),
    identity,
  );
}

export function observeFunctionalDocsDependency({
  compilation,
  plan,
  dependency,
}) {
  const build = docsDependencies.get(dependency);
  const state = compilations.get(compilation);
  assert(
    build &&
      state &&
      build.compilation === compilation &&
      build.plan === plan &&
      state.status === "ready" &&
      state.docsStatus === "built" &&
      state.docsDependency === dependency,
    "Expected owned live Docs dependency capability",
  );
  for (const [path, identity] of [
    [state.root, state.rootIdentity],
    [build.root, build.rootIdentity],
  ]) {
    const directory = lstatSync(path);
    assert(
      directory.isDirectory() &&
        !directory.isSymbolicLink() &&
        directory.uid === process.getuid() &&
        (directory.mode & 0o7777) === 0o700,
    );
    assert.equal(realpathSync(path), path);
    assert.equal(directory.dev, identity.dev);
    assert.equal(directory.ino, identity.ino);
  }
  const toolchain = toolchains.get(state.toolchain);
  for (const pin of [
    ...build.pins,
    state.helperPin,
    state.signatureProbePin,
    toolchain.compiler,
    ...toolchain.compilerInputs,
    ...toolchain.buildTools,
    ...toolchain.sdkFiles,
  ])
    requireSyncPin(pin);
  for (const pin of state.sourcePins.files)
    assert.equal(
      digest(readFileSync(join(state.snapshot, pin.path))),
      state.generated.get(pin.path) ?? pin.sha256,
      "Docs original source changed",
    );
  for (const dependencySource of build.dependencySources) {
    const git = (args) =>
      execute("git", args, dependencySource.directory, state.environment)
        .toString("utf8")
        .trim();
    validateFunctionalDependencyRevision(
      {
        identity: dependencySource.identity,
        location: dependencySource.location,
        revision: dependencySource.revision,
      },
      {
        identity: dependencySource.identity,
        location: git(["remote", "get-url", "origin"]),
        revision: git(["rev-parse", "HEAD"]),
        status: git(["status", "--porcelain", "--untracked-files=all"]),
      },
    );
    for (const file of dependencySource.files) {
      assert.equal(realpathSync(file.path), file.path);
      assert.equal(
        digest(readFileSync(file.path)),
        file.sha256,
        "Docs locked dependency changed",
      );
    }
  }
  assert.deepEqual(
    observeDocsSignature(state, build.projection.libraryPath),
    build.projection.signature,
  );
  for (const pin of build.pins) requireSyncPin(pin);
  return build.projection;
}

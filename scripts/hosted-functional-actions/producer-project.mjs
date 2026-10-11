import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import {
  chmod,
  lstat,
  mkdir,
  readFile,
  realpath,
  writeFile,
} from "node:fs/promises";
import { join, resolve } from "node:path";
import {
  functionalCanonicalJSON,
  functionalDigest,
  validateFunctionalCaseDefinition,
} from "./contract.mjs";
import { functionalActionOwners } from "./owners.mjs";

export const functionalProducerSources = Object.freeze(
  [
    "FunctionalIssuer.swift",
    "FunctionalLifecycle.swift",
    "FunctionalPersistence.swift",
    "FunctionalOriginalUI.swift",
    "FunctionalProducer.swift",
  ].map((name) => `Tests/HostedFunctionalActions/ProducerSources/${name}`),
);

const sha = (bytes) => createHash("sha256").update(bytes).digest("hex");
const uuid =
  /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;
const certificate = /^[A-Za-z0-9+/]{43}=$/;

export function admitFunctionalRunner(environment, sourceCommit) {
  assert.match(sourceCommit, /^[0-9a-f]{40}$/);
  for (const [key, value] of Object.entries({
    GITHUB_ACTIONS: "true",
    RUNNER_ENVIRONMENT: "github-hosted",
    RUNNER_OS: "macOS",
    GITHUB_REPOSITORY: "pulkitxm/edith",
    GITHUB_EVENT_NAME: "workflow_dispatch",
    EDITH_HOSTED_FUNCTIONAL_ACTIONS: "1",
    GITHUB_SHA: sourceCommit,
    EXPECTED_SOURCE_SHA: sourceCommit,
    EXTENSION_SWIFT_JOBS: "1",
  }))
    assert.equal(environment[key], value, `Unadmitted runner ${key}`);
  assert(["65671483", "320458784"].includes(environment.GITHUB_ACTOR_ID));
  assert(
    ["refs/heads/main", "refs/heads/feat/extension-marketplace"].includes(
      environment.GITHUB_REF,
    ),
  );
  assert(
    environment.EXTENSION_SIGN_IDENTITY &&
      environment.EXTENSION_SIGN_IDENTITY !== "-",
  );
  assert.match(
    environment.DEVELOPER_DIR,
    /^\/Applications\/Xcode[^/]*\.app\/Contents\/Developer$/,
  );
  assert.equal(resolve(environment.RUNNER_TEMP), environment.RUNNER_TEMP);
}

export function functionalProducerPlan({
  sourceCommit,
  session,
  root,
  certificateSHA256,
  sourcePins,
  cases,
  manifest,
  environment,
}) {
  admitFunctionalRunner(environment, sourceCommit);
  assert.match(session, uuid);
  assert.equal(
    root,
    join(environment.RUNNER_TEMP, `functional-fixture-${session}`),
  );
  assert.match(certificateSHA256, certificate);
  assert.equal(Buffer.from(certificateSHA256, "base64").length, 32);
  assert.equal(
    Buffer.from(certificateSHA256, "base64").toString("base64"),
    certificateSHA256,
  );
  assert.deepEqual(Object.keys(sourcePins).sort(), ["files", "sourceCommit"]);
  assert.equal(sourcePins.sourceCommit, sourceCommit);
  const seen = new Set();
  for (const pin of sourcePins.files) {
    assert.deepEqual(Object.keys(pin).sort(), ["path", "sha256"]);
    assert.match(pin.sha256, /^[0-9a-f]{64}$/);
    assert(
      typeof pin.path === "string" &&
        !pin.path.startsWith("/") &&
        !pin.path.includes("\\"),
    );
    assert(
      !pin.path
        .split("/")
        .some((part) =>
          ["", ".", "..", ".git", ".build", "node_modules"].includes(part),
        ),
    );
    assert(!seen.has(pin.path));
    seen.add(pin.path);
  }
  for (const path of [
    ...functionalProducerSources,
    "Tests/HostedFunctionalActions/ProducerSources/FunctionalSignatureProbe.swift",
    "scripts/hosted-functional-actions/producer-project.mjs",
    "scripts/hosted-functional-actions/controller.mjs",
    "Extensions/manifest.json",
    "Tests/HostedFunctionalActions/Sources/FunctionalActionContract/HostedFunctionalActionContext.swift",
    "Extensions/fixtureSupport/WorkerFixtureJSON.swift",
  ])
    assert(seen.has(path), `Missing source pin ${path}`);
  assert.deepEqual(
    cases.map(({ definition }) => definition.owner).sort(),
    [...functionalActionOwners].sort(),
  );
  assert.deepEqual(
    manifest.map(({ id }) => id).sort(),
    [...functionalActionOwners].sort(),
  );
  for (const item of cases) {
    validateFunctionalCaseDefinition(item.definition);
    assert.equal(item.sourceCommit, sourceCommit);
  }
  const definitions = cases.map(({ definition }) =>
    structuredClone(definition),
  );
  const roles = Object.fromEntries(
    manifest.map(({ id, roles }) => {
      assert(roles && Object.keys(roles).length > 0);
      assert(
        Object.keys(roles).every((role) =>
          ["helper", "agent", "app"].includes(role),
        ),
      );
      return [id, Object.keys(roles)];
    }),
  );
  return Object.freeze({
    sourceCommit,
    session,
    root,
    certificateSHA256,
    definitions,
    roles,
    hostIdentifier: `com.pulkit.edith.tests.worker-${session}`,
    producerIdentifier: `com.pulkit.edith.tests.functional-producer-${session}`,
    executable: join(root, "Producer/functional-producer"),
    sources: functionalProducerSources,
    sourcePins: structuredClone(sourcePins),
  });
}

export function functionalProducerBootstrapSource(plan) {
  const quoted = (value) => {
    assert(typeof value === "string" && /^[ -~]+$/.test(value));
    return JSON.stringify(value);
  };
  const dictionary = (pairs) =>
    `[${pairs.map(([key, value]) => `${quoted(key)}: ${value}`).join(", ")}]`;
  const digests = dictionary(
    plan.definitions.map((definition) => [
      definition.owner,
      quoted(functionalDigest(definition)),
    ]),
  );
  const operations = dictionary(
    plan.definitions.map((definition) => [
      definition.owner,
      `[${definition.operations.map(quoted).join(", ")}]`,
    ]),
  );
  const activation = dictionary(
    plan.definitions.map((definition) => [
      definition.owner,
      quoted(definition.activation.operation),
    ]),
  );
  const roles = dictionary(
    Object.entries(plan.roles).map(([owner, roles]) => [
      owner,
      `[${roles.map(quoted).join(", ")}]`,
    ]),
  );
  return `import Foundation

enum FunctionalProducerBuild {
    static let sourceCommit = ${quoted(plan.sourceCommit)}
    static let session = ${quoted(plan.session)}
    static let root = ${quoted(plan.root)}
    static let hostIdentifier = ${quoted(plan.hostIdentifier)}
    static let producerIdentifier = ${quoted(plan.producerIdentifier)}
    static let certificateSHA256 = Data(base64Encoded: ${quoted(plan.certificateSHA256)})!
    static let caseDigests: [String: String] = ${digests}
    static let operations: [String: [String]] = ${operations}
    static let activationOperations: [String: String] = ${activation}
    static let roles: [String: [String]] = ${roles}
}
`;
}

export async function requireFunctionalPrivateDirectory(path) {
  assert.equal(await realpath(path), path);
  const state = await lstat(path);
  assert(state.isDirectory() && !state.isSymbolicLink());
  assert.equal(state.uid, process.getuid());
  assert.equal(state.mode & 0o7777, 0o700);
}

export async function verifyFunctionalSourcePins(repository, sourcePins) {
  for (const pin of sourcePins.files)
    assert.equal(
      sha(await readFile(join(repository, pin.path))),
      pin.sha256,
      `Changed source ${pin.path}`,
    );
}

export async function buildFunctionalProducer({
  repository,
  plan,
  environment = process.env,
}) {
  environment = Object.freeze({ ...environment });
  admitFunctionalRunner(environment, plan.sourceCommit);
  assert.equal(process.platform, "darwin");
  assert.equal(process.arch, "arm64");
  assert.equal(await realpath(repository), repository);
  await requireFunctionalPrivateDirectory(plan.root);
  const run = (file, args) =>
    execFileSync(file, args, {
      cwd: repository,
      env: environment,
      timeout: 600_000,
      maxBuffer: 16_777_216,
      stdio: ["ignore", "pipe", "pipe"],
    });
  assert.equal(
    run("git", ["rev-parse", "HEAD"]).toString().trim(),
    plan.sourceCommit,
  );
  assert.equal(
    run("git", ["status", "--porcelain", "--untracked-files=no"]).length,
    0,
  );
  await verifyFunctionalSourcePins(repository, plan.sourcePins);
  const directory = join(plan.root, "Producer");
  await mkdir(directory, { mode: 0o700 });
  await requireFunctionalPrivateDirectory(directory);
  const bootstrap = join(directory, "FunctionalProducerBuild.swift");
  const bootstrapBytes = Buffer.from(functionalProducerBootstrapSource(plan));
  await writeFile(bootstrap, bootstrapBytes, { mode: 0o600, flag: "wx" });
  const contextPath =
    "Tests/HostedFunctionalActions/Sources/FunctionalActionContract/HostedFunctionalActionContext.swift";
  const context = await readFile(join(repository, contextPath), "utf8");
  assert.equal(context.split("import WorkerFixtureSupport\n").length, 2);
  const copiedContext = join(directory, "HostedFunctionalActionContext.swift");
  await writeFile(
    copiedContext,
    context.replace("import WorkerFixtureSupport\n", ""),
    { mode: 0o600, flag: "wx" },
  );
  const jsonSource = join(
    repository,
    "Extensions/fixtureSupport/WorkerFixtureJSON.swift",
  );
  run("xcrun", [
    "swiftc",
    "-parse-as-library",
    "-swift-version",
    "6",
    "-O",
    "-framework",
    "ApplicationServices",
    "-framework",
    "Security",
    ...plan.sources,
    copiedContext,
    jsonSource,
    bootstrap,
    "-o",
    plan.executable,
  ]);
  run("codesign", [
    "--sign",
    environment.EXTENSION_SIGN_IDENTITY,
    "--identifier",
    plan.producerIdentifier,
    "--options",
    "runtime",
    "--timestamp",
    plan.executable,
  ]);
  run("codesign", ["--verify", "--strict", plan.executable]);
  const probe = join(directory, "functional-signature-probe");
  run("xcrun", [
    "swiftc",
    "-parse-as-library",
    "Tests/HostedFunctionalActions/ProducerSources/FunctionalSignatureProbe.swift",
    "-o",
    probe,
  ]);
  assert.deepEqual(
    JSON.parse(
      run(probe, [
        plan.executable,
        plan.producerIdentifier,
        plan.certificateSHA256,
      ]),
    ),
    {
      identifier: plan.producerIdentifier,
      certificateSHA256: plan.certificateSHA256,
    },
  );
  await verifyFunctionalSourcePins(repository, plan.sourcePins);
  await chmod(plan.executable, 0o500);
  const receipt = Object.freeze({
    schema: 1,
    sourceCommit: plan.sourceCommit,
    session: plan.session,
    sourcePins: plan.sourcePins.files,
    bootstrapSHA256: sha(bootstrapBytes),
    producer: {
      path: plan.executable,
      executableSHA256: sha(await readFile(plan.executable)),
    },
    producerIdentifier: plan.producerIdentifier,
    certificateSHA256: plan.certificateSHA256,
    scope:
      "independently source-built synthetic-development producer; no downloaded UI proof",
  });
  await writeFile(
    join(directory, "build-receipt.json"),
    functionalCanonicalJSON(receipt),
    { mode: 0o600, flag: "wx" },
  );
  return receipt;
}

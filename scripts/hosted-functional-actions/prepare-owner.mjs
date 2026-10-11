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
import { requireRegularTree } from "../build-contained-host-runtime.mjs";
import { functionalCanonicalJSON } from "./contract.mjs";
import { functionalFixtureTrustSource } from "./fixture-trust.mjs";
import { functionalActionOwners } from "./owners.mjs";

const sha = (bytes) => createHash("sha256").update(bytes).digest("hex");
const exact = (value, fields) => {
  assert(value && Object.getPrototypeOf(value) === Object.prototype);
  assert.deepEqual(Object.keys(value).sort(), [...fields].sort());
};

export function functionalPairBuildPlan({
  owner,
  artifactBytes,
  admittedArtifact,
  sourcePins,
  environment,
}) {
  assert(functionalActionOwners.includes(owner));
  const anchor = functionalFixtureTrustSource(artifactBytes, admittedArtifact);
  const artifact = JSON.parse(artifactBytes.toString("utf8"));
  assert.equal(environment.GITHUB_ACTIONS, "true");
  assert.equal(environment.RUNNER_ENVIRONMENT, "github-hosted");
  assert.equal(environment.RUNNER_OS, "macOS");
  assert.equal(environment.GITHUB_REPOSITORY, "pulkitxm/edith");
  assert.equal(environment.GITHUB_EVENT_NAME, "workflow_dispatch");
  assert.equal(environment.EDITH_HOSTED_FUNCTIONAL_ACTIONS, "1");
  assert.equal(environment.GITHUB_SHA, admittedArtifact.sourceCommit);
  assert.equal(environment.EXPECTED_SOURCE_SHA, admittedArtifact.sourceCommit);
  assert(["65671483", "320458784"].includes(environment.GITHUB_ACTOR_ID));
  assert(
    ["refs/heads/feat/extension-marketplace", "refs/heads/main"].includes(
      environment.GITHUB_REF,
    ),
  );
  assert.equal(environment.EXTENSION_SWIFT_JOBS, "1");
  assert(
    environment.EXTENSION_SIGN_IDENTITY &&
      environment.EXTENSION_SIGN_IDENTITY !== "-",
  );
  assert(
    environment.DEVELOPER_DIR?.startsWith("/Applications/Xcode") &&
      environment.DEVELOPER_DIR.endsWith(".app/Contents/Developer"),
  );
  assert.equal(resolve(environment.RUNNER_TEMP), environment.RUNNER_TEMP);
  assert(artifact.root.startsWith(`${environment.RUNNER_TEMP}/`));
  exact(sourcePins, ["sourceCommit", "files"]);
  assert.equal(sourcePins.sourceCommit, admittedArtifact.sourceCommit);
  assert(
    Array.isArray(sourcePins.files) &&
      sourcePins.files.length > 0 &&
      sourcePins.files.length <= 100000,
  );
  const files = new Map();
  for (const entry of sourcePins.files) {
    exact(entry, ["path", "sha256"]);
    assert(
      typeof entry.path === "string" &&
        entry.path.length <= 4096 &&
        !entry.path.startsWith("/") &&
        !entry.path.includes("\\"),
    );
    assert(
      !entry.path
        .split("/")
        .some((part) =>
          ["", ".", "..", ".git", ".build", "node_modules"].includes(part),
        ),
    );
    assert.match(entry.sha256, /^[0-9a-f]{64}$/);
    assert(!files.has(entry.path));
    files.set(entry.path, entry.sha256);
  }
  for (const path of [
    anchor.generatedPath,
    "Extensions/manifest.json",
    "scripts/build-extension-package.mjs",
    "scripts/hosted-managed-views/verify-package.py",
    "scripts/hosted-functional-actions/prepare-owner.mjs",
    "Extensions/fixtureSupport/WorkerFixtureUIAdmission.swift",
    "Extensions/fixtureSupport/WorkerFixtureUIContract.swift",
    "Extensions/fixtureSupport/WorkerFixtureUITrust.swift",
    "Tests/HostedFunctionalActions/ProducerSources/FunctionalSignatureProbe.swift",
  ])
    assert(files.has(path), `Missing independently admitted source: ${path}`);
  const versions = ["1.0.0", "1.1.0"];
  return Object.freeze({
    owner,
    sourceCommit: sourcePins.sourceCommit,
    pairScope: "synthetic-development",
    anchor,
    host: Object.freeze(structuredClone(artifact.host)),
    root: artifact.root,
    hostIdentifier: artifact.hostIdentifier,
    workerCertificateSHA256: artifact.workerCertificateSHA256,
    roleCertificateSHA256: artifact.roleCertificateSHA256,
    steps: Object.freeze(
      versions.map((version) =>
        Object.freeze({
          version,
          sourceRoot: `${artifact.root}/source-${owner}-${version}`,
          output: `${artifact.root}/packages-${owner}-${version}`,
          environment: Object.freeze({
            EXTENSION_VERSION: version,
            EXTENSION_SWIFT_JOBS: "1",
          }),
        }),
      ),
    ),
    sourcePins: Object.freeze(
      sourcePins.files.map((entry) => Object.freeze({ ...entry })),
    ),
  });
}

async function requirePrivateDirectory(path) {
  assert.equal(resolve(path), path);
  assert.equal(await realpath(path), path);
  const state = await lstat(path);
  assert(state.isDirectory() && !state.isSymbolicLink());
  assert.equal(state.uid, process.getuid());
  assert.equal(state.mode & 0o7777, 0o700);
}

async function verifyPins(root, plan, generated = false) {
  for (const pin of plan.sourcePins) {
    const expected =
      generated && pin.path === plan.anchor.generatedPath
        ? sha(Buffer.from(plan.anchor.source))
        : pin.sha256;
    assert.equal(
      sha(await readFile(join(root, pin.path))),
      expected,
      `Source changed: ${pin.path}`,
    );
  }
}

function run(command, args, cwd, environment, input) {
  return execFileSync(command, args, {
    cwd,
    env: environment,
    input,
    stdio: ["pipe", "pipe", "pipe"],
    timeout: 3_600_000,
    maxBuffer: 256 * 1024 * 1024,
  });
}

export async function prepareFunctionalOwnerPair({
  repository,
  owner,
  artifactBytes,
  admittedArtifact,
  sourcePins,
  environment = process.env,
}) {
  environment = Object.freeze({ ...environment });
  const plan = functionalPairBuildPlan({
    owner,
    artifactBytes,
    admittedArtifact,
    sourcePins,
    environment,
  });
  assert.equal(process.platform, "darwin");
  assert.equal(process.arch, "arm64");
  assert.equal(await realpath(repository), repository);
  await requirePrivateDirectory(plan.root);
  const git = (args) =>
    run("git", args, repository, environment).toString("utf8").trim();
  assert.equal(git(["rev-parse", "HEAD"]), plan.sourceCommit);
  assert.equal(git(["status", "--porcelain", "--untracked-files=no"]), "");
  await verifyPins(repository, plan);
  assert.equal(
    sha(await readFile(join(plan.host.path, "Contents/MacOS/Edith"))),
    plan.host.executableSHA256,
  );
  run(
    "codesign",
    [
      "--verify",
      "--strict",
      "--deep",
      "-R",
      plan.host.requirement,
      plan.host.path,
    ],
    repository,
    environment,
  );
  const probe = join(plan.root, `signature-probe-${owner}`);
  run(
    "xcrun",
    [
      "swiftc",
      "-parse-as-library",
      "Tests/HostedFunctionalActions/ProducerSources/FunctionalSignatureProbe.swift",
      "-o",
      probe,
    ],
    repository,
    environment,
  );
  const verifySignature = (path, identifier, certificate) => {
    const result = JSON.parse(
      run(
        probe,
        [path, identifier, certificate],
        repository,
        environment,
      ).toString("utf8"),
    );
    assert.deepEqual(result, { identifier, certificateSHA256: certificate });
  };
  verifySignature(
    plan.host.path,
    plan.hostIdentifier,
    plan.host.certificateSHA256,
  );
  const snapshot = run(
    "git",
    ["archive", "--format=tar", plan.sourceCommit],
    repository,
    environment,
  );
  const packages = [];
  for (const step of plan.steps) {
    await mkdir(step.sourceRoot, { mode: 0o700 });
    await mkdir(step.output, { mode: 0o700 });
    await requirePrivateDirectory(step.sourceRoot);
    await requirePrivateDirectory(step.output);
    run(
      "tar",
      ["-xf", "-", "-C", step.sourceRoot],
      repository,
      environment,
      snapshot,
    );
    await requireRegularTree(step.sourceRoot);
    await verifyPins(step.sourceRoot, plan);
    await writeFile(
      join(step.sourceRoot, plan.anchor.generatedPath),
      plan.anchor.source,
    );
    await verifyPins(step.sourceRoot, plan, true);
    const buildEnvironment = {
      ...environment,
      ...step.environment,
      EXTENSION_OUTPUT: step.output,
      EXTENSION_CONTAINING_HOST_APP: plan.host.path,
    };
    delete buildEnvironment.EXTENSION_RELEASE_TAG;
    delete buildEnvironment.EXTENSION_CATALOG_PRIVATE_KEY;
    run(
      "bun",
      ["install", "--frozen-lockfile"],
      step.sourceRoot,
      buildEnvironment,
    );
    run(
      "bun",
      ["scripts/build-extension-package.mjs", owner],
      step.sourceRoot,
      buildEnvironment,
    );
    await verifyPins(step.sourceRoot, plan, true);
    const metadata = JSON.parse(
      await readFile(join(step.output, `${owner}.json`), "utf8"),
    );
    assert.equal(metadata.id, owner);
    assert.equal(metadata.version, step.version);
    assert.equal(metadata.hostABI, "edith-host-2");
    assert.equal(metadata.architecture, "arm64");
    assert.equal(
      sha(await readFile(join(step.output, `${owner}.zip`))),
      metadata.sha256,
    );
    const definitions = JSON.parse(
      await readFile(join(repository, "Extensions/manifest.json"), "utf8"),
    );
    const definition = definitions.find((entry) => entry.id === owner);
    assert(definition);
    const verification = join(plan.root, `verify-${owner}-${step.version}`);
    await mkdir(verification, { mode: 0o700 });
    await writeFile(
      join(verification, "definition.json"),
      JSON.stringify(definition),
    );
    const artifact = join(plan.root, `native-${owner}-${step.version}.zip`);
    run(
      "python3",
      [
        "-c",
        "import pathlib,sys,zipfile; root=pathlib.Path(sys.argv[1]); files=sorted(p for p in root.rglob('*') if p.is_file()); z=zipfile.ZipFile(sys.argv[2],'x',zipfile.ZIP_DEFLATED); [(z.write(p,p.relative_to(root))) for p in files]; z.close()",
        step.output,
        artifact,
      ],
      repository,
      environment,
    );
    const receipt = JSON.parse(
      run(
        "python3",
        [
          "scripts/hosted-managed-views/verify-package.py",
          artifact,
          verification,
          plan.host.path,
          plan.sourceCommit,
          metadata.sourceFingerprint,
          plan.host.executableSHA256,
        ],
        repository,
        environment,
      ).toString("utf8"),
    );
    assert.equal(receipt.extensionID, owner);
    assert.equal(receipt.zipSHA256, metadata.sha256);
    assert.equal(receipt.sourceCommit, plan.sourceCommit);
    assert.equal(receipt.packageCodeExecuted, false);
    const carrier = join(
      verification,
      "expanded",
      owner,
      "ExtensionCarrier.app",
    );
    const worker = join(carrier, "Contents/Extensions/ExtensionWorker.appex");
    verifySignature(
      worker,
      `${plan.hostIdentifier}.extension.${owner}.worker`,
      plan.workerCertificateSHA256,
    );
    for (const role of Object.keys(receipt.roles))
      verifySignature(
        join(worker, "Contents/Resources/Payload", owner, `${role}.bundle`),
        `com.pulkit.edith.extensions.${owner}.${role}`,
        plan.roleCertificateSHA256,
      );
    await chmod(join(step.output, `${owner}.zip`), 0o400);
    packages.push(
      Object.freeze({
        version: step.version,
        archive: join(step.output, `${owner}.zip`),
        archiveSHA256: metadata.sha256,
        metadata,
        receipt,
      }),
    );
  }
  assert.notEqual(packages[0].archiveSHA256, packages[1].archiveSHA256);
  assert.equal(git(["rev-parse", "HEAD"]), plan.sourceCommit);
  assert.equal(git(["status", "--porcelain", "--untracked-files=no"]), "");
  await verifyPins(repository, plan);
  assert.equal(
    sha(await readFile(join(plan.host.path, "Contents/MacOS/Edith"))),
    plan.host.executableSHA256,
  );
  const result = {
    schema: 1,
    sourceCommit: plan.sourceCommit,
    owner,
    pairScope: plan.pairScope,
    fixtureTrustArtifactSHA256: plan.anchor.artifactSHA256,
    generatedAnchorSHA256: sha(Buffer.from(plan.anchor.source)),
    packages,
    scope:
      "independently source-built signed development package pair; no functional or public release qualification",
  };
  await writeFile(
    join(plan.root, `prepared-${owner}.json`),
    functionalCanonicalJSON(result),
    { flag: "wx", mode: 0o600 },
  );
  return Object.freeze(result);
}

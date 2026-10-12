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
import * as trustCompiler from "./fixture-trust.mjs";
import {
  functionalFixtureRolePolicySource,
  functionalFixtureTrustSource,
} from "./fixture-trust.mjs";
import { functionalActionOwners } from "./owners.mjs";
import { admitFunctionalRunner } from "./producer-project.mjs";

const pairPlans = new WeakSet();

const sha = (bytes) => createHash("sha256").update(bytes).digest("hex");
const exact = (value, fields) => {
  assert(value && Object.getPrototypeOf(value) === Object.prototype);
  assert.deepEqual(Object.keys(value).sort(), [...fields].sort());
};

export function functionalPairBuildPlan({
  owner,
  issuerManifestBytes,
  admittedIssuer,
  artifactBytes,
  admittedArtifact,
  policyBytes,
  admittedPolicies,
  sourcePins,
  environment,
}) {
  assert(functionalActionOwners.includes(owner));
  const policy = functionalFixtureRolePolicySource(
    policyBytes,
    admittedPolicies,
  );
  const anchor = functionalFixtureTrustSource(
    artifactBytes,
    admittedArtifact,
    policyBytes,
    admittedPolicies,
  );
  assert.equal(
    typeof trustCompiler.functionalFixtureBootstrapTrustSource,
    "function",
  );
  const bootstrapAnchor = trustCompiler.functionalFixtureBootstrapTrustSource(
    issuerManifestBytes,
    admittedIssuer,
    policyBytes,
    admittedPolicies,
  );
  assert.equal(bootstrapAnchor.sourceCommit, anchor.sourceCommit);
  const artifact = JSON.parse(artifactBytes.toString("utf8"));
  admitFunctionalRunner(environment, admittedArtifact.sourceCommit);
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
    bootstrapAnchor.generatedPath,
    "Extensions/manifest.json",
    "scripts/build-extension-package.mjs",
    "scripts/hosted-managed-views/verify-package.py",
    "scripts/hosted-functional-actions/verify-role-package.py",
    "scripts/hosted-functional-actions/prepare-owner.mjs",
    "scripts/hosted-functional-actions/fixture-trust.mjs",
    "scripts/hosted-functional-actions/producer-project.mjs",
    "scripts/hosted-functional-actions/functional-build.mjs",
    ".github/workflows/hosted-functional-actions.yml",
    "Extensions/fixtureSupport/WorkerFixtureRolePolicy.swift",
    "Extensions/fixtureSupport/WorkerFixtureUIAdmission.swift",
    "Extensions/fixtureSupport/WorkerFixtureUIContract.swift",
    "Extensions/fixtureSupport/WorkerFixtureUITrust.swift",
    "Tests/HostedFunctionalActions/ProducerSources/FunctionalSignatureProbe.swift",
  ])
    assert(files.has(path), `Missing independently admitted source: ${path}`);
  assert.equal(policy.sourceCommit, sourcePins.sourceCommit);
  assert.equal(
    sha(Buffer.from(functionalCanonicalJSON(sourcePins))),
    JSON.parse(issuerManifestBytes.toString("utf8")).producer.sourceSHA256,
    "Pair source union differs from actual live issuer authority",
  );
  assert.equal(
    files.get("Extensions/manifest.json"),
    admittedPolicies.manifest.sha256,
  );
  for (const entry of admittedPolicies.cases)
    assert.equal(
      files.get(entry.path),
      entry.sha256,
      `Policy case source changed: ${entry.owner}`,
    );
  const versions = ["1.0.0", "1.1.0"];
  const plan = Object.freeze({
    owner,
    sourceCommit: sourcePins.sourceCommit,
    pairScope: "synthetic-development",
    anchor,
    bootstrapAnchor,
    policySHA256: policy.policySHA256,
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
  pairPlans.add(plan);
  return plan;
}

export function functionalPairPlanForBuilder(plan) {
  assert(pairPlans.has(plan), "Expected admitted functional pair plan");
  return plan;
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
    const anchor =
      generated &&
      [plan.anchor, plan.bootstrapAnchor].find(
        (entry) => entry.generatedPath === pin.path,
      );
    const expected = anchor ? sha(Buffer.from(anchor.source)) : pin.sha256;
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
  issuerManifestBytes,
  admittedIssuer,
  artifactBytes,
  admittedArtifact,
  policyBytes,
  admittedPolicies,
  sourcePins,
  compilation,
  environment = process.env,
}) {
  environment = Object.freeze({ ...environment });
  const plan = functionalPairBuildPlan({
    owner,
    issuerManifestBytes,
    admittedIssuer,
    artifactBytes,
    admittedArtifact,
    policyBytes,
    admittedPolicies,
    sourcePins,
    environment,
  });
  const { functionalCompilationForBuilder, createFunctionalRoleBuild } =
    await import("./functional-build.mjs");
  const compiled = await functionalCompilationForBuilder(compilation);
  assert.equal(compiled.sourceCommit, plan.sourceCommit);
  assert.equal(compiled.root, plan.root);
  assert.equal(
    compiled.source.sha256,
    sha(Buffer.from(functionalCanonicalJSON(sourcePins))),
  );
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
    for (const anchor of [plan.anchor, plan.bootstrapAnchor])
      await writeFile(
        join(step.sourceRoot, anchor.generatedPath),
        anchor.source,
        { mode: 0o600 },
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
    const functionalRoleBuild = await createFunctionalRoleBuild({
      compilation,
      plan,
      version: step.version,
    });
    const { buildExtensionPackage } = await import(
      "../build-extension-package.mjs"
    );
    await buildExtensionPackage({
      root: step.sourceRoot,
      id: owner,
      version: step.version,
      output: step.output,
      containedHostApp: plan.host.path,
      environment: buildEnvironment,
      functionalRoleBuild,
    });
    await functionalCompilationForBuilder(compilation);
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
    const { functionalRoleVerificationInput } = await import(
      "./functional-build.mjs"
    );
    const verificationInput = await functionalRoleVerificationInput(
      functionalRoleBuild,
      {
        root: step.sourceRoot,
        id: owner,
        version: step.version,
        output: step.output,
        hostApp: plan.host.path,
      },
    );
    const receipt = JSON.parse(
      run(
        "python3",
        [
          "scripts/hosted-functional-actions/verify-role-package.py",
          artifact,
          verification,
          plan.host.path,
          plan.sourceCommit,
          metadata.sourceFingerprint,
          plan.host.executableSHA256,
        ],
        repository,
        buildEnvironment,
        Buffer.from(functionalCanonicalJSON(verificationInput)),
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
    generatedBootstrapSHA256: sha(Buffer.from(plan.bootstrapAnchor.source)),
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

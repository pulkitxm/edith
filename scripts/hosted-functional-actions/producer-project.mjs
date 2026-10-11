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
import { functionalFixtureRolePolicySource } from "./fixture-trust.mjs";
import { functionalActionOwners } from "./owners.mjs";
import { validateInstalledPresentationRecipe } from "./presentation.mjs";

export const functionalProducerSources = Object.freeze(
  [
    "FunctionalIssuer.swift",
    "FunctionalLifecycle.swift",
    "FunctionalPersistence.swift",
    "FunctionalOriginalUI.swift",
    "FunctionalProducer.swift",
    "FunctionalFileScopes.swift",
    "FunctionalRequestJournal.swift",
    "FunctionalProducerReceiver.swift",
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
  recipes,
  policyBytes,
  admittedPolicies,
  environment,
}) {
  admitFunctionalRunner(environment, sourceCommit);
  const policy = functionalFixtureRolePolicySource(
    policyBytes,
    admittedPolicies,
  );
  assert.equal(policy.sourceCommit, sourceCommit);
  const policies = JSON.parse(policyBytes.toString("utf8"));
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
    "Extensions/fixtureSupport/WorkerFixtureRolePolicy.swift",
    "Extensions/fixtureSupport/Package.swift",
    "scripts/hosted-functional-actions/fixture-trust.mjs",
    "Tests/HostedFunctionalActions/HostSources/FunctionalHostSocket.swift",
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
  assert.deepEqual(
    Object.keys(recipes).sort(),
    [...functionalActionOwners].sort(),
  );
  assert.equal(
    sourcePins.files.find(({ path }) => path === "Extensions/manifest.json")
      ?.sha256,
    admittedPolicies.manifest.sha256,
  );
  for (const entry of admittedPolicies.cases)
    assert.equal(
      sourcePins.files.find(({ path }) => path === entry.path)?.sha256,
      entry.sha256,
    );
  for (const { definition } of cases) {
    validateInstalledPresentationRecipe(recipes[definition.owner], definition);
    const original = policies.find(({ owner }) => owner === definition.owner);
    assert(original, "Missing independently admitted original role policy");
    assert.deepEqual(original.operations, definition.operations);
    const scopes = original.fileScopes;
    for (const step of recipes[definition.owner].steps) {
      for (const name of [
        step.ownedPath,
        step.ownedLabel?.name,
        step.scope?.ownedLabel?.name,
        step.scope?.anchor?.ownedLabel?.name,
      ].filter(Boolean))
        assert(
          scopes.some((scope) => scope.name === name),
          `Uncompiled chooser capability ${name}`,
        );
    }
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
    recipes: structuredClone(recipes),
    policySHA256: policy.policySHA256,
    rolePolicySwiftExpression: policy.swiftExpression,
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
  const recipes = dictionary(
    Object.entries(plan.recipes).map(([owner, recipe]) => [
      owner,
      `Data(base64Encoded: ${quoted(Buffer.from(functionalCanonicalJSON(recipe)).toString("base64"))})!`,
    ]),
  );
  return `import Foundation
import WorkerFixtureSupport

enum FunctionalProducerBuild {
    static let sourceCommit = ${quoted(plan.sourceCommit)}
    static let session = ${quoted(plan.session)}
    static let root = ${quoted(plan.root)}
    static let hostIdentifier = ${quoted(plan.hostIdentifier)}
    static let producerIdentifier = ${quoted(plan.producerIdentifier)}
    static let certificateSHA256 = Data(base64Encoded: ${quoted(plan.certificateSHA256)})!
    static let recipes: [String: Data] = ${recipes}
    static let policySHA256 = ${quoted(plan.policySHA256)}
    static let rolePolicies: [WorkerFixtureRolePolicy] = try! ${plan.rolePolicySwiftExpression}
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
  const supportDirectory = join(directory, "WorkerFixtureSupport");
  await mkdir(supportDirectory, { mode: 0o700 });
  await requireFunctionalPrivateDirectory(supportDirectory);
  const supportSources = plan.sourcePins.files.filter(
    ({ path }) =>
      /^Extensions\/fixtureSupport\/[^/]+\.swift$/.test(path) &&
      !path.endsWith("/Package.swift"),
  );
  assert(supportSources.length > 0);
  const supportTracked = run("git", [
    "ls-files",
    "--",
    "Extensions/fixtureSupport",
  ])
    .toString("utf8")
    .trim()
    .split("\n")
    .filter(
      (path) =>
        /^Extensions\/fixtureSupport\/[^/]+\.swift$/.test(path) &&
        !path.endsWith("/Package.swift"),
    );
  assert.deepEqual(
    supportSources.map(({ path }) => path).sort(),
    supportTracked.sort(),
  );
  assert(
    plan.sourcePins.files.some(
      ({ path }) => path === "Extensions/fixtureSupport/Package.swift",
    ),
  );
  const supportLibrary = join(supportDirectory, "libWorkerFixtureSupport.a");
  run("xcrun", [
    "swiftc",
    "-parse-as-library",
    "-emit-module",
    "-emit-library",
    "-static",
    "-swift-version",
    "5",
    "-O",
    "-num-threads",
    "1",
    "-module-name",
    "WorkerFixtureSupport",
    "-DEDITH_FUNCTIONAL_FIXTURE",
    ...supportSources.map(({ path }) => path),
    "-emit-module-path",
    join(supportDirectory, "WorkerFixtureSupport.swiftmodule"),
    "-o",
    supportLibrary,
  ]);
  run("xcrun", [
    "swiftc",
    "-parse-as-library",
    "-swift-version",
    "6",
    "-O",
    "-num-threads",
    "1",
    "-I",
    supportDirectory,
    "-framework",
    "ApplicationServices",
    "-framework",
    "Security",
    ...plan.sources,
    "Tests/HostedFunctionalActions/HostSources/FunctionalHostSocket.swift",
    contextPath,
    bootstrap,
    supportLibrary,
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
    policySHA256: plan.policySHA256,
    fixtureSupport: {
      module: "WorkerFixtureSupport",
      swiftVersion: "5",
      functionalFixture: true,
      sources: supportSources,
      librarySHA256: sha(await readFile(supportLibrary)),
    },
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

export function functionalHostProject(plan, inputs) {
  assert.match(plan.sourceCommit, /^[0-9a-f]{40}$/);
  assert.equal(resolve(inputs.repository), inputs.repository);
  assert.equal(inputs.directory, join(plan.root, "HostBuild"));
  const sourceFiles = inputs.sourceFiles;
  assert(
    Array.isArray(sourceFiles) &&
      sourceFiles.length > 80 &&
      sourceFiles.length < 512,
  );
  assert.equal(new Set(sourceFiles).size, sourceFiles.length);
  const original = sourceFiles.filter((path) =>
    path.startsWith("Packages/EdithHost/Sources/EdithHost/"),
  );
  assert.deepEqual(
    [...original].sort(),
    plan.sourcePins.files
      .map(({ path }) => path)
      .filter(
        (path) =>
          path.startsWith("Packages/EdithHost/Sources/EdithHost/") &&
          path.endsWith(".swift"),
      )
      .sort(),
  );
  assert(
    original.includes("Packages/EdithHost/Sources/EdithHost/HostEntry.swift"),
  );
  for (const path of sourceFiles) {
    assert(path.endsWith(".swift"));
    assert(!path.split("/").some((part) => ["", ".", ".."].includes(part)));
    assert(plan.sourcePins.files.some((pin) => pin.path === path));
    assert(
      path.startsWith("Packages/EdithHost/Sources/EdithHost/") ||
        path.startsWith("Tests/HostedFunctionalActions/HostSources/") ||
        functionalProducerSources.slice(0, 4).includes(path) ||
        path ===
          "Tests/HostedFunctionalActions/Sources/FunctionalActionContract/HostedFunctionalActionContext.swift",
    );
  }
  for (const name of [
    "FunctionalHostApplication.swift",
    "FunctionalHostSession.swift",
    "FunctionalHostBootstrap.swift",
    "FunctionalHostSocket.swift",
    "FunctionalSyntheticMedia.swift",
  ])
    assert(
      sourceFiles.includes(`Tests/HostedFunctionalActions/HostSources/${name}`),
    );
  assert(
    sourceFiles.includes(
      "Tests/HostedFunctionalActions/ProducerSources/FunctionalIssuer.swift",
    ),
  );
  assert(
    !sourceFiles.includes(
      "Tests/HostedFunctionalActions/ProducerSources/FunctionalProducer.swift",
    ),
  );
  const generated = ["FunctionalHostBuild.swift"];
  assert.deepEqual(Object.keys(inputs.generatedSources).sort(), generated);
  assert(
    inputs.generatedSources[generated[0]].includes("enum FunctionalHostBuild"),
  );
  const dependencyRoot = join(plan.root, "HostDependencies");
  const artifacts = inputs.dependencyArtifacts;
  assert(
    Array.isArray(artifacts) &&
      artifacts.length > 10 &&
      artifacts.length < 4096,
  );
  assert.equal(
    new Set(artifacts.map(({ path }) => path)).size,
    artifacts.length,
  );
  for (const artifact of artifacts) {
    assert.deepEqual(Object.keys(artifact).sort(), ["kind", "path", "sha256"]);
    assert.match(artifact.sha256, /^[0-9a-f]{64}$/);
    assert(artifact.path.startsWith(`${dependencyRoot}/`));
    assert(!artifact.path.includes("/EdithHost.build/"));
    assert(
      ["object", "module", "modulemap", "framework", "resource"].includes(
        artifact.kind,
      ),
    );
  }
  const objectsToLink = artifacts
    .filter(({ kind }) => kind === "object")
    .map(({ path }) => path);
  assert(
    objectsToLink.some((path) =>
      path.endsWith("/HostBootstrap.build/HostBootstrap.c.o"),
    ),
  );
  assert(objectsToLink.some((path) => path.includes("/EdithHostCore.build/")));
  assert(
    objectsToLink.some((path) => path.includes("/WorkerFixtureSupport.build/")),
  );
  assert(
    objectsToLink.some((path) => path.includes("/EdithExtensionUI.build/")),
  );
  assert.equal(resolve(inputs.modulesDirectory), inputs.modulesDirectory);
  assert(inputs.modulesDirectory.startsWith(`${dependencyRoot}/`));
  assert.equal(
    inputs.moduleMap,
    artifacts.find(({ kind }) => kind === "modulemap")?.path,
  );
  assert(inputs.sparkleFramework.startsWith(`${dependencyRoot}/`));
  assert(inputs.sparkleFramework.endsWith("/Sparkle.framework"));
  const sourceDigest = sha(
    Buffer.from(
      functionalCanonicalJSON(
        sourceFiles.map((path) =>
          plan.sourcePins.files.find((pin) => pin.path === path),
        ),
      ),
    ),
  );
  const objects = {};
  const add = (name, value) => {
    const id = sha(Buffer.from(`functional-host-project:${name}`))
      .slice(0, 24)
      .toUpperCase();
    assert(!Object.hasOwn(objects, id));
    objects[id] = value;
    return id;
  };
  const sources = [],
    files = [];
  for (const path of sourceFiles) {
    const file = add(`source:${path}`, {
      isa: "PBXFileReference",
      lastKnownFileType: "sourcecode.swift",
      path: join(inputs.repository, path),
      sourceTree: "<absolute>",
    });
    files.push(file);
    sources.push(
      add(`compile:${path}`, { isa: "PBXBuildFile", fileRef: file }),
    );
  }
  for (const path of generated) {
    const file = add(`generated:${path}`, {
      isa: "PBXFileReference",
      lastKnownFileType: "sourcecode.swift",
      path: join(inputs.directory, path),
      sourceTree: "<absolute>",
    });
    files.push(file);
    sources.push(
      add(`compile-generated:${path}`, { isa: "PBXBuildFile", fileRef: file }),
    );
  }
  const binary = add("product", {
    isa: "PBXFileReference",
    explicitFileType: "wrapper.application",
    path: "Fixture.app",
    sourceTree: "BUILT_PRODUCTS_DIR",
  });
  const products = add("products", {
    isa: "PBXGroup",
    children: [binary],
    name: "Products",
    sourceTree: "<group>",
  });
  const group = add("root-group", {
    isa: "PBXGroup",
    children: files,
    sourceTree: "<group>",
  });
  const sourcePhase = add("source-phase", {
    isa: "PBXSourcesBuildPhase",
    buildActionMask: 2147483647,
    files: sources,
    runOnlyForDeploymentPostprocessing: 0,
  });
  const frameworkFile = add("sparkle-file", {
    isa: "PBXFileReference",
    lastKnownFileType: "wrapper.framework",
    path: inputs.sparkleFramework,
    sourceTree: "<absolute>",
  });
  const frameworkBuild = add("sparkle-link", {
    isa: "PBXBuildFile",
    fileRef: frameworkFile,
  });
  const frameworkPhase = add("framework-phase", {
    isa: "PBXFrameworksBuildPhase",
    buildActionMask: 2147483647,
    files: [frameworkBuild],
    runOnlyForDeploymentPostprocessing: 0,
  });
  const embedBuild = add("sparkle-embed", {
    isa: "PBXBuildFile",
    fileRef: frameworkFile,
    settings: { ATTRIBUTES: ["CodeSignOnCopy", "RemoveHeadersOnCopy"] },
  });
  const embedPhase = add("embed-phase", {
    isa: "PBXCopyFilesBuildPhase",
    buildActionMask: 2147483647,
    dstPath: "",
    dstSubfolderSpec: 10,
    files: [embedBuild],
    name: "Embed Frameworks",
    runOnlyForDeploymentPostprocessing: 0,
  });
  const resources = [];
  for (const path of inputs.resources) {
    assert(
      path.startsWith(`${inputs.repository}/Packages/EdithHost/Sources/`) ||
        path.startsWith(`${dependencyRoot}/`),
    );
    const file = add(`resource:${path}`, {
      isa: "PBXFileReference",
      lastKnownFileType: path.endsWith(".bundle")
        ? "wrapper.plug-in"
        : "text.json",
      path,
      sourceTree: "<absolute>",
    });
    files.push(file);
    resources.push(
      add(`copy-resource:${path}`, { isa: "PBXBuildFile", fileRef: file }),
    );
  }
  assert(inputs.resources.some((path) => path.endsWith("/index.json")));
  assert(
    inputs.resources.some((path) =>
      path.endsWith("/EdithHost_EdithHost.bundle"),
    ),
  );
  const resourcePhase = add("resource-phase", {
    isa: "PBXResourcesBuildPhase",
    buildActionMask: 2147483647,
    files: resources,
    runOnlyForDeploymentPostprocessing: 0,
  });
  const settings = {
    PRODUCT_NAME: "Fixture",
    PRODUCT_MODULE_NAME: "EdithHost",
    EXECUTABLE_NAME: "Edith",
    PRODUCT_BUNDLE_IDENTIFIER: plan.hostIdentifier,
    SDKROOT: "macosx",
    MACOSX_DEPLOYMENT_TARGET: "14.0",
    ARCHS: "arm64",
    ONLY_ACTIVE_ARCH: "YES",
    SWIFT_VERSION: "6.0",
    SWIFT_ACTIVE_COMPILATION_CONDITIONS: [
      "EDITH_FUNCTIONAL_FIXTURE",
      "EDITH_FUNCTIONAL_FIXTURE_ENTRY",
    ],
    OTHER_SWIFT_FLAGS: [
      "-I",
      inputs.modulesDirectory,
      "-Xcc",
      `-fmodule-map-file=${inputs.moduleMap}`,
    ],
    OTHER_LDFLAGS: [
      ...objectsToLink,
      "-e",
      "_NSExtensionMain",
      "-application_extension",
    ],
    LD_RUNPATH_SEARCH_PATHS: ["@executable_path/../Frameworks"],
    FRAMEWORK_SEARCH_PATHS: [
      inputs.sparkleFramework.slice(0, -"/Sparkle.framework".length),
    ],
    GENERATE_INFOPLIST_FILE: "NO",
    INFOPLIST_FILE: join(inputs.directory, "Info.plist"),
    CODE_SIGNING_ALLOWED: "NO",
    CODE_SIGNING_REQUIRED: "NO",
    ENABLE_HARDENED_RUNTIME: "YES",
    SWIFT_OPTIMIZATION_LEVEL: "-O",
    CLANG_ENABLE_MODULES: "YES",
    SWIFT_COMPILATION_MODE: "wholemodule",
    SWIFT_DISABLE_SAFETY_CHECKS: "NO",
  };
  const configuration = add("configuration", {
    isa: "XCBuildConfiguration",
    name: "Release",
    buildSettings: settings,
  });
  const configurations = add("configurations", {
    isa: "XCConfigurationList",
    buildConfigurations: [configuration],
    defaultConfigurationIsVisible: 0,
    defaultConfigurationName: "Release",
  });
  const target = add("target", {
    isa: "PBXNativeTarget",
    name: "EdithHost",
    productName: "Fixture",
    productType: "com.apple.product-type.application",
    productReference: binary,
    buildConfigurationList: configurations,
    buildPhases: [sourcePhase, frameworkPhase, resourcePhase, embedPhase],
    buildRules: [],
    dependencies: [],
  });
  objects[group].children.push(frameworkFile, products);
  const project = add("project", {
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
  return {
    archiveVersion: "1",
    classes: {},
    objectVersion: "56",
    objects,
    rootObject: project,
    sourceDigest,
    settings,
    sourceFiles,
    dependencyArtifacts: structuredClone(artifacts),
  };
}

export function functionalHostProjectXML(project) {
  const escapeXML = (text) =>
    String(text)
      .replaceAll("&", "&amp;")
      .replaceAll("<", "&lt;")
      .replaceAll(">", "&gt;")
      .replaceAll('"', "&quot;");
  const encode = (value) => {
    if (Array.isArray(value))
      return `<array>${value.map(encode).join("")}</array>`;
    if (value && typeof value === "object")
      return `<dict>${Object.entries(value)
        .map(([key, item]) => `<key>${escapeXML(key)}</key>${encode(item)}`)
        .join("")}</dict>`;
    if (typeof value === "number") {
      assert(Number.isSafeInteger(value));
      return `<integer>${value}</integer>`;
    }
    assert.equal(typeof value, "string");
    return `<string>${escapeXML(value)}</string>`;
  };
  const { archiveVersion, classes, objectVersion, objects, rootObject } =
    project;
  return `<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0">${encode({ archiveVersion, classes, objectVersion, objects, rootObject })}</plist>\n`;
}

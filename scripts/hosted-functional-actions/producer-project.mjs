import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { createHash, X509Certificate } from "node:crypto";
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
    "FunctionalCollectedEvidence.swift",
    "FunctionalEvidenceAssembly.swift",
    "FunctionalEvidenceSealing.swift",
    "FunctionalContentActionRelations.swift",
    "FunctionalToolsActionRelations.swift",
  ].map((name) => `Tests/HostedFunctionalActions/ProducerSources/${name}`),
);

export const functionalProducerCatalogSources = Object.freeze([
  "Packages/ExtensionMarketplace/Sources/ExtensionMarketplace/ExtensionCatalog.swift",
  "Packages/ExtensionMarketplace/Sources/ExtensionMarketplace/ExtensionSystemVersion.swift",
]);

export const functionalProducerMediaSources = Object.freeze([
  "Tests/HostedFunctionalActions/HostSources/FunctionalSyntheticMedia.swift",
]);

const producerBuilds = new WeakMap();
const producerPlans = new WeakMap();

function freezePlan(value) {
  if (value && typeof value === "object" && !Buffer.isBuffer(value)) {
    for (const child of Object.values(value)) freezePlan(child);
    Object.freeze(value);
  }
  return value;
}

const sha = (bytes) => createHash("sha256").update(bytes).digest("hex");
const uuid =
  /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;
const certificate = /^[A-Za-z0-9+/]{43}=$/;

export function admitFunctionalSourceEnvironment(environment, sourceCommit) {
  assert.match(sourceCommit, /^[0-9a-f]{40}$/);
  for (const [key, value] of Object.entries({
    GITHUB_ACTIONS: "true",
    RUNNER_ENVIRONMENT: "github-hosted",
    RUNNER_OS: "macOS",
    GITHUB_REPOSITORY: "pulkitxm/edith",
    GITHUB_REPOSITORY_ID: "1289153439",
    GITHUB_EVENT_NAME: "pull_request",
    GITHUB_REF: "refs/pull/1014/merge",
    GITHUB_JOB: "functional-build",
    EDITH_HOSTED_FUNCTIONAL_ACTIONS: "1",
    EXPECTED_SOURCE_SHA: sourceCommit,
    EXTENSION_SWIFT_JOBS: "1",
  }))
    assert.equal(environment[key], value, `Unadmitted runner ${key}`);
  assert.match(environment.GITHUB_SHA, /^[0-9a-f]{40}$/);
  assert.notEqual(environment.GITHUB_SHA, sourceCommit);
  assert(["65671483", "320458784"].includes(environment.GITHUB_ACTOR_ID));
  assert(
    ["pulkitxm", "pukbot[bot]"].includes(environment.GITHUB_TRIGGERING_ACTOR),
  );
  for (const key of [
    "GITHUB_RUN_ID",
    "GITHUB_RUN_ATTEMPT",
    "FUNCTIONAL_JOB_ID",
  ])
    assert.match(environment[key], /^[1-9][0-9]{0,15}$/);
  assert.equal(environment.RUNNER_NAME?.length > 0, true);
  assert.match(
    environment.DEVELOPER_DIR,
    /^\/Applications\/Xcode[^/]*\.app\/Contents\/Developer$/,
  );
  assert.equal(resolve(environment.RUNNER_TEMP), environment.RUNNER_TEMP);
  assert.equal(
    resolve(environment.GITHUB_EVENT_PATH),
    environment.GITHUB_EVENT_PATH,
  );
  for (const key of [
    "CAMERA_SIGN_TEAM",
    "CAMERA_CARRIER_PROFILE",
    "CAMERA_EXTENSION_PROFILE",
    "EXTENSION_RELEASE_TAG",
    "EXTENSION_CATALOG_PRIVATE_KEY",
  ])
    assert(!environment[key], `Unadmitted publication input ${key}`);
}

export function admitFunctionalRunner(environment, sourceCommit) {
  admitFunctionalSourceEnvironment(environment, sourceCommit);
  assert(
    environment.EXTENSION_SIGN_IDENTITY &&
      environment.EXTENSION_SIGN_IDENTITY !== "-",
  );
}

export function functionalHostedRunPins(
  activeJob,
  environment,
  workflowSHA256,
) {
  const { sourceCommit, run, job, context } = activeJob;
  admitFunctionalSourceEnvironment(environment, sourceCommit);
  assert.equal(run.id, Number(environment.GITHUB_RUN_ID));
  assert.equal(job.id, Number(environment.FUNCTIONAL_JOB_ID));
  assert.equal(job.run_attempt, Number(environment.GITHUB_RUN_ATTEMPT));
  assert.equal(context.runAttempt, Number(environment.GITHUB_RUN_ATTEMPT));
  assert.equal(context.mergeCommit.sha, environment.GITHUB_SHA);
  assert.equal(run.head_sha, sourceCommit);
  assert.equal(run.status, "in_progress");
  assert.equal(job.status, "in_progress");
  assert.equal(run.conclusion, null);
  assert.equal(job.conclusion, null);
  assert.equal(job.runner_name, environment.RUNNER_NAME);
  assert.match(workflowSHA256, /^[0-9a-f]{64}$/);
  return Object.freeze({
    sourceCommit,
    mergeCommit: context.mergeCommit.sha,
    baseCommit: context.event.pull_request.base.sha,
    runID: run.id,
    jobID: job.id,
    runAttempt: context.runAttempt,
    runnerName: environment.RUNNER_NAME,
    workflowSHA256,
  });
}

export async function captureFunctionalSigningCertificate({
  environment = process.env,
  sourceCommit,
}) {
  admitFunctionalRunner(environment, sourceCommit);
  assert.equal(process.platform, "darwin");
  assert.equal(process.arch, "arm64");
  const keychain = join(
    environment.RUNNER_TEMP,
    "hosted-functional-actions.keychain-db",
  );
  assert.equal(await realpath(keychain), keychain);
  const pem = execFileSync(
    "security",
    [
      "find-certificate",
      "-c",
      environment.EXTENSION_SIGN_IDENTITY,
      "-p",
      keychain,
    ],
    {
      env: environment,
      timeout: 15000,
      maxBuffer: 65536,
      stdio: ["ignore", "pipe", "pipe"],
    },
  );
  const certificate = new X509Certificate(pem);
  return createHash("sha256").update(certificate.raw).digest("base64");
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
  savedReaderPolicies,
  savedReaderSources,
  policySources,
  preparationPolicies,
  preparationSources,
  observationPolicies,
  observationSources,
  activeJob,
  toolchain,
  environment,
}) {
  admitFunctionalRunner(environment, sourceCommit);
  const hostedRunPins = functionalHostedRunPins(
    activeJob,
    environment,
    sourcePins.files.find(
      ({ path }) => path === ".github/workflows/hosted-functional-actions.yml",
    )?.sha256,
  );
  assert(Buffer.isBuffer(toolchain.bytes));
  assert.equal(sha(toolchain.bytes), toolchain.sha256);
  const toolchainValue = JSON.parse(toolchain.bytes.toString("utf8"));
  assert.equal(
    functionalCanonicalJSON(toolchainValue),
    toolchain.bytes.toString("utf8"),
  );
  assert.deepEqual(Object.keys(toolchainValue).sort(), [
    "buildSettingsSHA256",
    "sdkSHA256",
    "swiftCompilerSHA256",
  ]);
  for (const value of Object.values(toolchainValue))
    assert.match(value, /^[0-9a-f]{64}$/);
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
    ...functionalProducerCatalogSources,
    ...functionalProducerMediaSources,
    "scripts/hosted-functional-actions/functional-build.mjs",
    "scripts/hosted-functional-actions/owned-process.mjs",
    "scripts/hosted-functional-actions/run-functional.mjs",
    ".github/workflows/hosted-functional-actions.yml",
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
  assert.deepEqual(
    Object.keys(savedReaderPolicies).sort(),
    [...functionalActionOwners].sort(),
  );
  for (const owner of functionalActionOwners) {
    const reader = savedReaderPolicies[owner];
    assert.equal(reader.owner, owner);
    assert.equal(reader.schema, 1);
    assert(
      seen.has(`scripts/hosted-functional-actions/saved-readers/${owner}.json`),
      `Missing source-compiled saved reader ${owner}`,
    );
    assert(
      seen.has(`scripts/hosted-functional-actions/policies/${owner}.json`),
      `Missing source-compiled role policy ${owner}`,
    );
  }
  assert.deepEqual(
    Object.keys(preparationPolicies).sort(),
    [...functionalActionOwners].sort(),
  );
  assert.deepEqual(
    Object.keys(observationPolicies).sort(),
    [...functionalActionOwners].sort(),
  );
  for (const [kind, sources, values] of [
    ["observation-policies", observationSources, observationPolicies],
    ["preparation", preparationSources, preparationPolicies],
    ["saved-readers", savedReaderSources, savedReaderPolicies],
    [
      "policies",
      policySources,
      Object.fromEntries(
        policies.map(({ manifestSHA256, caseSHA256, ...value }) => [
          value.owner,
          value,
        ]),
      ),
    ],
  ]) {
    assert.deepEqual(
      Object.keys(sources).sort(),
      [...functionalActionOwners].sort(),
    );
    for (const owner of functionalActionOwners) {
      const entry = sources[owner];
      assert.deepEqual(Object.keys(entry).sort(), ["bytes", "path", "sha256"]);
      assert.equal(
        entry.path,
        `scripts/hosted-functional-actions/${kind}/${owner}.json`,
      );
      assert(Buffer.isBuffer(entry.bytes));
      assert.equal(sha(entry.bytes), entry.sha256);
      assert.equal(
        sourcePins.files.find((pin) => pin.path === entry.path)?.sha256,
        entry.sha256,
      );
      assert.equal(
        functionalCanonicalJSON(JSON.parse(entry.bytes.toString("utf8"))),
        functionalCanonicalJSON(values[owner]),
        `Source-compiled literal ${kind} changed for ${owner}`,
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
  const plan = freezePlan({
    sourceCommit,
    hostedRunPins,
    sourceSHA256: sha(Buffer.from(functionalCanonicalJSON(sourcePins))),
    toolchainSHA256: toolchain.sha256,
    toolchain: {
      bytes: Buffer.from(toolchain.bytes),
      sha256: toolchain.sha256,
    },
    session,
    root,
    certificateSHA256,
    definitions,
    recipes: structuredClone(recipes),
    savedReaderPolicies: structuredClone(savedReaderPolicies),
    preparationPolicies: structuredClone(preparationPolicies),
    observationPolicies: structuredClone(observationPolicies),
    policySHA256: policy.policySHA256,
    rolePolicySwiftExpression: policy.swiftExpression,
    roles,
    hostIdentifier: `com.pulkit.edith.tests.worker-${session}`,
    producerIdentifier: `com.pulkit.edith.tests.functional-producer-${session}`,
    executable: join(root, "Producer/functional-producer"),
    sources: functionalProducerSources,
    sourcePins: structuredClone(sourcePins),
  });
  producerPlans.set(plan, {
    policySHA256: plan.policySHA256,
    sourceSHA256: plan.sourceSHA256,
    toolchainSHA256: plan.toolchainSHA256,
  });
  return plan;
}

export function functionalProducerPlanForBuild(plan) {
  const state = producerPlans.get(plan);
  assert(state, "Expected source-admitted producer plan");
  assert.equal(
    sha(Buffer.from(functionalCanonicalJSON(plan.sourcePins))),
    state.sourceSHA256,
  );
  assert.equal(sha(plan.toolchain.bytes), state.toolchainSHA256);
  assert.equal(plan.policySHA256, state.policySHA256);
  return plan;
}

export function functionalHostedRunPinsSwift(pins) {
  assert.deepEqual(Object.keys(pins).sort(), [
    "baseCommit",
    "jobID",
    "mergeCommit",
    "runAttempt",
    "runID",
    "runnerName",
    "sourceCommit",
    "workflowSHA256",
  ]);
  for (const key of ["sourceCommit", "mergeCommit", "baseCommit"])
    assert.match(pins[key], /^[0-9a-f]{40}$/);
  for (const key of ["runID", "jobID", "runAttempt"])
    assert(Number.isSafeInteger(pins[key]) && pins[key] > 0);
  assert.match(pins.workflowSHA256, /^[0-9a-f]{64}$/);
  assert(
    typeof pins.runnerName === "string" &&
      /^[ -~]{1,256}$/.test(pins.runnerName),
  );
  return `FunctionalHostedRunPins(sourceCommit: ${JSON.stringify(pins.sourceCommit)}, mergeCommit: ${JSON.stringify(pins.mergeCommit)}, baseCommit: ${JSON.stringify(pins.baseCommit)}, runID: ${pins.runID}, jobID: ${pins.jobID}, runAttempt: ${pins.runAttempt}, runnerName: ${JSON.stringify(pins.runnerName)}, workflowSHA256: ${JSON.stringify(pins.workflowSHA256)})`;
}

function swiftLiteral(value, depth = 0) {
  assert(depth < 32);
  if (value === null) return ".null";
  if (typeof value === "boolean") return `.boolean(${value})`;
  if (typeof value === "number") {
    assert(Number.isFinite(value));
    if (Number.isInteger(value)) {
      assert(Number.isSafeInteger(value));
      return `.integer(${value})`;
    }
    return `.number(${value})`;
  }
  if (typeof value === "string")
    return `.string(String(decoding: Data(base64Encoded: ${JSON.stringify(Buffer.from(value).toString("base64"))})!, as: UTF8.self))`;
  if (Array.isArray(value))
    return `.array([${value.map((item) => swiftLiteral(item, depth + 1)).join(", ")}])`;
  assert(value && Object.getPrototypeOf(value) === Object.prototype);
  return `.object(${
    Object.keys(value).length
      ? `[${Object.entries(value)
          .map(
            ([key, item]) =>
              `${JSON.stringify(key)}: ${swiftLiteral(item, depth + 1)}`,
          )
          .join(", ")}]`
      : "[:]"
  })`;
}

export function functionalObservationRuleSwift(rule, depth = 0) {
  assert(depth < 32);
  const fields = {
    literal: ["kind", "value"],
    integer: ["kind", "minimum", "maximum"],
    number: ["kind", "minimum", "maximum"],
    object: ["kind", "fields"],
    array: ["kind", "minimumCount", "maximumCount", "element"],
    oneOf: ["kind", "values"],
    sha256: ["kind"],
    uuid: ["kind"],
    nullable: ["kind", "rule"],
  };
  assert(
    rule &&
      Object.getPrototypeOf(rule) === Object.prototype &&
      Object.hasOwn(fields, rule.kind),
  );
  assert.deepEqual(Object.keys(rule).sort(), [...fields[rule.kind]].sort());
  if (rule.kind === "literal") return `.literal(${swiftLiteral(rule.value)})`;
  if (["integer", "number"].includes(rule.kind)) {
    assert(
      Number.isFinite(rule.minimum) &&
        Number.isFinite(rule.maximum) &&
        rule.minimum <= rule.maximum,
    );
    if (rule.kind === "integer")
      assert(
        Number.isSafeInteger(rule.minimum) &&
          Number.isSafeInteger(rule.maximum),
      );
    return `.${rule.kind}(minimum: ${rule.minimum}, maximum: ${rule.maximum})`;
  }
  if (rule.kind === "object") {
    assert(
      rule.fields &&
        Object.getPrototypeOf(rule.fields) === Object.prototype &&
        Object.keys(rule.fields).length <= 128,
    );
    for (const key of Object.keys(rule.fields))
      assert(key.length > 0 && Buffer.byteLength(key) <= 256);
    return `.object(${
      Object.keys(rule.fields).length
        ? `[${Object.entries(rule.fields)
            .map(
              ([key, value]) =>
                `${JSON.stringify(key)}: ${functionalObservationRuleSwift(value, depth + 1)}`,
            )
            .join(", ")}]`
        : "[:]"
    })`;
  }
  if (rule.kind === "array") {
    assert(
      Number.isSafeInteger(rule.minimumCount) &&
        Number.isSafeInteger(rule.maximumCount) &&
        rule.minimumCount >= 0 &&
        rule.maximumCount >= rule.minimumCount &&
        rule.maximumCount <= 65536,
    );
    return `.array(minimumCount: ${rule.minimumCount}, maximumCount: ${rule.maximumCount}, element: ${functionalObservationRuleSwift(rule.element, depth + 1)})`;
  }
  if (rule.kind === "oneOf") {
    assert(
      Array.isArray(rule.values) &&
        rule.values.length > 0 &&
        rule.values.length <= 32,
    );
    return `.oneOf([${rule.values.map((value) => swiftLiteral(value)).join(", ")}])`;
  }
  if (rule.kind === "nullable")
    return `.nullable(${functionalObservationRuleSwift(rule.rule, depth + 1)})`;
  return `.${rule.kind}`;
}

function sourceSavedValue(value, plan, owner, phase, depth = 0) {
  assert(depth <= 32);
  if (Array.isArray(value))
    return value.map((item) =>
      sourceSavedValue(item, plan, owner, phase, depth + 1),
    );
  if (!value || typeof value !== "object") return value;
  if (value.$binding === "session") {
    assert.deepEqual(Object.keys(value), ["$binding"]);
    return plan.session;
  }
  if (value.$binding === "owned-path") {
    assert.deepEqual(Object.keys(value).sort(), [
      "$binding",
      "components",
      "root",
    ]);
    const roots = {
      "owner-home": `${plan.root}/${owner}-home`,
      "owner-data": `${plan.root}/Edith Tests/worker-${plan.session}/Data/${owner}`,
      "owner-inputs": `${plan.root}/inputs/${owner}`,
      "owner-outputs": `${plan.root}/outputs/${owner}`,
    };
    assert(Object.hasOwn(roots, value.root));
    const components = value.components.map((component) => {
      if (typeof component === "string") return component;
      if (component.derived === "session") return plan.session;
      if (component.derived === "phase") return phase;
      if (component.derived === "ui-suite-plist")
        return `${plan.hostIdentifier}.extension.${owner}.worker.plist`;
      assert.equal(component.derived, "engine-suite-plist");
      return `${plan.hostIdentifier}.extensions.${owner}.plist`;
    });
    return `${roots[value.root]}/${components.join("/")}`;
  }
  return Object.fromEntries(
    Object.entries(value).map(([key, item]) => [
      key,
      sourceSavedValue(item, plan, owner, phase, depth + 1),
    ]),
  );
}

export function functionalProducerBootstrapSource(plan, repository) {
  assert.equal(resolve(repository), repository);
  const quoted = (value) => {
    assert(typeof value === "string" && /^[ -~]+$/.test(value));
    return JSON.stringify(value);
  };
  const dictionary = (pairs) =>
    pairs.length === 0
      ? "[:]"
      : `[${pairs.map(([key, value]) => `${quoted(key)}: ${value}`).join(", ")}]`;
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
    plan.definitions.map((definition) => {
      if (definition.owner === "calendar") {
        assert.equal(definition.activation.kind, "original-calendar-details");
        assert.equal(definition.activation.operation, null);
        return [definition.owner, "nil"];
      }
      return [definition.owner, quoted(definition.activation.operation)];
    }),
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
  const savedReaderPolicies = dictionary(
    Object.entries(plan.savedReaderPolicies).map(([owner, reader]) => [
      owner,
      `Data(base64Encoded: ${quoted(Buffer.from(functionalCanonicalJSON(reader)).toString("base64"))})!`,
    ]),
  );
  const preparationPolicies = dictionary(
    Object.entries(plan.preparationPolicies).map(([owner, preparation]) => [
      owner,
      `Data(base64Encoded: ${quoted(Buffer.from(functionalCanonicalJSON(preparation)).toString("base64"))})!`,
    ]),
  );
  const sourceFiles = dictionary(
    plan.sourcePins.files.map(({ path, sha256 }) => [path, quoted(sha256)]),
  );
  const caseDefinitions = dictionary(
    plan.definitions.map((definition) => [
      definition.owner,
      `Data(base64Encoded: ${quoted(Buffer.from(functionalCanonicalJSON(definition)).toString("base64"))})!`,
    ]),
  );
  const observationPolicies = dictionary(
    Object.entries(plan.observationPolicies).map(([owner, value]) => [
      owner,
      `Data(base64Encoded: ${quoted(Buffer.from(functionalCanonicalJSON(value)).toString("base64"))})!`,
    ]),
  );
  const readPolicies = dictionary(
    Object.entries(plan.observationPolicies).map(([owner, value]) => [
      owner,
      `Data(base64Encoded: ${quoted(Buffer.from(functionalCanonicalJSON({ schema: 1, owner, operation: value.readback.operation, payload: value.readback.payload })).toString("base64"))})!`,
    ]),
  );
  const normalizers = dictionary(
    Object.entries(plan.observationPolicies).map(([owner, value]) => [
      owner,
      `Data(base64Encoded: ${quoted(Buffer.from(functionalCanonicalJSON({ schema: 1, owner, normalizer: value.readback.normalizer })).toString("base64"))})!`,
    ]),
  );
  const evidencePolicies = dictionary(
    plan.definitions.map((definition) => {
      const reader = plan.savedReaderPolicies[definition.owner];
      const phases = plan.observationPolicies[definition.owner].phases;
      const encoded = quoted(
        Buffer.from(functionalCanonicalJSON(definition)).toString("base64"),
      );
      return [
        definition.owner,
        `FunctionalCollectedEvidence.Policy(definition: try! JSONDecoder().decode(FunctionalCollectedEvidence.Definition.self, from: Data(base64Encoded: ${encoded})!), semantics: [${phases
          .map((rule) => {
            const before = sourceSavedValue(
              rule.phase === "initial" || definition.owner === "blitztree"
                ? reader.initial
                : reader.final,
              plan,
              definition.owner,
              rule.phase,
            );
            const after = sourceSavedValue(
              reader.final,
              plan,
              definition.owner,
              rule.phase,
            );
            return `FunctionalCollectedEvidence.PhaseSemantics(phase: ${quoted(rule.phase)}, before: ${functionalObservationRuleSwift(sourceSavedValue(rule.before, plan, definition.owner, rule.phase))}, after: ${functionalObservationRuleSwift(sourceSavedValue(rule.after, plan, definition.owner, rule.phase))}, savedBefore: ${before === null ? "nil" : swiftLiteral(before)}, savedAfter: ${after === null ? "nil" : swiftLiteral(after)}, relation: ${definition.owner === "colorPicker" ? ".colorPickerHistory" : "nil"})`;
          })
          .join(", ")}])`,
      ];
    }),
  );
  return `import Foundation
import WorkerFixtureSupport

enum FunctionalProducerBuild {
    static let sourceCommit = ${quoted(plan.sourceCommit)}
    static let repository = ${quoted(repository)}
    static let sourceFiles: [String: String] = ${sourceFiles}
    static let caseDefinitions: [String: Data] = ${caseDefinitions}
    static let observationPolicies: [String: Data] = ${observationPolicies}
    static let authoritativeReadPolicies: [String: Data] = ${readPolicies}
    static let authoritativeNormalizers: [String: Data] = ${normalizers}
    @MainActor static let evidencePolicies: [String: FunctionalCollectedEvidence.Policy] = ${evidencePolicies}
    static let hostedRunPins = ${functionalHostedRunPinsSwift(plan.hostedRunPins)}
    static let sourceSHA256 = ${quoted(plan.sourceSHA256)}
    static let toolchainSHA256 = ${quoted(plan.toolchainSHA256)}
    static let session = ${quoted(plan.session)}
    static let root = ${quoted(plan.root)}
    static let hostIdentifier = ${quoted(plan.hostIdentifier)}
    static let producerIdentifier = ${quoted(plan.producerIdentifier)}
    static let certificateSHA256 = Data(base64Encoded: ${quoted(plan.certificateSHA256)})!
    static let recipes: [String: Data] = ${recipes}
    static let savedReaderPolicies: [String: Data] = ${savedReaderPolicies}
    static let preparationPolicies: [String: Data] = ${preparationPolicies}
    static let policySHA256 = ${quoted(plan.policySHA256)}
    static let rolePolicies: [WorkerFixtureRolePolicy] = try! ${plan.rolePolicySwiftExpression}
    static let caseDigests: [String: String] = ${digests}
    static let operations: [String: [String]] = ${operations}
    static let activationOperations: [String: String?] = ${activation}
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

export function functionalFixtureSupportCompilerArguments({
  directory,
  sources,
}) {
  assert.equal(resolve(directory), directory);
  assert(Array.isArray(sources) && sources.length > 0);
  assert.equal(new Set(sources).size, sources.length);
  for (const path of sources) {
    assert.equal(resolve(path), path);
    assert(/\/Extensions\/fixtureSupport\/[^/]+\.swift$/.test(path));
    assert(!path.endsWith("/Package.swift"));
  }
  return Object.freeze([
    "swiftc",
    "-target",
    "arm64-apple-macosx14.0",
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
    ...sources,
    "-emit-module-path",
    join(directory, "WorkerFixtureSupport.swiftmodule"),
    "-o",
    join(directory, "libWorkerFixtureSupport.a"),
  ]);
}

export async function buildFunctionalProducer({
  repository,
  plan,
  compilation,
  environment = process.env,
}) {
  environment = Object.freeze({ ...environment });
  functionalProducerPlanForBuild(plan);
  admitFunctionalRunner(environment, plan.sourceCommit);
  assert.equal(process.platform, "darwin");
  assert.equal(process.arch, "arm64");
  const {
    functionalCompilationForBuilder,
    prepareFunctionalDocsDependency,
    functionalDocsDependencyForBuilder,
    observeFunctionalDocsDependency,
  } = await import("./functional-build.mjs");
  const compiled = await functionalCompilationForBuilder(compilation);
  assert.equal(compiled.sourceCommit, plan.sourceCommit);
  assert.equal(compiled.root, plan.root);
  assert.equal(compiled.source.sha256, plan.sourceSHA256);
  assert.equal(compiled.toolchain.sha256, plan.toolchainSHA256);
  assert.deepEqual(compiled.toolchain.bytes, plan.toolchain.bytes);
  const { observeFunctionalActiveJob, functionalActiveJobBuildPins } =
    await import("./controller.mjs");
  const activeJob = await observeFunctionalActiveJob({
    repository,
    sourceCommit: plan.sourceCommit,
    environment,
  });
  assert.deepEqual(functionalActiveJobBuildPins(activeJob), plan.hostedRunPins);
  assert.equal(await realpath(repository), repository);
  await requireFunctionalPrivateDirectory(plan.root);
  const run = (file, args) =>
    execFileSync(
      file,
      file === "xcrun" && args[0] === "swiftc"
        ? ["swiftc", "-target", "arm64-apple-macosx26.0", ...args.slice(1)]
        : args,
      {
        cwd: repository,
        env: environment,
        timeout: 600_000,
        maxBuffer: 16_777_216,
        stdio: ["ignore", "pipe", "pipe"],
      },
    );
  assert.equal(
    run("git", ["rev-parse", "HEAD"]).toString().trim(),
    plan.sourceCommit,
  );
  assert.equal(
    run("git", ["status", "--porcelain", "--untracked-files=no"]).length,
    0,
  );
  await verifyFunctionalSourcePins(repository, plan.sourcePins);
  const docsDependency = await prepareFunctionalDocsDependency({
    compilation,
    plan,
  });
  const docs = await functionalDocsDependencyForBuilder({
    compilation,
    plan,
    dependency: docsDependency,
  });
  assert.equal(docs.sourceCommit, plan.sourceCommit);
  assert.equal(docs.sourceSHA256, plan.sourceSHA256);
  assert.equal(docs.toolchainSHA256, plan.toolchainSHA256);
  const directory = join(plan.root, "Producer");
  await mkdir(directory, { mode: 0o700 });
  await requireFunctionalPrivateDirectory(directory);
  const bootstrap = join(directory, "FunctionalProducerBuild.swift");
  const bootstrapBytes = Buffer.from(
    functionalProducerBootstrapSource(plan, repository),
  );
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
  execFileSync(
    "xcrun",
    functionalFixtureSupportCompilerArguments({
      directory: supportDirectory,
      sources: supportSources.map(({ path }) =>
        join(compiled.sourceRepository, path),
      ),
    }),
    {
      cwd: repository,
      env: environment,
      timeout: 600000,
      maxBuffer: 16777216,
      stdio: ["ignore", "pipe", "pipe"],
    },
  );
  const catalogDirectory = join(directory, "ExtensionMarketplace");
  await mkdir(catalogDirectory, { mode: 0o700 });
  await requireFunctionalPrivateDirectory(catalogDirectory);
  const catalogLibrary = join(catalogDirectory, "libExtensionMarketplace.a");
  for (const path of functionalProducerCatalogSources)
    assert(
      plan.sourcePins.files.some((pin) => pin.path === path),
      `Missing source-owned catalog dependency ${path}`,
    );
  run("xcrun", [
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
    ...functionalProducerCatalogSources.map((path) =>
      join(compiled.sourceRepository, path),
    ),
    "-emit-module-path",
    join(catalogDirectory, "ExtensionMarketplace.swiftmodule"),
    "-o",
    catalogLibrary,
  ]);
  await functionalDocsDependencyForBuilder({
    compilation,
    plan,
    dependency: docsDependency,
  });
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
    "-I",
    catalogDirectory,
    ...docs.compilerArguments,
    "-framework",
    "ApplicationServices",
    "-framework",
    "Security",
    ...[...plan.sources, ...functionalProducerMediaSources].map((path) =>
      join(compiled.sourceRepository, path),
    ),
    join(
      compiled.sourceRepository,
      "Tests/HostedFunctionalActions/HostSources/FunctionalHostSocket.swift",
    ),
    join(compiled.sourceRepository, contextPath),
    bootstrap,
    supportLibrary,
    catalogLibrary,
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
    join(
      compiled.sourceRepository,
      "Tests/HostedFunctionalActions/ProducerSources/FunctionalSignatureProbe.swift",
    ),
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
  await functionalDocsDependencyForBuilder({
    compilation,
    plan,
    dependency: docsDependency,
  });
  await verifyFunctionalSourcePins(repository, plan.sourcePins);
  await chmod(plan.executable, 0o500);
  await chmod(probe, 0o500);
  const receipt = freezePlan({
    schema: 2,
    sourceCommit: plan.sourceCommit,
    session: plan.session,
    source: compiled.source,
    toolchain: compiled.toolchain,
    sourcePins: plan.sourcePins.files,
    bootstrapSHA256: sha(bootstrapBytes),
    policySHA256: plan.policySHA256,
    signatureProbe: {
      path: probe,
      executableSHA256: sha(await readFile(probe)),
    },
    fixtureSupport: {
      module: "WorkerFixtureSupport",
      targetTriple: "arm64-apple-macosx14.0",
      swiftVersion: "5",
      functionalFixture: true,
      sources: supportSources,
      librarySHA256: sha(await readFile(supportLibrary)),
      moduleSHA256: sha(
        await readFile(
          join(supportDirectory, "WorkerFixtureSupport.swiftmodule"),
        ),
      ),
    },
    catalog: {
      module: "ExtensionMarketplace",
      sources: functionalProducerCatalogSources.map((path) =>
        plan.sourcePins.files.find((pin) => pin.path === path),
      ),
      librarySHA256: sha(await readFile(catalogLibrary)),
    },
    docs: {
      module: "EdithDocsWorker",
      sourceCommit: docs.sourceCommit,
      sourceSHA256: docs.sourceSHA256,
      toolchainSHA256: docs.toolchainSHA256,
      signature: docs.signature,
      artifacts: docs.dependencyArtifacts,
      dependencies: docs.dependencySources,
    },
    producer: {
      path: plan.executable,
      executableSHA256: sha(await readFile(plan.executable)),
      certificateSHA256: plan.certificateSHA256,
      requirement: `identifier "${plan.producerIdentifier}"`,
    },
    producerIdentifier: plan.producerIdentifier,
    certificateSHA256: plan.certificateSHA256,
    scope:
      "independently source-built synthetic-development producer; no downloaded UI proof",
  });
  await writeFile(
    join(directory, "build-receipt.json"),
    functionalCanonicalJSON({
      ...receipt,
      source: { sha256: receipt.source.sha256 },
      toolchain: { sha256: receipt.toolchain.sha256 },
    }),
    { mode: 0o600, flag: "wx" },
  );
  retainFunctionalProducerBuild(
    receipt,
    plan,
    compilation,
    docsDependency,
    observeFunctionalDocsDependency,
  );
  const { retainFunctionalRoleProducer } = await import(
    "./functional-build.mjs"
  );
  await retainFunctionalRoleProducer({ compilation, receipt });
  return receipt;
}

function retainFunctionalProducerBuild(
  receipt,
  plan,
  compilation,
  docsDependency,
  observeDocs,
) {
  producerBuilds.set(
    receipt,
    Object.freeze({ plan, compilation, docsDependency, observeDocs }),
  );
}

export function functionalProducerBuildForLaunch(receipt) {
  const state = producerBuilds.get(receipt);
  assert(state, "Expected source-built signed producer receipt");
  state.observeDocs({
    compilation: state.compilation,
    plan: state.plan,
    dependency: state.docsDependency,
  });
  return state;
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
    MACOSX_DEPLOYMENT_TARGET: "26.0",
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

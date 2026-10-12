import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { functionalCanonicalJSON } from "./contract.mjs";
import { functionalActionOwners } from "./owners.mjs";

const hash = /^[0-9a-f]{64}$/;
const source = /^[0-9a-f]{40}$/;
const uuid =
  /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;

function exact(value, fields) {
  assert(value && Object.getPrototypeOf(value) === Object.prototype);
  assert.deepEqual(Object.keys(value).sort(), [...fields].sort());
}

function bytes(value) {
  assert.match(value, /^[A-Za-z0-9+/]{43}=$/);
  const result = Buffer.from(value, "base64");
  assert.equal(result.length, 32);
  assert.equal(result.toString("base64"), value);
  return result;
}

function canonicalPath(value) {
  assert(
    typeof value === "string" && value.startsWith("/") && value.length <= 4096,
  );
  assert(!value.endsWith("/") && !value.includes("//"));
  assert(
    [...value].every(
      (character) =>
        character.charCodeAt(0) >= 32 && character.charCodeAt(0) < 127,
    ),
  );
  assert(
    !value
      .split("/")
      .slice(1)
      .some((part) => ["", ".", ".."].includes(part)),
  );
}

function swiftString(value) {
  assert(typeof value === "string");
  return `"${value.replaceAll("\\", "\\\\").replaceAll('"', '\\"')}"`;
}

function fileScopeSource(scope) {
  exact(scope, [
    "name",
    "kind",
    "purpose",
    "root",
    "components",
    "maximumBytes",
    "maximumEntries",
    "initialState",
    "allowedStates",
    "immutableFiles",
    "mutableFiles",
  ]);
  assert.match(scope.name, /^[A-Za-z0-9_.-]{1,256}$/);
  assert(["file", "directory"].includes(scope.kind));
  const purposes = {
    "immutable-input": "immutableInput",
    "mutable-state": "mutableState",
    "initially-absent-output": "initiallyAbsentOutput",
  };
  const roots = {
    "owner-home": "ownerHome",
    "owner-data": "ownerData",
    "owner-inputs": "ownerInputs",
    "owner-outputs": "ownerOutputs",
  };
  assert(
    Object.hasOwn(purposes, scope.purpose) && Object.hasOwn(roots, scope.root),
  );
  const component = (value) => {
    assert(
      typeof value === "string" && value.length > 0 && value.length <= 256,
    );
    assert(
      ![".", ".."].includes(value) &&
        !value.includes("/") &&
        !value.includes("\\"),
    );
    assert(
      [...value].every((character) => {
        const code = character.charCodeAt(0);
        return code >= 32 && code < 127;
      }),
    );
  };
  const relative = (components) => {
    assert(
      Array.isArray(components) &&
        components.length > 0 &&
        components.length <= 32,
    );
    components.forEach(component);
    assert(components.join("/").length <= 4096);
  };
  const maximum = (value, limit, zero = false) => {
    assert(
      Number.isSafeInteger(value) && value >= (zero ? 0 : 1) && value <= limit,
    );
  };
  const states = (value) => {
    assert(["present", "absent"].includes(value.initialState));
    assert(
      Array.isArray(value.allowedStates) &&
        value.allowedStates.length > 0 &&
        value.allowedStates.length <= 2,
    );
    assert(
      value.allowedStates.every((state) =>
        ["present", "absent"].includes(state),
      ),
    );
    assert.equal(new Set(value.allowedStates).size, value.allowedStates.length);
    assert(value.allowedStates.includes(value.initialState));
  };
  maximum(scope.maximumBytes, 268435456, true);
  maximum(scope.maximumEntries, 4096, true);
  states(scope);
  assert(
    Array.isArray(scope.components) &&
      scope.components.length > 0 &&
      scope.components.length <= 32,
  );
  let sessions = 0,
    phases = 0,
    defaults = 0;
  const components = scope.components.map((value) => {
    assert(value && Object.getPrototypeOf(value) === Object.prototype);
    if (Object.hasOwn(value, "literal")) {
      exact(value, ["literal"]);
      component(value.literal);
      return `.literal(${swiftString(value.literal)})`;
    }
    if (Object.hasOwn(value, "sessionUUID")) {
      exact(value, ["sessionUUID"]);
      assert(["lowercase", "uppercase"].includes(value.sessionUUID));
      sessions += 1;
      return `.sessionUUID(.${value.sessionUUID})`;
    }
    if (Object.hasOwn(value, "workerDefaultsPlist")) {
      exact(value, ["workerDefaultsPlist"]);
      assert(["engine", "ui"].includes(value.workerDefaultsPlist));
      defaults += 1;
      return `.workerDefaultsPlist(.${value.workerDefaultsPlist})`;
    }
    exact(value, ["phase"]);
    assert.equal(value.phase, true);
    phases += 1;
    return ".phase";
  });
  assert(sessions <= 1 && phases <= 1 && defaults <= 1);
  if (defaults > 0) {
    assert.equal(scope.kind, "file");
    assert.equal(scope.purpose, "mutable-state");
    assert.equal(scope.root, "owner-home");
    assert.equal(scope.components.length, 3);
    assert.deepEqual(scope.components.slice(0, 2), [
      { literal: "Library" },
      { literal: "Preferences" },
    ]);
    exact(scope.components[2], ["workerDefaultsPlist"]);
  }
  assert(
    Array.isArray(scope.immutableFiles) && Array.isArray(scope.mutableFiles),
  );
  const immutableFiles = scope.immutableFiles.map((file) => {
    exact(file, ["components", "maximumBytes"]);
    relative(file.components);
    maximum(file.maximumBytes, 268435456);
    return `try WorkerFixtureImmutableFileScope(components: [${file.components.map(swiftString).join(", ")}], maximumBytes: ${file.maximumBytes})`;
  });
  const mutableFiles = scope.mutableFiles.map((file) => {
    exact(file, [
      "components",
      "maximumBytes",
      "initialState",
      "allowedStates",
    ]);
    relative(file.components);
    maximum(file.maximumBytes, 268435456);
    states(file);
    return `try WorkerFixtureMutableFileScope(components: [${file.components.map(swiftString).join(", ")}], maximumBytes: ${file.maximumBytes}, initialState: .${file.initialState}, allowedStates: [${file.allowedStates.map((state) => `.${state}`).join(", ")}])`;
  });
  if (scope.kind === "file") {
    maximum(scope.maximumBytes, 268435456);
    assert.equal(scope.maximumEntries, 1);
    assert.equal(immutableFiles.length + mutableFiles.length, 0);
  } else {
    assert.equal(scope.initialState, "present");
    assert.deepEqual(scope.allowedStates, ["present"]);
    const files = [...scope.immutableFiles, ...scope.mutableFiles];
    assert(files.length <= 4096);
    if (files.length === 0) {
      assert.equal(scope.maximumBytes, 0);
      assert.equal(scope.maximumEntries, 0);
    } else {
      assert(scope.maximumBytes > 0 && scope.maximumEntries > 0);
      assert(
        files.reduce((sum, file) => sum + file.maximumBytes, 0) <=
          scope.maximumBytes,
      );
      const leaves = new Set(
        files.map((file) => file.components.join("/").toLowerCase()),
      );
      assert.equal(leaves.size, files.length);
      const spellings = new Map();
      for (const file of files) {
        for (let length = 1; length <= file.components.length; length += 1) {
          const prefix = file.components.slice(0, length).join("/");
          const folded = prefix.toLowerCase();
          assert(!spellings.has(folded) || spellings.get(folded) === prefix);
          spellings.set(folded, prefix);
        }
      }
      const entries = new Set(leaves);
      for (const file of files) {
        for (let length = 1; length < file.components.length; length += 1) {
          const parent = file.components
            .slice(0, length)
            .join("/")
            .toLowerCase();
          assert(!leaves.has(parent));
          entries.add(parent);
        }
      }
      assert(entries.size <= scope.maximumEntries);
    }
  }
  if (scope.purpose === "immutable-input") {
    assert.notEqual(scope.root, "owner-outputs");
    assert.equal(scope.initialState, "present");
    assert.deepEqual(scope.allowedStates, ["present"]);
    assert.equal(mutableFiles.length, 0);
  } else if (scope.purpose === "mutable-state") {
    assert.notEqual(scope.root, "owner-inputs");
    assert.equal(immutableFiles.length, 0);
  } else {
    assert.equal(scope.root, "owner-outputs");
    assert.equal(scope.kind, "file");
    assert.equal(scope.initialState, "absent");
    assert.deepEqual([...scope.allowedStates].sort(), ["absent", "present"]);
  }
  return `try WorkerFixtureFileScope(name: ${swiftString(scope.name)}, kind: .${scope.kind}, purpose: .${purposes[scope.purpose]}, root: .${roots[scope.root]}, components: [${components.join(", ")}], maximumBytes: ${scope.maximumBytes}, maximumEntries: ${scope.maximumEntries}, initialState: .${scope.initialState}, allowedStates: [${scope.allowedStates.map((state) => `.${state}`).join(", ")}], immutableFiles: [${immutableFiles.join(", ")}], mutableFiles: [${mutableFiles.join(", ")}])`;
}

export function functionalFixtureRolePolicySource(
  policyBytes,
  admittedPolicies,
) {
  exact(admittedPolicies, [
    "sourceCommit",
    "policySHA256",
    "manifest",
    "cases",
  ]);
  assert.match(admittedPolicies.sourceCommit, source);
  assert.match(admittedPolicies.policySHA256, hash);
  assert(
    Buffer.isBuffer(policyBytes) &&
      policyBytes.length > 0 &&
      policyBytes.length <= 131072,
  );
  assert.equal(
    createHash("sha256").update(policyBytes).digest("hex"),
    admittedPolicies.policySHA256,
  );
  const readSource = (entry, maximum) => {
    assert(
      Buffer.isBuffer(entry.bytes) &&
        entry.bytes.length > 0 &&
        entry.bytes.length <= maximum,
    );
    assert.match(entry.sha256, hash);
    assert.equal(
      createHash("sha256").update(entry.bytes).digest("hex"),
      entry.sha256,
    );
  };
  exact(admittedPolicies.manifest, ["bytes", "sha256"]);
  readSource(admittedPolicies.manifest, 262144);
  const manifest = JSON.parse(
    new TextDecoder("utf-8", { fatal: true }).decode(
      admittedPolicies.manifest.bytes,
    ),
  );
  assert(Array.isArray(manifest) && manifest.length === 39);
  assert.deepEqual(
    manifest.map((entry) => entry.id).sort(),
    [...functionalActionOwners].sort(),
  );
  assert(
    Array.isArray(admittedPolicies.cases) &&
      admittedPolicies.cases.length === 39,
  );
  assert.deepEqual(
    admittedPolicies.cases.map((entry) => entry.owner).sort(),
    [...functionalActionOwners].sort(),
  );
  for (const entry of admittedPolicies.cases) {
    exact(entry, ["owner", "path", "bytes", "sha256"]);
    assert.equal(
      entry.path,
      `Tests/HostedFunctionalActions/OwnerCases/${entry.owner}ActionCase.swift`,
    );
    readSource(entry, 131072);
  }
  const policies = JSON.parse(
    new TextDecoder("utf-8", { fatal: true }).decode(policyBytes),
  );
  assert.equal(functionalCanonicalJSON(policies), policyBytes.toString("utf8"));
  assert(Array.isArray(policies) && policies.length === 39);
  assert.deepEqual(
    policies.map((entry) => entry.owner).sort(),
    [...functionalActionOwners].sort(),
  );
  const helpers = new Set([
    "keepAwake",
    "focusDim",
    "windowSweaters",
    "micMute",
    "keystrokeHighlight",
    "presenter",
    "colorPicker",
    "systemStats",
    "emoji",
    "notchShelf",
    "clipboard",
  ]);
  const token = /^[A-Za-z0-9_.-]{1,256}$/;
  const expression = policies.map((policy) => {
    exact(policy, [
      "owner",
      "primaryRole",
      "operations",
      "presentations",
      "inputs",
      "outputs",
      "fileScopes",
      "manifestSHA256",
      "caseSHA256",
    ]);
    assert.equal(policy.manifestSHA256, admittedPolicies.manifest.sha256);
    assert.equal(
      policy.caseSHA256,
      admittedPolicies.cases.find((entry) => entry.owner === policy.owner)
        .sha256,
    );
    const original = manifest.find((entry) => entry.id === policy.owner);
    assert(
      original.roles &&
        Object.getPrototypeOf(original.roles) === Object.prototype,
    );
    const primary = Object.hasOwn(original.roles, "app") ? "app" : "helper";
    assert(Object.hasOwn(original.roles, primary));
    assert.equal(policy.primaryRole, primary);
    assert.equal(primary, helpers.has(policy.owner) ? "helper" : "app");
    assert(
      Array.isArray(policy.operations) &&
        policy.operations.length > 0 &&
        policy.operations.length <= 16,
    );
    assert.equal(new Set(policy.operations).size, policy.operations.length);
    for (const operation of policy.operations) assert.match(operation, token);
    if (policy.owner === "notchShelf")
      assert.deepEqual(policy.operations, [
        "notch.settings.read",
        "notch.settings.write",
        "notchShelf.cli.catalog",
      ]);
    assert(
      Array.isArray(policy.presentations) &&
        policy.presentations.length > 0 &&
        policy.presentations.length <= 8,
    );
    const presentationKeys = new Set();
    const presentations = policy.presentations.map((presentation) => {
      exact(presentation, ["location", "section"]);
      assert(["main", "settings"].includes(presentation.location));
      assert(
        presentation.section === policy.owner ||
          (presentation.location === "settings" &&
            ["general", "appearance", "extensions", "extension"].includes(
              presentation.section,
            )),
      );
      const key = `${presentation.location}.${presentation.section}`;
      assert(!presentationKeys.has(key));
      presentationKeys.add(key);
      return `try WorkerFixturePresentationScope(location: ${swiftString(presentation.location)}, section: ${swiftString(presentation.section)})`;
    });
    assert(Array.isArray(policy.inputs) && policy.inputs.length <= 64);
    assert(Array.isArray(policy.outputs) && policy.outputs.length <= 64);
    const inputs = policy.inputs.map((input) => {
      exact(input, ["name", "maximumBytes"]);
      assert.match(input.name, token);
      assert(
        Number.isSafeInteger(input.maximumBytes) &&
          input.maximumBytes > 0 &&
          input.maximumBytes <= 268435456,
      );
      return `try WorkerFixtureInputScope(name: ${swiftString(input.name)}, maximumBytes: ${input.maximumBytes})`;
    });
    for (const output of policy.outputs) assert.match(output, token);
    assert.equal(
      new Set([...policy.inputs.map((input) => input.name), ...policy.outputs])
        .size,
      policy.inputs.length + policy.outputs.length,
    );
    assert(Array.isArray(policy.fileScopes) && policy.fileScopes.length <= 32);
    assert.equal(
      new Set(policy.fileScopes.map((scope) => scope.name)).size,
      policy.fileScopes.length,
    );
    const fileScopes = policy.fileScopes.map(fileScopeSource);
    return `try WorkerFixtureRolePolicy(owner: ${swiftString(policy.owner)}, primaryRole: .${primary}, operations: [${policy.operations.map(swiftString).join(", ")}], presentations: [${presentations.join(", ")}], inputs: [${inputs.join(", ")}], outputs: [${policy.outputs.map(swiftString).join(", ")}], fileScopes: [${fileScopes.join(", ")}], manifestSHA256: ${swiftString(policy.manifestSHA256)}, caseSHA256: ${swiftString(policy.caseSHA256)})`;
  });
  return Object.freeze({
    sourceCommit: admittedPolicies.sourceCommit,
    policySHA256: admittedPolicies.policySHA256,
    swiftExpression: `[${expression.join(",\n")}]`,
  });
}

const liveIssuers = new WeakMap();
const fixtureHosts = new WeakMap();
const digest = (value) => createHash("sha256").update(value).digest("hex");

function document(value, maximum = 65536) {
  assert(Buffer.isBuffer(value) && value.length > 0 && value.length <= maximum);
  const result = JSON.parse(
    new TextDecoder("utf-8", { fatal: true }).decode(value),
  );
  assert.equal(functionalCanonicalJSON(result), value.toString("utf8"));
  return result;
}

function positive(value) {
  assert(Number.isSafeInteger(value) && value > 0);
}

function same(value, expected) {
  assert.equal(
    functionalCanonicalJSON(value),
    functionalCanonicalJSON(expected),
  );
}

function signature(certificate, requirement) {
  bytes(certificate);
  assert(
    typeof requirement === "string" &&
      requirement.length > 0 &&
      requirement.length <= 1024,
  );
  assert(
    [...requirement].every(
      (character) =>
        character.charCodeAt(0) >= 32 && character.charCodeAt(0) < 127,
    ),
  );
}

function signing(value) {
  exact(value, [
    "path",
    "executableSHA256",
    "certificateSHA256",
    "requirement",
  ]);
  canonicalPath(value.path);
  assert.match(value.executableSHA256, hash);
  signature(value.certificateSHA256, value.requirement);
}

function provenance(value, sourceCommit, toolchain = false) {
  exact(value, ["bytes", "sha256"]);
  assert.match(value.sha256, hash);
  const parsed = document(value.bytes, toolchain ? 65536 : 16777216);
  assert.equal(digest(value.bytes), value.sha256);
  if (toolchain) {
    exact(parsed, ["swiftCompilerSHA256", "sdkSHA256", "buildSettingsSHA256"]);
    Object.values(parsed).forEach((value) => {
      assert.match(value, hash);
    });
    return parsed;
  }
  exact(parsed, ["sourceCommit", "files"]);
  assert.equal(parsed.sourceCommit, sourceCommit);
  assert(
    Array.isArray(parsed.files) &&
      parsed.files.length > 0 &&
      parsed.files.length <= 100000,
  );
  const files = new Map();
  for (const entry of parsed.files) {
    exact(entry, ["path", "sha256"]);
    assert(
      typeof entry.path === "string" &&
        entry.path.length > 0 &&
        entry.path.length <= 4096,
    );
    assert(!entry.path.startsWith("/") && !entry.path.includes("\\"));
    assert(
      !entry.path
        .split("/")
        .some((part) =>
          ["", ".", "..", ".git", ".build", "node_modules"].includes(part),
        ),
    );
    assert.match(entry.sha256, hash);
    assert(!files.has(entry.path));
    files.set(entry.path, entry.sha256);
  }
  for (const path of [
    "Extensions/manifest.json",
    ".github/workflows/hosted-functional-actions.yml",
    "Extensions/fixtureSupport/WorkerFixtureRolePolicy.swift",
    "Tests/HostedFunctionalActions/ProducerSources/FunctionalIssuer.swift",
    "Tests/HostedFunctionalActions/ProducerSources/FunctionalProducer.swift",
    "Tests/HostedFunctionalActions/ProducerSources/FunctionalSignatureProbe.swift",
    "scripts/hosted-functional-actions/fixture-trust.mjs",
    "scripts/hosted-functional-actions/producer-project.mjs",
    "scripts/hosted-functional-actions/controller.mjs",
    "scripts/hosted-functional-actions/prepare-owner.mjs",
  ])
    assert(files.has(path), `Missing immutable build source: ${path}`);
  return files;
}

function ownedProducer(value) {
  exact(value, [
    "pid",
    "birthSeconds",
    "birthMicroseconds",
    "uid",
    "executable",
    "executableSHA256",
    "certificateSHA256",
    "requirement",
  ]);
  positive(value.pid);
  positive(value.birthSeconds);
  assert(
    Number.isSafeInteger(value.birthMicroseconds) &&
      value.birthMicroseconds >= 0 &&
      value.birthMicroseconds < 1000000,
  );
  assert(Number.isSafeInteger(value.uid) && value.uid >= 0);
  signing({
    path: value.executable,
    executableSHA256: value.executableSHA256,
    certificateSHA256: value.certificateSHA256,
    requirement: value.requirement,
  });
}

function prContext(context, sourceCommit) {
  exact(context, [
    "event",
    "pullRequest",
    "mergeCommit",
    "workflow",
    "runAttempt",
  ]);
  positive(context.runAttempt);
  const repository = (value) => {
    assert.equal(value.id, 1289153439);
    assert.equal(value.full_name, "pulkitxm/edith");
  };
  repository(context.event.repository);
  assert.equal(context.event.number, 1014);
  assert(
    ["opened", "synchronize", "reopened", "ready_for_review"].includes(
      context.event.action,
    ),
  );
  const current = context.pullRequest;
  assert.equal(current.number, 1014);
  assert.equal(current.state, "open");
  assert.equal(current.merged, false);
  for (const pull of [context.event.pull_request, current]) {
    assert.equal(pull.number, 1014);
    repository(pull.head.repo);
    repository(pull.base.repo);
    assert.equal(pull.head.sha, sourceCommit);
    assert.match(pull.base.sha, source);
    assert.equal(pull.base.ref, "main");
    assert.equal(pull.head.ref, "feat/extension-marketplace");
    assert.equal(pull.base.sha, current.base.sha);
  }
  assert.equal(current.merge_commit_sha, context.mergeCommit.sha);
  assert.match(context.mergeCommit.sha, source);
  assert.notEqual(context.mergeCommit.sha, sourceCommit);
  assert.deepEqual(
    context.mergeCommit.parents.map((parent) => parent.sha),
    [current.base.sha, sourceCommit],
  );
  positive(context.workflow.id);
  assert.equal(
    context.workflow.path,
    ".github/workflows/hosted-functional-actions.yml",
  );
  assert.equal(context.workflow.state, "active");
  return {
    repositoryID: 1289153439,
    pullRequestNumber: 1014,
    sourceCommit,
    baseCommit: current.base.sha,
    mergeCommit: context.mergeCommit.sha,
    workflowID: context.workflow.id,
    runAttempt: context.runAttempt,
    headRef: current.head.ref,
    baseRef: current.base.ref,
    action: context.event.action,
  };
}

function liveJob(manifest, evidence) {
  assert.match(evidence.sourceCommit, source);
  assert.equal(manifest.sourceCommit, evidence.sourceCommit);
  const context = prContext(evidence.context, evidence.sourceCommit);
  const { run, job } = evidence;
  positive(run.id);
  positive(job.id);
  assert.equal(manifest.runID, run.id);
  assert.equal(manifest.jobID, job.id);
  assert.equal(run.head_sha, evidence.sourceCommit);
  assert.equal(run.repository.id, 1289153439);
  assert.equal(run.repository.full_name, "pulkitxm/edith");
  assert.equal(run.head_repository.id, 1289153439);
  assert.equal(run.head_repository.full_name, "pulkitxm/edith");
  assert([65671483, 320458784].includes(run.actor.id));
  assert([65671483, 320458784].includes(run.triggering_actor.id));
  assert.equal(run.event, "pull_request");
  assert(Array.isArray(run.pull_requests) && run.pull_requests.length === 1);
  const pull = run.pull_requests[0];
  assert.equal(pull.number, 1014);
  assert.equal(pull.head.sha, evidence.sourceCommit);
  assert.equal(pull.base.sha, evidence.context.pullRequest.base.sha);
  assert.equal(pull.head.repo.id, 1289153439);
  assert.equal(pull.base.repo.id, 1289153439);
  assert.equal(run.run_attempt, evidence.context.runAttempt);
  assert.equal(run.workflow_id, evidence.context.workflow.id);
  assert.equal(run.path, ".github/workflows/hosted-functional-actions.yml");
  assert.equal(run.status, "in_progress");
  assert.equal(run.conclusion, null);
  assert.equal(job.run_id, run.id);
  assert.equal(job.run_attempt, evidence.context.runAttempt);
  assert(
    typeof job.runner_name === "string" &&
      job.runner_name.trim().length > 0 &&
      job.runner_name.length <= 256,
  );
  assert(
    [...job.runner_name].every(
      (character) =>
        character.charCodeAt(0) >= 32 && character.charCodeAt(0) < 127,
    ),
  );
  assert.equal(job.head_sha, evidence.sourceCommit);
  assert.equal(job.name, "functional-build");
  assert.equal(job.status, "in_progress");
  assert.equal(job.conclusion, null);
  assert(
    Array.isArray(job.labels) &&
      job.labels.includes("macos-26") &&
      !job.labels.includes("self-hosted"),
  );
  return {
    ...context,
    runID: run.id,
    jobID: job.id,
    actorID: run.actor.id,
    triggeringActorID: run.triggering_actor.id,
    runnerName: job.runner_name,
  };
}

export function admitFunctionalLiveIssuer(
  manifestBytes,
  evidence,
  observeOwnedProducer,
) {
  exact(evidence, [
    "sourceCommit",
    "run",
    "job",
    "context",
    "build",
    "launch",
    "bootstrap",
  ]);
  assert.equal(typeof observeOwnedProducer, "function");
  const manifest = document(manifestBytes);
  exact(manifest, [
    "schema",
    "sourceCommit",
    "runID",
    "jobID",
    "session",
    "root",
    "hostIdentifier",
    "issuerPublicKey",
    "policySHA256",
    "producer",
    "signing",
  ]);
  assert.equal(manifest.schema, 2);
  liveJob(manifest, evidence);
  assert.match(manifest.session, uuid);
  canonicalPath(manifest.root);
  assert(manifest.root.endsWith(`/functional-fixture-${manifest.session}`));
  assert.equal(
    manifest.hostIdentifier,
    `com.pulkit.edith.tests.worker-${manifest.session}`,
  );
  bytes(manifest.issuerPublicKey);
  assert.match(manifest.policySHA256, hash);
  exact(manifest.producer, [
    "path",
    "executableSHA256",
    "certificateSHA256",
    "requirement",
    "sourceSHA256",
    "toolchainSHA256",
  ]);
  const { sourceSHA256, toolchainSHA256, ...producer } = manifest.producer;
  signing(producer);
  assert.equal(producer.path, `${manifest.root}/Producer/functional-producer`);
  exact(manifest.signing, [
    "hostRequirement",
    "hostCertificateSHA256",
    "workerCertificateSHA256",
    "roleCertificateSHA256",
  ]);
  signature(
    manifest.signing.hostCertificateSHA256,
    manifest.signing.hostRequirement,
  );
  bytes(manifest.signing.workerCertificateSHA256);
  bytes(manifest.signing.roleCertificateSHA256);
  exact(evidence.build, [
    "sourceCommit",
    "policySHA256",
    "source",
    "toolchain",
    "producer",
  ]);
  assert.equal(evidence.build.sourceCommit, manifest.sourceCommit);
  assert.equal(evidence.build.policySHA256, manifest.policySHA256);
  const files = provenance(evidence.build.source, manifest.sourceCommit);
  provenance(evidence.build.toolchain, manifest.sourceCommit, true);
  assert.equal(sourceSHA256, evidence.build.source.sha256);
  assert.equal(toolchainSHA256, evidence.build.toolchain.sha256);
  same(evidence.build.producer, producer);
  ownedProducer(evidence.launch);
  same(
    {
      path: evidence.launch.executable,
      executableSHA256: evidence.launch.executableSHA256,
      certificateSHA256: evidence.launch.certificateSHA256,
      requirement: evidence.launch.requirement,
    },
    producer,
  );
  exact(evidence.bootstrap, [
    "schema",
    "kind",
    "sourceCommit",
    "session",
    "issuerPublicKey",
    "producer",
  ]);
  assert.equal(evidence.bootstrap.schema, 1);
  assert.equal(evidence.bootstrap.kind, "bootstrap");
  assert.equal(evidence.bootstrap.sourceCommit, manifest.sourceCommit);
  assert.equal(evidence.bootstrap.session, manifest.session);
  assert.equal(evidence.bootstrap.issuerPublicKey, manifest.issuerPublicKey);
  const { certificateSHA256, requirement, ...birth } = evidence.launch;
  same(evidence.bootstrap.producer, birth);
  const launch = structuredClone(evidence.launch);
  const admitted = Object.freeze({
    sourceCommit: manifest.sourceCommit,
    runID: manifest.runID,
    jobID: manifest.jobID,
    manifestSHA256: digest(manifestBytes),
  });
  liveIssuers.set(admitted, {
    manifest,
    files,
    launch,
    jobBindings: liveJob(manifest, evidence),
    observeOwnedProducer,
    bootstrapHashes: new Set(),
  });
  requireLiveIssuer(admitted);
  return admitted;
}

function requireLiveIssuer(admitted) {
  const state = liveIssuers.get(admitted);
  assert(state, "Expected independently admitted live issuer");
  const observed = state.observeOwnedProducer();
  exact(observed, ["sourceCommit", "run", "job", "context", "producer"]);
  same(liveJob(state.manifest, observed), state.jobBindings);
  ownedProducer(observed.producer);
  same(observed.producer, state.launch);
  return state;
}

function admittedPolicy(policyBytes, admittedPolicies, issuer) {
  const policy = functionalFixtureRolePolicySource(
    policyBytes,
    admittedPolicies,
  );
  assert.equal(policy.sourceCommit, issuer.manifest.sourceCommit);
  assert.equal(policy.policySHA256, issuer.manifest.policySHA256);
  assert.equal(
    issuer.files.get("Extensions/manifest.json"),
    admittedPolicies.manifest.sha256,
  );
  for (const entry of admittedPolicies.cases)
    assert.equal(issuer.files.get(entry.path), entry.sha256);
  return policy;
}

function trustSource(manifest, policy, host) {
  const data = (value) => `Data(base64Encoded: ${swiftString(value)})!`;
  const arguments_ = [
    `sourceCommit: ${swiftString(manifest.sourceCommit)}`,
    `session: ${swiftString(manifest.session)}`,
    `root: ${swiftString(manifest.root)}`,
    `issuerKey: ${data(manifest.issuerPublicKey)}`,
    ...(host
      ? [`hostExecutableSHA256: ${swiftString(host.executableSHA256)}`]
      : []),
    `hostRequirement: ${swiftString(manifest.signing.hostRequirement)}`,
    `hostCertificateSHA256: ${data(manifest.signing.hostCertificateSHA256)}`,
    `workerCertificateSHA256: ${data(manifest.signing.workerCertificateSHA256)}`,
    `roleCertificateSHA256: ${data(manifest.signing.roleCertificateSHA256)}`,
    `producerExecutable: ${swiftString(manifest.producer.path)}`,
    `producerExecutableSHA256: ${swiftString(manifest.producer.executableSHA256)}`,
    `rolePolicies: ${policy.swiftExpression}`,
  ];
  const type = host ? "UI" : "Bootstrap";
  const sourceText = `import Foundation\n\npublic enum WorkerFixture${type}TrustAnchor {\n    public static let admitted: WorkerFixture${type}Trust? = try! WorkerFixture${type}Trust(\n        ${arguments_.join(",\n        ")}\n    )\n}\n`;
  return Object.freeze({
    sourceCommit: manifest.sourceCommit,
    source: sourceText,
    sourceSHA256: digest(sourceText),
    generatedPath: `Extensions/fixtureSupport/WorkerFixture${type}TrustAnchor.swift`,
    scope:
      "independently admitted same-job source build constants before compilation and signing",
  });
}

export function functionalFixtureBootstrapTrustSource(
  manifestBytes,
  admittedIssuer,
  policyBytes,
  admittedPolicies,
) {
  const issuer = requireLiveIssuer(admittedIssuer);
  assert.equal(digest(manifestBytes), admittedIssuer.manifestSHA256);
  same(document(manifestBytes), issuer.manifest);
  const policy = admittedPolicy(policyBytes, admittedPolicies, issuer);
  const result = trustSource(issuer.manifest, policy);
  issuer.bootstrapHashes.add(result.sourceSHA256);
  return result;
}

export function admitFunctionalFixtureHost(
  artifactBytes,
  admittedIssuer,
  evidence,
  observeOwnedHost,
) {
  const issuer = requireLiveIssuer(admittedIssuer);
  assert.equal(typeof observeOwnedHost, "function");
  exact(evidence, [
    "sourceCommit",
    "runID",
    "jobID",
    "source",
    "toolchain",
    "bootstrapSHA256",
    "host",
    "hostProcess",
  ]);
  assert.equal(evidence.sourceCommit, admittedIssuer.sourceCommit);
  assert.equal(evidence.runID, admittedIssuer.runID);
  assert.equal(evidence.jobID, admittedIssuer.jobID);
  provenance(evidence.source, admittedIssuer.sourceCommit);
  provenance(evidence.toolchain, admittedIssuer.sourceCommit, true);
  assert.equal(evidence.source.sha256, issuer.manifest.producer.sourceSHA256);
  assert(
    issuer.bootstrapHashes.has(evidence.bootstrapSHA256),
    "Host must compile admitted bootstrap source first",
  );
  const artifact = document(artifactBytes);
  exact(artifact, [
    "schema",
    "sourceCommit",
    "session",
    "root",
    "hostIdentifier",
    "issuerPublicKey",
    "issuerManifestSHA256",
    "host",
    "producer",
    "workerCertificateSHA256",
    "roleCertificateSHA256",
  ]);
  assert.equal(artifact.schema, 2);
  for (const field of [
    "sourceCommit",
    "session",
    "root",
    "hostIdentifier",
    "issuerPublicKey",
  ])
    assert.equal(artifact[field], issuer.manifest[field]);
  assert.equal(artifact.issuerManifestSHA256, admittedIssuer.manifestSHA256);
  const {
    sourceSHA256,
    toolchainSHA256,
    certificateSHA256,
    requirement,
    ...producer
  } = issuer.manifest.producer;
  same(artifact.producer, producer);
  signing(artifact.host);
  assert.equal(artifact.host.path, `${artifact.root}/Fixture.app`);
  assert.equal(
    artifact.host.certificateSHA256,
    issuer.manifest.signing.hostCertificateSHA256,
  );
  assert.equal(
    artifact.host.requirement,
    issuer.manifest.signing.hostRequirement,
  );
  assert.equal(
    artifact.workerCertificateSHA256,
    issuer.manifest.signing.workerCertificateSHA256,
  );
  assert.equal(
    artifact.roleCertificateSHA256,
    issuer.manifest.signing.roleCertificateSHA256,
  );
  same(evidence.host, artifact.host);
  ownedProducer(evidence.hostProcess);
  assert.equal(
    evidence.hostProcess.executable,
    artifact.host.path + "/Contents/MacOS/Edith",
  );
  assert.equal(
    evidence.hostProcess.executableSHA256,
    artifact.host.executableSHA256,
  );
  assert.equal(
    evidence.hostProcess.certificateSHA256,
    artifact.host.certificateSHA256,
  );
  assert.equal(evidence.hostProcess.requirement, artifact.host.requirement);
  assert.equal(evidence.hostProcess.uid, issuer.launch.uid);
  assert.notEqual(evidence.hostProcess.pid, issuer.launch.pid);
  const expected = {
    sourceCommit: admittedIssuer.sourceCommit,
    runID: admittedIssuer.runID,
    jobID: admittedIssuer.jobID,
    sourceSHA256: evidence.source.sha256,
    toolchainSHA256: evidence.toolchain.sha256,
    bootstrapSHA256: evidence.bootstrapSHA256,
    host: structuredClone(evidence.host),
    hostProcess: structuredClone(evidence.hostProcess),
  };
  same(observeOwnedHost(), expected);
  const admitted = Object.freeze({
    sourceCommit: admittedIssuer.sourceCommit,
    runID: admittedIssuer.runID,
    jobID: admittedIssuer.jobID,
    artifactSHA256: digest(artifactBytes),
  });
  fixtureHosts.set(admitted, {
    admittedIssuer,
    artifact,
    expected,
    observeOwnedHost,
  });
  return admitted;
}

export function functionalFixtureTrustSource(
  artifactBytes,
  admittedArtifact,
  policyBytes,
  admittedPolicies,
) {
  const host = fixtureHosts.get(admittedArtifact);
  assert(host, "Expected independently admitted same-job Host build");
  const issuer = requireLiveIssuer(host.admittedIssuer);
  assert.equal(digest(artifactBytes), admittedArtifact.artifactSHA256);
  same(document(artifactBytes), host.artifact);
  same(host.observeOwnedHost(), host.expected);
  const policy = admittedPolicy(policyBytes, admittedPolicies, issuer);
  const result = trustSource(issuer.manifest, policy, host.artifact.host);
  return Object.freeze({
    ...result,
    artifactSHA256: admittedArtifact.artifactSHA256,
  });
}

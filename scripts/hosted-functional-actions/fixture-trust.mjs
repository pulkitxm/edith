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
    phases = 0;
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
    exact(value, ["phase"]);
    assert.equal(value.phase, true);
    phases += 1;
    return ".phase";
  });
  assert(sessions <= 1 && phases <= 1);
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

export function functionalFixtureTrustSource(
  artifactBytes,
  admittedArtifact,
  policyBytes,
  admittedPolicies,
) {
  const policy = functionalFixtureRolePolicySource(
    policyBytes,
    admittedPolicies,
  );
  exact(admittedArtifact, [
    "sourceCommit",
    "runID",
    "jobID",
    "artifactID",
    "artifactSHA256",
  ]);
  assert.match(admittedArtifact.sourceCommit, source);
  assert.equal(policy.sourceCommit, admittedArtifact.sourceCommit);
  assert.match(admittedArtifact.artifactSHA256, hash);
  for (const field of ["runID", "jobID", "artifactID"])
    assert(
      Number.isSafeInteger(admittedArtifact[field]) &&
        admittedArtifact[field] > 0,
    );
  assert(
    Buffer.isBuffer(artifactBytes) &&
      artifactBytes.length > 0 &&
      artifactBytes.length <= 65536,
  );
  assert.equal(
    createHash("sha256").update(artifactBytes).digest("hex"),
    admittedArtifact.artifactSHA256,
  );
  const artifact = JSON.parse(
    new TextDecoder("utf-8", { fatal: true }).decode(artifactBytes),
  );
  assert.equal(
    functionalCanonicalJSON(artifact),
    artifactBytes.toString("utf8"),
  );
  exact(artifact, [
    "schema",
    "sourceCommit",
    "session",
    "root",
    "hostIdentifier",
    "issuerPublicKey",
    "host",
    "producer",
    "workerCertificateSHA256",
    "roleCertificateSHA256",
  ]);
  assert.equal(artifact.schema, 1);
  assert.equal(artifact.sourceCommit, admittedArtifact.sourceCommit);
  assert.match(artifact.session, uuid);
  canonicalPath(artifact.root);
  assert(artifact.root.endsWith(`/functional-fixture-${artifact.session}`));
  assert.equal(
    artifact.hostIdentifier,
    `com.pulkit.edith.tests.worker-${artifact.session}`,
  );
  exact(artifact.host, [
    "path",
    "executableSHA256",
    "certificateSHA256",
    "requirement",
  ]);
  assert.equal(artifact.host.path, `${artifact.root}/Fixture.app`);
  assert.match(artifact.host.executableSHA256, hash);
  bytes(artifact.host.certificateSHA256);
  assert(
    typeof artifact.host.requirement === "string" &&
      artifact.host.requirement.length > 0 &&
      artifact.host.requirement.length <= 1024,
  );
  assert(
    [...artifact.host.requirement].every(
      (character) =>
        character.charCodeAt(0) >= 32 && character.charCodeAt(0) < 127,
    ),
  );
  exact(artifact.producer, ["path", "executableSHA256"]);
  assert.equal(
    artifact.producer.path,
    `${artifact.root}/Producer/functional-producer`,
  );
  assert.match(artifact.producer.executableSHA256, hash);
  bytes(artifact.issuerPublicKey);
  bytes(artifact.workerCertificateSHA256);
  bytes(artifact.roleCertificateSHA256);
  const data = (value) => `Data(base64Encoded: ${swiftString(value)})!`;
  const arguments_ = [
    `sourceCommit: ${swiftString(artifact.sourceCommit)}`,
    `session: ${swiftString(artifact.session)}`,
    `root: ${swiftString(artifact.root)}`,
    `issuerKey: ${data(artifact.issuerPublicKey)}`,
    `hostExecutableSHA256: ${swiftString(artifact.host.executableSHA256)}`,
    `hostRequirement: ${swiftString(artifact.host.requirement)}`,
    `hostCertificateSHA256: ${data(artifact.host.certificateSHA256)}`,
    `workerCertificateSHA256: ${data(artifact.workerCertificateSHA256)}`,
    `roleCertificateSHA256: ${data(artifact.roleCertificateSHA256)}`,
    `producerExecutable: ${swiftString(artifact.producer.path)}`,
    `producerExecutableSHA256: ${swiftString(artifact.producer.executableSHA256)}`,
    `rolePolicies: ${policy.swiftExpression}`,
  ];
  return Object.freeze({
    sourceCommit: artifact.sourceCommit,
    artifactSHA256: admittedArtifact.artifactSHA256,
    source: `import Foundation\n\npublic enum WorkerFixtureUITrustAnchor {\n    public static let admitted: WorkerFixtureUITrust? = try! WorkerFixtureUITrust(\n        ${arguments_.join(",\n        ")}\n    )\n}\n`,
    generatedPath: "Extensions/fixtureSupport/WorkerFixtureUITrustAnchor.swift",
    scope:
      "independently admitted fixture build constants before compilation and signing",
  });
}

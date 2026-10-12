import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { readFile } from "node:fs/promises";
import test from "node:test";
import { fileURLToPath } from "node:url";
import {
  createFunctionalRoleBuild,
  functionalRoleBuildEnvironment,
  functionalRoleCarrierInput,
  functionalRoleCompilerInputs,
  functionalRoleVerificationInput,
  probeFunctionalRoleBinding,
  retainFunctionalRoleProducer,
} from "./functional-build.mjs";
import { functionalPairPlanForBuilder } from "./prepare-owner.mjs";

const binding = () => ({
  status: "ready",
  sourceCommit: "a".repeat(40),
  sourceSHA256: "b".repeat(64),
  toolchainSHA256: "c".repeat(64),
  root: "/synthetic/functional-session",
  owner: "keepAwake",
  version: "1.0.0",
  sourceRoot: "/synthetic/functional-session/source-keepAwake-1.0.0",
  output: "/synthetic/functional-session/packages-keepAwake-1.0.0",
  hostExecutableSHA256: "d".repeat(64),
  librarySHA256: "e".repeat(64),
  moduleSHA256: "f".repeat(64),
  fixtureSupportTarget: "arm64-apple-macosx14.0",
});

for (const [name, mutation] of Object.entries({
  revoked: { status: "closed" },
  stale: { status: "failed" },
  foreignSource: { sourceCommit: "0".repeat(40) },
  changedSource: { sourceSHA256: "0".repeat(64) },
  changedToolchain: { toolchainSHA256: "0".repeat(64) },
  foreignSession: { root: "/synthetic/other-session" },
  foreignOwner: { owner: "calendar" },
  foreignVersion: { version: "1.1.0" },
  foreignArchive: { sourceRoot: "/synthetic/other-archive" },
  foreignOutput: { output: "/synthetic/other-output" },
  replacedHost: { hostExecutableSHA256: "0".repeat(64) },
  replacedLibrary: { librarySHA256: "0".repeat(64) },
  replacedModule: { moduleSHA256: "0".repeat(64) },
  higherDeploymentModule: { fixtureSupportTarget: "arm64-apple-macosx26.0" },
})) {
  test(`role compiler refuses ${name} before invoking compilation`, async () => {
    let compiles = 0;
    await assert.rejects(
      probeFunctionalRoleBinding({
        expected: binding(),
        runtime: {
          observe: async () => ({ ...binding(), ...mutation }),
          compile: async () => {
            compiles += 1;
          },
        },
      }),
    );
    assert.equal(compiles, 0);
  });
}

test("role compiler refuses lifetime revocation after compilation", async () => {
  let compiled = false;
  await assert.rejects(
    probeFunctionalRoleBinding({
      expected: binding(),
      runtime: {
        observe: async () => ({
          ...binding(),
          status: compiled ? "closed" : "ready",
        }),
        compile: async () => {
          compiled = true;
        },
      },
    }),
  );
  assert.equal(compiled, true);
});

test("role binding probe never grants real compiler or carrier authority", async () => {
  let compiles = 0;
  const result = await probeFunctionalRoleBinding({
    expected: binding(),
    runtime: {
      observe: async () => binding(),
      compile: async () => {
        compiles += 1;
      },
    },
  });
  assert.equal(compiles, 1);
  assert.equal(result.nativeProof, false);
  for (const capability of [
    {},
    Object.freeze({}),
    structuredClone(result),
    result,
  ]) {
    await assert.rejects(functionalRoleCompilerInputs(capability, {}));
    await assert.rejects(functionalRoleCarrierInput(capability, {}));
    await assert.rejects(functionalRoleVerificationInput(capability, {}));
    await assert.rejects(functionalRoleBuildEnvironment(capability, {}, {}));
  }
});

test("malformed binding observations cannot invoke compilation", async () => {
  for (const observed of [
    null,
    { ...binding(), extraFlags: ["-DUNSAFE"] },
    { ...binding(), moduleSHA256: undefined },
  ]) {
    let invoked = false;
    await assert.rejects(
      probeFunctionalRoleBinding({
        expected: binding(),
        runtime: {
          observe: async () => observed,
          compile: async () => {
            invoked = true;
          },
        },
      }),
    );
    assert.equal(invoked, false);
  }
});

test("plain producer, compilation and pair records grant no role authority", async () => {
  assert.throws(() => functionalPairPlanForBuilder({}));
  await assert.rejects(
    retainFunctionalRoleProducer({ compilation: {}, receipt: {} }),
  );
  await assert.rejects(
    createFunctionalRoleBuild({ compilation: {}, plan: {}, version: "1.0.0" }),
  );
});

test("QA pair uses same-process capabilities and keeps production compiler defaults", async () => {
  const source = async (path) =>
    readFile(new URL(path, import.meta.url), "utf8");
  const preparation = await source("./prepare-owner.mjs");
  assert(preparation.includes("await buildExtensionPackage({"));
  assert(
    !preparation.includes('["scripts/build-extension-package.mjs", owner]'),
  );
  const builder = await source("../build-extension-package.mjs");
  assert(builder.includes("environment = process.env"));
  assert(
    /functionalRoleBuildEnvironment\(\s*functionalRoleBuild/.test(builder),
  );
  assert(builder.includes("...fixtureFlags"));
  assert(!builder.includes("EDITH_FUNCTIONAL_FIXTURE"));
  const carrier = await source("../build-extension-ui-carrier.mjs");
  assert(carrier.includes("await readFrozenUICarrier({"));
  assert(/functionalRoleCarrierInput\(\s*functionalRoleBuild/.test(carrier));
  assert(!carrier.includes("EDITH_FUNCTIONAL_FIXTURE"));
});

test("real package and carrier entry points reject forged authority before filesystem or native work", async () => {
  const { buildExtensionPackage } = await import(
    "../build-extension-package.mjs"
  );
  const { buildExtensionUICarrier } = await import(
    "../build-extension-ui-carrier.mjs"
  );
  const inputs = {
    root: "/absent-synthetic",
    id: "keepAwake",
    version: "1.0.0",
    output: "/absent-output",
    hostApp: "/absent-host.app",
  };
  await assert.rejects(
    buildExtensionPackage({
      ...inputs,
      containedHostApp: inputs.hostApp,
      functionalRoleBuild: {},
      environment: {},
    }),
    /Expected owned functional role build capability/,
  );
  await assert.rejects(
    buildExtensionUICarrier({
      ...inputs,
      functionalInputs: inputs,
      functionalRoleBuild: {},
      environment: {},
    }),
    /Expected owned functional role build capability/,
  );
});

test("functional carrier verification counterexamples run with the role compiler suite", () => {
  execFileSync(
    "python3",
    [
      "-B",
      fileURLToPath(new URL("./verify-role-package.test.py", import.meta.url)),
    ],
    { env: process.env, stdio: "pipe", timeout: 30000, maxBuffer: 65536 },
  );
});

test("fixture support targets every admitted role minimum while the host remains at26", async () => {
  const { functionalFixtureSupportCompilerArguments } = await import(
    "./producer-project.mjs"
  );
  const { functionalCompilationArguments } = await import(
    "./functional-build.mjs"
  );
  const command = functionalFixtureSupportCompilerArguments({
    directory: "/synthetic/Producer/WorkerFixtureSupport",
    sources: [
      "/synthetic/source/Extensions/fixtureSupport/WorkerFixtureAdmission.swift",
    ],
  });
  assert.equal(
    command[command.indexOf("-target") + 1],
    "arm64-apple-macosx14.0",
  );
  assert.equal(
    command[command.indexOf("-module-name") + 1],
    "WorkerFixtureSupport",
  );
  assert.equal(command.filter((argument) => argument === "-target").length, 1);
  assert(command.includes("-DEDITH_FUNCTIONAL_FIXTURE"));
  assert(command.includes("-static"));
  const definitions = JSON.parse(
    await readFile(
      new URL("../../Extensions/manifest.json", import.meta.url),
      "utf8",
    ),
  );
  const { functionalActionOwners } = await import("./owners.mjs");
  for (const owner of functionalActionOwners) {
    const definition = definitions.find((entry) => entry.id === owner);
    assert(definition, `Missing admitted owner ${owner}`);
    assert(Number(definition.minimumSystemVersion.split(".")[0]) >= 14);
  }
  const host = functionalCompilationArguments("xcrun", [
    "swiftc",
    "Host.swift",
  ]);
  assert.equal(host[host.indexOf("-target") + 1], "arm64-apple-macosx26.0");
  for (const sources of [
    [],
    ["relative.swift"],
    ["/synthetic/source/Extensions/fixtureSupport/Package.swift"],
    ["/synthetic/foreign.swift"],
  ])
    assert.throws(() =>
      functionalFixtureSupportCompilerArguments({
        directory: "/synthetic/Producer/WorkerFixtureSupport",
        sources,
      }),
    );
});

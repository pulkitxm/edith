import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdir, writeFile } from "node:fs/promises";
import { join, resolve } from "node:path";
import { admitManagedExecution } from "./execution-contract.mjs";

const runnerKeys = [
  "GITHUB_ACTIONS",
  "RUNNER_OS",
  "RUNNER_ENVIRONMENT",
  "GITHUB_REPOSITORY",
  "GITHUB_ACTOR_ID",
  "GITHUB_EVENT_NAME",
  "GITHUB_REF",
  "GITHUB_SHA",
  "EXPECTED_SOURCE_SHA",
  "EDITH_HOSTED_MANAGED_VIEWS",
  "PUBLISH",
  "REBUILD",
  "EDITH_HOSTED_MANAGED_DIRECTORY",
  "EDITH_HOSTED_MANAGED_IDENTIFIER",
];

export function managedRunnerEnvironment(environment, fixture) {
  const result = Object.fromEntries(
    runnerKeys.map((key) => [
      key,
      key === "EDITH_HOSTED_MANAGED_DIRECTORY"
        ? fixture.directory
        : key === "EDITH_HOSTED_MANAGED_IDENTIFIER"
          ? fixture.identifier
          : environment[key],
    ]),
  );
  validateManagedRunnerEnvironment(result);
  assert.equal(fixture.sourceCommit, result.GITHUB_SHA);
  return result;
}

function validateManagedRunnerEnvironment(environment) {
  assert.deepEqual(Object.keys(environment).sort(), [...runnerKeys].sort());
  for (const value of Object.values(environment))
    assert(
      typeof value === "string" &&
        value.length <= 4096 &&
        !/[\0\r\n]/.test(value),
    );
  admitManagedExecution(environment, environment.GITHUB_SHA);
  assert.match(
    environment.EDITH_HOSTED_MANAGED_IDENTIFIER,
    /^com\.pulkit\.edith\.tests\.(worker|remote)-[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/,
  );
  assert.equal(
    resolve(environment.EDITH_HOSTED_MANAGED_DIRECTORY),
    environment.EDITH_HOSTED_MANAGED_DIRECTORY,
  );
}

export async function writeManagedUIProject(directory, environment) {
  validateManagedRunnerEnvironment(environment);
  const project = join(directory, "HostedManagedApproval.xcodeproj");
  await mkdir(join(project, "xcshareddata/xcschemes"), { recursive: true });
  const source = resolve(
    "Tests/HostedManagedViews/UITests/HostedManagedApprovalUITests.swift",
  );
  const contract = resolve(
    "Tests/HostedManagedViews/ApprovalSources/HostedManagedApprovalContract.swift",
  );
  const id = (value) => `0000000000000000000000${value}`;
  const settings = {
    SDKROOT: "macosx",
    MACOSX_DEPLOYMENT_TARGET: "14.0",
    SWIFT_VERSION: "5.0",
    ARCHS: "arm64",
    PRODUCT_NAME: "HostedManagedApproval",
    PRODUCT_BUNDLE_IDENTIFIER: "com.pulkit.edith.tests.hosted-managed-ui",
    GENERATE_INFOPLIST_FILE: "YES",
    CODE_SIGN_IDENTITY: "-",
    CODE_SIGN_STYLE: "Manual",
    ENABLE_APP_SANDBOX: "NO",
    ENABLE_HARDENED_RUNTIME: "NO",
    SKIP_INSTALL: "YES",
    TEST_TARGET_NAME: "",
    SWIFT_OPTIMIZATION_LEVEL: "-Onone",
    ENABLE_TESTING_SEARCH_PATHS: "YES",
  };
  const objects = {
    [id("01")]: {
      isa: "PBXProject",
      attributes: { LastUpgradeCheck: "2600" },
      buildConfigurationList: id("08"),
      compatibilityVersion: "Xcode 14.0",
      developmentRegion: "en",
      knownRegions: ["en"],
      mainGroup: id("02"),
      projectDirPath: "",
      projectRoot: "",
      targets: [id("04")],
    },
    [id("02")]: {
      isa: "PBXGroup",
      children: [id("03"), id("11"), id("12")],
      sourceTree: "<group>",
    },
    [id("03")]: {
      isa: "PBXFileReference",
      explicitFileType: "wrapper.cfbundle",
      path: "HostedManagedApproval.xctest",
      sourceTree: "BUILT_PRODUCTS_DIR",
    },
    [id("04")]: {
      isa: "PBXNativeTarget",
      buildConfigurationList: id("09"),
      buildPhases: [id("05")],
      buildRules: [],
      dependencies: [],
      name: "HostedManagedApproval",
      productName: "HostedManagedApproval",
      productReference: id("03"),
      productType: "com.apple.product-type.bundle.ui-testing",
    },
    [id("05")]: {
      isa: "PBXSourcesBuildPhase",
      buildActionMask: 2147483647,
      files: [id("13"), id("14")],
      runOnlyForDeploymentPostprocessing: 0,
    },
    [id("06")]: {
      isa: "XCBuildConfiguration",
      buildSettings: settings,
      name: "Debug",
    },
    [id("07")]: {
      isa: "XCBuildConfiguration",
      buildSettings: settings,
      name: "Debug",
    },
    [id("08")]: {
      isa: "XCConfigurationList",
      buildConfigurations: [id("06")],
      defaultConfigurationIsVisible: 0,
      defaultConfigurationName: "Debug",
    },
    [id("09")]: {
      isa: "XCConfigurationList",
      buildConfigurations: [id("07")],
      defaultConfigurationIsVisible: 0,
      defaultConfigurationName: "Debug",
    },
    [id("11")]: {
      isa: "PBXFileReference",
      lastKnownFileType: "sourcecode.swift",
      path: source,
      sourceTree: "<absolute>",
    },
    [id("12")]: {
      isa: "PBXFileReference",
      lastKnownFileType: "sourcecode.swift",
      path: contract,
      sourceTree: "<absolute>",
    },
    [id("13")]: { isa: "PBXBuildFile", fileRef: id("11") },
    [id("14")]: { isa: "PBXBuildFile", fileRef: id("12") },
  };
  const encode = (value) => {
    if (Array.isArray(value)) return `(${value.map(encode).join(",")})`;
    if (value && typeof value === "object")
      return `{${Object.entries(value)
        .map(([key, entry]) => `${JSON.stringify(key)} = ${encode(entry)};`)
        .join("\n")}}`;
    return JSON.stringify(value);
  };
  await writeFile(
    join(project, "project.pbxproj"),
    encode({
      archiveVersion: 1,
      classes: {},
      objectVersion: 56,
      objects,
      rootObject: id("01"),
    }),
  );
  const xml = (value) =>
    value
      .replaceAll("&", "&amp;")
      .replaceAll('"', "&quot;")
      .replaceAll("<", "&lt;");
  const variables = Object.entries(environment)
    .map(
      ([key, value]) =>
        `<EnvironmentVariable key="${xml(key)}" value="${xml(value)}" isEnabled="YES"/>`,
    )
    .join("\n");
  const reference = `<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="${id("04")}" BuildableName="HostedManagedApproval.xctest" BlueprintName="HostedManagedApproval" ReferencedContainer="container:HostedManagedApproval.xcodeproj"/>`;
  await writeFile(
    join(project, "xcshareddata/xcschemes/HostedManagedApproval.xcscheme"),
    `<?xml version="1.0" encoding="UTF-8"?><Scheme LastUpgradeVersion="2600" version="1.3"><BuildAction parallelizeBuildables="NO" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="NO" buildForProfiling="NO" buildForArchiving="NO" buildForAnalyzing="YES">${reference}</BuildActionEntry></BuildActionEntries></BuildAction><TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="NO"><Testables><TestableReference skipped="NO">${reference}</TestableReference></Testables><EnvironmentVariables>${variables}</EnvironmentVariables></TestAction></Scheme>`,
  );
  return project;
}

export function configureManagedUITestRun(path, environment) {
  validateManagedRunnerEnvironment(environment);
  execFileSync(
    "python3",
    [
      "-c",
      `import json,plistlib,sys
path=sys.argv[1]
environment=json.loads(sys.argv[2])
with open(path,'rb') as handle:
    value=plistlib.load(handle)
assert value['__xctestrun_metadata__']['FormatVersion']==1
assert set(value)=={'HostedManagedApproval','__xctestrun_metadata__'}
target=value['HostedManagedApproval']
assert target['IsUITestBundle'] is True
assert target['UseUITargetAppProvidedByTests'] is True
variables=target.setdefault('EnvironmentVariables',{})
assert not any(key in variables for key in ('HOME','CFFIXED_USER_HOME','XDG_CONFIG_HOME','XDG_CACHE_HOME','XDG_DATA_HOME','SSH_AUTH_SOCK','GITHUB_TOKEN'))
variables.update(environment)
target['TestTimeoutsEnabled']=True
target['DefaultTestExecutionTimeAllowance']=240
target['MaximumTestExecutionTimeAllowance']=240
with open(path,'wb') as handle:
    plistlib.dump(value,handle)
`,
      path,
      JSON.stringify(environment),
    ],
    { stdio: "pipe", maxBuffer: 16384 },
  );
}

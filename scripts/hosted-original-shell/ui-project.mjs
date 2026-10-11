import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdir, writeFile } from "node:fs/promises";
import { join, resolve } from "node:path";
import { admitHostedJourney } from "./prepare-journey.mjs";

const runnerKeys = [
  "GITHUB_ACTIONS",
  "RUNNER_OS",
  "RUNNER_ENVIRONMENT",
  "EDITH_HOSTED_SHELL_JOURNEY",
  "EDITH_GUI_FIXTURE_DIRECTORY",
  "EDITH_JOURNEY_ACCOUNT_HOME",
  "EDITH_APPLICATION_IDENTIFIER",
  "EDITH_SHARED_DEFAULTS_SUITE",
  "EDITH_EXTENSION_FIXTURE_HOME",
  "EDITH_JOURNEY_OPERATOR_ENDPOINT",
  "EDITH_JOURNEY_OPERATOR_TOKEN",
];

export function journeyRunnerEnvironment(environment) {
  const result = Object.fromEntries(
    runnerKeys.map((key) => [key, environment[key]]),
  );
  validateRunnerEnvironment(result);
  return result;
}

function validateRunnerEnvironment(environment) {
  assert.deepEqual(Object.keys(environment).sort(), [...runnerKeys].sort());
  for (const value of Object.values(environment))
    assert(
      typeof value === "string" &&
        value.length <= 4096 &&
        !/[\0\r\n]/.test(value),
    );
  const endpoint = new URL(environment.EDITH_JOURNEY_OPERATOR_ENDPOINT);
  assert.equal(endpoint.protocol, "http:");
  assert.equal(endpoint.hostname, "127.0.0.1");
  assert(
    endpoint.port &&
      Number(endpoint.port) >= 1 &&
      Number(endpoint.port) <= 65535,
  );
  assert.equal(endpoint.pathname, "/replace");
  assert.equal(
    endpoint.username + endpoint.password + endpoint.search + endpoint.hash,
    "",
  );
  assert.match(environment.EDITH_JOURNEY_OPERATOR_TOKEN, /^[a-f0-9]{64}$/);
  admitHostedJourney(
    environment,
    environment.EDITH_GUI_FIXTURE_DIRECTORY,
    environment.EDITH_APPLICATION_IDENTIFIER,
    environment.EDITH_JOURNEY_ACCOUNT_HOME,
  );
  assert.equal(
    environment.EDITH_SHARED_DEFAULTS_SUITE,
    environment.EDITH_APPLICATION_IDENTIFIER,
  );
  assert.equal(
    environment.EDITH_EXTENSION_FIXTURE_HOME,
    join(environment.EDITH_GUI_FIXTURE_DIRECTORY, "synthetic-data"),
  );
}

export async function writeUIProject(directory, environment) {
  validateRunnerEnvironment(environment);
  const project = join(directory, "HostedShellJourney.xcodeproj");
  await mkdir(join(project, "xcshareddata/xcschemes"), { recursive: true });
  const source = resolve(
    "Tests/HostedOriginalShell/UITests/OriginalShellJourneyTests.swift",
  );
  const contract = resolve(
    "Tests/HostedOriginalShell/Sources/JourneyContract/JourneyContract.swift",
  );
  const interaction = resolve(
    "Tests/HostedOriginalShell/Sources/JourneyContract/JourneyInteraction.swift",
  );
  const packageDirectory = resolve(
    "Tests/HostedOriginalShell/Sources/JourneyContract/JourneyPackageDirectory.swift",
  );
  const id = (value) => `0000000000000000000000${value}`;
  const settings = {
    SDKROOT: "macosx",
    MACOSX_DEPLOYMENT_TARGET: "14.0",
    SWIFT_VERSION: "5.0",
    ARCHS: "arm64",
    PRODUCT_NAME: "HostedShellJourney",
    PRODUCT_BUNDLE_IDENTIFIER: "com.pulkit.edith.tests.hosted-shell-ui",
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
      children: [id("03"), id("11"), id("12"), id("15"), id("17")],
      sourceTree: "<group>",
    },
    [id("03")]: {
      isa: "PBXFileReference",
      explicitFileType: "wrapper.cfbundle",
      path: "HostedShellJourney.xctest",
      sourceTree: "BUILT_PRODUCTS_DIR",
    },
    [id("04")]: {
      isa: "PBXNativeTarget",
      buildConfigurationList: id("09"),
      buildPhases: [id("05")],
      buildRules: [],
      dependencies: [],
      name: "HostedShellJourney",
      productName: "HostedShellJourney",
      productReference: id("03"),
      productType: "com.apple.product-type.bundle.ui-testing",
    },
    [id("05")]: {
      isa: "PBXSourcesBuildPhase",
      buildActionMask: 2147483647,
      files: [id("13"), id("14"), id("16"), id("18")],
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
    [id("15")]: {
      isa: "PBXFileReference",
      lastKnownFileType: "sourcecode.swift",
      path: interaction,
      sourceTree: "<absolute>",
    },
    [id("13")]: { isa: "PBXBuildFile", fileRef: id("11") },
    [id("14")]: { isa: "PBXBuildFile", fileRef: id("12") },
    [id("16")]: { isa: "PBXBuildFile", fileRef: id("15") },
    [id("17")]: {
      isa: "PBXFileReference",
      lastKnownFileType: "sourcecode.swift",
      path: packageDirectory,
      sourceTree: "<absolute>",
    },
    [id("18")]: { isa: "PBXBuildFile", fileRef: id("17") },
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
  const reference = `<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="${id("04")}" BuildableName="HostedShellJourney.xctest" BlueprintName="HostedShellJourney" ReferencedContainer="container:HostedShellJourney.xcodeproj"/>`;
  await writeFile(
    join(project, "xcshareddata/xcschemes/HostedShellJourney.xcscheme"),
    `<?xml version="1.0" encoding="UTF-8"?><Scheme LastUpgradeVersion="2600" version="1.3"><BuildAction parallelizeBuildables="NO" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="NO" buildForProfiling="NO" buildForArchiving="NO" buildForAnalyzing="YES">${reference}</BuildActionEntry></BuildActionEntries></BuildAction><TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="NO"><Testables><TestableReference skipped="NO">${reference}</TestableReference></Testables><EnvironmentVariables>${variables}</EnvironmentVariables></TestAction></Scheme>`,
  );
  return project;
}

export function configureUITestRun(path, environment) {
  validateRunnerEnvironment(environment);
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
assert set(value)=={'HostedShellJourney','__xctestrun_metadata__'}
target=value['HostedShellJourney']
assert target['IsUITestBundle'] is True
assert target['UseUITargetAppProvidedByTests'] is True
variables=target.setdefault('EnvironmentVariables',{})
assert variables.get('HOME',environment['EDITH_JOURNEY_ACCOUNT_HOME'])==environment['EDITH_JOURNEY_ACCOUNT_HOME']
assert variables.get('CFFIXED_USER_HOME',environment['EDITH_JOURNEY_ACCOUNT_HOME'])==environment['EDITH_JOURNEY_ACCOUNT_HOME']
assert not any(key in variables for key in ('XDG_CONFIG_HOME','XDG_CACHE_HOME','XDG_DATA_HOME','SSH_AUTH_SOCK'))
variables.update(environment)
target['TestTimeoutsEnabled']=True
target['DefaultTestExecutionTimeAllowance']=600
target['MaximumTestExecutionTimeAllowance']=600
with open(path,'wb') as handle:
    plistlib.dump(value,handle)
`,
      path,
      JSON.stringify(environment),
    ],
    { stdio: "inherit" },
  );
}

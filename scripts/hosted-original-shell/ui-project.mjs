import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdir, writeFile } from "node:fs/promises";
import { join, resolve } from "node:path";

export async function writeUIProject(directory, environment) {
  const project = join(directory, "HostedShellJourney.xcodeproj");
  await mkdir(join(project, "xcshareddata/xcschemes"), { recursive: true });
  const source = resolve(
    "Tests/HostedOriginalShell/UITests/OriginalShellJourneyTests.swift",
  );
  const contract = resolve(
    "Tests/HostedOriginalShell/Sources/JourneyContract/JourneyContract.swift",
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
      children: [id("03"), id("11"), id("12")],
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
  const reference = `<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="${id("04")}" BuildableName="HostedShellJourney.xctest" BlueprintName="HostedShellJourney" ReferencedContainer="container:HostedShellJourney.xcodeproj"/>`;
  await writeFile(
    join(project, "xcshareddata/xcschemes/HostedShellJourney.xcscheme"),
    `<?xml version="1.0" encoding="UTF-8"?><Scheme LastUpgradeVersion="2600" version="1.3"><BuildAction parallelizeBuildables="NO" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="NO" buildForProfiling="NO" buildForArchiving="NO" buildForAnalyzing="YES">${reference}</BuildActionEntry></BuildActionEntries></BuildAction><TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="NO"><Testables><TestableReference skipped="NO">${reference}</TestableReference></Testables><EnvironmentVariables>${variables}</EnvironmentVariables></TestAction></Scheme>`,
  );
  return project;
}

export function configureUITestRun(path, environment) {
  const allowed = new Set([
    "GITHUB_ACTIONS",
    "RUNNER_OS",
    "RUNNER_ENVIRONMENT",
    "EDITH_HOSTED_SHELL_JOURNEY",
    "EDITH_GUI_FIXTURE_DIRECTORY",
    "EDITH_JOURNEY_ACCOUNT_HOME",
    "HOME",
    "XDG_CONFIG_HOME",
    "XDG_CACHE_HOME",
    "XDG_DATA_HOME",
    "EDITH_APPLICATION_IDENTIFIER",
    "EDITH_SHARED_DEFAULTS_SUITE",
    "EDITH_EXTENSION_FIXTURE_HOME",
  ]);
  for (const [key, value] of Object.entries(environment)) {
    assert(allowed.has(key), "Unexpected UI test environment key");
    assert(
      typeof value === "string" &&
        value.length <= 4096 &&
        !/[\0\r\n]/.test(value),
    );
  }
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
target.setdefault('EnvironmentVariables',{}).update(environment)
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

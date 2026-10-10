import { execFileSync, spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import {
  copyFile,
  lstat,
  mkdir,
  readdir,
  readFile,
  realpath,
  rename,
  unlink,
  writeFile,
} from "node:fs/promises";
import { basename, dirname, resolve } from "node:path";
import {
  copyContainedHostRuntime,
  requireRegularTree,
} from "./build-camera-carrier.mjs";

const identifierPattern = /^[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+$/;
const extensionPattern = /^[A-Za-z][A-Za-z0-9]{0,63}$/;
const versionPattern = /^\d+\.\d+\.\d+$/;
const hashPattern = /^[a-f0-9]{64}$/;

export function extensionUIExtensionPoint(hostIdentifier) {
  if (!identifierPattern.test(hostIdentifier ?? ""))
    throw new Error("Invalid extension UI host identity");
  return {
    EXVersion: 1,
    [`${hostIdentifier}.ExtensionUI`]: {
      EXExtensionPointIsPublic: true,
      EXExtensionPointName: "ExtensionUI",
      EXPresentsUserInterface: true,
      EXRequiredEntitlements: { "com.apple.security.app-sandbox": true },
      EXRequiresEnhancedSecurity: false,
      EXSupportedPlatforms: ["macOS"],
      _EXScopeRestriction: "none",
    },
  };
}

export function extensionUICarrierMetadata({
  hostIdentifier,
  id,
  version,
  hostABI,
  executableSHA256,
  hostCodeRequirement,
  hostExecutablePath,
}) {
  if (
    !identifierPattern.test(hostIdentifier ?? "") ||
    !extensionPattern.test(id ?? "") ||
    !versionPattern.test(version ?? "") ||
    !/^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/.test(hostABI ?? "") ||
    !hashPattern.test(executableSHA256 ?? "") ||
    typeof hostCodeRequirement !== "string" ||
    hostCodeRequirement.length < 1 ||
    hostCodeRequirement.length > 4096 ||
    /[\r\n\0]/.test(hostCodeRequirement) ||
    typeof hostExecutablePath !== "string" ||
    hostExecutablePath.length > 4096 ||
    !hostExecutablePath.startsWith("/") ||
    /[\r\n\0]/.test(hostExecutablePath) ||
    resolve(hostExecutablePath) !== hostExecutablePath ||
    (hostIdentifier === "com.pulkit.edith" &&
      hostExecutablePath !== "/Applications/Edith.app/Contents/MacOS/Edith")
  )
    throw new Error("Invalid extension UI carrier metadata");
  const applicationIdentifier = `${hostIdentifier}.extension.${id}`;
  return {
    applicationIdentifier,
    workerIdentifier: `${applicationIdentifier}.worker`,
    extensionPointIdentifier: `${hostIdentifier}.ExtensionUI`,
    attributes: {
      EdithHostIdentifier: hostIdentifier,
      EdithExtensionID: id,
      EdithExtensionVersion: version,
      EdithHostABI: hostABI,
      EdithExecutableProvenance: executableSHA256,
      EdithHostCodeRequirement: hostCodeRequirement,
      EdithHostExecutablePath: hostExecutablePath,
      EdithPayloadRelativePath: "Contents/Resources/Payload",
    },
  };
}

export async function extensionUICarrierPaths(payloadDirectory) {
  const root = resolve(payloadDirectory);
  await requireRegularTree(root);
  const carrier = resolve(root, "ExtensionCarrier.app");
  try {
    await lstat(carrier);
    throw new Error("The extension UI carrier already exists");
  } catch (error) {
    if (error.code !== "ENOENT") throw error;
  }
  return {
    carrier,
    contents: resolve(carrier, "Contents"),
    worker: resolve(carrier, "Contents/Extensions/ExtensionWorker.appex"),
    workerContents: resolve(
      carrier,
      "Contents/Extensions/ExtensionWorker.appex/Contents",
    ),
  };
}

async function writePlist(path, value) {
  await mkdir(dirname(path), { recursive: true });
  execFileSync(
    "python3",
    [
      "-c",
      "import json,plistlib,sys; plistlib.dump(json.loads(sys.argv[1]),open(sys.argv[2],'wb'))",
      JSON.stringify(value),
      path,
    ],
    { stdio: "pipe" },
  );
}

function codeRequirement(hostApp, development) {
  const result = spawnSync("codesign", ["-d", "-r", "-", hostApp], {
    encoding: "utf8",
  });
  const requirements = `${result.stdout ?? ""}\n${result.stderr ?? ""}`
    .split("\n")
    .filter((line) => line.startsWith("designated => "))
    .map((line) => line.slice("designated => ".length));
  if (result.status === 0 && requirements.length === 0 && development) {
    const signature = spawnSync("codesign", ["-d", "-vvv", hostApp], {
      encoding: "utf8",
    });
    const digest = /^CDHash=([a-f0-9]{40})$/m.exec(signature.stderr ?? "");
    if (signature.status === 0 && digest) return `cdhash H"${digest[1]}"`;
  }
  if (result.status !== 0 || requirements.length !== 1)
    throw new Error("The frozen host has no readable signing requirement");
  return requirements[0];
}

function sign(path, identity, development, entitlements) {
  execFileSync(
    "codesign",
    [
      "--force",
      "--sign",
      identity,
      ...(development ? [] : ["--options", "runtime", "--timestamp"]),
      ...(entitlements ? ["--entitlements", entitlements] : []),
      path,
    ],
    { stdio: "inherit" },
  );
}

export async function buildExtensionUICarrier({
  hostApp,
  payloadDirectory,
  id,
  version,
  hostABI,
  dependencies = [],
  development = false,
  identity = process.env.EXTENSION_SIGN_IDENTITY,
}) {
  if (!hostApp || !payloadDirectory || (!development && !identity))
    throw new Error("Extension UI carrier build inputs are incomplete");
  const signingIdentity = development ? "-" : identity;
  const source = resolve(hostApp, "Contents/MacOS/Edith");
  await requireRegularTree(hostApp);
  execFileSync("codesign", ["--verify", "--deep", "--strict", hostApp], {
    stdio: "pipe",
  });
  const hostIdentifier = execFileSync(
    "/usr/libexec/PlistBuddy",
    [
      "-c",
      "Print :CFBundleIdentifier",
      resolve(hostApp, "Contents/Info.plist"),
    ],
    { encoding: "utf8", stdio: "pipe" },
  ).trim();
  if (
    development &&
    !["com.pulkit.edith.tests.", "com.pulkit.edith.dev."].some((prefix) =>
      hostIdentifier.startsWith(prefix),
    )
  )
    throw new Error(
      "Ad-hoc UI carriers require a synthetic or development host",
    );
  const metadata = extensionUICarrierMetadata({
    hostIdentifier,
    id,
    version,
    hostABI,
    executableSHA256: createHash("sha256")
      .update(await readFile(source))
      .digest("hex"),
    hostCodeRequirement: codeRequirement(hostApp, development),
    hostExecutablePath:
      hostIdentifier === "com.pulkit.edith"
        ? "/Applications/Edith.app/Contents/MacOS/Edith"
        : await realpath(source),
  });
  const paths = await extensionUICarrierPaths(payloadDirectory);
  await mkdir(paths.workerContents, { recursive: true });
  const selectedPayload = resolve(
    paths.workerContents,
    "Resources/Payload",
    id,
  );
  await mkdir(selectedPayload, { recursive: true });
  for (const entry of await readdir(payloadDirectory, {
    withFileTypes: true,
  })) {
    if (!entry.name.endsWith(".bundle")) continue;
    if (
      !entry.isDirectory() ||
      !["app", "helper", "agent", "cli", "privileged"].some(
        (role) => entry.name === `${role}.bundle`,
      )
    )
      throw new Error("Invalid extension UI role payload");
    await rename(
      resolve(payloadDirectory, entry.name),
      resolve(selectedPayload, entry.name),
    );
  }
  await writeFile(
    resolve(selectedPayload, "package.json"),
    JSON.stringify({
      id,
      version,
      hostABI,
      architecture: "arm64",
      dependencies,
    }),
  );
  const provenance = await copyContainedHostRuntime(hostApp, paths.contents, {
    identity: signingIdentity,
    development,
  });
  if (provenance.runtimeDependencies.length > 0) {
    const loadCommands = execFileSync("otool", ["-l", source], {
      encoding: "utf8",
      stdio: "pipe",
    });
    if (
      !loadCommands.includes(
        "path @executable_path/../../../../Frameworks (offset",
      )
    )
      throw new Error(
        "The frozen host cannot resolve its UI carrier frameworks",
      );
  }
  const workerExecutable = resolve(paths.workerContents, "MacOS/Edith");
  await mkdir(dirname(workerExecutable), { recursive: true });
  await copyFile(source, workerExecutable);
  if (
    createHash("sha256")
      .update(await readFile(workerExecutable))
      .digest("hex") !== provenance.originalSHA256
  )
    throw new Error("The UI worker executable differs from the frozen host");
  const shared = {
    CFBundleExecutable: "Edith",
    CFBundleInfoDictionaryVersion: "6.0",
    CFBundleShortVersionString: version,
    CFBundleVersion: version,
    CFBundleSupportedPlatforms: ["MacOSX"],
    DTPlatformName: "macosx",
    LSMinimumSystemVersion: "14.0",
    ...metadata.attributes,
  };
  await writePlist(resolve(paths.contents, "Info.plist"), {
    ...shared,
    CFBundleIdentifier: metadata.applicationIdentifier,
    CFBundleName: `Edith ${id} Extension`,
    CFBundlePackageType: "APPL",
    LSUIElement: true,
    NSPrincipalClass: "NSApplication",
  });
  await writePlist(resolve(paths.workerContents, "Info.plist"), {
    ...shared,
    CFBundleIdentifier: metadata.workerIdentifier,
    CFBundleName: `Edith ${id}`,
    CFBundlePackageType: "XPC!",
    EXAppExtensionAttributes: {
      EXExtensionPointIdentifier: metadata.extensionPointIdentifier,
    },
  });
  await writeFile(resolve(paths.contents, "PkgInfo"), "APPL????");
  await writeFile(resolve(paths.workerContents, "PkgInfo"), "XPC!????");
  const entitlements = resolve(paths.contents, ".worker-entitlements.plist");
  await writePlist(entitlements, { "com.apple.security.app-sandbox": true });
  sign(paths.worker, signingIdentity, development, entitlements);
  await unlink(entitlements);
  sign(paths.carrier, signingIdentity, development);
  await requireRegularTree(paths.carrier);
  execFileSync("codesign", ["--verify", "--deep", "--strict", paths.carrier], {
    stdio: "inherit",
  });
  return {
    carrier: basename(paths.carrier),
    applicationIdentifier: metadata.applicationIdentifier,
    workerIdentifier: metadata.workerIdentifier,
    extensionPointIdentifier: metadata.extensionPointIdentifier,
    executableSHA256: provenance.originalSHA256,
    runtimeDependencies: provenance.runtimeDependencies,
  };
}

import { execFileSync, spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { constants } from "node:fs";
import {
  chmod,
  copyFile,
  cp,
  lstat,
  mkdir,
  open,
  readdir,
  readFile,
  readlink,
  realpath,
  rename,
  unlink,
  writeFile,
} from "node:fs/promises";
import { basename, dirname, resolve } from "node:path";
import {
  copyContainedHostRuntime,
  requireRegularTree,
} from "./build-contained-host-runtime.mjs";
import { validateMinimumSystemVersion } from "./extension-system-version.mjs";

const identifierPattern = /^[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+$/;
const extensionPattern = /^[A-Za-z][A-Za-z0-9]{0,63}$/;
const versionPattern = /^\d+\.\d+\.\d+$/;
const hashPattern = /^[a-f0-9]{64}$/;

export function extensionUIWorkerEntitlements(id) {
  if (!extensionPattern.test(id ?? ""))
    throw new Error("Invalid extension UI identity");
  return {
    "com.apple.security.app-sandbox": true,
    ...(["music", "notchShelf"].includes(id)
      ? { "com.apple.security.network.client": true }
      : {}),
  };
}

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
  carrierExecutableSHA256,
  hostCodeRequirement,
  hostExecutablePath,
}) {
  if (
    !identifierPattern.test(hostIdentifier ?? "") ||
    !extensionPattern.test(id ?? "") ||
    !versionPattern.test(version ?? "") ||
    !/^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/.test(hostABI ?? "") ||
    !hashPattern.test(executableSHA256 ?? "") ||
    !hashPattern.test(carrierExecutableSHA256 ?? "") ||
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
      EdithCarrierExecutableProvenance: carrierExecutableSHA256,
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

async function writePlist(path, value, environment = process.env) {
  await mkdir(dirname(path), { recursive: true });
  execFileSync(
    "python3",
    [
      "-c",
      "import json,plistlib,sys; plistlib.dump(json.loads(sys.argv[1]),open(sys.argv[2],'wb'))",
      JSON.stringify(value),
      path,
    ],
    { stdio: "pipe", env: environment },
  );
}

export async function verifyExtensionUIHost(
  hostApp,
  verify = (arguments_) =>
    execFileSync("codesign", arguments_, { stdio: "pipe" }),
) {
  const root = resolve(hostApp);
  const rootInfo = await lstat(root);
  if (
    !rootInfo.isDirectory() ||
    rootInfo.uid !== process.getuid() ||
    (await realpath(root)) !== root
  )
    throw new Error("The frozen host must be an owned canonical directory");
  const launcher = resolve(root, "Contents/MacOS/ed");
  const target = resolve(root, "Contents/Resources/ed-launcher");
  let entries = 0;
  async function validate(path) {
    if (++entries > 100000)
      throw new Error("The frozen host tree exceeds its entry bound");
    const info = await lstat(path);
    if (info.isSymbolicLink()) {
      if (
        path !== launcher ||
        info.uid !== process.getuid() ||
        (await readlink(path)) !== "../Resources/ed-launcher"
      )
        throw new Error("The frozen host contains an unexpected symbolic link");
      const targetInfo = await lstat(target);
      if (
        !targetInfo.isFile() ||
        targetInfo.uid !== process.getuid() ||
        targetInfo.nlink !== 1 ||
        (await realpath(target)) !== target
      )
        throw new Error(
          "The frozen host launcher target is not a regular in-bundle file",
        );
      return;
    }
    if (!info.isFile() && !info.isDirectory())
      throw new Error("The frozen host contains a special file");
    if (info.isDirectory())
      for (const child of await readdir(path))
        await validate(resolve(path, child));
  }
  await validate(root);
  await verify(["--verify", "--deep", "--strict", hostApp]);
}

function codeRequirement(hostApp, development, environment = process.env) {
  const result = spawnSync("codesign", ["-d", "-r", "-", hostApp], {
    encoding: "utf8",
    env: environment,
  });
  const requirements = `${result.stdout ?? ""}\n${result.stderr ?? ""}`
    .split("\n")
    .filter((line) => line.startsWith("designated => "))
    .map((line) => line.slice("designated => ".length));
  if (result.status === 0 && requirements.length === 0 && development) {
    const signature = spawnSync("codesign", ["-d", "-vvv", hostApp], {
      encoding: "utf8",
      env: environment,
    });
    const digest = /^CDHash=([a-f0-9]{40})$/m.exec(signature.stderr ?? "");
    if (signature.status === 0 && digest) return `cdhash H"${digest[1]}"`;
  }
  if (result.status !== 0 || requirements.length !== 1)
    throw new Error("The frozen host has no readable signing requirement");
  return requirements[0];
}

function sign(
  path,
  identity,
  development,
  entitlements,
  environment = process.env,
) {
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
    { stdio: "inherit", env: environment },
  );
}

export async function readBoundedCarrierBytes(descriptor, size) {
  if (!Number.isSafeInteger(size) || size < 1 || size > 134217728)
    throw new Error("Invalid frozen UI carrier byte bound");
  const buffer = Buffer.alloc(size + 1);
  let offset = 0;
  while (offset < buffer.length) {
    const { bytesRead } = await descriptor.read(
      buffer,
      offset,
      buffer.length - offset,
      null,
    );
    if (bytesRead === 0) break;
    offset += bytesRead;
  }
  if (offset !== size)
    throw new Error(
      "The frozen UI carrier exceeds or falls short of its bound",
    );
  return buffer.subarray(0, offset);
}

export async function readFrozenUICarrier({
  root,
  frozenHostApp,
  carrierTools,
}) {
  const verify = () =>
    JSON.parse(
      execFileSync(
        "python3",
        [
          "-B",
          resolve(root, "scripts/package_extension_lifecycle_tools.py"),
          "--verify",
          "--verify-carrier",
          "--root",
          root,
          "--host",
          frozenHostApp,
          "--output",
          carrierTools,
        ],
        { encoding: "utf8", stdio: "pipe", maxBuffer: 65536 },
      ),
    );
  const receipt = verify();
  const record = receipt.files.EdithExtensionCarrier;
  const source = resolve(carrierTools, "EdithExtensionCarrier");
  const descriptor = await open(
    source,
    constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK,
  );
  try {
    const before = await descriptor.stat();
    if (
      !before.isFile() ||
      before.uid !== process.getuid() ||
      before.nlink !== 1 ||
      before.mode & 0o022 ||
      !(before.mode & 0o111) ||
      before.size < 1 ||
      before.size > 134217728 ||
      before.size !== record.bytes ||
      (before.mode & 0o777) !== record.mode
    )
      throw new Error(
        "The frozen UI carrier is not an owned bounded executable",
      );
    const bytes = await readBoundedCarrierBytes(descriptor, record.bytes);
    const after = await descriptor.stat();
    if (
      ["dev", "ino", "mode", "uid", "nlink", "size", "mtimeMs", "ctimeMs"].some(
        (field) => before[field] !== after[field],
      ) ||
      bytes.length !== record.bytes ||
      createHash("sha256").update(bytes).digest("hex") !== record.sha256 ||
      JSON.stringify(verify()) !== JSON.stringify(receipt)
    )
      throw new Error("The frozen UI carrier changed during reading");
    return {
      bytes,
      mode: record.mode,
      sha256: record.sha256,
      sourceCommit: receipt.sourceCommit,
      hostExecutableSHA256: receipt.hostExecutableSHA256,
    };
  } finally {
    await descriptor.close();
  }
}

export async function buildExtensionUICarrier({
  root = process.cwd(),
  functionalRoleBuild,
  functionalInputs,
  frozenHostApp = resolve(root, "local/minimal-host/Edith.app"),
  carrierTools = resolve(root, "local/minimal-host/carrier-tools"),
  minimumSystemVersion,
  hostApp,
  payloadDirectory,
  id,
  version,
  hostABI,
  dependencies = [],
  development = false,
  environment = process.env,
  identity = environment.EXTENSION_SIGN_IDENTITY,
}) {
  if (functionalRoleBuild) {
    if (
      development ||
      !functionalInputs ||
      functionalInputs.root !== root ||
      functionalInputs.id !== id ||
      functionalInputs.version !== version ||
      functionalInputs.hostApp !== hostApp
    )
      throw new Error("Functional UI carrier context changed");
    const { functionalRoleBuildEnvironment } = await import(
      "./hosted-functional-actions/functional-build.mjs"
    );
    environment = await functionalRoleBuildEnvironment(
      functionalRoleBuild,
      functionalInputs,
      environment,
    );
    if (identity !== environment.EXTENSION_SIGN_IDENTITY)
      throw new Error("Functional UI carrier signing identity changed");
  }
  const run = (file, args, options = {}) =>
    execFileSync(file, args, { env: environment, ...options });
  if (!hostApp || !payloadDirectory || (!development && !identity))
    throw new Error("Extension UI carrier build inputs are incomplete");
  validateMinimumSystemVersion(minimumSystemVersion);
  const signingIdentity = development ? "-" : identity;
  const source = resolve(hostApp, "Contents/MacOS/Edith");
  await verifyExtensionUIHost(hostApp, (args) =>
    run("codesign", args, { stdio: "pipe" }),
  );
  const hostIdentifier = run(
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
  let carrierInput;
  if (functionalRoleBuild) {
    if (
      development ||
      functionalInputs.root !== root ||
      functionalInputs.id !== id ||
      functionalInputs.version !== version ||
      functionalInputs.hostApp !== hostApp
    )
      throw new Error("Functional UI carrier context changed");
    const { functionalRoleCarrierInput } = await import(
      "./hosted-functional-actions/functional-build.mjs"
    );
    carrierInput = await functionalRoleCarrierInput(
      functionalRoleBuild,
      functionalInputs,
    );
  } else {
    carrierInput = await readFrozenUICarrier({
      root,
      frozenHostApp,
      carrierTools,
    });
  }
  const metadata = extensionUICarrierMetadata({
    hostIdentifier,
    id,
    version,
    hostABI,
    carrierExecutableSHA256: carrierInput.sha256,
    executableSHA256: createHash("sha256")
      .update(await readFile(source))
      .digest("hex"),
    hostCodeRequirement: codeRequirement(hostApp, development, environment),
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
      minimumSystemVersion,
      dependencies,
    }),
  );
  const provenance = await copyContainedHostRuntime(hostApp, paths.contents, {
    identity: signingIdentity,
    environment,
    development,
  });
  const carrierExecutable = resolve(paths.contents, "MacOS/Edith");
  await unlink(carrierExecutable);
  await writeFile(carrierExecutable, carrierInput.bytes, {
    flag: "wx",
    mode: carrierInput.mode,
  });
  await chmod(carrierExecutable, carrierInput.mode);
  if (
    createHash("sha256")
      .update(await readFile(carrierExecutable))
      .digest("hex") !== carrierInput.sha256
  )
    throw new Error(
      "The UI carrier executable differs from its frozen receipt",
    );
  await cp(
    resolve(hostApp, "Contents/Resources/EdithHost_EdithHost.bundle"),
    resolve(paths.workerContents, "Resources/EdithHost_EdithHost.bundle"),
    { recursive: true, dereference: false },
  );
  if (provenance.runtimeDependencies.length > 0) {
    const loadCommands = run("otool", ["-l", source], {
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
  await writePlist(
    resolve(paths.contents, "Info.plist"),
    {
      ...shared,
      CFBundleIdentifier: metadata.applicationIdentifier,
      CFBundleName: `Edith ${id} Extension`,
      CFBundlePackageType: "APPL",
      LSUIElement: true,
      NSPrincipalClass: "NSApplication",
    },
    environment,
  );
  await writePlist(
    resolve(paths.workerContents, "Info.plist"),
    {
      ...shared,
      CFBundleIdentifier: metadata.workerIdentifier,
      CFBundleName: `Edith ${id}`,
      CFBundlePackageType: "XPC!",
      EXAppExtensionAttributes: {
        EXExtensionPointIdentifier: metadata.extensionPointIdentifier,
      },
    },
    environment,
  );
  await writeFile(resolve(paths.contents, "PkgInfo"), "APPL????");
  await writeFile(resolve(paths.workerContents, "PkgInfo"), "XPC!????");
  const entitlements = resolve(paths.contents, ".worker-entitlements.plist");
  await writePlist(
    entitlements,
    extensionUIWorkerEntitlements(id),
    environment,
  );
  sign(paths.worker, signingIdentity, development, entitlements, environment);
  await unlink(entitlements);
  sign(paths.carrier, signingIdentity, development, undefined, environment);
  await requireRegularTree(paths.carrier);
  run("codesign", ["--verify", "--deep", "--strict", paths.carrier], {
    stdio: "inherit",
  });
  return {
    carrier: basename(paths.carrier),
    applicationIdentifier: metadata.applicationIdentifier,
    workerIdentifier: metadata.workerIdentifier,
    extensionPointIdentifier: metadata.extensionPointIdentifier,
    executableSHA256: provenance.originalSHA256,
    carrierExecutableSHA256: carrierInput.sha256,
    carrierSourceCommit: carrierInput.sourceCommit,
    carrierFrozenHostSHA256: carrierInput.hostExecutableSHA256,
    runtimeDependencies: provenance.runtimeDependencies,
  };
}

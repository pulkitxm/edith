import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import {
  copyFile,
  cp,
  lstat,
  mkdir,
  readdir,
  readFile,
  rm,
  writeFile,
} from "node:fs/promises";
import { dirname, join, resolve } from "node:path";

const allowedRoles = new Set(["cameraCarrier", "cameraProvider"]);
const hash = async (file) =>
  createHash("sha256")
    .update(await readFile(file))
    .digest("hex");
const identifierPattern = /^[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+$/;

export function validateCameraCarrierDefinition(value) {
  if (
    value?.role !== "cameraCarrier" ||
    value.providerRole !== "cameraProvider" ||
    value.minimumSystemVersion !== 14 ||
    value.installEntitlement !==
      "com.apple.developer.system-extension.install" ||
    !identifierPattern.test(value.applicationIdentifier ?? "") ||
    !identifierPattern.test(value.extensionIdentifier ?? "") ||
    !value.applicationIdentifier.endsWith(".cameraCarrier") ||
    value.extensionIdentifier !==
      `${value.applicationIdentifier.slice(0, -14)}.camera` ||
    Object.keys(value).some(
      (key) =>
        ![
          "role",
          "providerRole",
          "applicationIdentifier",
          "extensionIdentifier",
          "minimumSystemVersion",
          "installEntitlement",
        ].includes(key),
    )
  ) {
    throw new Error("Invalid camera system extension carrier definition");
  }
  return value;
}

async function plist(file, object) {
  await mkdir(dirname(file), { recursive: true });
  const json = `${file}.json`;
  await writeFile(json, JSON.stringify(object));
  execFileSync("python3", [
    "-c",
    "import json,plistlib,sys; plistlib.dump(json.load(open(sys.argv[1])),open(sys.argv[2],'wb'),fmt=plistlib.FMT_BINARY)",
    json,
    file,
  ]);
  await rm(json);
}

export async function requireRegularTree(directory) {
  const info = await lstat(directory);
  if (info.isSymbolicLink() || (!info.isFile() && !info.isDirectory()))
    throw new Error("Contained packages require regular files and directories");
  if (info.isDirectory())
    for (const child of await readdir(directory))
      await requireRegularTree(join(directory, child));
}

function sign(path, identity, development, entitlements) {
  const options = development ? [] : ["--options", "runtime", "--timestamp"];
  execFileSync(
    "codesign",
    [
      "--force",
      "--sign",
      identity,
      ...options,
      ...(entitlements ? ["--entitlements", entitlements] : []),
      path,
    ],
    { stdio: "inherit" },
  );
}

async function signRuntimeTree(directory, identity, development) {
  for (const item of await readdir(directory, { withFileTypes: true })) {
    const path = join(directory, item.name);
    if (item.isDirectory()) await signRuntimeTree(path, identity, development);
    else if (
      execFileSync("file", ["-b", path], { encoding: "utf8" }).includes(
        "Mach-O",
      )
    )
      sign(path, identity, development);
  }
  if (["framework", "app", "xpc"].includes(directory.split(".").at(-1)))
    sign(directory, identity, development);
}

export async function copyContainedHostRuntime(
  hostApp,
  contents,
  { identity, development },
) {
  const source = resolve(hostApp, "Contents/MacOS/Edith");
  const destination = resolve(contents, "MacOS/Edith");
  await mkdir(dirname(destination), { recursive: true });
  const originalSHA256 = await hash(source);
  await copyFile(source, destination);
  if ((await hash(destination)) !== originalSHA256)
    throw new Error(
      "The contained executable differs from its host provenance",
    );
  const dependencies = execFileSync("otool", ["-L", source], {
    encoding: "utf8",
  })
    .split("\n")
    .slice(1)
    .map((line) => line.trim().split(" ")[0])
    .filter(Boolean);
  const frameworks = resolve(contents, "Frameworks");
  await mkdir(frameworks, { recursive: true });
  const copied = new Set();
  for (const dependency of dependencies) {
    if (dependency.startsWith("/System/") || dependency.startsWith("/usr/"))
      continue;
    if (!dependency.startsWith("@rpath/") || dependency.includes(".."))
      throw new Error(
        "The host executable has an unsupported runtime dependency",
      );
    const path = dependency.slice(7);
    const name = path.split("/")[0];
    if (!copied.has(name)) {
      copied.add(name);
      const origin = resolve(hostApp, "Contents/Frameworks", name);
      const target = resolve(frameworks, name);
      execFileSync("/bin/cp", ["-RL", origin, target]);
      if (name.endsWith(".framework")) {
        await rm(join(target, "Versions"), {
          recursive: true,
          force: true,
        });
        if (path.split("/").length !== 2)
          throw new Error(
            "The release host framework load paths must be normalized before signing",
          );
      }
      await signRuntimeTree(
        name.endsWith(".framework") ? target : frameworks,
        identity,
        development,
      );
    }
    await lstat(resolve(frameworks, path));
  }
  await requireRegularTree(frameworks);
  if ((await hash(destination)) !== originalSHA256)
    throw new Error("Runtime packaging modified the copied host executable");
  return {
    originalSHA256,
    runtimeDependencies: dependencies.filter((path) =>
      path.startsWith("@rpath/"),
    ),
  };
}

export async function buildCameraCarrier({
  root = process.cwd(),
  hostApp,
  payloadDirectory,
  output,
  version,
  hostABI,
  definition,
  development = false,
  identity = process.env.EXTENSION_SIGN_IDENTITY,
  team = process.env.CAMERA_SIGN_TEAM,
  carrierProfile = process.env.CAMERA_CARRIER_PROFILE,
  providerProfile = process.env.CAMERA_EXTENSION_PROFILE,
}) {
  const metadata = validateCameraCarrierDefinition(definition);
  const hostIdentifier = metadata.applicationIdentifier.slice(0, -14);
  if (
    !hostApp ||
    !payloadDirectory ||
    !output ||
    !/^\d+\.\d+\.\d+$/.test(version ?? "") ||
    !hostABI
  )
    throw new Error("Camera carrier build inputs are incomplete");
  if (development) {
    if (!hostIdentifier.startsWith("com.pulkit.edith.tests."))
      throw new Error(
        "Unsigned camera carriers are restricted to synthetic fixtures",
      );
    identity = "-";
  } else {
    if (
      !identity ||
      identity === "-" ||
      !/^[A-Z0-9]{10}$/.test(team ?? "") ||
      !carrierProfile ||
      !providerProfile
    )
      throw new Error(
        "Camera release signing and matching provisioning profiles are required",
      );
    for (const [profile, identifier, entitlement] of [
      [
        carrierProfile,
        metadata.applicationIdentifier,
        metadata.installEntitlement,
      ],
      [providerProfile, metadata.extensionIdentifier, ""],
    ])
      execFileSync(
        "python3",
        [
          resolve(root, "scripts/camera_extension.py"),
          "profile",
          profile,
          identifier,
          team,
          entitlement,
          identity,
        ],
        { stdio: "inherit" },
      );
  }
  const destination = resolve(output, "CameraCarrier.app");
  await rm(destination, { recursive: true, force: true });
  const provider = join(
    destination,
    "Contents/Library/SystemExtensions",
    `${metadata.extensionIdentifier}.systemextension`,
  );
  const provenance = [];
  for (const [role, bundle, identifier, profile] of [
    ["cameraProvider", provider, metadata.extensionIdentifier, providerProfile],
    [
      "cameraCarrier",
      destination,
      metadata.applicationIdentifier,
      carrierProfile,
    ],
  ]) {
    if (!allowedRoles.has(role)) throw new Error("Invalid contained role");
    const contents = join(bundle, "Contents");
    await mkdir(join(contents, "PlugIns"), { recursive: true });
    const payload = resolve(payloadDirectory, `${role}.bundle`);
    await requireRegularTree(payload);
    execFileSync("codesign", ["--verify", "--strict", "--deep", payload], {
      stdio: "inherit",
    });
    await cp(payload, join(contents, "PlugIns", `${role}.bundle`), {
      recursive: true,
    });
    const runtime = await copyContainedHostRuntime(hostApp, contents, {
      identity,
      development,
    });
    const info = {
      CFBundleIdentifier: identifier,
      CFBundleName: "Edith Camera",
      CFBundleDisplayName: "Edith Camera",
      CFBundleExecutable: "Edith",
      CFBundlePackageType: role === "cameraProvider" ? "SYSX" : "APPL",
      CFBundleShortVersionString: version,
      CFBundleVersion: version,
      LSMinimumSystemVersion: "14.0",
      EdithContainedRole: role,
      EdithContainedExtensionID: "virtualCamera",
      EdithHostIdentifier: hostIdentifier,
      EdithHostABI: hostABI,
      EdithExecutableProvenance: runtime.originalSHA256,
    };
    if (role === "cameraProvider") {
      info.CMIOExtension = {
        CMIOExtensionMachServiceName: development
          ? identifier
          : `${team}.${identifier}`,
      };
      info.NSSystemExtensionUsageDescription =
        "Edith Camera supplies the picture composed in Edith to video apps.";
    } else info.LSUIElement = true;
    await plist(join(contents, "Info.plist"), info);
    const entitlements = join(output, `${role}-entitlements.plist`);
    if (!development) {
      await copyFile(profile, join(contents, "embedded.provisionprofile"));
      const group = `${team}.${metadata.extensionIdentifier}`;
      await plist(
        entitlements,
        role === "cameraProvider"
          ? {
              "com.apple.security.app-sandbox": true,
              "com.apple.security.application-groups": [group],
            }
          : {
              [metadata.installEntitlement]: true,
              "com.apple.application-identifier": `${team}.${identifier}`,
              "com.apple.developer.team-identifier": team,
              "com.apple.security.application-groups": [group],
            },
      );
    }
    sign(bundle, identity, development, development ? undefined : entitlements);
    if (!development) await rm(entitlements);
    execFileSync("codesign", ["--verify", "--strict", "--deep", bundle], {
      stdio: "inherit",
    });
    provenance.push({
      role,
      executableBeforeSigningSHA256: runtime.originalSHA256,
      executableAfterSigningSHA256: await hash(join(contents, "MacOS/Edith")),
      runtimeDependencies: runtime.runtimeDependencies,
    });
  }
  await requireRegularTree(destination);
  const record = {
    schemaVersion: 1,
    hostIdentifier,
    version,
    hostABI,
    roles: provenance,
  };
  await writeFile(
    join(output, "camera-carrier-provenance.json"),
    `${JSON.stringify(record, null, 2)}\n`,
  );
  return { directory: destination, provider, provenance: record };
}

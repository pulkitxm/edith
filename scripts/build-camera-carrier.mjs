import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import {
  copyFile,
  cp,
  lstat,
  mkdir,
  readFile,
  rm,
  writeFile,
} from "node:fs/promises";
import { dirname, join, resolve } from "node:path";

import {
  copyContainedHostRuntime,
  requireRegularTree,
} from "./build-contained-host-runtime.mjs";

const allowedRoles = new Set(["cameraCarrier", "cameraProvider"]);
const hash = async (file) =>
  createHash("sha256")
    .update(await readFile(file))
    .digest("hex");
const identifierPattern = /^[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+$/;

export function validateCameraCarrierDefinition(value) {
  const obs = value?.transport === "obs";
  const native = !obs && value?.transport === undefined;
  if (
    value?.role !== "cameraCarrier" ||
    (!obs && (!native || value.providerRole !== "cameraProvider")) ||
    (obs &&
      (value.providerRole !== undefined ||
        value.installEntitlement !== undefined)) ||
    value.minimumSystemVersion !== 14 ||
    (!obs &&
      (value.installEntitlement !==
        "com.apple.developer.system-extension.install" ||
        !identifierPattern.test(value.extensionIdentifier ?? ""))) ||
    !identifierPattern.test(value.applicationIdentifier ?? "") ||
    !value.applicationIdentifier.endsWith(".cameraCarrier") ||
    (!obs &&
      value.extensionIdentifier !==
        `${value.applicationIdentifier.slice(0, -14)}.camera`) ||
    Object.keys(value).some(
      (key) =>
        ![
          "role",
          "providerRole",
          "applicationIdentifier",
          "extensionIdentifier",
          "minimumSystemVersion",
          "installEntitlement",
          "transport",
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
  const obs = metadata.transport === "obs";
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
      (!obs &&
        (!/^[A-Z0-9]{10}$/.test(team ?? "") ||
          !carrierProfile ||
          !providerProfile))
    )
      throw new Error(
        "Camera release signing and matching provisioning profiles are required",
      );
    for (const [profile, identifier, entitlement] of obs
      ? []
      : [
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
    ...(obs
      ? []
      : [
          [
            "cameraProvider",
            provider,
            metadata.extensionIdentifier,
            providerProfile,
          ],
        ]),
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
    if (role === "cameraCarrier") {
      const privileged = resolve(payloadDirectory, "privileged.bundle");
      if (!development || (await lstat(privileged).catch(() => null))) {
        await requireRegularTree(privileged);
        execFileSync(
          "codesign",
          ["--verify", "--strict", "--deep", privileged],
          { stdio: "inherit" },
        );
        await cp(privileged, join(contents, "PlugIns/privileged.bundle"), {
          recursive: true,
        });
      }
      const microphone = resolve(contents, "Library/Audio/Plug-Ins/HAL");
      execFileSync(
        "python3",
        [
          resolve(root, "scripts/build-camera-microphone.py"),
          "--application",
          hostIdentifier,
          "--version",
          version,
          "--identity",
          identity,
          "--output",
          microphone,
        ],
        { stdio: "inherit" },
      );
    }
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
      EdithCameraTransport: obs ? "obs" : "native",
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
    if (!development && !obs) {
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
    sign(
      bundle,
      identity,
      development,
      development || obs ? undefined : entitlements,
    );
    if (!development && !obs) await rm(entitlements);
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

import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import {
  cp,
  lstat,
  mkdir,
  readdir,
  readFile,
  realpath,
  rm,
  writeFile,
} from "node:fs/promises";
import { dirname, isAbsolute, join, resolve } from "node:path";
import {
  copyContainedHostRuntime,
  requireRegularTree,
} from "../build-contained-host-runtime.mjs";
import {
  buildExtensionUICarrier,
  extensionUIExtensionPoint,
  extensionUIWorkerEntitlements,
} from "../build-extension-ui-carrier.mjs";
import { compileFactoryOverlay } from "./factory-overlay.mjs";
import { proveFixturePayload } from "./package-preparation.mjs";
import {
  copyNativeRolePayloads,
  fixturePayloadQualification,
  validateFixtureHost,
} from "./payload-transform.mjs";

const knownOwners = new Set(
  JSON.parse(
    readFileSync(
      new URL("../../Tests/HostedManagedViews/routes.json", import.meta.url),
    ),
  ).owners.map(({ id }) => id),
);

const run = (command, args) =>
  execFileSync(command, args, {
    stdio: "pipe",
    timeout: 120_000,
    maxBuffer: 32 * 1024 * 1024,
  });
const digest = (bytes) => createHash("sha256").update(bytes).digest("hex");
const readPlist = (file) =>
  JSON.parse(
    run("python3", [
      "-c",
      "import json,plistlib,sys;print(json.dumps(plistlib.load(open(sys.argv[1],'rb'))))",
      file,
    ]),
  );
async function writePlist(file, value) {
  await mkdir(dirname(file), { recursive: true, mode: 0o700 });
  run("python3", [
    "-c",
    "import json,plistlib,sys;plistlib.dump(json.loads(sys.argv[2]),open(sys.argv[1],'wb'))",
    file,
    JSON.stringify(value),
  ]);
}
function sign(file, identity, entitlements) {
  run("codesign", [
    "--force",
    "--sign",
    identity,
    "--timestamp=none",
    "--options",
    "runtime",
    ...(entitlements ? ["--entitlements", entitlements] : []),
    file,
  ]);
}
async function signTree(directory, identity) {
  await requireRegularTree(directory);
  for (const entry of await readdir(directory, { withFileTypes: true })) {
    const path = join(directory, entry.name);
    if (entry.isDirectory()) await signTree(path, identity);
    else if (run("file", ["-b", path]).toString().includes("Mach-O"))
      sign(path, identity);
  }
  if (/\.(bundle|app|framework|xpc)$/.test(directory))
    sign(directory, identity);
}

export function admitManagedPreparation(
  environment,
  directory,
  identifier,
  accountHome,
  owner,
) {
  assert(knownOwners.has(owner));
  assert(isAbsolute(accountHome) && resolve(accountHome) === accountHome);
  assert.equal(environment.GITHUB_ACTIONS, "true");
  assert.equal(environment.RUNNER_OS, "macOS");
  assert.equal(environment.RUNNER_ENVIRONMENT, "github-hosted");
  assert.equal(environment.EDITH_HOSTED_MANAGED_VIEWS, "1");
  const prefix = `com.pulkit.edith.tests.${owner === "calendar" ? "remote" : "worker"}-`;
  assert(identifier.startsWith(prefix));
  const uuid = identifier.slice(prefix.length);
  assert.match(
    uuid,
    /^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/,
  );
  assert.equal(
    directory,
    join(accountHome, "Applications", `Edith Managed Views ${uuid}`),
  );
}

async function rebindCamera({ original, payload, host, identity }) {
  const source = join(original.expandedDirectory, "CameraCarrier.app");
  await requireRegularTree(source);
  const destination = join(payload, "CameraCarrier.app");
  await cp(source, destination, {
    recursive: true,
    dereference: false,
    errorOnExist: true,
    force: false,
  });
  const contents = join(destination, "Contents");
  const metadata = readPlist(join(contents, "Info.plist"));
  assert.equal(metadata.EdithContainedRole, "cameraCarrier");
  assert.equal(metadata.EdithContainedExtensionID, "virtualCamera");
  assert.equal(metadata.EdithCameraTransport, "obs");
  const originalIdentity = metadata.CFBundleIdentifier;
  assert.equal(
    originalIdentity,
    `${metadata.EdithHostIdentifier}.cameraCarrier`,
  );
  for (const path of ["Frameworks", "Resources/EdithHost_EdithHost.bundle"])
    await rm(join(contents, path), { recursive: true, force: true });
  await copyContainedHostRuntime(host.app, contents, {
    identity,
    development: true,
  });
  const changed = {
    ...metadata,
    CFBundleIdentifier: `${host.identifier}.cameraCarrier`,
    EdithHostIdentifier: host.identifier,
    EdithExecutableProvenance: host.executableSHA256,
  };
  await writePlist(join(contents, "Info.plist"), changed);
  await signTree(destination, identity);
  return {
    originalIdentity,
    fixtureIdentity: changed.CFBundleIdentifier,
    originalMetadata: metadata,
    fixtureMetadata: changed,
    nativeRolePayloadIncluded: false,
  };
}

export async function prepareManagedOwner({
  root,
  directory,
  identifier,
  accountHome,
  owner,
  definition,
  original,
  sourceHost,
  sourceHostReceipt,
  identity,
  environment = process.env,
}) {
  admitManagedPreparation(
    environment,
    directory,
    identifier,
    accountHome,
    owner.id,
  );
  assert.equal(definition.id, owner.id);
  assert.match(identity, /^[A-Fa-f0-9]{40}$/);
  assert.equal(sourceHostReceipt.productionExecutableUnchangedProof, false);
  assert.match(sourceHostReceipt.sourceCommit, /^[a-f0-9]{40}$/);
  assert.equal(
    digest(await readFile(join(sourceHost, "Contents/MacOS/Edith"))),
    sourceHostReceipt.executableSHA256,
  );
  await mkdir(directory, { mode: 0o700 });
  assert.equal(await realpath(directory), directory);
  const status = await lstat(directory);
  assert.equal(status.uid, process.getuid());
  assert.equal(status.mode & 0o7777, 0o700);
  const app = join(directory, "Fixture.app");
  await requireRegularTree(sourceHost);
  await cp(sourceHost, app, {
    recursive: true,
    dereference: false,
    errorOnExist: true,
    force: false,
  });
  const hostInfo = readPlist(join(app, "Contents/Info.plist"));
  await writePlist(join(app, "Contents/Info.plist"), {
    ...hostInfo,
    CFBundleIdentifier: identifier,
    CFBundleName: "Synthetic managed original view",
    CFBundleDisplayName: "Synthetic managed original view",
  });
  await writePlist(
    join(app, "Contents/Extensions/ExtensionUI.appextensionpoints"),
    extensionUIExtensionPoint(identifier),
  );
  await signTree(join(app, "Contents/Frameworks"), identity);
  sign(app, identity);
  const host = {
    app,
    identifier,
    sourceCommit: sourceHostReceipt.sourceCommit,
    executableSHA256: digest(await readFile(join(app, "Contents/MacOS/Edith"))),
    productionExecutableUnchangedProof: false,
  };
  await validateFixtureHost(host);
  run("codesign", ["--verify", "--deep", "--strict", app]);
  const package_ = JSON.parse(
    await readFile(join(dirname(original.archivePath), `${owner.id}.json`)),
  );
  assert.equal(package_.id, owner.id);
  assert.equal(package_.sha256, original.zipSHA256);
  assert.equal(package_.sourceFingerprint, original.sourceFingerprint);
  assert.equal(package_.hostABI, definition.hostABI);
  assert.equal(package_.architecture, "arm64");
  assert.deepEqual(package_.dependencies, []);
  const staging = join(directory, "transformed");
  await mkdir(staging, { mode: 0o700 });
  const { payload, roles } = await copyNativeRolePayloads({
    original,
    owner,
    definition,
    host,
    output: staging,
  });
  let overlay;
  if (owner.factoryOverlay) {
    overlay = await compileFactoryOverlay({
      root,
      definition,
      original,
      payload,
      output: directory,
    });
    run("strip", ["-rSTx", join(payload, "app.bundle/Contents/MacOS/Runtime")]);
  }
  for (const role of roles)
    await signTree(join(payload, `${role}.bundle`), identity);
  const camera =
    owner.id === "virtualCamera"
      ? await rebindCamera({ original, payload, host, identity })
      : null;
  await buildExtensionUICarrier({
    hostApp: app,
    payloadDirectory: payload,
    id: owner.id,
    version: package_.version,
    hostABI: package_.hostABI,
    dependencies: [],
    development: true,
  });
  const carrier = join(payload, "ExtensionCarrier.app");
  const worker = join(carrier, "Contents/Extensions/ExtensionWorker.appex");
  await signTree(join(carrier, "Contents/Frameworks"), identity);
  const entitlements = join(directory, "worker-entitlements.plist");
  await writePlist(entitlements, extensionUIWorkerEntitlements(owner.id));
  sign(worker, identity, entitlements);
  await rm(entitlements);
  sign(carrier, identity);
  await writeFile(
    join(payload, "package.json"),
    JSON.stringify({
      id: owner.id,
      version: package_.version,
      hostABI: package_.hostABI,
      architecture: "arm64",
      dependencies: [],
    }),
    { mode: 0o600 },
  );
  const fixtureInventory = { extensionID: owner.id, roles: {} };
  const selectedPayload = join(worker, "Contents/Resources/Payload", owner.id);
  for (const role of roles)
    fixtureInventory.roles[role] = JSON.parse(
      run("python3", [
        join(root, "scripts/hosted-managed-views/payload-inventory.py"),
        join(selectedPayload, `${role}.bundle`),
      ]),
    );
  if (overlay)
    overlay.codeChanges = [
      {
        role: "app",
        path: "Contents/MacOS/Runtime",
        originalNormalizedSHA256:
          original.receipt.roles.app.code["Contents/MacOS/Runtime"]
            .normalizedUnsignedSHA256,
        fixtureNormalizedSHA256:
          fixtureInventory.roles.app.code["Contents/MacOS/Runtime"]
            .normalizedUnsignedSHA256,
      },
    ];
  const nativeProof = proveFixturePayload(original.receipt, fixtureInventory, {
    extensionID: owner.id,
    overlay,
  });
  const hostMetadataPath = join(directory, "host-tier-metadata.json");
  await writeFile(
    hostMetadataPath,
    JSON.stringify({
      hostIdentifier: identifier,
      extensionID: owner.id,
      version: package_.version,
      hostABI: package_.hostABI,
      hostExecutableSHA256: host.executableSHA256,
      sourceHost,
      sourceHostExecutableSHA256: sourceHostReceipt.executableSHA256,
    }),
    { mode: 0o600 },
  );
  const hostProof = JSON.parse(
    run("python3", [
      join(root, "scripts/hosted-managed-views/fixture-host-inventory.py"),
      app,
      payload,
      hostMetadataPath,
    ]),
  );
  const result = {
    schema: 1,
    directory,
    host,
    package: package_,
    originalArchive: original.archivePath,
    originalZipSHA256: original.zipSHA256,
    payload,
    nativeProof,
    hostProof,
    camera,
    qualification: fixturePayloadQualification(owner),
    originalSourceCommit: original.receipt.sourceCommit,
  };
  await writeFile(
    join(directory, "transformation-receipt.json"),
    JSON.stringify(result),
    { mode: 0o600 },
  );
  return result;
}

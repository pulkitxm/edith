import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { cp, lstat, mkdir, readFile, realpath } from "node:fs/promises";
import { join, resolve } from "node:path";
import { requireRegularTree } from "../build-contained-host-runtime.mjs";

const digest = (bytes) => createHash("sha256").update(bytes).digest("hex");
const hash = /^[a-f0-9]{64}$/;
const uuid = /^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/;

export function validateTransformationInput({
  original,
  owner,
  definition,
  host,
}) {
  assert.equal(original.extensionID, owner.id);
  assert.equal(definition.id, owner.id);
  assert.equal(original.receipt.extensionID, owner.id);
  assert.equal(original.receipt.sourceFingerprint, original.sourceFingerprint);
  assert.equal(original.receipt.zipSHA256, original.zipSHA256);
  assert.equal(original.receipt.packageCodeExecuted, false);
  assert.equal(original.receipt.signaturesVerified, true);
  assert.equal(original.receipt.sealedHostProvenanceVerified, true);
  assert.equal(original.receipt.zipCRCVerified, true);
  assert.match(original.sourceFingerprint, hash);
  assert.match(original.zipSHA256, hash);
  assert.match(original.receipt.sourceCommit, /^[a-f0-9]{40}$/);
  assert.match(host.sourceCommit, /^[a-f0-9]{40}$/);
  assert.match(host.executableSHA256, hash);
  assert.equal(host.productionExecutableUnchangedProof, false);
  assert.equal(host.app, resolve(host.app));
  const prefix = `com.pulkit.edith.tests.${owner.id === "calendar" ? "remote" : "worker"}-`;
  assert(host.identifier.startsWith(prefix));
  assert.match(host.identifier.slice(prefix.length), uuid);
  assert.equal(owner.factoryOverlay, ["plugins", "studio"].includes(owner.id));
  const roles = Object.keys(definition.roles)
    .filter((role) => !["cameraCarrier", "cameraProvider"].includes(role))
    .sort();
  assert(roles.length > 0 && roles.length <= 5);
  for (const role of roles)
    assert(["app", "helper", "agent", "cli", "privileged"].includes(role));
  assert.deepEqual(Object.keys(original.receipt.roles).sort(), roles);
  return roles;
}

export async function copyNativeRolePayloads({
  original,
  owner,
  definition,
  host,
  output,
}) {
  const roles = validateTransformationInput({
    original,
    owner,
    definition,
    host,
  });
  assert.equal(output, resolve(output));
  const parent = await lstat(output);
  assert(parent.isDirectory() && !parent.isSymbolicLink());
  assert.equal(parent.uid, process.getuid());
  assert.equal(parent.mode & 0o7777, 0o700);
  assert.equal(await realpath(output), output);
  assert.equal(
    await realpath(original.expandedDirectory),
    original.expandedDirectory,
  );
  await requireRegularTree(original.expandedDirectory);
  const source = join(
    original.expandedDirectory,
    "ExtensionCarrier.app/Contents/Extensions/ExtensionWorker.appex/Contents/Resources/Payload",
    owner.id,
  );
  const payload = join(output, owner.id);
  await mkdir(payload, { mode: 0o700 });
  try {
    for (const role of roles)
      await cp(
        join(source, `${role}.bundle`),
        join(payload, `${role}.bundle`),
        {
          recursive: true,
          dereference: false,
          errorOnExist: true,
          force: false,
        },
      );
    return { payload, roles, originalPayload: source };
  } finally {
    assert.equal(
      await realpath(original.expandedDirectory),
      original.expandedDirectory,
    );
  }
}

export async function validateFixtureHost(
  host,
  readMetadata = (app) => {
    return JSON.parse(
      execFileSync(
        "python3",
        [
          "-c",
          "import json,plistlib,sys;print(json.dumps(plistlib.load(open(sys.argv[1],'rb'))))",
          join(app, "Contents/Info.plist"),
        ],
        { encoding: "utf8" },
      ),
    );
  },
) {
  assert.equal(await realpath(host.app), host.app);
  await requireRegularTree(host.app);
  assert.equal(
    digest(await readFile(join(host.app, "Contents/MacOS/Edith"))),
    host.executableSHA256,
  );
  const metadata = await readMetadata(host.app);
  assert.equal(metadata.CFBundleIdentifier, host.identifier);
  assert.equal(metadata.CFBundleExecutable, "Edith");
  assert.equal(metadata.CFBundlePackageType, "APPL");
  return metadata;
}

export function fixturePayloadQualification(owner) {
  return {
    schema: 1,
    extensionID: owner.id,
    nativeRoleCodeAndResourcesUnchanged: !owner.factoryOverlay,
    unchangedScope:
      "Payload/<id>/<role>.bundle only, excluding signatures and all Host executable carriers",
    productionExecutableUnchangedProof: false,
    factoryOverlay: owner.factoryOverlay,
    auxiliaryCameraCarrierTransformed: owner.id === "virtualCamera",
    functionalActionsValidated: false,
    managedNativeViewValidated: false,
  };
}

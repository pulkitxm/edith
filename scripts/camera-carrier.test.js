import { expect, test } from "bun:test";
import { mkdir, mkdtemp, rm, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  requireRegularTree,
  validateCameraCarrierDefinition,
} from "./build-camera-carrier.mjs";

const definition = {
  role: "cameraCarrier",
  providerRole: "cameraProvider",
  applicationIdentifier: "com.pulkit.edith.cameraCarrier",
  extensionIdentifier: "com.pulkit.edith.camera",
  minimumSystemVersion: 14,
  installEntitlement: "com.apple.developer.system-extension.install",
};

test("camera carrier metadata permits only the matching sealed roles and identities", () => {
  expect(validateCameraCarrierDefinition(definition)).toEqual(definition);
  for (const change of [
    { role: "app" },
    { providerRole: "agent" },
    { extensionIdentifier: "org.other.camera" },
    { minimumSystemVersion: 13 },
    { applicationIdentifier: "../arbitrary" },
    { providerEntitlement: "com.apple.developer.cmio.extension" },
  ])
    expect(() =>
      validateCameraCarrierDefinition({ ...definition, ...change }),
    ).toThrow();
});

test("OBS microphone carriers require no provider role or installation entitlement", () => {
  const obs = {
    role: "cameraCarrier",
    transport: "obs",
    applicationIdentifier: "com.pulkit.edith.cameraCarrier",
    minimumSystemVersion: 14,
  };
  expect(validateCameraCarrierDefinition(obs)).toEqual(obs);
  for (const change of [
    { providerRole: "cameraProvider" },
    { installEntitlement: "com.apple.developer.system-extension.install" },
    { transport: "unrecognized" },
  ])
    expect(() =>
      validateCameraCarrierDefinition({ ...obs, ...change }),
    ).toThrow();
});

test("contained camera archive rejects nested links rather than following them", async () => {
  const root = await mkdtemp(join(tmpdir(), "camera-regular-tree-"));
  try {
    await mkdir(join(root, "nested"));
    await writeFile(join(root, "nested/data"), "synthetic");
    await requireRegularTree(root);
    await symlink("data", join(root, "nested/link"));
    await expect(requireRegularTree(root)).rejects.toThrow();
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});
